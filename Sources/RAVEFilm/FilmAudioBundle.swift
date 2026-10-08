/*
 RAVE SDK — compressed object-audio segments

 The Atmos Objects plugin's `Segments/{n}/Bundle`: every channel of a
 segment in one response, each its own mono AAC (M4A) or Opus (Ogg) stream,
 at a fraction of the FLAC groups' size, for links that can't carry lossless
 object audio. Format in JellyfinPlugin/Jellyfin.Plugin.AtmosObjects/
 CompressedSegments.cs.

 Built to keep up with scenes far larger than a consumer Atmos track's dozen
 or so elements:
 - **Decoded in memory**, never through a temporary file per channel.
 - **In parallel**, loudest channels first (the bundle carries each one's
   level), with a deadline: on a device that can't decode everything before
   the segment plays, the quietest channels are left silent for that segment
   (`FilmAudioSegment.droppedChannels`) rather than the stream falling
   behind for good.
 - Silent channels aren't sent at all.
 */

import AudioToolbox
import AVFoundation
import Foundation
import os

/// How a `FilmServerClient` asks for a film's object audio.
public enum FilmAudioEncoding: Sendable, Hashable {
    /// The FLAC channel groups: lossless, about 3 Mbps for a dozen elements.
    case lossless
    /// One mono AAC stream per channel at `bitrate` bits per second.
    case aac(bitrate: Int)
    /// One mono Opus stream per channel. Apple platforms decode Ogg Opus
    /// through the system; the codec exists for clients without an AAC
    /// decoder of their own (the plugin serves both).
    case opus(bitrate: Int)

    var bundleCodec: String? {
        switch self {
        case .lossless: nil
        case .aac: "aac"
        case .opus: "opus"
        }
    }

    var bitrate: Int? {
        switch self {
        case .lossless: nil
        case .aac(let bitrate), .opus(let bitrate): bitrate
        }
    }
}

/// A parsed bundle: its header, and each channel's stream within the body.
struct FilmAudioBundle: Sendable {
    enum Codec: UInt16, Sendable { case aac = 1, opus = 2 }

    struct Channel: Sendable {
        /// Byte range of the stream within `data`; empty for a silent channel.
        let range: Range<Int>
        let rmsDB: Float
        let peakDB: Float
    }

    let data: Data
    let codec: Codec
    let sampleRate: Int
    let frames: Int
    let prerollFrames: Int
    let channels: [Channel]

    enum ParseError: Error, LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            switch self { case .malformed(let what): "Object-audio bundle: \(what)" }
        }
    }

    init(data: Data) throws {
        self.data = data
        func u16(_ at: Int) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian } }
        func u32(_ at: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian }) }
        func f32(_ at: Int) -> Float { Float(bitPattern: UInt32(u32(at))) }
        guard data.count >= 24, data.prefix(4) == Data("AOB1".utf8) else { throw ParseError.malformed("not a bundle") }
        guard u16(4) == 1 else { throw ParseError.malformed("version \(u16(4))") }
        guard let codec = Codec(rawValue: u16(6)) else { throw ParseError.malformed("codec \(u16(6))") }
        self.codec = codec
        sampleRate = u32(8)
        frames = u32(12)
        prerollFrames = u32(16)
        let count = u32(20)
        let header = 24 + 12 * count
        guard data.count >= header else { throw ParseError.malformed("truncated header") }
        var offset = header
        var channels: [Channel] = []
        channels.reserveCapacity(count)
        for ch in 0 ..< count {
            let entry = 24 + 12 * ch
            let length = u32(entry)
            guard offset + length <= data.count else { throw ParseError.malformed("truncated channel \(ch)") }
            channels.append(Channel(range: offset ..< offset + length, rmsDB: f32(entry + 4), peakDB: f32(entry + 8)))
            offset += length
        }
        self.channels = channels
    }

    /// Decodes into one planar Float32 buffer per scene group, the shape
    /// `FilmAudioSegment.buffers` has. Channels still undecoded at
    /// `deadline` stay silent and are counted in the result.
    func decode(groups: [[Int]], deadline: ContinuousClock.Instant?, workers: Int) -> (buffers: [AVAudioPCMBuffer], dropped: Int, failed: Int) {
        // A discrete layout: AVAudioFormat has no format for more than two
        // channels without one, and groups can hold any number.
        let format = { (channels: Int) in
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), interleaved: false,
                          channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!)
        }
        let buffers = groups.map { group -> AVAudioPCMBuffer in
            let buffer = AVAudioPCMBuffer(pcmFormat: format(group.count), frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            if let planes = buffer.floatChannelData {
                for k in 0 ..< group.count { planes[k].initialize(repeating: 0, count: frames) }
            }
            return buffer
        }
        // Where each scene channel lands.
        var destination: [Int: UnsafeMutablePointer<Float>] = [:]
        for (g, group) in groups.enumerated() {
            guard let planes = buffers[g].floatChannelData else { continue }
            for (k, channel) in group.enumerated() { destination[channel] = planes[k] }
        }

        let order = channels.indices
            .filter { !channels[$0].range.isEmpty && destination[$0] != nil }
            .sorted { channels[$0].rmsDB > channels[$1].rmsDB }
        // The package floor (macOS 14) predates Synchronization.Atomic.
        let progress = OSAllocatedUnfairLock(initialState: (next: 0, dropped: 0, failed: 0))
        let targets = destination
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, order.count))) { _ in
            while true {
                let i = progress.withLock { state in
                    defer { state.next += 1 }
                    return state.next
                }
                guard i < order.count else { return }
                if let deadline, ContinuousClock.now >= deadline {
                    progress.withLock { $0.dropped += 1 }
                    continue
                }
                let channel = order[i]
                if !decodeStream(channels[channel].range, into: targets[channel]!) {
                    progress.withLock { $0.failed += 1 }
                }
            }
        }
        let result = progress.withLock { $0 }
        return (buffers, result.dropped, result.failed)
    }

    /// One mono stream into `output` (`frames` long), the pre-roll dropped.
    private func decodeStream(_ range: Range<Int>, into output: UnsafeMutablePointer<Float>) -> Bool {
        let file = MemoryAudioFile(data.subdata(in: range))
        let hint: AudioFileTypeID = codec == .aac ? kAudioFileM4AType : 0
        var fileID: AudioFileID?
        let box = Unmanaged.passUnretained(file).toOpaque()
        guard AudioFileOpenWithCallbacks(box, memoryRead, nil, memorySize, nil, hint, &fileID) == noErr, let fileID else { return false }
        defer { AudioFileClose(fileID) }
        var extFile: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(fileID, false, &extFile) == noErr, let extFile else { return false }
        defer { ExtAudioFileDispose(extFile) }

        var client = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        guard ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else { return false }

        let chunk = 8192
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { scratch.deallocate() }
        var position = 0  // frames decoded so far, pre-roll included
        let end = prerollFrames + frames
        while position < end {
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(chunk * 4), mData: UnsafeMutableRawPointer(scratch)))
            var count = UInt32(chunk)
            guard ExtAudioFileRead(extFile, &count, &list) == noErr else { return false }
            if count == 0 { break }
            let read = Int(count)
            // The part of this chunk past the pre-roll and within the segment.
            let from = max(position, prerollFrames), to = min(position + read, end)
            if to > from {
                (output + (from - prerollFrames)).update(from: scratch + (from - position), count: to - from)
            }
            position += read
        }
        return true
    }
}

/// A stream held in memory, read by AudioFile through callbacks.
private final class MemoryAudioFile {
    let data: Data
    init(_ data: Data) { self.data = data }
}

private let memoryRead: AudioFile_ReadProc = { client, position, requested, buffer, actual in
    let file = Unmanaged<MemoryAudioFile>.fromOpaque(client).takeUnretainedValue()
    let size = Int64(file.data.count)
    guard position < size else {
        actual.pointee = 0
        return noErr
    }
    let count = Int(min(Int64(requested), size - position))
    file.data.withUnsafeBytes { raw in
        buffer.copyMemory(from: raw.baseAddress! + Int(position), byteCount: count)
    }
    actual.pointee = UInt32(count)
    return noErr
}

private let memorySize: AudioFile_GetSizeProc = { client in
    Int64(Unmanaged<MemoryAudioFile>.fromOpaque(client).takeUnretainedValue().data.count)
}

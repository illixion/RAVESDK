/*
 RAVEMedia - the audio EQ on an HLS stream.

 No `MTAudioProcessingTap` reaches HLS (see `EQAudioTap`), so for an HLS item
 the EQ plays the sound itself: the host reads and decodes the stream's audio
 (`RAVEAudioEQ.streamSource`; Hypnos's reader fetches the playlist's audio
 segments), and this plays it through an `EQProcessor` on an
 `AVSampleBufferAudioRenderer` held to the player item's clock, while the
 player, muted, goes on doing everything else: the picture, buffering,
 seeking, speed, the variant it picks.

 The clock: the item's timebase is the truth. Every 20 ms the engine reads
 it against the host clock and keeps an `AVSampleBufferRenderSynchronizer`
 at the same time and rate: started at a host time a moment ahead, moved
 when the rate changes (pause, a stall, a speed), set again when the two
 drift 30 ms apart, and reset (the reader restarted at the playhead) when
 the item jumps (a seek). Both count the host clock, so set once they stay
 together.

 Only `lead` (0.3 s of media) is ever with the renderer, so an EQ change is
 heard within that. The reader runs up to `readAhead` (6 s) ahead, so a
 slow segment fetch doesn't starve it.

 The player is muted only while this is sounding. Before it has primed,
 after a seek until it has primed again, if the reader falls behind the
 playhead, and for good if the reader fails, the player's own sound plays
 (unequalised) instead of silence. Whoever else mutes the player is heard:
 a write to `isMuted` while this holds it muted becomes the listener's mute,
 which this applies to its renderer. `volume` is left to the player and
 copied.

 What it copies from the player: volume, mute, time-pitch algorithm, and on
 visionOS the spatial audio experience (`intendedSpatialAudioExperience`,
 which RAVEMedia's spatial policy and the Cinema set on the player) and the
 item's allowed spatialisation formats. An item lent to a RealityKit
 `VideoPlayerComponent` has its sound placed at that entity by AVPlayer; a
 renderer can't be, so there the sound follows the experience alone.

 Not while AirPlay video is active (the TV plays the player's own sound).
 */

import AVFoundation
import CoreMedia
import Foundation
import os

/// A stretch of a stream's decoded audio, on the player item's timeline.
public struct EQStreamChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// Seconds on the item's timeline of the buffer's first frame.
    public let time: Double
    public init(buffer: AVAudioPCMBuffer, time: Double) { self.buffer = buffer; self.time = time }
}

/// A stream's audio from some time on, a chunk at a time; nil at its end.
public typealias EQStreamReader = @Sendable () async throws -> EQStreamChunk?

/// Makes a reader for `item`'s audio from `start` seconds, or nil when the
/// host can't read this item. Called again after every seek and audio switch.
public typealias EQStreamSource = @MainActor (_ item: AVPlayerItem, _ start: Double) async throws -> EQStreamReader?

/// One HLS item's equalised sound, for as long as the item lives.
@MainActor
public final class EQStreamPlayback {
    public private(set) weak var player: AVPlayer?
    public private(set) weak var item: AVPlayerItem?
    /// The EQ's sound is what plays (the player is muted under it).
    public private(set) var isSounding = false
    /// Why it stopped for good, if it did.
    public private(set) var failure: String?

    let engine: EQStreamEngine
    /// Every live one, whichever EQ made it, for `AVPlayer.listenerIsMuted`.
    static let live = NSHashTable<EQStreamPlayback>.weakObjects()
    private weak var eq: RAVEAudioEQ?
    private let onResult: (@MainActor (EQAttachResult) -> Void)?
    /// The listener's mute, which the player shows while this isn't sounding.
    private var listeningMuted: Bool
    private var writingMute = false
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?
    private var poll: Task<Void, Never>?

    init(player: AVPlayer, item: AVPlayerItem, eq: RAVEAudioEQ, source: @escaping EQStreamSource,
         onResult: (@MainActor (EQAttachResult) -> Void)?) {
        self.player = player
        self.item = item
        self.eq = eq
        self.onResult = onResult
        listeningMuted = player.isMuted
        let processor = eq.makeProcessor()
        let itemBox = WeakItem(item)
        engine = EQStreamEngine(processor: processor) { start in
            guard let item = await itemBox.item else { return nil }
            return try await source(item, start)
        }
        engine.onSounding = { [weak self] sounding in
            Task { @MainActor in self?.setSounding(sounding) }
        }
        engine.onFailure = { [weak self] message in
            Task { @MainActor in self?.fail(message) }
        }
        observations.append(player.observe(\.isMuted, options: [.new]) { [weak self] player, _ in
            MainActor.assumeIsolated { self?.playerMuteChanged(player.isMuted) }
        })
        observations.append(player.observe(\.volume, options: [.initial, .new]) { [weak self] player, _ in
            let volume = player.volume
            MainActor.assumeIsolated { self?.engine.setVolume(volume) }
        })
        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
            // Another audio rendition: read that one from the playhead.
            MainActor.assumeIsolated { self?.engine.restartAtPlayhead() }
        }
        Self.live.add(self)
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.update() { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    isolated deinit {
        poll?.cancel()
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        engine.stop()
    }

    /// Stops it and gives the player its sound back.
    public func stop() {
        poll?.cancel()
        poll = nil
        engine.stop()
        setSounding(false)
        observations.removeAll()
    }

    /// Follows the EQ, the item's state and the player's; false once there is nothing left to follow.
    @discardableResult
    func update() -> Bool {
        guard let player, let item, let eq else {
            stop()
            return false
        }
        #if os(visionOS)
        let airPlaying = false // no AirPlay video from a headset
        #else
        let airPlaying = player.isExternalPlaybackActive
        #endif
        let wanted = failure == nil && eq.isActive && player.currentItem === item
            && item.status == .readyToPlay && !airPlaying
        if wanted, !engine.isRunning, let timebase = item.timebase {
            engine.start(timebase: timebase)
        } else if !wanted, engine.isRunning {
            engine.stop()
            setSounding(false)
        }
        if engine.isRunning {
            engine.setPitch(item.audioTimePitchAlgorithm)
            #if os(visionOS)
            engine.setSpatial(experience: player.intendedSpatialAudioExperience,
                              formats: item.allowedAudioSpatializationFormats)
            #endif
        }
        return true
    }

    private func setSounding(_ sounding: Bool) {
        guard sounding != isSounding else { return }
        isSounding = sounding
        engine.setMuted(listeningMuted)
        writingMute = true
        player?.isMuted = sounding ? true : listeningMuted
        writingMute = false
    }

    private func playerMuteChanged(_ muted: Bool) {
        guard !writingMute else { return }
        listeningMuted = muted
        engine.setMuted(muted)
        if isSounding, !muted {
            // The listener unmuted: that is our renderer's sound, not the player's.
            writingMute = true
            player?.isMuted = true
            writingMute = false
        }
    }

    /// The listener's mute, whatever the player shows while this sounds.
    public var isListenerMuted: Bool { isSounding ? listeningMuted : (player?.isMuted ?? listeningMuted) }

    private func fail(_ message: String?) {
        guard failure == nil else { return }
        failure = message ?? "no audio"
        engine.stop()
        setSounding(false)
        if let message {
            RAVEMediaLog.audioEQ.error("Stream equalizer stopped: \(message, privacy: .private)")
            onResult?(.failed(message))
        } else {
            onResult?(.noAudioTrack)
        }
    }
}

/// An item to hand the reader factory across isolation, weakly.
private final class WeakItem: @unchecked Sendable {
    @MainActor weak var item: AVPlayerItem?
    @MainActor init(_ item: AVPlayerItem) { self.item = item }
}

/// The real-time half: reading ahead, feeding the renderer, holding the clock.
/// Everything but the setters runs on `queue`.
nonisolated final class EQStreamEngine: @unchecked Sendable {
    /// Media seconds with the renderer ahead of the playhead.
    static let lead = 0.3
    /// How far ahead of the playhead the reader decodes.
    static let readAhead = 6.0
    /// The renderer and the item may drift this far apart before they're set again.
    static let driftLimit = 0.03

    let renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let processor: EQProcessor
    private let makeReader: @Sendable (Double) async throws -> EQStreamReader?
    private let queue = DispatchQueue(label: "RAVEMedia.EQStream", qos: .userInteractive)
    private let hostClock = CMClockGetHostTimeClock()

    var onSounding: (@Sendable (Bool) -> Void)?
    /// The stream path gave up; nil when there was nothing to read.
    var onFailure: (@Sendable (String?) -> Void)?

    // Shared with the reader task and the main actor.
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private struct Shared {
        var running = false
        var generation = 0
        /// How far the decoded audio reaches past the playhead, for the reader's back-pressure.
        var ahead = 0.0
    }

    // Queue state.
    private var timebase: CMTimebase?
    private var timer: DispatchSourceTimer?
    private var readerTask: Task<Void, Never>?
    private var pending: [EQStreamChunk] = []
    private var pendingEnd: Double?
    private var readerStart = 0.0
    private var readerDone = false
    /// The next frame to enqueue, in the current rate's frames; nil after a flush.
    private var nextFrame: Int64?
    private var enqueuedEnd = 0.0
    private var synced = false
    private var syncedRate: Float64 = 0
    private var sounding = false
    private var format: (rate: Double, channels: Int, description: CMAudioFormatDescription)?

    init(processor: EQProcessor, makeReader: @escaping @Sendable (Double) async throws -> EQStreamReader?) {
        self.processor = processor
        self.makeReader = makeReader
        synchronizer.addRenderer(renderer)
    }

    deinit {
        timer?.cancel()
        readerTask?.cancel()
    }

    var isRunning: Bool { shared.withLock { $0.running } }

    func start(timebase: CMTimebase) {
        shared.withLock { $0.running = true }
        queue.async { [self] in
            self.timebase = timebase
            restart(at: playhead().time)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        shared.withLock { $0.running = false; $0.generation += 1 }
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            readerTask?.cancel()
            readerTask = nil
            pending.removeAll()
            synchronizer.setRate(0, time: .zero)
            renderer.flush()
            synced = false
            nextFrame = nil
            setSounding(false)
        }
    }

    func restartAtPlayhead() {
        queue.async { [self] in
            guard timebase != nil, shared.withLock({ $0.running }) else { return }
            restart(at: playhead().time)
        }
    }

    func setVolume(_ volume: Float) { renderer.volume = volume }
    func setMuted(_ muted: Bool) { renderer.isMuted = muted }
    func setPitch(_ algorithm: AVAudioTimePitchAlgorithm) {
        if renderer.audioTimePitchAlgorithm != algorithm { renderer.audioTimePitchAlgorithm = algorithm }
    }
    #if os(visionOS)
    func setSpatial(experience: any SpatialAudioExperience, formats: AVAudioSpatializationFormats) {
        if renderer.allowedAudioSpatializationFormats != formats { renderer.allowedAudioSpatializationFormats = formats }
        if String(describing: synchronizer.intendedSpatialAudioExperience) != String(describing: experience) {
            synchronizer.intendedSpatialAudioExperience = experience
        }
    }
    #endif

    // MARK: - Queue

    /// The item's time now, and its rate.
    private func playhead(atHost host: CMTime? = nil) -> (time: Double, rate: Float64, host: CMTime) {
        let host = host ?? CMClockGetTime(hostClock)
        guard let timebase else { return (0, 0, host) }
        return (CMSyncConvertTime(host, from: hostClock, to: timebase).seconds, CMTimebaseGetRate(timebase), host)
    }

    /// Drops everything and reads again from `time`.
    private func restart(at time: Double) {
        let generation = shared.withLock { state -> Int in
            state.generation += 1
            state.ahead = 0
            return state.generation
        }
        readerTask?.cancel()
        pending.removeAll()
        pendingEnd = nil
        readerDone = false
        readerStart = time
        renderer.flush()
        synchronizer.setRate(0, time: CMTime(seconds: time, preferredTimescale: 48_000))
        synced = false
        nextFrame = nil
        enqueuedEnd = time
        setSounding(false)

        let makeReader = makeReader
        readerTask = Task.detached(priority: .userInitiated) { [weak self, shared] in
            do {
                guard let reader = try await makeReader(time) else {
                    // Not a stream the host reads (a file with no audio at all): nothing to equalise.
                    self?.failed(nil, generation: generation)
                    return
                }
                while !Task.isCancelled {
                    while shared.withLock({ $0.generation == generation && $0.ahead > Self.readAhead }) {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard shared.withLock({ $0.generation == generation && $0.running }) else { return }
                    let chunk = try await reader()
                    guard let self else { return }
                    self.queue.async {
                        guard self.shared.withLock({ $0.generation == generation }) else { return }
                        guard let chunk else { self.readerDone = true; return }
                        self.pending.append(chunk)
                        let end = chunk.time + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
                        self.pendingEnd = max(self.pendingEnd ?? end, end)
                    }
                    if chunk == nil { return }
                }
            } catch is CancellationError {
            } catch {
                self?.failed(error.localizedDescription, generation: generation)
            }
        }
    }

    private nonisolated func failed(_ message: String?, generation: Int) {
        guard shared.withLock({ $0.generation == generation && $0.running }) else { return }
        onFailure?(message)
    }

    private func tick() {
        guard shared.withLock({ $0.running }), timebase != nil else { return }
        if renderer.status == .failed {
            onFailure?(renderer.error?.localizedDescription ?? "The audio renderer failed.")
            return
        }
        let now = playhead()
        shared.withLock { $0.ahead = (pendingEnd ?? now.time) - now.time }

        // A jump: the item seeked, or wandered off what was read.
        if synced {
            let ours = CMSyncConvertTime(now.host, from: hostClock, to: synchronizer.timebase).seconds
            if abs(ours - now.time) > 0.3 { restart(at: now.time); return }
        } else if now.time < readerStart - 0.3 || now.time > max(pendingEnd ?? readerStart, readerStart) + 3 {
            restart(at: now.time)
            return
        }

        feed(playhead: now.time, rate: now.rate)

        if synced {
            let ours = CMSyncConvertTime(now.host, from: hostClock, to: synchronizer.timebase).seconds
            if now.rate != syncedRate || (now.rate > 0 && abs(ours - now.time) > Self.driftLimit) {
                setClock(rate: now.rate)
            }
            // Starved: the reader fell behind. The player's sound until it catches up.
            if now.rate > 0, enqueuedEnd < now.time + 0.02, !readerDone {
                renderer.flush()
                synced = false
                nextFrame = nil
                enqueuedEnd = now.time
                setSounding(false)
            }
        } else if enqueuedEnd >= now.time + Self.lead * 0.8 {
            setClock(rate: now.rate)
            synced = true
            setSounding(true)
        }
    }

    /// Sets the renderer's clock to the item's at a host time just ahead.
    private func setClock(rate: Float64) {
        let host = CMClockGetTime(hostClock) + CMTime(value: 40, timescale: 1000)
        let at = playhead(atHost: host)
        synchronizer.setRate(Float(at.rate), time: CMTime(seconds: at.time, preferredTimescale: 48_000), atHostTime: host)
        syncedRate = at.rate
    }

    private func setSounding(_ value: Bool) {
        guard sounding != value else { return }
        sounding = value
        onSounding?(value)
    }

    /// Hands the renderer what it needs to reach `lead` past the playhead, equalised now.
    private func feed(playhead: Double, rate: Float64) {
        let target = playhead + Self.lead * max(1, rate)
        while enqueuedEnd < target, !pending.isEmpty, renderer.isReadyForMoreMediaData {
            let chunk = pending.removeFirst()
            let sampleRate = chunk.buffer.format.sampleRate
            let frames = Int(chunk.buffer.frameLength)
            guard sampleRate > 0, frames > 0 else { continue }
            var start = Int64((chunk.time * sampleRate).rounded())
            // Before anything is queued, start at the playhead, not the segment's start.
            let floor = nextFrame ?? Int64((max(playhead, readerStart) * sampleRate).rounded())
            if let nextFrame, abs(start - nextFrame) <= 2 { start = nextFrame } // the same stream, rounding apart
            let skip = Int(max(0, floor - start))
            guard skip < frames else { continue }
            if format?.rate != sampleRate || format?.channels != Int(chunk.buffer.format.channelCount) {
                guard let description = Self.formatDescription(for: chunk.buffer.format) else {
                    onFailure?("This stream's audio format can't be played.")
                    return
                }
                processor.configure(sampleRate: sampleRate, channelCount: Int(chunk.buffer.format.channelCount))
                format = (sampleRate, Int(chunk.buffer.format.channelCount), description)
            }
            guard let format, let sample = Self.sampleBuffer(from: chunk.buffer, skipping: skip,
                                                              at: CMTime(value: start + Int64(skip), timescale: CMTimeScale(sampleRate)),
                                                              description: format.description, processor: processor) else { continue }
            renderer.enqueue(sample)
            nextFrame = start + Int64(frames)
            enqueuedEnd = Double(start + Int64(frames)) / sampleRate
        }
    }

    // MARK: - Sample buffers

    /// Interleaved float32 with the source's channel layout.
    static func formatDescription(for format: AVAudioFormat) -> CMAudioFormatDescription? {
        let channels = Int(format.channelCount)
        guard channels > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        let status: OSStatus
        if let layout = format.channelLayout {
            let size = MemoryLayout<AudioChannelLayout>.size
                + max(0, Int(layout.layout.pointee.mNumberChannelDescriptions) - 1) * MemoryLayout<AudioChannelDescription>.size
            status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: size, layout: layout.layout,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        } else {
            status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    /// `buffer` from frame `skip` on, interleaved and through the EQ, stamped `time`.
    static func sampleBuffer(from buffer: AVAudioPCMBuffer, skipping skip: Int, at time: CMTime,
                             description: CMAudioFormatDescription, processor: EQProcessor) -> CMSampleBuffer? {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength) - skip
        guard frames > 0, let source = buffer.floatChannelData else { return nil }
        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let out = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Float.self)
        if buffer.format.isInterleaved {
            out.update(from: source[0] + skip * channels, count: frames * channels)
        } else {
            for c in 0 ..< channels {
                let plane = source[c] + skip
                for i in 0 ..< frames { out[i * channels + c] = plane[i] }
            }
        }
        for c in 0 ..< channels {
            processor.process(channel: c, samples: out + c, count: frames, stride: channels)
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

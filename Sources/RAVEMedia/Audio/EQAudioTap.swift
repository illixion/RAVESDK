/*
 RAVEMedia - the audio EQ on an AVPlayerItem.

 `EQAudioTap` runs an `EQProcessor` inside an `MTAudioProcessingTap` on an
 item's audio tracks, so any file-backed `AVPlayer` source (a local video, a
 song, a progressive stream) is equalised with no change to how it plays: the
 same player, clock, speed, spatial audio and AirPlay.

 **What it cannot reach: HLS.** A tap needs real asset tracks, and an HLS
 asset has none to load (`loadTracks(.audio)` is empty). Measured on macOS 27.2
 with fMP4 and TS HLS, the tap attached through `item.tracks` after
 `readyToPlay`, before play, and through the asset: `prepare` never ran and no
 audio ever reached it. Progressive MP4 and MP3 over HTTP and files all work.
 So `attach` reports `.noAudioTrack` for such an item and leaves it
 untouched; a host shows that rather than pretending (see `RAVEAudioEQ`).

 Only the processor is shared across tracks of one item's taps: each audio
 track gets its own `EQProcessor`, because only one plays at a time but each
 `prepare` learns its own format.

 Raven had this as its Native Player's `EQAudioTap` until that player was
 removed (b2287e4 there); this is the same idea, shared.
 */

import AVFoundation
import Foundation
import MediaToolbox

/// What `RAVEAudioEQ.attach` found.
public nonisolated enum EQAttachResult: Equatable, Sendable {
    /// The tap is on the item; it filters whenever the EQ is enabled.
    case attached
    /// The item has no audio track an asset can load: HLS (never tappable), or a silent file.
    case noAudioTrack
    /// The tap could not be created or attached.
    case failed(String)

    public var isAttached: Bool { self == .attached }
}

/// The tap's callbacks and the state they share. Retained by the `MTAudioProcessingTap`
/// (through `clientInfo`) until its `finalize`.
private nonisolated final class EQTapContext: @unchecked Sendable {
    let processor: EQProcessor
    /// The format `prepare` was given; `process` leaves audio it can't filter alone.
    var supported = false
    var interleaved = false
    var channels = 2

    init(processor: EQProcessor) { self.processor = processor }
}

public nonisolated enum EQAudioTap {
    /// A tap that filters through `processor`, or nil when MediaToolbox refuses.
    public static func makeTap(processor: EQProcessor) -> MTAudioProcessingTap? {
        let context = EQTapContext(processor: processor)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storage in
                storage.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                // Float32 linear PCM is what a player item's tap delivers; anything else is left alone.
                let float = description.mFormatID == kAudioFormatLinearPCM
                    && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && description.mBitsPerChannel == 32
                context.supported = float
                context.interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                context.channels = Int(description.mChannelsPerFrame)
                if float {
                    context.processor.configure(sampleRate: description.mSampleRate, channelCount: context.channels)
                }
            },
            unprepare: { _ in },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                guard status == noErr else { return }
                let context = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard context.supported else { return }
                let count = Int(framesOut.pointee)
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                if context.interleaved {
                    guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    for channel in 0 ..< channels {
                        context.processor.process(channel: channel, samples: data + channel, count: count, stride: channels)
                    }
                } else {
                    for (channel, buffer) in buffers.enumerated() {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        context.processor.process(channel: channel, samples: data, count: count)
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap
        )
        guard status == noErr, let tap else {
            // `init` never ran, so nothing else will release the context.
            Unmanaged.passUnretained(context).release()
            return nil
        }
        return tap
    }
}

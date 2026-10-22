/*
 Hypnos - film video player

 Feeds the plugin's video segments into an AVSampleBufferDisplayLayer whose
 control timebase runs on the host clock. That clock is also where the
 Atmos audio engine anchors its render timestamps, which is the point: the
 audio can say "film time T plays at host time H" and the picture follows
 with no drift correction, because both sides count the same ticks.

 Decoding and display management are the system's. The layer receives the
 compressed samples with the format description CoreMedia builds from the
 segment's own sample entry, so a dvh1 entry with its Dolby Vision
 configuration reaches the decoder intact.

 A seek flushes the layer, parks the timebase at the target and feeds from
 the keyframe interval containing it. Samples before the target are marked
 do-not-display: they are decoded (later frames depend on them) but never
 shown. Playback resumes at a host time slightly in the future so the
 decoder has caught up to the target by the time it is due.

 A lower picture tier (`pictureHeight`, one of the index's
 `pictureHeights`: the plugin's HEVC transcode cut on the same index) is
 changed the way a seek feeds, without the seek: the next tier's segment at
 the playhead and its init are fetched while the current picture plays on,
 then the layer is flushed (the stereo tap's `onFlush` with it) and fed from
 the keyframe interval containing the playhead, frames before it hidden.
 The timebase keeps running, so the audio, which leads it, never notices.

 A `FilmPictureSource` (pictures the platform can't decode, decoded by the
 app) replaces the segments: its frames go to the same layer on the same
 timebase, so the transport and the audio clock are unchanged. They arrive
 uncompressed, so only `pictureAheadSeconds` of them are queued.

 visionOS draws the picture through RealityKit instead of the layer: a
 `VideoPlayerComponent` on `videoEntity`, fed by a renderer of its own. HDR
 and Dolby Vision through a display layer came out visibly darker and
 flatter than the same frames through the video component, which is how
 AVKit's own visionOS player draws (side by side on the device, 2026-10-10).
 That renderer has no control timebase, so an `AVSampleBufferRenderSynchronizer`
 clocks it and every change to `timebase` (start, halt, park) is made to the
 synchronizer at the same host time; both count the host clock, so they
 stay locked. A renderer no component holds throws on its first enqueue, so
 the feed waits until a view has shown the entity (`pictureAttached`).
 */

import DebugTrace
import AVFoundation
import CoreMedia
import Foundation
import Observation
#if os(visionOS)
import RealityKit
#endif
import os
import RAVEMedia

@MainActor
@Observable
public final class FilmVideoPlayer {
    #if os(visionOS)
    /// The picture's renderer, shown by the `VideoPlayerComponent` on `videoEntity`.
    public let renderer = AVSampleBufferVideoRenderer()
    /// The flat picture: RealityKit's video component on `renderer`, a plane
    /// (aspect × 1 m) for `RAVEVideoPlaneView` to place.
    public let videoEntity = Entity()
    @ObservationIgnored private let synchronizer = AVSampleBufferRenderSynchronizer()
    /// A view has shown `videoEntity`, so enqueueing is safe.
    @ObservationIgnored public var pictureAttached = false
    #else
    public let displayLayer = AVSampleBufferDisplayLayer()
    public var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }
    #endif
    /// Film time, on the host clock.
    public let timebase: CMTimebase

    public private(set) var index: FilmVideoIndex?
    /// Decoded pictures in place of the plugin's segments; see `load(_:startAt:)`.
    public private(set) var pictureSource: FilmPictureSource?
    /// A picture is loaded, from either kind of source.
    public var isLoaded: Bool { index != nil || pictureSource != nil }
    public private(set) var track: FragmentedMP4Track?
    /// The picture tier fed: nil for the film's own picture, else one of
    /// `offeredPictureHeights`.
    public private(set) var pictureHeight: Int?
    /// A tier change is fetching its first segment.
    public private(set) var isChangingPictureTier = false
    public private(set) var formatSummary = ""
    /// The picture's format as fed to the renderer, HDR static metadata included.
    public private(set) var format: CMVideoFormatDescription?
    /// Frames per second, from the first segment's sample durations.
    public private(set) var frameRate: Double?
    public private(set) var status = "Idle"
    public private(set) var isPlaying = false
    /// The frame at the last seek target is queued and the renderer can start smoothly.
    public private(set) var isPrimed = false
    /// Film time up to which samples have been enqueued.
    public private(set) var bufferedUntil: Double = 0
    public private(set) var currentSegment = 0
    /// Wall time from a seek to the clock starting (the target frame primed).
    public private(set) var lastSeekLatency: Double = 0

    /// Film seconds per second while playing, taken by the next start
    /// (`FilmPlayer.setSpeed` restarts the clock with it).
    public var rate: Double = 1
    /// How far ahead of the playhead to keep samples enqueued.
    public var aheadSeconds: Double = 12
    /// The same for decoded pictures, which are about 6 MB each at 1080p.
    public var pictureAheadSeconds: Double = 0.75
    /// How far ahead of now a resume is scheduled, so the decoder can reach the target first.
    public var startDelay: Double = 0.2
    /// How far past the playhead a tier change resumes the picture while
    /// playing: the frames up to there are decoded, not shown, so the first
    /// one shown is due after the decoder has reached it.
    public var tierChangeLead: Double = 0.25

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "FilmVideo")
    private var client: FilmServerClient?
    private var feedTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var segments: [Int: Task<FragmentedMP4Segment, Error>] = [:]
    /// Bumped by every load and stop, so a tier change finishing after one lets it be.
    private var loadGeneration = 0
    private var tierChangeGeneration = 0
    /// The seek whose first frame isn't primed yet, which a tier change
    /// landing meanwhile repeats in the new tier.
    private var pendingSeek: (target: Double, resume: Bool)?

    /// Optional compressed-picture tap for a host-owned stereo display. The
    /// samples keep their original PTS/DTS and this timebase remains the clock.
    /// Assign before seeking to prime the tap from a keyframe. Clear both hooks
    /// when the external display leaves; audio and the normal picture continue.
    @ObservationIgnored public var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    @ObservationIgnored public var onFlush: (@Sendable () -> Void)?
    /// The renderer lost its decoder and was flushed (see `recoverDecoding`);
    /// the owner re-seeks at the current position so its own clock (the
    /// Atmos audio) is re-anchored too. Without an owner the player re-seeks
    /// itself.
    @ObservationIgnored public var onDecodingInterrupted: (@MainActor () -> Void)?
    /// Flushes and re-seeks when visionOS took the picture's decoding away
    /// (another app's immersive space): the renderer then fails and drops
    /// every sample until flushed, which froze the picture on its last frame
    /// with the audio playing on (device, 2026-10-07). It watches the
    /// renderer itself, as the feed loop sleeps while buffered or paused.
    @ObservationIgnored private var decoderRecovery: DecoderRecovery?


    public init() {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        self.timebase = timebase!
        CMTimebaseSetRate(self.timebase, rate: 0)
        #if os(visionOS)
        synchronizer.addRenderer(renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        var component = VideoPlayerComponent(videoRenderer: renderer)
        component.desiredViewingMode = .mono
        videoEntity.name = "film-picture"
        videoEntity.components.set(component)
        #else
        displayLayer.controlTimebase = self.timebase
        displayLayer.videoGravity = .resizeAspect
        // A layer's dynamic range defaults to .standard, which tone-maps HDR10
        // and Dolby Vision frames down to SDR on macOS and iOS.
        if #available(macOS 26, iOS 26, *) {
            displayLayer.preferredDynamicRange = .high
        }
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        #endif
        decoderRecovery = DecoderRecovery(
            renderer: renderer,
            maximumAttempts: 40,
            onGiveUp: { [weak self] _ in
                Task { @MainActor in self?.status = "The picture's decoder could not be restarted." }
            }
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAfterDecoderLoss() }
        }
    }

    /// The renderer is flushed and fed again from the playhead; the owner's
    /// seek re-anchors its own clock with it.
    private func restartAfterDecoderLoss() {
        // Flushed even with nothing loaded: the idle player behind the shared
        // film session otherwise kept asking every second for as long as the
        // app ran (device log, 2026-10-07).
        renderer.flush()
        guard isLoaded else { return }
        if let onDecodingInterrupted {
            onDecodingInterrupted()
        } else {
            seek(to: currentTime)
        }
    }

    #if os(tvOS) || os(visionOS)
    /// What the picture is, for the display: its dynamic range (from the
    /// format, HDR metadata included) and its frame rate snapped to the
    /// standard rate it approximates. `FilmVideoView` hands this to its
    /// window's AVDisplayManager: tvOS switches the TV's mode with it, and
    /// on visionOS it is how a player declares HDR video, as AVKit's player
    /// does on its own.
    public var displayCriteria: AVDisplayCriteria? {
        guard let format else { return nil }
        let measured = frameRate ?? 24
        let standard: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]
        let rate = standard.min { abs($0 - measured) < abs($1 - measured) } ?? measured
        return AVDisplayCriteria(refreshRate: Float(rate), formatDescription: format)
    }
    #endif

    /// Current film time.
    public var currentTime: Double { CMTimebaseGetTime(timebase).seconds }
    /// The clock is running, whoever started it (the Atmos audio starts it
    /// without `play`, so `isPlaying` doesn't say).
    private var isClockRunning: Bool { CMTimebaseGetRate(timebase) != 0 }
    public var duration: Double { index?.durationSeconds ?? pictureSource?.durationSeconds ?? 0 }

    // MARK: Transport

    /// The lower tiers the loaded film offers, largest first; empty for a
    /// download, decoded pictures or a plugin older than tiers.
    public var offeredPictureHeights: [Int] { pictureSource == nil ? index?.pictureHeights ?? [] : [] }
    /// Playing a download: no tiers, and nothing to convert a picture with.
    public var isOffline: Bool { client?.offline != nil }

    /// Loads the plugin's picture of `client`'s film, at `pictureHeight`
    /// when the index offers that tier (else the original).
    public func load(_ client: FilmServerClient, startAt seconds: Double = 0, pictureHeight: Int? = nil) async {
        stop()
        let generation = loadGeneration
        self.client = client
        pictureSource = nil
        index = nil
        track = nil
        format = nil
        frameRate = nil
        self.pictureHeight = nil
        formatSummary = ""
        status = "Loading…"
        do {
            let index = try await client.videoIndex()
            let height = pictureHeight.flatMap { index.pictureHeights.contains($0) ? $0 : nil }
            let opening = index.segment(containing: seconds)
            // A tier's segment first: its run then writes the init the next
            // request waits for (an init asked for first makes one more
            // segment, at the film's start). The original's init comes first
            // as it always has.
            let initSegment: Data
            let firstData: Data?
            if height != nil {
                firstData = try await client.videoSegment(opening, height: height)
                initSegment = try await client.videoInit(height: height)
            } else {
                initSegment = try await client.videoInit()
                firstData = nil
            }
            guard generation == loadGeneration else { return }
            let track = try FragmentedMP4Track(initSegment: initSegment)
            var format = try track.makeFormatDescription()
            self.index = index
            self.track = track
            self.pictureHeight = height
            if let firstData {
                let segment = try FragmentedMP4Segment(data: firstData, track: track)
                segments[opening] = Task { segment }
            }
            // The HDR static metadata is only in the keyframes' SEI; see
            // HEVCStaticHDR. The segment request is the one the first feed
            // needs anyway, so it costs no extra round trip.
            let first = try await load(segment: opening)
            guard generation == loadGeneration else { return }
            format = Self.withStaticHDR(of: first, applyingTo: format)
            self.format = format
            // Averaged: a millisecond timescale (MKV-derived) alternates 41 and 42.
            let total = first.samples.reduce(Int64(0)) { $0 + $1.duration }
            if total > 0 {
                frameRate = Double(first.samples.count) * Double(track.timescale) / Double(total)
            }
            formatSummary = Self.summarize(format, track: track, index: index, height: height)
            logger.info("Loaded \(client.itemID, privacy: .public): \(self.formatSummary, privacy: .public)")
            status = "Ready"
            seek(to: seconds, resume: false)
        } catch {
            status = "Load failed: \(error.localizedDescription)"
            logger.error("\(self.status, privacy: .public)")
        }
    }

    /// The format with the HDR static metadata from `segment`'s first keyframe.
    private static func withStaticHDR(of segment: FragmentedMP4Segment, applyingTo format: CMVideoFormatDescription) -> CMVideoFormatDescription {
        guard let keyframe = segment.samples.first(where: \.isSync) else { return format }
        return HEVCStaticHDR.applying(HEVCStaticHDR.metadata(in: segment.data.subdata(in: keyframe.range)), to: format)
    }

    /// Feeds tier `height` (nil: the original) from the playhead on. The
    /// current picture plays until the new tier's segment there and its
    /// init are in, then the layer is flushed and fed from the keyframe
    /// before the playhead, hiding what precedes it; the clock is left
    /// running. False when nothing changed: not offered, already playing,
    /// a newer change or load took over, or the fetch failed (the old tier
    /// plays on).
    @discardableResult
    public func setPictureHeight(_ height: Int?) async -> Bool {
        guard let client, let index, pictureSource == nil else { return false }
        let height = height.flatMap { index.pictureHeights.contains($0) ? $0 : nil }
        guard height != pictureHeight || isChangingPictureTier else { return false }
        tierChangeGeneration += 1
        let change = tierChangeGeneration
        let generation = loadGeneration
        let name = Self.tierName(height)
        isChangingPictureTier = true
        defer { if change == tierChangeGeneration { isChangingPictureTier = false } }
        // Where the picture resumes if the fetch is quick. A slow one (a
        // cold transcode) resumes further on, from the same server run.
        let wanted = index.segment(containing: currentTime + (isClockRunning ? tierChangeLead : 0))
        logger.info("Picture → \(name, privacy: .public) from segment \(wanted, privacy: .public)")
        let started = ContinuousClock.now
        let track: FragmentedMP4Track
        let segment: FragmentedMP4Segment
        var format: CMVideoFormatDescription
        do {
            // The segment first, as in `load`.
            let data = try await client.videoSegment(wanted, height: height)
            track = try FragmentedMP4Track(initSegment: await client.videoInit(height: height))
            segment = try FragmentedMP4Segment(data: data, track: track)
            format = Self.withStaticHDR(of: segment, applyingTo: try track.makeFormatDescription())
        } catch {
            guard change == tierChangeGeneration, generation == loadGeneration else { return false }
            logger.error("Picture tier \(name, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard change == tierChangeGeneration, generation == loadGeneration, self.index != nil else { return false }

        feedTask?.cancel()
        segments.values.forEach { $0.cancel() }
        segments = [wanted: Task { segment }]
        self.track = track
        self.format = format
        pictureHeight = height
        formatSummary = Self.summarize(format, track: track, index: index, height: height)
        let took = ContinuousClock.now - started
        logger.info("Picture now \(self.formatSummary, privacy: .public), fetched in \(Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18, format: .fixed(precision: 2), privacy: .public)s")

        // A seek still priming, its clock parked, starts over in the new
        // tier, so whoever waits on `isPrimed` to start the clock still gets it.
        if let pendingSeek, !isPrimed, !isClockRunning {
            seek(to: pendingSeek.target, resume: pendingSeek.resume)
            return true
        }
        startTask?.cancel()
        renderer.flush()
        onFlush?()
        let target = min(currentTime + (isClockRunning ? tierChangeLead : 0), max(0, duration - 0.5))
        let first = index.segment(containing: target)
        bufferedUntil = target
        isPrimed = false
        let requested = Date()
        feedTask = Task { [weak self] in
            await self?.feed(from: first, target: target, resume: false, keepsClock: true, requested: requested)
        }
        return true
    }

    static func tierName(_ height: Int?) -> String { height.map { "\($0)p" } ?? "original" }

    /// Loads pictures decoded by `source` instead of the plugin's segments.
    public func load(_ source: FilmPictureSource, startAt seconds: Double = 0) {
        stop()
        client = nil
        index = nil
        track = nil
        pictureHeight = nil
        format = nil
        pictureSource = source
        frameRate = source.frameRate
        formatSummary = source.summary
        logger.info("Loaded decoded pictures: \(source.summary, privacy: .public)")
        status = "Ready"
        seek(to: seconds, resume: false)
    }

    public func play() {
        guard isLoaded, !isPlaying else { return }
        isPlaying = true
        start(filmTime: currentTime, atHostTime: CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.05, preferredTimescale: 1_000_000_000))
    }

    public func pause() {
        isPlaying = false
        halt()
    }

    /// Runs the timebase so `filmTime` is due at `hostTime`, at `rate`. This
    /// is the hook an external clock (the Atmos audio engine) uses to lead the picture.
    public func start(filmTime: Double, atHostTime hostTime: CMTime) {
        pendingSeek = nil
        let time = CMTime(seconds: filmTime, preferredTimescale: 1_000_000_000)
        CMTimebaseSetRateAndAnchorTime(timebase, rate: rate, anchorTime: time, immediateSourceTime: hostTime)
        #if os(visionOS)
        synchronizer.setRate(Float(rate), time: time, atHostTime: hostTime)
        #endif
    }

    private func halt() {
        CMTimebaseSetRate(timebase, rate: 0)
        #if os(visionOS)
        synchronizer.setRate(0, time: CMTimebaseGetTime(timebase))
        #endif
    }

    private func park(at seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseSetTime(timebase, time: time)
        #if os(visionOS)
        synchronizer.setRate(0, time: time)
        #endif
    }

    /// The renderer can take samples: on visionOS only once a view holds its
    /// component (see `pictureAttached`).
    private var canEnqueue: Bool {
        #if os(visionOS)
        pictureAttached
        #else
        true
        #endif
    }

    /// The picture's width over its height, from the format.
    public var pictureAspect: Float? {
        guard let format else { return nil }
        let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
        return size.width > 0 && size.height > 0 ? Float(size.width / size.height) : nil
    }

    public func seek(to seconds: Double, resume: Bool? = nil) {
        guard isLoaded else { return }
        let target = min(max(0, seconds), max(0, duration - 0.5))
        let resume = resume ?? isPlaying
        isPlaying = resume
        feedTask?.cancel()
        startTask?.cancel()
        renderer.flush()
        onFlush?()
        park(at: target)
        bufferedUntil = target
        isPrimed = false
        pendingSeek = (target, resume)
        let requested = Date()
        if let pictureSource {
            let stereo = onSampleBuffer != nil
            feedTask = Task { [weak self] in
                await self?.feed(pictureSource, target: target, stereo: stereo, resume: resume, requested: requested)
            }
            return
        }
        guard let index else { return }
        let first = index.segment(containing: target)
        segments = segments.filter { abs($0.key - first) <= 2 }
        feedTask = Task { [weak self] in
            await self?.feed(from: first, target: target, resume: resume, keepsClock: false, requested: requested)
        }
    }

    public func stop() {
        loadGeneration += 1
        tierChangeGeneration += 1
        isChangingPictureTier = false
        pendingSeek = nil
        feedTask?.cancel()
        feedTask = nil
        startTask?.cancel()
        segments.values.forEach { $0.cancel() }
        segments.removeAll()
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        onFlush?()
        halt()
        isPlaying = false
    }

    // MARK: Feeding

    /// `keepsClock`: a tier change under a running clock, which priming
    /// must not restart or re-anchor.
    private func feed(from first: Int, target: Double, resume: Bool, keepsClock: Bool, requested: Date) async {
        guard let index, let track, let format else { return }
        let timescale = track.timescale
        // Half a frame of slack so a keyframe exactly at the target is displayed.
        let hideBefore = Int64((target - 0.01) * Double(timescale))
        var primed = false
        var n = first
        while n < index.segmentStarts.count, !Task.isCancelled {
            while primed, !Task.isCancelled, bufferedUntil - currentTime > aheadSeconds {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if n + 1 < index.segmentStarts.count {
                prefetch(n + 1 ... min(n + 2, index.segmentStarts.count - 1))
            }
            let segment: FragmentedMP4Segment
            do {
                segment = try await load(segment: n)
            } catch {
                if Task.isCancelled { return }
                segments[n] = nil // retry with a fresh request
                status = "Segment \(n) failed: \(error.localizedDescription)"
                logger.error("\(self.status, privacy: .public)")
                // The clock (the sound) doesn't wait for the picture. Once it
                // is past this segment, its frames could only show late, so
                // go on to the next keyframe: retrying it forever froze the
                // picture for the rest of the film while the sound played on
                // (a plugin that never produced one segment, 2026-10-10).
                if n + 1 < index.segmentStarts.count, currentTime >= index.segmentStarts[n + 1] {
                    logger.error("Skipping video segment \(n, privacy: .public): the film is already past it")
                    n += 1
                    continue
                }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard !Task.isCancelled else { return }
            currentSegment = n

            for sample in segment.samples {
                // A suspended renderer may never report ready, so check
                // while waiting, not after.
                while !canEnqueue || !renderer.isReadyForMoreMediaData, decoderRecovery?.checkRenderer() != true, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                guard !Task.isCancelled else { return }
                // Recovery re-seeks, which starts a new feed.
                if decoderRecovery?.checkRenderer() == true { return }
                let hidden = sample.presentationTime < hideBefore
                guard let buffer = Self.makeSampleBuffer(sample, in: segment.data, format: format, timescale: timescale,
                                                         doNotDisplay: hidden)
                else { continue }
                onSampleBuffer?(buffer)
                renderer.enqueue(buffer)
                bufferedUntil = max(bufferedUntil, Double(sample.presentationTime + sample.duration) / Double(timescale))

                // Start from the first frame that will be shown. Waiting for the
                // whole segment instead deadlocks: the renderer stops accepting
                // samples once its displayable queue is full, and a parked clock
                // never drains it.
                if !primed, !hidden {
                    primed = true
                    if keepsClock {
                        isPrimed = true
                        lastSeekLatency = Date().timeIntervalSince(requested)
                    } else {
                        startTask = Task { [weak self] in
                            await self?.startWhenPrimed(target: target, resume: resume, requested: requested)
                        }
                    }
                }
            }
            segments[n - 1] = nil
            n += 1
        }
    }

    /// Feeds decoded pictures. The source starts at the target, so nothing
    /// is hidden; the layer only queues and shows them.
    ///
    /// `bufferedUntil` is observed by the transport, so it is published at
    /// most twice a second: set per frame (24 times a second), it re-rendered
    /// every view reading it, and menus in those views flickered.
    private func feed(_ source: FilmPictureSource, target: Double, stereo: Bool, resume: Bool, requested: Date) async {
        var primed = false
        var queuedUntil = target
        do {
            for try await frame in source.frames(from: target, stereo: stereo) {
                // In wall time: faster playback needs as many seconds queued, so more film.
                while primed, !Task.isCancelled, queuedUntil - currentTime > pictureAheadSeconds * max(1, rate) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                while !canEnqueue || !renderer.isReadyForMoreMediaData, decoderRecovery?.checkRenderer() != true, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                guard !Task.isCancelled else { return }
                if decoderRecovery?.checkRenderer() == true { return }
                if format == nil { format = CMSampleBufferGetFormatDescription(frame.picture) }
                if let stereo = frame.stereo { onSampleBuffer?(stereo) }
                renderer.enqueue(frame.picture)
                let end = CMSampleBufferGetPresentationTimeStamp(frame.picture) + CMSampleBufferGetDuration(frame.picture)
                queuedUntil = max(queuedUntil, end.seconds)
                if queuedUntil - bufferedUntil >= 0.5 { bufferedUntil = queuedUntil }
                if !primed {
                    primed = true
                    startTask = Task { [weak self] in
                        await self?.startWhenPrimed(target: target, resume: resume, requested: requested)
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            status = "Picture failed: \(error.localizedDescription)"
            logger.error("\(self.status, privacy: .public)")
        }
    }

    /// Starts the clock once the renderer has enough queued to play smoothly
    /// (or its queue is full), a moment in the future so the frames decoded
    /// ahead of the target are out of the way.
    private func startWhenPrimed(target: Double, resume: Bool, requested: Date) async {
        let deadline = Date().addingTimeInterval(2)
        while !Task.isCancelled, !renderer.hasSufficientMediaDataForReliablePlaybackStart,
              renderer.isReadyForMoreMediaData, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else { return }
        lastSeekLatency = Date().timeIntervalSince(requested)
        isPrimed = true
        pendingSeek = nil
        status = resume ? "Playing" : "Ready"
        if resume {
            let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: startDelay, preferredTimescale: 1_000_000_000)
            start(filmTime: target, atHostTime: host)
        }
    }

    private func prefetch(_ range: ClosedRange<Int>) {
        for n in range where segments[n] == nil {
            _ = segmentTask(n)
        }
    }

    private func load(segment n: Int) async throws -> FragmentedMP4Segment {
        try await segmentTask(n).value
    }

    private func segmentTask(_ n: Int) -> Task<FragmentedMP4Segment, Error> {
        if let existing = segments[n] { return existing }
        guard let client, let track else { return Task { throw CancellationError() } }
        let height = pictureHeight
        let task = Task.detached(priority: .userInitiated) {
            try FragmentedMP4Segment(data: try await client.videoSegment(n, height: height), track: track)
        }
        segments[n] = task
        return task
    }

    // MARK: Sample buffers

    private nonisolated static func makeSampleBuffer(
        _ sample: FragmentedMP4Segment.Sample,
        in data: Data,
        format: CMVideoFormatDescription,
        timescale: Int32,
        doNotDisplay: Bool
    ) -> CMSampleBuffer? {
        let length = sample.range.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!.advanced(by: sample.range.lowerBound),
                blockBuffer: block, offsetIntoDestination: 0, dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: sample.duration, timescale: timescale),
            presentationTimeStamp: CMTime(value: sample.presentationTime, timescale: timescale),
            decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: timescale)
        )
        var size = length
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        ) == noErr, let buffer else { return nil }

        if !sample.isSync || doNotDisplay,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if !sample.isSync {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if doNotDisplay {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return buffer
    }

    // MARK: Telemetry

    /// Codec, colour and HDR metadata as CoreMedia understood the sample entry.
    nonisolated static func summarize(_ format: CMVideoFormatDescription, track: FragmentedMP4Track, index: FilmVideoIndex,
                                      height: Int? = nil) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let atoms = (extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any])?
            .keys.sorted().joined(separator: "+") ?? "none"
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? "?"
        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? "?"
        let mastering = extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil ? " mdcv" : ""
        let lightLevel = extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil ? " clli" : ""
        let profile = index.dvProfile.map { " P\($0)" } ?? ""
        let tier = height.map { " (\($0)p tier)" } ?? ""
        return "\(fourCC(CMFormatDescriptionGetMediaSubType(format))) \(dimensions.width)×\(dimensions.height)\(tier) atoms \(atoms), "
            + "\(transfer) / \(primaries)\(mastering)\(lightLevel), server says \(index.videoRange)\(profile)"
    }

    nonisolated static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
    }
}

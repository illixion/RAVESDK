/*
 RAVEMedia - recovering a video decoder the system took away.

 visionOS withdraws video decoding from an app while another app has an
 immersive space open (and on other occasions, such as the app going to the
 background). An `AVSampleBufferVideoRenderer` then goes `.failed` with
 `requiresFlushToResumeDecoding` and drops every sample until it is flushed;
 a `VTDecompressionSession` answers `kVTInvalidSessionErr`. Neither recovers on
 its own, and after either is reset, decoding needs a key frame: pictures that
 predict from frames the old decoder held decode to nothing. Unhandled, every
 player in the portfolio froze on its last frame for good while its audio and
 transport carried on (device, 2026-10-07: Hypnos's stereo and film pictures,
 Longwave's desktop stream).

 What a player does about it differs (flush and re-show its last frame,
 flush and re-seek a file, ask a streaming host for a key frame), so that is
 the client's `recover` closure. The rest was the same in all four and is
 here: noticing the loss even while no frames are flowing, waiting while the
 app is away, retrying about once a second while decoding is still withheld
 (a reset issued then just fails again), and the key-frame gate afterwards,
 which asks again when only delta frames keep arriving.

 Not every client needs it: one whose frames never stop arriving and that has
 to recover synchronously inside its decode callback (Longwave's Moonlight
 renderer answers DR_NEED_IDR so moonlight-common-c requests the IDR) keeps
 an inline flush with the same one-second spacing.

 `recover` is always called asynchronously on this object's own queue, never
 from inside a call the client made: the renderer posts its notification from
 inside `flush` and `enqueue`, which a client typically runs under its own
 lock.
 */

import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
#endif

public final class RAVEDecoderRecovery: @unchecked Sendable {
    /// Why the client is being asked to recover; for its log line.
    public struct Reason: Sendable, CustomStringConvertible {
        public let description: String
        /// The decoder is fine and was reset already; only a key frame is
        /// missing. A sender is asked again; nothing needs flushing.
        public let needsKeyFrameOnly: Bool
        /// Counts toward `maximumAttempts`. Decoding resources withdrawn (a
        /// renderer that needs a flush, an invalidated session) can stay
        /// withdrawn for as long as another app's immersive space is open, and
        /// must never end playback; a renderer that fails with resources
        /// available is something else, and does.
        public let countsTowardLimit: Bool
        public init(_ description: String, needsKeyFrameOnly: Bool = false, countsTowardLimit: Bool = true) {
            self.description = description
            self.needsKeyFrameOnly = needsKeyFrameOnly
            self.countsTowardLimit = countsTowardLimit
        }
        public static let rendererNeedsFlush = Reason("the renderer needs a flush to resume", countsTowardLimit: false)
        public static let rendererFailed = Reason("the renderer failed")
        public static let sessionLost = Reason("the decompression session was invalidated", countsTowardLimit: false)
        public static let appReturned = Reason("the app returned", countsTowardLimit: false)
        public static let noKeyFrameYet = Reason("no key frame since asking for one", needsKeyFrameOnly: true,
                                                 countsTowardLimit: false)
    }

    private let renderer: AVSampleBufferVideoRenderer?
    private let minimumInterval: TimeInterval
    private var _assumesLossOnInterruption: Bool
    /// See `init`. Settable for a client that switches to and from decoding
    /// with VideoToolbox itself.
    public var assumesLossOnInterruption: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _assumesLossOnInterruption }
        set { lock.lock(); _assumesLossOnInterruption = newValue; lock.unlock() }
    }
    private let recover: @Sendable (Reason) -> Void
    private let maximumAttempts: Int?
    private let onGiveUp: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "com.illixion.ravemedia.decoder-recovery", qos: .userInitiated)
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    // Under `lock`.
    private var pending: Reason?
    private var lastAttempt: TimeInterval = -.infinity
    private var appInBackground = false
    private var interrupted = false
    private var awaitingKeyFrame = false
    private var retryScheduled = false
    private var cancelled = false
    /// Recoveries since the decoder last worked; drives `maximumAttempts`.
    private var attempts = 0
    private var gaveUp = false

    /// - Parameters:
    ///   - renderer: watched for `requiresFlushToResumeDecoding`, so a player
    ///     that is paused or idle (no frames to notice it with) recovers too.
    ///     Nil for a client that decodes with VideoToolbox itself.
    ///   - minimumInterval: seconds between attempts.
    ///   - assumesLossOnInterruption: treat any trip to the background as a
    ///     loss. A `VTDecompressionSession` only reports `kVTInvalidSessionErr`
    ///     on its next decode, so an idle stream would otherwise not know.
    ///   - maximumAttempts: recoveries in a row without the decoder working
    ///     again before `onGiveUp`; nil retries for as long as it takes. A loss
    ///     of decoding resources recovers on the first attempt once the app is
    ///     back; repeated failures mean something else (a stream this decoder
    ///     can't take).
    ///   - onGiveUp: called once, on this object's queue, with the last reason.
    ///   - recover: reset the decoder (flush the renderer, or drop the session)
    ///     and get a key frame (re-seek, re-show, or ask the sender). Called on
    ///     this object's queue.
    public init(
        renderer: AVSampleBufferVideoRenderer? = nil,
        minimumInterval: TimeInterval = 1,
        assumesLossOnInterruption: Bool = false,
        maximumAttempts: Int? = nil,
        onGiveUp: (@Sendable (String) -> Void)? = nil,
        recover: @escaping @Sendable (Reason) -> Void
    ) {
        self.renderer = renderer
        self.minimumInterval = minimumInterval
        self._assumesLossOnInterruption = assumesLossOnInterruption
        self.maximumAttempts = maximumAttempts
        self.onGiveUp = onGiveUp
        self.recover = recover
        observe()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Stops all recovery; call when the player is torn down.
    public func cancel() {
        lock.lock()
        cancelled = true
        pending = nil
        lock.unlock()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: Client calls

    /// Checks the renderer where the client feeds it. True when its state is
    /// bad: the client should not enqueue now (recovery has been arranged).
    @discardableResult
    public func checkRenderer() -> Bool {
        guard let renderer else { return false }
        if renderer.requiresFlushToResumeDecoding {
            noteLoss(.rendererNeedsFlush)
            return true
        }
        if renderer.status == .failed {
            noteLoss(.rendererFailed)
            return true
        }
        return false
    }

    /// The client saw its decoder fail (`kVTInvalidSessionErr`, a failed
    /// session creation, a renderer error). Recovery follows, rate-limited.
    public func noteLoss(_ reason: Reason) {
        lock.lock()
        pending = reason
        lock.unlock()
        attemptIfAllowed()
    }

    /// The key-frame gate after a recovery. True: decode this frame. False:
    /// drop it, it predicts from pictures the reset decoder never had. When
    /// only delta frames keep coming a while after asking, the request is
    /// taken to have gone missing and the client is asked to recover again.
    public func admit(isKeyFrame: Bool) -> Bool {
        lock.lock()
        guard awaitingKeyFrame else { lock.unlock(); return true }
        if isKeyFrame {
            awaitingKeyFrame = false
            attempts = 0
            lock.unlock()
            return true
        }
        let askAgain = now() - lastAttempt >= minimumInterval && !appInBackground
        if askAgain { lastAttempt = now() }
        lock.unlock()
        if askAgain { dispatchRecover(.noKeyFrameYet) }
        return false
    }

    /// The client started a decoder afresh by itself (a new stream, a seek):
    /// whatever was pending is moot.
    public func reset() {
        lock.lock()
        pending = nil
        awaitingKeyFrame = false
        interrupted = false
        attempts = 0
        gaveUp = false
        lock.unlock()
    }

    /// The client reset its decoder for its own reasons (a new format, a
    /// different decoder) and asked for a key frame: gate on it as after a
    /// recovery, asking again if it doesn't come.
    public func expectKeyFrame() {
        lock.lock()
        awaitingKeyFrame = true
        lastAttempt = now()
        lock.unlock()
    }

    // MARK: Scheduling

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func attemptIfAllowed() {
        lock.lock()
        guard !cancelled, let reason = pending else { lock.unlock(); return }
        if appInBackground {
            // Decoding isn't permitted; the return will retry.
            lock.unlock()
            return
        }
        let wait = lastAttempt + minimumInterval - now()
        if wait > 0 {
            let schedule = !retryScheduled
            retryScheduled = true
            lock.unlock()
            if schedule {
                queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.retryScheduled = false; self.lock.unlock()
                    self.attemptIfAllowed()
                }
            }
            return
        }
        if gaveUp { lock.unlock(); return }
        if reason.countsTowardLimit, let maximumAttempts, attempts >= maximumAttempts {
            gaveUp = true
            pending = nil
            lock.unlock()
            RAVEMediaLog.pipeline.error("Decoder recovery gave up after \(maximumAttempts, privacy: .public) attempts: \(reason.description, privacy: .public)")
            if let onGiveUp { queue.async { onGiveUp(reason.description) } }
            return
        }
        if reason.countsTowardLimit { attempts += 1 }
        lastAttempt = now()
        pending = nil
        interrupted = false
        awaitingKeyFrame = true
        lock.unlock()
        dispatchRecover(reason)
        // Check the renderer once the attempt has had time to take: still
        // withheld, retry (spaced by the interval); working, the count resets.
        queue.asyncAfter(deadline: .now() + minimumInterval) { [weak self] in
            guard let self, self.renderer != nil else { return }
            if !self.checkRenderer() {
                self.lock.lock(); self.attempts = 0; self.lock.unlock()
            }
        }
    }

    private func dispatchRecover(_ reason: Reason) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
            guard !cancelled else { return }
            RAVEMediaLog.pipeline.notice("Decoder recovery: \(reason.description, privacy: .public)")
            self.recover(reason)
        }
    }

    // MARK: Observation

    private func observe() {
        let center = NotificationCenter.default
        if let renderer {
            observers.append(center.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: renderer, queue: nil
            ) { [weak self] _ in
                // Posted from inside flush/enqueue; get off that stack first.
                self?.queue.async { self?.checkRenderer() }
            })
        }
        observers.append(center.addObserver(forName: RAVEAppLifecycle.didEnterBackground, object: nil, queue: nil) { [weak self] _ in
            self?.enteredBackground(appWide: true)
        })
        observers.append(center.addObserver(forName: RAVEAppLifecycle.willEnterForeground, object: nil, queue: nil) { [weak self] _ in
            self?.returned()
        })
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.enteredBackground(appWide: false)
        })
        for name in [UIApplication.didBecomeActiveNotification, UIScene.willEnterForegroundNotification,
                     UIScene.didActivateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.returned()
            })
        }
        #endif
    }

    private func enteredBackground(appWide: Bool) {
        lock.lock()
        if appWide { appInBackground = true }
        interrupted = true
        lock.unlock()
    }

    private func returned() {
        lock.lock()
        appInBackground = false
        let assumeLost = interrupted && _assumesLossOnInterruption
        interrupted = false
        if assumeLost, pending == nil { pending = .appReturned }
        // Coming back is the moment decoding is allowed again; don't make it
        // wait out an interval started while it was still withheld.
        if pending != nil { lastAttempt = -.infinity }
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.checkRenderer()
            self.attemptIfAllowed()
        }
    }
}

/*
 RAVECompanion - the device's side of discovery

 Finds hosts on the local network and knocks for a paired one's ports. A knock
 is a Bonjour record this device advertises while it wants a host — a
 listener that accepts nothing, there only to carry the record. Callers keep
 it alive by renewing a lease (`renewKnock`), so it goes away by itself once
 nothing is using that host, and the host closes its ports.
 */

import DebugLog
import Foundation
import Network
import Observation

enum RAVECompanionLog {
    static let subsystem = "com.illixion.rave"
    static let discovery = DebugLogger(subsystem: subsystem, category: "CompanionDiscovery")
    static let pairing = DebugLogger(subsystem: subsystem, category: "CompanionPairing")
    static let host = DebugLogger(subsystem: subsystem, category: "CompanionHost")
}

@MainActor
@Observable
public final class RAVECompanionLocator {
    public struct NearbyHost: Identifiable, Equatable, Sendable {
        public var id: String { macID }
        public let macID: String
        public let name: String
        public let addresses: [String]
        public let open: Bool
        public var isWindows = false
        /// Set for a host paired by dialling its fixed pairing port (Windows).
        public var pairPort: UInt16?

        public init(macID: String, name: String, addresses: [String], open: Bool, isWindows: Bool = false,
                    pairPort: UInt16? = nil) {
            self.macID = macID
            self.name = name
            self.addresses = addresses
            self.open = open
            self.isWindows = isWindows
            self.pairPort = pairPort
        }
    }

    public let namespace: RAVECompanionNamespace
    /// This device's identity towards hosts: stable, random, and not tied to
    /// anything else about the device.
    public let deviceID: String
    private let deviceName: @MainActor () -> String

    /// Hosts announcing themselves on this network, while browsing.
    public private(set) var nearby: [NearbyHost] = []

    /// An address link waiting for the app's UI to pair with it. Set by the
    /// app's URL handler; the UI clears it.
    public var pendingPairLink: RAVECompanionPairLink?

    /// A random id kept in `UserDefaults` under `key`, made on first use.
    public nonisolated static func persistentDeviceID(key: String) -> String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    public init(namespace: RAVECompanionNamespace, deviceID: String, deviceName: @escaping @MainActor () -> String) {
        self.namespace = namespace
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    private let log = RAVECompanionLog.discovery
    private var browser: NWBrowser?
    private var browseClients = 0
    private var knocks: [String: Knock] = [:]
    private var leaseTimer: Timer?

    private final class Knock {
        let listener: NWListener
        let token: String?
        var leaseUntil: Date
        var lastMinute: Int64 = .min
        init(listener: NWListener, token: String?, leaseUntil: Date) {
            self.listener = listener
            self.token = token
            self.leaseUntil = leaseUntil
        }
    }

    public static let lease: TimeInterval = 90

    // MARK: - Browsing

    /// Starts watching for hosts; balanced by `stopBrowsing`.
    public func startBrowsing() {
        browseClients += 1
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: namespace.hostServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    self?.log.error("Browsing for hosts failed: \(error.localizedDescription)")
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stopBrowsing() {
        browseClients = max(0, browseClients - 1)
        guard browseClients == 0 else { return }
        browser?.cancel()
        browser = nil
        nearby = []
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        typealias Key = RAVECompanionDiscovery.Key
        var hosts: [String: NearbyHost] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let macID = txt[Key.hostID] else { continue }
            var name = "Mac"
            if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
            let addresses = (txt[Key.addresses] ?? "").split(separator: ",").map(String.init)
            let host = NearbyHost(
                macID: macID, name: name, addresses: addresses,
                open: txt[Key.open] == "1",
                isWindows: txt[Key.os] == "windows",
                pairPort: txt[Key.pairPort].flatMap(UInt16.init)
            )
            // The same record arrives once per interface; keep the fullest.
            if let existing = hosts[macID], existing.addresses.count >= addresses.count, existing.open || !host.open {
                continue
            }
            hosts[macID] = host
        }
        nearby = hosts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Locating a paired host

    /// Knocks for a paired host and waits for it to open its ports. Returns
    /// the LAN address to connect to, or nil when the host isn't on this
    /// network (the caller then uses the address it was saved with).
    ///
    /// Waits up to 1.5 s for the host's record to appear — away from home it
    /// never will, and that wait is all connecting by address costs — then up
    /// to 3 s in all for the host to say its ports are open.
    public func locate(macID: String, token: String) async -> String? {
        renewKnock(macID: macID, token: token)
        startBrowsing()
        defer { stopBrowsing() }
        let start = ContinuousClock.now
        var seen: NearbyHost?
        while true {
            let elapsed = ContinuousClock.now - start
            if let host = nearby.first(where: { $0.macID == macID }) {
                seen = host
                if host.open || elapsed > .seconds(3) { break }
            } else if elapsed > .milliseconds(1500) {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let seen else {
            log.info("Paired host not found nearby; using its saved address")
            return nil
        }
        if !seen.open {
            log.info("Paired host found but hasn't opened its ports yet")
        }
        return seen.addresses.first
    }

    /// Keeps knocking for `macID` for another `lease` seconds. Callers renew
    /// while they use the host; the knock is withdrawn once nobody has for a
    /// while.
    public func renewKnock(macID: String, token: String) {
        let until = Date().addingTimeInterval(Self.lease)
        if let knock = knocks[macID], knock.token != nil {
            knock.leaseUntil = until
            return
        }
        startKnock(macID: macID, token: token, until: until)
    }

    /// Withdraws the knock for `macID` now.
    public func endKnock(macID: String) {
        knocks.removeValue(forKey: macID)?.listener.cancel()
    }

    /// Advertises a pairing request to `macID` until `endKnock`.
    public func requestPairing(macID: String) {
        endKnock(macID: macID)
        startKnock(macID: macID, token: nil, until: .distantFuture)
    }

    private func startKnock(macID: String, token: String?, until: Date) {
        endKnock(macID: macID)
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            log.error("Could not knock: \(error.localizedDescription)")
            return
        }
        listener.newConnectionHandler = { $0.cancel() }
        let knock = Knock(listener: listener, token: token, leaseUntil: until)
        knocks[macID] = knock
        refreshRecord(knock, macID: macID)
        listener.start(queue: .main)
        ensureLeaseTimer()
    }

    /// The record names the host it is for and carries a tag that expires
    /// within minutes, so it's re-issued as the minute turns.
    private func refreshRecord(_ knock: Knock, macID: String) {
        typealias Key = RAVECompanionDiscovery.Key
        let minute = RAVECompanionDiscovery.minute(of: Date())
        guard minute != knock.lastMinute else { return }
        knock.lastMinute = minute
        var txt = NWTXTRecord()
        txt[Key.version] = RAVECompanionDiscovery.version
        txt[Key.hostID] = macID
        txt[Key.deviceID] = deviceID
        txt[Key.name] = deviceName()
        if let token = knock.token {
            txt[Key.tag] = RAVECompanionDiscovery.knockTag(namespace, token: token, hostID: macID,
                                                           deviceID: deviceID, minute: minute)
        } else {
            txt[Key.pairRequest] = "1"
        }
        knock.listener.service = NWListener.Service(
            name: "\(namespace.labelPrefix) \(deviceID.prefix(6)) \(macID.prefix(6))",
            type: namespace.knockServiceType,
            txtRecord: txt
        )
    }

    private func ensureLeaseTimer() {
        guard leaseTimer == nil else { return }
        leaseTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickLeases() }
        }
    }

    private func tickLeases() {
        let now = Date()
        for (macID, knock) in knocks {
            if now > knock.leaseUntil {
                endKnock(macID: macID)
            } else {
                refreshRecord(knock, macID: macID)
            }
        }
        if knocks.isEmpty {
            leaseTimer?.invalidate()
            leaseTimer = nil
        }
    }
}

extension RAVECompanionLocator.NearbyHost {
    /// What to dial for a host that takes direct pairing.
    public func directPairLink(_ namespace: RAVECompanionNamespace) -> RAVECompanionPairLink? {
        guard let pairPort, !addresses.isEmpty else { return nil }
        return RAVECompanionPairLink(namespace, macID: macID, name: name, port: pairPort, addresses: addresses)
    }
}

/*
 RAVECompanion - the host's side of discovery (macOS)

 Announces this Mac on the local network and watches for devices knocking to
 connect or pair. The announcement is a bare mDNS registration — nothing
 listens behind it — so having it up costs no open port. Ports open only while
 a paired device's knock is present (or connections by address are allowed),
 which the owner reads from `knockActive`.

 Two traps, both from Longwave: every call on a `DNSServiceRef` must come from
 the queue it is scheduled on, or mDNSResponder drops it
 (`kDNSServiceErr_ServiceNotRunning`) and the record vanishes; and macOS can
 keep enforcing a stale Local Network denial (`kDNSServiceErr_PolicyDenied`)
 after the user has allowed it, which only a reboot cleared (2026-10-02).
 */

#if os(macOS)
import DebugLog
import Foundation
import Network
import Observation
import SystemConfiguration
import dnssd

@MainActor
@Observable
public final class RAVECompanionPresence {
    /// A device asking to pair, by its id and the name it gave.
    public struct PairRequest: Equatable, Sendable {
        public let deviceID: String
        public let name: String
    }

    public let namespace: RAVECompanionNamespace
    /// A paired device is knocking now, or stopped less than `knockGrace` ago.
    public private(set) var knockActive = false
    /// Names of the paired devices knocking right now, for a status line.
    public private(set) var knockingDevices: [String] = []
    /// Set when macOS refuses this app local network access, which blocks
    /// both the announcement and seeing devices knock.
    public private(set) var localNetworkDenied = false
    /// Fired for each new pairing request.
    @ObservationIgnored public var onPairRequest: ((PairRequest) -> Void)?
    /// Fired whenever `knockActive` changes.
    @ObservationIgnored public var onKnockChange: (() -> Void)?
    /// The tokens a knock from a device may be tagged with.
    @ObservationIgnored public var knockTokens: (String) -> [String] = { _ in [] }

    /// The id devices remember this Mac by. Stable across launches and
    /// independent of any token.
    public let macID: String

    public var macName: String { Host.current().localizedName ?? "Mac" }

    private static let knockGrace: Duration = .seconds(30)

    private let log = RAVECompanionLog.host
    private let queue = DispatchQueue(label: "com.illixion.rave.companion.presence")
    @ObservationIgnored private var registration: DNSServiceRef?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    private var open = false
    private var validKnocks: [String: String] = [:]
    private var seenPairRequests: Set<String> = []
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    /// The latest browse results, re-checked as tags age: a device whose app
    /// was suspended can leave its record behind with a tag that has expired.
    @ObservationIgnored private var lastResults: Set<NWBrowser.Result> = []
    @ObservationIgnored private var recheckTimer: Timer?

    /// - Parameter macIDKey: the `UserDefaults` key the host's id is kept
    ///   under (Longwave: `companionMacID`).
    public init(namespace: RAVECompanionNamespace, macIDKey: String) {
        self.namespace = namespace
        self.macID = RAVECompanionLocator.persistentDeviceID(key: macIDKey)
    }

    public func start() {
        register()
        startBrowsing()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRecord() }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handle(self.lastResults)
            }
        }
    }

    /// Paired devices changed: re-judge the knocks already seen.
    public func devicesChanged() {
        handle(lastResults)
    }

    /// Whether the ports are listening, so a knocking device knows when to
    /// connect.
    public func setOpen(_ open: Bool) {
        guard open != self.open else { return }
        self.open = open
        updateRecord()
    }

    // MARK: - Announcement

    /// DNS-SD invokes this callback on `queue`, which is deliberately not the
    /// main actor. Keep the C callback itself nonisolated; closures written
    /// inside this @MainActor type otherwise inherit actor isolation and trap
    /// when mDNSResponder calls them from its dispatch queue.
    private func register() {
        let txt = record()
        var ref: DNSServiceRef?
        let status = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0, macName, namespace.hostServiceType, nil, nil,
                // No socket behind the record; SRV needs a port, so the
                // discard port stands in.
                UInt16(9).bigEndian,
                UInt16(txt.count), bytes.baseAddress,
                raveCompanionPresenceRegistrationReply,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard status == kDNSServiceErr_NoError, let ref else {
            log.error("Could not announce this Mac on the local network (\(status, privacy: .public))")
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        registration = ref
        log.info("Announcing this Mac to nearby devices")
    }

    /// After a failure the reference is dead; drop it, and try again a little
    /// later in case access was just granted.
    fileprivate func registrationFinished(denied: Bool, failed: Bool) {
        if denied { localNetworkDenied = true }
        if !failed {
            localNetworkDenied = false
            return
        }
        guard let registration else { return }
        nonisolated(unsafe) let ref = registration
        self.registration = nil
        queue.async { DNSServiceRefDeallocate(ref) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.registration == nil else { return }
            self.register()
        }
    }

    private func updateRecord() {
        guard let registration else { return }
        let txt = record()
        nonisolated(unsafe) let ref = registration
        queue.async {
            txt.withUnsafeBytes { bytes in
                _ = DNSServiceUpdateRecord(ref, nil, 0, UInt16(txt.count), bytes.baseAddress, 0)
            }
        }
    }

    private func record() -> Data {
        typealias Key = RAVECompanionDiscovery.Key
        var entries: [String] = [
            "\(Key.version)=\(RAVECompanionDiscovery.version)",
            "\(Key.hostID)=\(macID)",
            "\(Key.open)=\(open ? "1" : "0")",
        ]
        let addresses = Self.lanAddresses()
        if !addresses.isEmpty {
            entries.append("\(Key.addresses)=\(addresses.joined(separator: ","))")
        }
        var data = Data()
        for entry in entries {
            let bytes = Array(entry.utf8.prefix(255))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    /// This Mac's IPv4 LAN addresses, wired interfaces first: a device that
    /// can reach both should use the cable.
    public nonisolated static func lanAddresses() -> [String] {
        var wired: Set<String> = []
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                if let type = SCNetworkInterfaceGetInterfaceType(interface),
                   type == kSCNetworkInterfaceTypeEthernet,
                   let name = SCNetworkInterfaceGetBSDName(interface) {
                    wired.insert(name as String)
                }
            }
        }
        var results: [(address: String, wired: Bool)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            // Real LAN interfaces only: not VPN tunnels, bridges or AWDL.
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254.") else { continue }
            results.append((text, wired.contains(name)))
        }
        return results.sorted { $0.wired && !$1.wired }.map(\.address)
    }

    /// Every IPv4 address a device might reach this Mac on, for the address
    /// link: the LAN ones first, then tunnels such as Tailscale (100.64/10)
    /// and any other non-loopback interface.
    public nonisolated static func reachableAddresses() -> [String] {
        var others: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return lanAddresses() }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254.") else { continue }
            others.append(text)
        }
        let lan = lanAddresses()
        var seen = Set(lan)
        return lan + others.filter { seen.insert($0).inserted }
    }

    // MARK: - Knocks

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: namespace.knockServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.handle(results) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                RAVECompanionLog.host.error("Watching for devices failed: \(error.localizedDescription)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        typealias Key = RAVECompanionDiscovery.Key
        lastResults = results
        var knocks: [String: String] = [:]
        var pairRequests: Set<String> = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  txt[Key.hostID] == macID,
                  let deviceID = txt[Key.deviceID] else { continue }
            let name = txt[Key.name] ?? "Vision Pro"
            if txt[Key.pairRequest] == "1" {
                pairRequests.insert(deviceID)
                if !seenPairRequests.contains(deviceID) {
                    seenPairRequests.insert(deviceID)
                    log.info("Pairing request from a device")
                    onPairRequest?(PairRequest(deviceID: deviceID, name: name))
                }
            } else if let tag = txt[Key.tag],
                      knockTokens(deviceID).contains(where: {
                          RAVECompanionDiscovery.isValidKnock(namespace, tag: tag, token: $0, hostID: macID,
                                                              deviceID: deviceID)
                      }) {
                knocks[deviceID] = name
            }
        }
        // A request is answered once per appearance: withdrawn and made again,
        // it asks again.
        seenPairRequests.formIntersection(pairRequests)
        let arrived = Set(knocks.keys).subtracting(validKnocks.keys)
        if !arrived.isEmpty { log.info("\(arrived.count, privacy: .public) paired device(s) knocking") }
        validKnocks = knocks
        knockingDevices = knocks.values.sorted()
        if !knocks.isEmpty {
            graceTask?.cancel()
            graceTask = nil
            setKnockActive(true)
        } else if knockActive, graceTask == nil {
            graceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.knockGrace)
                guard let self, !Task.isCancelled else { return }
                self.graceTask = nil
                if self.validKnocks.isEmpty { self.setKnockActive(false) }
            }
        }
    }

    private func setKnockActive(_ active: Bool) {
        guard active != knockActive else { return }
        knockActive = active
        onKnockChange?()
    }
}

/// C callback invoked on `RAVECompanionPresence.queue`. This must stay outside
/// the @MainActor type so Swift does not insert an actor check on DNS-SD's
/// callback queue.
private nonisolated func raveCompanionPresenceRegistrationReply(
    _ service: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ errorCode: DNSServiceErrorType,
    _ name: UnsafePointer<CChar>?,
    _ type: UnsafePointer<CChar>?,
    _ domain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let presence = Unmanaged<RAVECompanionPresence>.fromOpaque(context).takeUnretainedValue()
    let denied = errorCode == kDNSServiceErr_PolicyDenied
    let failed = errorCode != kDNSServiceErr_NoError
    Task { @MainActor in
        if errorCode == kDNSServiceErr_NoError {
            RAVECompanionLog.host.info("Announced on the local network")
        } else {
            RAVECompanionLog.host.error("Announcement failed (\(errorCode, privacy: .public))")
        }
        presence.registrationFinished(denied: denied, failed: failed)
    }
}
#endif

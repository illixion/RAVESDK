/*
 RAVECompanion - the host's fixed pairing port

 The port (`RAVECompanionNamespace.defaultPairPort`) a device dials when it
 can't see the host over Bonjour, after opening the address link the host
 AirDropped or copied to it. Plain TCP: the six-digit exchange that runs on it
 protects everything, exactly as on the Bonjour-found listener. The owner
 decides when it listens (Longwave: while connections by address are allowed,
 or for ten minutes after an address link was sent).
 */

import DebugLog
import Foundation
import Network

@MainActor
public final class RAVEDirectPairingListener {
    public var onConnection: ((NWConnection) -> Void)?
    public private(set) var isListening = false
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.illixion.rave.companion.direct-pairing")
    private let log = RAVECompanionLog.pairing

    public init(namespace: RAVECompanionNamespace) {
        self.port = namespace.defaultPairPort
    }

    public func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        isListening = listening
        if listening { open() } else { close() }
    }

    private func open() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, let onConnection = self.onConnection else { connection.cancel(); return }
                    onConnection(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor [weak self] in
                        self?.log.error("Direct pairing listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.close()
                        self?.isListening = false
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            log.info("Direct pairing port open")
        } catch {
            log.error("Couldn't open the direct pairing port: \(error.localizedDescription, privacy: .public)")
            isListening = false
        }
    }

    private func close() {
        listener?.cancel()
        listener = nil
    }
}

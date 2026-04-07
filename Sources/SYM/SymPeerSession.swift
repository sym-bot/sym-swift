//
//  SymPeerSession.swift
//  SYM
//
//  Per-peer NWConnection lifecycle with length-prefixed JSON framing.
//  Handles handshake, heartbeat, send/receive for a single SYM peer.
//
//  Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.
//

import Foundation
import Network
import os.log

// MARK: - Session Delegate

/// Delegate for peer session lifecycle events.
protocol SymPeerSessionDelegate: AnyObject {
    /// Handshake completed — peer identified.
    func session(_ session: SymPeerSession, didHandshakeWith nodeId: String, name: String)

    /// A frame was received from the peer.
    func session(_ session: SymPeerSession, didReceive frame: SymFrame)

    /// The session disconnected.
    func session(_ session: SymPeerSession, didDisconnectWith reason: String)
}

// MARK: - Peer Session

/// Manages a single NWConnection to a SYM peer.
/// See MMP v0.2.0 Section 4 (Transport, Layer 1) and Section 5 (Connection, Layer 2).
///
/// Framing: [4-byte big-endian u32 length][JSON SymFrame]
/// Same wire format as Node.js SYM. Handles handshake, heartbeat, and send/receive lifecycle.
final class SymPeerSession {

    // MARK: - Properties

    /// Serial queue protecting mutable session state.
    private let stateQueue = DispatchQueue(label: "bot.sym.peer-state")

    /// The peer's node ID (set after handshake). Thread-safe read.
    private var _peerNodeId: String?
    var peerNodeId: String? { stateQueue.sync { _peerNodeId } }

    /// The peer's display name (set after handshake). Thread-safe read.
    private var _peerName: String?
    var peerName: String? { stateQueue.sync { _peerName } }

    /// Whether the handshake is complete and the session is active. Thread-safe read.
    private var _isActive = false
    var isActive: Bool { stateQueue.sync { _isActive } }

    /// Last time a frame was received. Thread-safe read.
    private var _lastSeen = Date()
    var lastSeen: Date { stateQueue.sync { _lastSeen } }

    /// True after the session has emitted its terminal disconnect notification.
    /// Guards against double-notify when both `stateUpdateHandler(.failed)` and
    /// the in-flight `readChunk` receive completion fire for the same failure.
    private var _didNotifyDisconnect = false

    private let connection: NWConnection
    private let identity: SymIdentity
    let isOutbound: Bool
    private let queue: DispatchQueue
    private let parser = SymFrameParser()
    private var heartbeatTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "bot.sym", category: "PeerSession")

    weak var delegate: SymPeerSessionDelegate?

    // MARK: - Init

    /// Outbound connection to a Bonjour endpoint.
    init(outboundTo endpoint: NWEndpoint, identity: SymIdentity) {
        let parameters = NWParameters.tcp
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.identity = identity
        self.isOutbound = true
        self.queue = DispatchQueue(label: "bot.sym.session.\(UUID().uuidString.prefix(8))", qos: .userInitiated)
    }

    /// Outbound connection to a direct host:port.
    init(remoteHost host: String, port: UInt16, identity: SymIdentity) {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fatalError("[SYM] Invalid port: \(port)")
        }
        let parameters = NWParameters.tcp
        self.connection = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.identity = identity
        self.isOutbound = true
        self.queue = DispatchQueue(label: "bot.sym.session.\(UUID().uuidString.prefix(8))", qos: .userInitiated)
    }

    /// Inbound connection accepted from NWListener.
    init(inbound connection: NWConnection, identity: SymIdentity) {
        self.connection = connection
        self.identity = identity
        self.isOutbound = false
        self.queue = DispatchQueue(label: "bot.sym.session.\(UUID().uuidString.prefix(8))", qos: .userInitiated)
    }

    deinit {
        heartbeatTask?.cancel()
        connection.cancel()
    }

    // MARK: - Lifecycle

    /// Start the connection and begin handshake.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
        connection.start(queue: queue)
    }

    /// Gracefully disconnect.
    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateQueue.async { self._isActive = false }
            self.heartbeatTask?.cancel()
            self.connection.cancel()
        }
    }

    // MARK: - Send

    /// Send a frame to the peer.
    func send(_ frame: SymFrame) {
        queue.async { [weak self] in
            self?.sendOnQueue(frame)
        }
    }

    private func sendOnQueue(_ frame: SymFrame) {
        guard let data = try? frame.serialize() else {
            logger.error("[SYM] session: failed to serialize frame")
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("[SYM] session: send failed: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - Receive

    private func startReceiving() {
        readChunk()
    }

    private func readChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let data = content, !data.isEmpty {
                let frames = self.parser.feed(data)
                for frame in frames {
                    self.stateQueue.async { self._lastSeen = Date() }
                    self.handleFrame(frame)
                }
            }

            if isComplete || error != nil {
                self.handleDisconnect(error: error)
                return
            }

            self.readChunk()
        }
    }

    // MARK: - Frame Handling

    private func handleFrame(_ frame: SymFrame) {
        if !isActive {
            // First frame must be handshake
            guard frame.type == .handshake, let nodeId = frame.nodeId, let name = frame.name else {
                logger.warning("[SYM] session: expected handshake, got \(frame.type.rawValue)")
                disconnect()
                return
            }
            stateQueue.async { [self] in _peerNodeId = nodeId }
            stateQueue.async { [self] in _peerName = name }
            stateQueue.async { [self] in _isActive = true }
            startHeartbeat()
            logger.info("[SYM] session: handshake complete with \(name) (\(nodeId.prefix(8)))")
            delegate?.session(self, didHandshakeWith: nodeId, name: name)
            return
        }

        delegate?.session(self, didReceive: frame)
    }

    // MARK: - Connection State

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("[SYM] session: connection ready (outbound=\(self.isOutbound))")
            startReceiving()
            // Handshake is sent by SymNode after peer registration (with publicKey + e2ePublicKey)

        case .failed(let error):
            logger.error("[SYM] session: connection failed: \(error.localizedDescription)")
            // Release Apple's underlying nw_endpoint_flow now. Without this
            // cancel, the failed flow lingers and any later cleanup logs
            // "nw_endpoint_flow_failed_with_error ... already failing, returning".
            connection.cancel()
            notifyDisconnect(reason: error.localizedDescription)

        case .cancelled:
            notifyDisconnect(reason: "Connection cancelled")

        case .waiting(let error):
            logger.info("[SYM] session: connection waiting: \(error.localizedDescription)")

        case .preparing:
            logger.info("[SYM] session: connection preparing...")

        default:
            break
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                guard !Task.isCancelled, let self else { break }

                let elapsed = Date().timeIntervalSince(self.lastSeen)
                if elapsed > 15 {
                    self.logger.warning("[SYM] session: heartbeat timeout for \(self.peerName ?? "unknown")")
                    self.disconnect()
                    break
                } else if elapsed > 5 {
                    self.send(.ping())
                }
            }
        }
    }

    // MARK: - Disconnect

    private func handleDisconnect(error: NWError?) {
        // Receive completion fired with EOF or error. Cancel the connection
        // so Apple's flow object is released; the resulting `.cancelled`
        // state will reach `handleConnectionState`, but `notifyDisconnect`
        // is idempotent so the delegate is still only called once.
        connection.cancel()
        let reason = error?.localizedDescription ?? "Connection closed"
        logger.info("[SYM] session: disconnected: \(reason)")
        notifyDisconnect(reason: reason)
    }

    /// Idempotent terminal disconnect. Only the first caller emits the
    /// delegate notification and tears down session state; subsequent
    /// callers are no-ops. This collapses the two failure paths
    /// (`stateUpdateHandler(.failed)` + `readChunk` error completion)
    /// into one upstream notification.
    private func notifyDisconnect(reason: String) {
        let shouldNotify: Bool = stateQueue.sync {
            guard !_didNotifyDisconnect else { return false }
            _didNotifyDisconnect = true
            _isActive = false
            return true
        }
        guard shouldNotify else { return }
        heartbeatTask?.cancel()
        delegate?.session(self, didDisconnectWith: reason)
    }
}

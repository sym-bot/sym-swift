//
//  SymPeerSession.swift
//  SYM
//
//  Per-peer NWConnection lifecycle with length-prefixed JSON framing.
//  Handles handshake, heartbeat, send/receive for a single SYM peer.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
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

    /// TCP connection is ready — delegate should send handshake.
    func sessionDidBecomeReady(_ session: SymPeerSession)
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
    private var handshakeTimeoutTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "bot.sym", category: "PeerSession")

    /// For outbound discovery sessions: the nodeId we expect to reach.
    /// Set by `SymNode` after init, before `start()`. Used to dedup
    /// concurrent connect attempts to the same peer in `SymNode`'s
    /// `pendingOutboundNodeIds` set.
    var outboundTargetNodeId: String?

    /// Time after which a session that has not completed its handshake
    /// is forcibly disconnected. Catches stale Bonjour records pointing
    /// at unreachable peers — without this, the OS TCP default of ~75s
    /// keeps the failed flow alive and stacks up.
    static let handshakeTimeout: TimeInterval = 10

    weak var delegate: SymPeerSessionDelegate?

    // MARK: - Init

    /// TCP parameters with Wi-Fi-friendly keepalive. Default macOS TCP
    /// keepalive is `TCP_KEEPALIVE = 7200s` (2 hours) before the first probe,
    /// which means a dead-but-ESTABLISHED socket (peer process killed without
    /// graceful FIN — common on iOS app suspension and Mac Catalyst rebuilds)
    /// stays in ESTABLISHED state on the survivor side for hours. The
    /// addPeer dedup logic then keeps rejecting the live new dial against
    /// this zombie entry.
    ///
    /// Earlier v0.3.81 tried `idle=1s, interval=1s, count=3` (~4s detection)
    /// to mirror @sym-bot/sym v0.5.3's `setKeepAlive(true, 1000)`. That was
    /// far too aggressive for Wi-Fi: handshake-in-progress connections that
    /// had brief mid-exchange pauses got reaped before the protocol-level
    /// handshake exchange could complete, producing
    /// "[SYM] session: handshake timeout after 10s — disconnecting" on
    /// healthy connections.
    ///
    /// v0.3.82 relaxes to `idle=10s, interval=30s, count=3` → ~100s to
    /// declare dead. Wi-Fi blips of a few seconds don't trigger reaping;
    /// peer-restart scenarios still recover within ~100s instead of ~2h.
    /// The application-layer `lastSeen`-stale check in `SymNode.addPeer`
    /// (also shipped in v0.3.81) handles faster recovery: a peer entry
    /// older than 10s is treated as stale and the new dial replaces it,
    /// regardless of whether OS keepalive has reaped the underlying
    /// socket yet.
    static func tcpParametersWithKeepalive() -> NWParameters {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 30
            tcp.keepaliveCount = 3
        }
        return params
    }

    /// Outbound connection to a Bonjour endpoint.
    init(outboundTo endpoint: NWEndpoint, identity: SymIdentity) {
        self.connection = NWConnection(to: endpoint, using: Self.tcpParametersWithKeepalive())
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
        self.connection = NWConnection(host: nwHost, port: nwPort, using: Self.tcpParametersWithKeepalive())
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
        handshakeTimeoutTask?.cancel()
        connection.cancel()
    }

    // MARK: - Lifecycle

    /// Start the connection and begin handshake.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
        connection.start(queue: queue)

        // Arm the handshake timeout. If `_isActive` is still false after
        // `handshakeTimeout` seconds, the peer never completed handshake
        // (unreachable, wrong protocol, stale Bonjour record) — tear down.
        let timeout = Self.handshakeTimeout
        handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isActive else { return }
            self.logger.warning("[SYM] session: handshake timeout after \(Int(timeout))s — disconnecting")
            self.notifyDisconnect(reason: "Handshake timeout")
            self.connection.cancel()
        }
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
            handshakeTimeoutTask?.cancel()
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
            // Notify delegate to send handshake immediately — both sides must
            // send before either can complete, avoiding the deadlock where each
            // waits for the other's handshake frame first.
            delegate?.sessionDidBecomeReady(self)

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
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s check interval (matches Node.js)
                guard !Task.isCancelled, let self else { break }

                let elapsed = Date().timeIntervalSince(self.lastSeen)
                if elapsed > 120 {
                    // 120s timeout matches Node.js SYM — tolerates wifi blips,
                    // iCloud sync pauses, and iOS backgrounding without false disconnects.
                    self.logger.warning("[SYM] session: heartbeat timeout for \(self.peerName ?? "unknown")")
                    self.disconnect()
                    break
                } else if elapsed > 10 {
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
        handshakeTimeoutTask?.cancel()
        delegate?.session(self, didDisconnectWith: reason)
    }
}

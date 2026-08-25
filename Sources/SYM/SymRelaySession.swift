//
//  SymRelaySession.swift
//  SYM
//
//  WebSocket relay transport for internet-scale mesh cognition.
//
//  Connects to a SYM relay server via WebSocket, multiplexing
//  multiple logical peer connections over a single socket.
//  The relay is dumb transport — all coupling decisions remain on-device.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation
import os.log

// MARK: - Relay Delegate

/// Delegate for relay lifecycle events.
protocol SymRelaySessionDelegate: AnyObject {
    /// Relay connected and authenticated.
    func relayDidConnect()

    /// A remote peer joined the relay.
    func relayDidFindPeer(nodeId: String, name: String)

    /// A remote peer left the relay.
    func relayDidLosePeer(nodeId: String, name: String)

    /// A frame was received from a remote peer via the relay.
    func relay(didReceiveFrame frame: SymFrame, from nodeId: String, fromName: String)

    /// The relay connection was lost.
    func relayDidDisconnect(reason: String)
}

// MARK: - Relay Envelope

/// Envelope for messages sent to/from the relay.
private struct RelayEnvelope: Codable {
    var type: String?
    var to: String?
    var from: String?
    var fromName: String?
    var payload: AnyCodable?

    // relay-auth categories
    var nodeId: String?
    var name: String?
    var token: String?

    // relay-peers categories
    var peers: [RelayPeerEntry]?

    // relay-error categories
    var message: String?
}

private struct RelayPeerEntry: Codable {
    let nodeId: String
    let name: String
}

/// Type-erased Codable wrapper for relay payloads.
private struct AnyCodable: Codable {
    let value: [String: AnyCodableValue]

    init(_ dict: [String: Any]) {
        var result: [String: AnyCodableValue] = [:]
        for (k, v) in dict {
            result[k] = AnyCodableValue(v)
        }
        self.value = result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dict = try container.decode([String: AnyCodableValue].self)
        self.value = dict
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

private enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case null

    init(_ value: Any) {
        if let s = value as? String { self = .string(s) }
        else if let b = value as? Bool { self = .bool(b) }
        else if let i = value as? Int { self = .int(i) }
        else if let d = value as? Double { self = .double(d) }
        else if let d = value as? Float { self = .double(Double(d)) }
        else if let arr = value as? [Any] { self = .array(arr.map { AnyCodableValue($0) }) }
        else { self = .null }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let arr = try? container.decode([AnyCodableValue].self) { self = .array(arr) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let arr): try container.encode(arr)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Relay Session

/// Manages a WebSocket connection to a SYM relay server for internet-scale mesh.
/// See MMP v0.2.0 Section 4 (Transport, Layer 1).
///
/// Protocol:
///   1. Connect via WebSocket
///   2. Send relay-auth with nodeId, name, optional token
///   3. Receive relay-peers (existing peers on the relay)
///   4. Send/receive SYM frames wrapped in relay envelopes
///   5. Relay notifies peer-joined/peer-left events
///
/// The relay is dumb transport — all coupling decisions remain on-device.
/// `@unchecked Sendable`: all mutable state is accessed exclusively via the
/// serial `queue` below. The compiler cannot prove this invariant, so we
/// assert it manually. Any new stored property MUST be either immutable or
/// mediated by `queue.sync` / `queue.async`.
final class SymRelaySession: @unchecked Sendable {

    // MARK: - Properties

    private let url: URL
    private let identity: SymIdentity
    private let token: String?
    /// The room PARTITION this session joins inside its token's channel.
    ///
    /// The token decides which CHANNEL the relay lets this connection reach — server-held state a
    /// client cannot influence. The room subdivides that already-authenticated channel, so it is
    /// safe for the client to name: it can only narrow what this connection receives, never widen
    /// it. `nil` means the unnamed partition, which is where every pre-room client lives, so
    /// omitting it behaves exactly as before.
    private let room: String?
    private let logger = Logger(subsystem: "bot.sym", category: "RelaySession")

    /// Serial queue protecting all mutable relay state.
    private let queue = DispatchQueue(label: "bot.sym.relay", qos: .userInitiated)

    // All mutable state below — access ONLY via `queue`.
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    /// Live socket state, behind a lock because it is written from the
    /// send-completion handler (an arbitrary thread) and read from whichever
    /// thread calls `SymNode.status()`.
    private let stateLock = NSLock()
    private var _isConnected = false
    private var _lastClose: SymRelayClose?

    /// Whether the relay socket is up and this node's auth frame has been
    /// sent without transport error. This is the value
    /// ``SymNodeStatus/relayConnected`` reports; the existence of a session
    /// object is NOT evidence of a connection.
    ///
    /// Known window, and it is not small in production: the relay
    /// acknowledges acceptance only implicitly (its first `relay-peers`
    /// message), so between the auth frame leaving and a refusal arriving
    /// this reads `true` for a node the relay is about to decline.
    /// Tightening it to a relay-proven signal would delay sends that
    /// currently succeed in that window, so it is named rather than changed
    /// blind.
    ///
    /// Measured against the deployed relay: a refused node reads
    /// `true → false → true` on a ~20 s cycle and never settles, because the
    /// edge holds the refused socket open ~20 s and the session then retries
    /// the same hopeless auth. So a client that needs to know whether it is
    /// actually on the mesh must read ``lastClose`` — a refusal populates it
    /// within half a second, whether it arrives as a `relay-error` message
    /// or a 4xxx socket close, and it stays stable across every flip.
    var isConnected: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isConnected }
        set { stateLock.lock(); _isConnected = newValue; stateLock.unlock() }
    }

    /// How the relay connection last ended, or nil if it never has.
    var lastClose: SymRelayClose? {
        stateLock.lock(); defer { stateLock.unlock() }; return _lastClose
    }

    /// Record a refusal the relay stated in a message, without touching the
    /// socket state — the socket may well still be open at this point.
    /// A stated refusal is never overwritten by the transport close that
    /// follows it: the relay's own words are the better explanation, and the
    /// close that comes a moment later would otherwise bury them.
    private func recordRelayError(_ message: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _lastClose = SymRelayClose(code: nil, reason: message, statedByRelay: true)
    }

    /// Atomically transition connected → disconnected, recording how.
    /// Returns false if the session was already disconnected, which is the
    /// double-disconnect guard (an old receive loop can still be running).
    private func markDisconnected(_ close: SymRelayClose?) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard _isConnected else { return false }
        _isConnected = false
        // A refusal the relay already stated outranks the transport close
        // that follows it — see recordRelayError.
        if let close, _lastClose?.statedByRelay != true { _lastClose = close }
        return true
    }
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTask: Task<Void, Never>?
    private var _running = false
    private var connectedAt: Date?

    weak var delegate: SymRelaySessionDelegate?

    // MARK: - Init

    init(url: URL, identity: SymIdentity, token: String? = nil, room: String? = nil) {
        self.url = url
        self.identity = identity
        self.token = token
        self.room = room
    }

    // MARK: - Lifecycle

    func start() {
        start(afterDelay: 0)
    }

    /// m136: a start within seconds of a previous stop dials into the relay's own
    /// duplicate-identity freshness window — the old socket's close is async (and lags further
    /// behind a proxy), so the node collides with ITSELF and burns a dial per cold-launch
    /// phase. Callers that know a disconnect just happened pass the remaining grace.
    func start(afterDelay delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [self] in
            guard !_running else { return }   // idempotent: a second start during the grace is absorbed
            _running = true
            _connect()
        }
    }

    /// Test seam (m136): whether the session considers itself running.
    var isRunningForTest: Bool { _running }

    func stop() {
        queue.async { [self] in
            _running = false
            reconnectTask?.cancel()
            reconnectTask = nil
            _disconnect()
        }
    }

    // MARK: - Send

    /// Send a SYM frame to a specific peer via the relay.
    func send(_ frame: SymFrame, to targetNodeId: String) {
        queue.async { [self] in
            guard isConnected, let ws = webSocketTask else { return }
            _sendFrame(frame, to: targetNodeId, ws: ws)
        }
    }

    private func _sendFrame(_ frame: SymFrame, to targetNodeId: String, ws: URLSessionWebSocketTask) {

        let frameDict = frameToDict(frame)
        var envelope: [String: Any] = [
            "to": targetNodeId,
            "payload": frameDict,
        ]
        // Remove nil values
        envelope = envelope.compactMapValues { $0 }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return }

        ws.send(.string(text)) { [weak self] error in
            if let error {
                self?.logger.error("[SYM] relay: send failed: \(error.localizedDescription)")
            }
        }
    }

    /// Broadcast a SYM frame to all peers via the relay.
    func broadcast(_ frame: SymFrame) {
        queue.async { [self] in
            guard isConnected, let ws = webSocketTask else { return }

            let frameDict = frameToDict(frame)
            let envelope: [String: Any] = ["payload": frameDict]

            guard let data = try? JSONSerialization.data(withJSONObject: envelope),
                  let text = String(data: data, encoding: .utf8) else { return }

            ws.send(.string(text)) { [weak self] error in
                if let error {
                    self?.logger.error("[SYM] relay: broadcast failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Connection

    private func _connect() {
        // Clean up any previous connection before reconnecting
        _disconnect()

        let config = URLSessionConfiguration.default
        config.shouldUseExtendedBackgroundIdleMode = true

        let session = URLSession(configuration: config)
        self.urlSession = session

        let ws = session.webSocketTask(with: url)
        self.webSocketTask = ws
        ws.resume()

        // Send auth immediately
        authenticate()

        // Start receiving
        receiveLoop()
    }

    private func _disconnect() {
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func authenticate() {
        var auth: [String: Any] = [
            "type": "relay-auth",
            "nodeId": identity.nodeId,
            "name": identity.name,
        ]
        if let token { auth["token"] = token }
        // Relay ≥ 0.1.3 partitions delivery, roster and departures by this. An older relay ignores
        // the field, so sending it is safe against both — but on an older relay every room lands in
        // one channel with no isolation, which is why the deployed build matters.
        if let room, !room.isEmpty { auth["room"] = room }

        guard let data = try? JSONSerialization.data(withJSONObject: auth),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(text)) { [weak self] error in
            if let error {
                self?.logger.error("[SYM] relay: auth failed: \(error.localizedDescription)")
            } else {
                self?.isConnected = true
                self?.connectedAt = Date()
                self?.logger.info("[SYM] relay: connected: \(self?.url.absoluteString ?? "")")
                self?.delegate?.relayDidConnect()
            }
        }
    }

    // MARK: - Receive

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveLoop()

            case .failure(let error):
                // Guard against double disconnect (old receiveLoop still
                // running) — and record HOW it ended, so a client can tell
                // "the relay refused me" from "nobody answered".
                let close = SymRelayClose(
                    code: self.webSocketTask?.closeCode.rawValue,
                    reason: error.localizedDescription
                )
                guard self.markDisconnected(close) else { return }
                self.logger.info("[SYM] relay: disconnected: \(error.localizedDescription) (close \(close.code.map(String.init) ?? "none"))")
                self.delegate?.relayDidDisconnect(reason: error.localizedDescription)
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String

        switch type {
        case "relay-ping":
            // Respond to relay heartbeat
            let pong = #"{"type":"relay-pong"}"#
            webSocketTask?.send(.string(pong)) { _ in }

        case "relay-peers":
            // Initial peer list
            if let peers = json["peers"] as? [[String: Any]] {
                for peer in peers {
                    if let nodeId = peer["nodeId"] as? String,
                       let name = peer["name"] as? String {
                        delegate?.relayDidFindPeer(nodeId: nodeId, name: name)
                    }
                }
            }

        case "relay-peer-joined":
            if let nodeId = json["nodeId"] as? String,
               let name = json["name"] as? String {
                delegate?.relayDidFindPeer(nodeId: nodeId, name: name)
            }

        case "relay-peer-left":
            if let nodeId = json["nodeId"] as? String,
               let name = json["name"] as? String {
                delegate?.relayDidLosePeer(nodeId: nodeId, name: name)
            }

        case "relay-error":
            let msg = json["message"] as? String ?? "Unknown relay error"
            let kind = json["kind"] as? String   // relay ≥0.1.6 names the refusal machine-readably
            // A refusal can reach us two ways: the socket closes with a 4xxx
            // code, or the relay says so in a message first. Recording both
            // means a client asking "why am I not on the channel?" gets an
            // answer either way — logging it only, as before, left the app
            // with a silent non-membership it could not describe.
            recordRelayError(msg)
            if kind == "duplicate-identity" || msg.contains("duplicate identity") {
                // m136: on a phased cold launch this is almost always OUR OWN previous socket
                // still draining server-side (stop()'s cancel is async and the proxy close can
                // lag seconds) — an expected transient, not an error the operator can act on.
                // Log at info and retry after the server's freshness window instead of the
                // exponential ladder starting at 1s (which re-collides).
                logger.info("[SYM] relay: previous connection for this identity still draining — retrying after the freshness window")
                reconnectDelay = 6.0
            } else {
                logger.error("[SYM] relay: error: \(msg)")
            }

        default:
            // Routed frame from a peer
            if let from = json["from"] as? String,
               let payloadDict = json["payload"] as? [String: Any] {
                let fromName = json["fromName"] as? String ?? "unknown"
                if let frame = dictToFrame(payloadDict) {
                    delegate?.relay(didReceiveFrame: frame, from: from, fromName: fromName)
                }
            }
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard _running else { return }

        // Only reset backoff if connection was stable (lasted > 30s)
        // This prevents rapid flapping when the relay is still spinning up
        if let connectedAt, Date().timeIntervalSince(connectedAt) > 30 {
            reconnectDelay = 1.0
        }
        self.connectedAt = nil

        let jitter = reconnectDelay * 0.1 * Double.random(in: 0...1)
        let delay = reconnectDelay + jitter

        logger.info("[SYM] relay: reconnecting in \(Int(delay))s")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.queue.async {
                guard self._running else { return }
                self._connect()
            }
        }

        // Exponential backoff capped at 30s
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    // MARK: - Frame ↔ Dictionary Conversion

    private func frameToDict(_ frame: SymFrame) -> [String: Any] {
        var dict: [String: Any] = ["type": frame.type.rawValue]

        if let v = frame.nodeId { dict["nodeId"] = v }
        if let v = frame.name { dict["name"] = v }
        if let v = frame.h1 { dict["h1"] = v.map { Double($0) } }
        if let v = frame.h2 { dict["h2"] = v.map { Double($0) } }
        if let v = frame.confidence { dict["confidence"] = Double(v) }
        if let v = frame.key { dict["key"] = v }
        if let v = frame.content { dict["content"] = v }
        if let v = frame.source { dict["source"] = v }
        if let v = frame.tags { dict["tags"] = v }
        if let v = frame.timestamp { dict["timestamp"] = v }
        if let v = frame.originTimestamp { dict["originTimestamp"] = v }
        if let v = frame.storedAt { dict["storedAt"] = v }
        if let v = frame.mood { dict["mood"] = v }
        if let v = frame.context { dict["context"] = v }
        if let v = frame.from { dict["from"] = v }
        if let v = frame.fromName { dict["fromName"] = v }
        if let v = frame.platform { dict["platform"] = v }
        if let v = frame.token { dict["token"] = v }
        if let v = frame.environment { dict["environment"] = v }
        if let v = frame.reason { dict["reason"] = v }
        if let v = frame.trajectory { dict["trajectory"] = v.map { Double($0) } }
        if let v = frame.patterns { dict["patterns"] = v.map { Double($0) } }
        if let v = frame.anomaly { dict["anomaly"] = Double(v) }
        if let v = frame.outcome { dict["outcome"] = v }
        if let v = frame.coherence { dict["coherence"] = Double(v) }

        // CMB: encode as JSON data embedded in the dict
        if let cmb = frame.cmb, let cmbData = try? JSONEncoder().encode(cmb),
           let cmbDict = try? JSONSerialization.jsonObject(with: cmbData) as? [String: Any] {
            dict["cmb"] = cmbDict
        }

        // Application payload rides INSIDE the cmb object (sibling of the
        // CAT7 content — Node's `msg.cmb.payload`), joined here AFTER the
        // signed CMB encoded so it can never enter a signing preimage. The
        // relay codec bypasses SymFrame.serialize(), so the same join is
        // needed on this path or requests silently lose correlation over
        // the relay while working on LAN.
        if let payloadData = frame.cmbPayload,
           let payloadJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            if var cmbObj = dict["cmb"] as? [String: Any] {
                cmbObj["payload"] = payloadJSON
                dict["cmb"] = cmbObj
            } else {
                // Cmb-less (E2E) frame — a synthetic cmb holding only a
                // payload is undecodable on the far side. See SymFrame.serialize().
                dict["cmbPayload"] = payloadJSON
            }
        }

        return dict
    }

    private func dictToFrame(_ dict: [String: Any]) -> SymFrame? {
        guard let typeStr = dict["type"] as? String,
              let type = SymFrameType(rawValue: typeStr) else { return nil }

        var frame = SymFrame(type: type)

        frame.nodeId = dict["nodeId"] as? String
        frame.name = dict["name"] as? String
        frame.confidence = (dict["confidence"] as? Double).map { Float($0) }
        frame.key = dict["key"] as? String
        frame.content = dict["content"] as? String
        frame.source = dict["source"] as? String
        frame.tags = dict["tags"] as? [String]
        frame.timestamp = (dict["timestamp"] as? NSNumber).map { UInt64(truncating: $0) }
        frame.originTimestamp = (dict["originTimestamp"] as? NSNumber).map { UInt64(truncating: $0) }
        frame.storedAt = (dict["storedAt"] as? NSNumber).map { UInt64(truncating: $0) }
        frame.mood = dict["mood"] as? String
        frame.context = dict["context"] as? String
        frame.from = dict["from"] as? String
        frame.fromName = dict["fromName"] as? String
        frame.platform = dict["platform"] as? String
        frame.token = dict["token"] as? String
        frame.environment = dict["environment"] as? String
        frame.reason = dict["reason"] as? String
        frame.outcome = dict["outcome"] as? String
        frame.anomaly = (dict["anomaly"] as? Double).map { Float($0) }
        frame.coherence = (dict["coherence"] as? Double).map { Float($0) }

        // h1/h2 come as [Double] from JSON
        if let h1 = dict["h1"] as? [Double] { frame.h1 = h1.map { Float($0) } }
        else if let h1 = dict["h1"] as? [NSNumber] { frame.h1 = h1.map { Float(truncating: $0) } }

        if let h2 = dict["h2"] as? [Double] { frame.h2 = h2.map { Float($0) } }
        else if let h2 = dict["h2"] as? [NSNumber] { frame.h2 = h2.map { Float(truncating: $0) } }

        // trajectory/patterns come as [Double] from JSON
        if let t = dict["trajectory"] as? [Double] { frame.trajectory = t.map { Float($0) } }
        else if let t = dict["trajectory"] as? [NSNumber] { frame.trajectory = t.map { Float(truncating: $0) } }

        if let p = dict["patterns"] as? [Double] { frame.patterns = p.map { Float($0) } }
        else if let p = dict["patterns"] as? [NSNumber] { frame.patterns = p.map { Float(truncating: $0) } }

        // CMB: decode from nested dict
        if let cmbDict = dict["cmb"] as? [String: Any],
           let cmbData = try? JSONSerialization.data(withJSONObject: cmbDict),
           let cmb = try? JSONDecoder().decode(CognitiveMemoryBlock.self, from: cmbData) {
            frame.cmb = cmb
        }

        // Lift the application payload back out of the cmb object (the
        // CognitiveMemoryBlock decode above ignores the key). Mirrors
        // SymFrameParser.extractCMBPayload on the LAN path.
        if let cmbDict = dict["cmb"] as? [String: Any],
           let payload = cmbDict["payload"] as? [String: Any] {
            frame.cmbPayload = try? JSONSerialization.data(withJSONObject: payload)
        } else if let payload = dict["cmbPayload"] as? [String: Any] {
            frame.cmbPayload = try? JSONSerialization.data(withJSONObject: payload)
        }

        return frame
    }
}

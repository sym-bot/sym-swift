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
//  Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.
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

    // relay-auth fields
    var nodeId: String?
    var name: String?
    var token: String?

    // relay-peers fields
    var peers: [RelayPeerEntry]?

    // relay-error fields
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

/// Manages a WebSocket connection to a SYM relay server.
///
/// Protocol:
///   1. Connect via WebSocket
///   2. Send relay-auth with nodeId, name, optional token
///   3. Receive relay-peers (existing peers on the relay)
///   4. Send/receive SYM frames wrapped in relay envelopes
///   5. Relay notifies peer-joined/peer-left events
final class SymRelaySession {

    // MARK: - Properties

    private let url: URL
    private let identity: SymIdentity
    private let token: String?
    private let logger = Logger(subsystem: "bot.sym", category: "RelaySession")

    /// Serial queue protecting all mutable relay state.
    private let queue = DispatchQueue(label: "bot.sym.relay", qos: .userInitiated)

    // All mutable state below — access ONLY via `queue`.
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTask: Task<Void, Never>?
    private var _running = false
    private var connectedAt: Date?

    weak var delegate: SymRelaySessionDelegate?

    // MARK: - Init

    init(url: URL, identity: SymIdentity, token: String? = nil) {
        self.url = url
        self.identity = identity
        self.token = token
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            _running = true
            _connect()
        }
    }

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
                // Guard against double disconnect (old receiveLoop still running)
                guard self.isConnected else { return }
                self.isConnected = false
                self.logger.info("[SYM] relay: disconnected: \(error.localizedDescription)")
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
            logger.error("[SYM] relay: error: \(msg)")

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
        if let v = frame.mood { dict["mood"] = v }
        if let v = frame.context { dict["context"] = v }
        if let v = frame.from { dict["from"] = v }
        if let v = frame.fromName { dict["fromName"] = v }
        if let v = frame.platform { dict["platform"] = v }
        if let v = frame.token { dict["token"] = v }
        if let v = frame.environment { dict["environment"] = v }
        if let v = frame.reason { dict["reason"] = v }

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
        frame.mood = dict["mood"] as? String
        frame.context = dict["context"] as? String
        frame.from = dict["from"] as? String
        frame.fromName = dict["fromName"] as? String
        frame.platform = dict["platform"] as? String
        frame.token = dict["token"] as? String
        frame.environment = dict["environment"] as? String
        frame.reason = dict["reason"] as? String

        // h1/h2 come as [Double] from JSON
        if let h1 = dict["h1"] as? [Double] { frame.h1 = h1.map { Float($0) } }
        else if let h1 = dict["h1"] as? [NSNumber] { frame.h1 = h1.map { Float(truncating: $0) } }

        if let h2 = dict["h2"] as? [Double] { frame.h2 = h2.map { Float($0) } }
        else if let h2 = dict["h2"] as? [NSNumber] { frame.h2 = h2.map { Float(truncating: $0) } }

        return frame
    }
}

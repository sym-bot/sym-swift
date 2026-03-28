//
//  SymFrame.swift
//  SYM
//
//  Wire protocol — length-prefixed JSON frames.
//  Compatible with Node.js SYM (lib/frame-parser.js).
//
//  Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.
//

import Foundation

// MARK: - Peer Gossip

/// Gossip payload for peer-info frames — describes a known peer and its wake channel.
public struct SymPeerGossip: Codable, Sendable {
    public var nodeId: String?
    public var name: String?
    public var wakeChannel: SymWakeChannel?

    public init(nodeId: String? = nil, name: String? = nil, wakeChannel: SymWakeChannel? = nil) {
        self.nodeId = nodeId
        self.name = name
        self.wakeChannel = wakeChannel
    }
}

/// Wake channel descriptor for a peer — platform, push token, environment.
public struct SymWakeChannel: Codable, Sendable {
    public var platform: String?
    public var token: String?
    public var environment: String?

    public init(platform: String? = nil, token: String? = nil, environment: String? = nil) {
        self.platform = platform
        self.token = token
        self.environment = environment
    }
}

// MARK: - Frame Types

/// SYM wire message types. Must match Node.js SymNode exactly.
public enum SymFrameType: String, Codable, Sendable {
    case handshake = "handshake"
    case stateSync = "state-sync"
    case memoryShare = "memory-share"
    case mood = "mood"
    case message = "message"
    case wakeChannel = "wake-channel"
    case wake = "wake"
    case xmeshInsight = "xmesh-insight"
    case peerInfo = "peer-info"
    case ping = "ping"
    case pong = "pong"
}

// MARK: - Frame

/// A single SYM wire frame. Serialized as JSON, prefixed with 4-byte big-endian length.
///
/// Wire format: [4-byte BE u32 length][JSON payload]
/// Same framing as Node.js SYM `frame-parser.js`.
public struct SymFrame: Codable, Sendable {

    public let type: SymFrameType

    // Handshake
    public var nodeId: String?
    public var name: String?

    // State sync
    public var h1: [Float]?
    public var h2: [Float]?
    public var confidence: Float?

    // Memory share
    public var key: String?
    public var content: String?
    public var source: String?
    public var tags: [String]?
    public var originTimestamp: UInt64?  // When the event happened (L0 time)
    public var storedAt: UInt64?         // When the L1 entry was created
    public var timestamp: UInt64?        // Backward-compatible

    // Mood
    public var mood: String?
    public var context: String?

    // Message
    public var from: String?
    public var fromName: String?

    // SVAF v2: Cognitive Memory Block
    public var cmb: CognitiveMemoryBlock?

    // xMesh insight (peer agent's cognitive state from its own LNN)
    public var trajectory: [Float]?
    public var patterns: [Float]?
    public var anomaly: Float?
    public var outcome: String?
    public var coherence: Float?

    // Wake
    public var platform: String?
    public var token: String?
    public var environment: String?
    public var reason: String?

    // Peer info (gossip)
    public var peers: [SymPeerGossip]?

    public init(type: SymFrameType) {
        self.type = type
    }

    // MARK: - Factory Methods

    static func handshake(nodeId: String, name: String) -> SymFrame {
        var frame = SymFrame(type: .handshake)
        frame.nodeId = nodeId
        frame.name = name
        return frame
    }

    static func stateSync(h1: [Float], h2: [Float], confidence: Float) -> SymFrame {
        var frame = SymFrame(type: .stateSync)
        frame.h1 = h1
        frame.h2 = h2
        frame.confidence = confidence
        return frame
    }

    static func memoryShare(key: String, content: String, source: String, tags: [String],
                            originTimestamp: UInt64, storedAt: UInt64) -> SymFrame {
        var frame = SymFrame(type: .memoryShare)
        frame.key = key
        frame.content = content
        frame.source = source
        frame.tags = tags
        frame.originTimestamp = originTimestamp
        frame.storedAt = storedAt
        frame.timestamp = storedAt  // Backward-compatible
        return frame
    }

    static func message(from: String, fromName: String, content: String) -> SymFrame {
        var frame = SymFrame(type: .message)
        frame.from = from
        frame.fromName = fromName
        frame.content = content
        frame.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return frame
    }

    static func wakeChannel(platform: String, token: String, environment: String = "production") -> SymFrame {
        var frame = SymFrame(type: .wakeChannel)
        frame.platform = platform
        frame.token = token
        frame.environment = environment
        return frame
    }

    static func peerInfo(peers: [SymPeerGossip]) -> SymFrame {
        var frame = SymFrame(type: .peerInfo)
        frame.peers = peers
        return frame
    }

    static func ping() -> SymFrame { SymFrame(type: .ping) }
    static func pong() -> SymFrame { SymFrame(type: .pong) }
}

// MARK: - Serialization

extension SymFrame {

    /// Serialize to length-prefixed JSON data for the wire.
    func serialize() throws -> Data {
        let encoder = JSONEncoder()
        let json = try encoder.encode(self)

        var length = UInt32(json.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(json)
        return data
    }
}

// MARK: - Frame Parser

/// Streaming parser for length-prefixed JSON frames.
/// Feed raw TCP data, get parsed SymFrame callbacks.
final class SymFrameParser {

    private var buffer = Data()
    private static let maxFrameSize: UInt32 = 65536

    /// Parse any complete frames from the accumulated buffer.
    func feed(_ data: Data) -> [SymFrame] {
        buffer.append(data)

        var frames: [SymFrame] = []

        while buffer.count >= 4 {
            let length = buffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            guard length > 0, length <= Self.maxFrameSize else {
                // Invalid frame — clear buffer to recover
                buffer.removeAll()
                break
            }

            let totalNeeded = 4 + Int(length)
            guard buffer.count >= totalNeeded else { break }

            let jsonData = buffer.subdata(in: 4..<totalNeeded)
            buffer.removeSubrange(0..<totalNeeded)

            do {
                let frame = try JSONDecoder().decode(SymFrame.self, from: jsonData)
                frames.append(frame)
            } catch {
                #if DEBUG
                print("[SYM] frame: malformed JSON: \(error)")
                #endif
            }
        }

        return frames
    }

    /// Reset the parser state.
    func reset() {
        buffer.removeAll()
    }
}

//
//  SymFrame.swift
//  SYM
//
//  Wire protocol — length-prefixed JSON frames.
//  Compatible with Node.js SYM (lib/frame-parser.js).
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation
import SYMCore
import os.log

// MARK: - Peer Gossip

/// Gossip payload for peer-info frames — describes a known peer and its wake channel.
/// See MMP v0.2.0 Section 5 (Connection) and Section 7 (Frame Types).
public struct SymPeerGossip: Codable, Sendable {
    /// Node ID of the gossiped peer.
    public var nodeId: String?
    /// Display name of the gossiped peer.
    public var name: String?
    /// Wake channel descriptor, if known, for P2P wake of this peer.
    public var wakeChannel: SymWakeChannel?

    /// Create a gossip entry for a known peer.
    /// - Parameters:
    ///   - nodeId: The peer's node ID.
    ///   - name: The peer's display name.
    ///   - wakeChannel: The peer's wake channel, if known.
    public init(nodeId: String? = nil, name: String? = nil, wakeChannel: SymWakeChannel? = nil) {
        self.nodeId = nodeId
        self.name = name
        self.wakeChannel = wakeChannel
    }
}

/// Wake channel descriptor for a peer — platform, push token, environment.
/// Used for P2P wake of sleeping mesh nodes. See MMP v0.2.0 Section 5.
public struct SymWakeChannel: Codable, Sendable {
    /// Push platform identifier (e.g. "apns", "fcm").
    public var platform: String?
    /// Device push token string.
    public var token: String?
    /// Push environment ("production" or "sandbox").
    public var environment: String?

    /// Create a wake channel descriptor.
    /// - Parameters:
    ///   - platform: Push platform identifier.
    ///   - token: Device push token string.
    ///   - environment: Push environment. Defaults to nil.
    public init(platform: String? = nil, token: String? = nil, environment: String? = nil) {
        self.platform = platform
        self.token = token
        self.environment = environment
    }
}

// MARK: - E2E Metadata

/// E2E encryption metadata attached to encrypted CMB frames.
/// Matches Node.js wire format: `_e2e: { nonce: "base64..." }`.
public struct E2EMetadata: Codable, Sendable {
    /// Base64-encoded 12-byte AES-GCM nonce/IV.
    public var nonce: String

    /// Create E2E metadata.
    /// - Parameter nonce: Base64-encoded 12-byte nonce.
    public init(nonce: String) {
        self.nonce = nonce
    }
}

// MARK: - Node Stats

/// Self-report tally a node gossips so mesh observers can display its store counts.
/// Wire: `{ type: "node-stats", stats: { name, nodeId, emitted, admitted, memory, at } }`.
/// Byte-compatible with Node.js `SymNode._nodeStats()` (lib/node.js); the receiving
/// Node routes it via `frame-handler.js` `case 'node-stats'` to `_ingestNodeStats`.
/// `emitted` = own emissions, `admitted` = peer CMBs this node accepted, `memory` = total.
public struct SymNodeStats: Codable, Sendable {
    /// This node's display name.
    public var name: String?
    /// This node's node ID (the observer ignores a node's own stats by nodeId).
    public var nodeId: String?
    /// Count of CMBs this node emitted itself.
    public var emitted: Int?
    /// Count of peer CMBs this node admitted (remixed into its store).
    public var admitted: Int?
    /// Total CMBs in this node's store.
    public var memory: Int?
    /// Emit time (epoch ms).
    public var at: UInt64?

    /// Create a node-stats payload.
    public init(name: String? = nil, nodeId: String? = nil, emitted: Int? = nil,
                admitted: Int? = nil, memory: Int? = nil, at: UInt64? = nil) {
        self.name = name
        self.nodeId = nodeId
        self.emitted = emitted
        self.admitted = admitted
        self.memory = memory
        self.at = at
    }
}

// MARK: - Frame Types

/// SYM wire message types. Must match Node.js SymNode exactly.
/// See MMP v0.2.1 Section 7 (Frame Types).
public enum SymFrameType: String, Codable, Sendable {
    /// Identity exchange on connection. See MMP v0.2.1 Section 5.
    case handshake = "handshake"
    /// **DEPRECATED in MMP v0.2.2.** Legacy hidden-state broadcast from MMP v0.2.0.
    /// CfC hidden states never cross the wire under SVAF
    /// (Xu, 2026, *Symbolic-Vector Attention Fusion for Collective Intelligence*,
    /// arXiv:2604.03955, §3.4). Use ``cmb`` instead — cognitive coupling is
    /// performed at Layer 4 over CMBs by SVAF, not over raw hidden states at
    /// Layer 5. Retained for one-way wire decoding only so v0.2.0 peers do
    /// not break the parser; receivers MUST NOT feed the contents into the
    /// local CfC. Senders MUST NOT emit this frame type.
    case stateSync = "state-sync"
    /// CMB memory share between peers. See MMP v0.2.1 Section 6.
    case cmb = "cmb"
    /// Mood signal broadcast. Crosses domain boundaries per MMP v0.2.1 Section 9.3.
    case mood = "mood"
    /// Free-form text message between peers. See MMP v0.2.1 Section 7.
    case message = "message"
    /// Declares this node's push token for P2P wake. See MMP v0.2.1 Section 5.
    case wakeChannel = "wake-channel"
    /// P2P wake request sent out-of-band (handled by AppDelegate). See MMP v0.2.1 Section 5.
    case wake = "wake"
    /// xMesh insight from a peer agent's LNN. See MMP v0.2.1 Section 12.
    case xmeshInsight = "xmesh-insight"
    /// Peer gossip — known peers and their wake channels. See MMP v0.2.1 Section 5.
    case peerInfo = "peer-info"
    /// Protocol error. Codes 1xxx close connection; 2xxx informational. See MMP v0.2.1 Section 7.2.
    case error = "error"
    /// Heartbeat ping. See MMP v0.2.1 Section 5.
    case ping = "ping"
    /// Heartbeat pong response. See MMP v0.2.1 Section 5.
    case pong = "pong"
    /// Node self-report tally — emitted/admitted/memory counts a mesh observer
    /// can display for this (possibly sovereign/cross-device) node. See MMP Section 7.
    case nodeStats = "node-stats"
}

// MARK: - Frame

/// A single SYM wire frame. Serialized as JSON, prefixed with 4-byte big-endian length.
///
/// Wire format: [4-byte BE u32 length][JSON payload]
/// Same framing as Node.js SYM `frame-parser.js`.
public struct SymFrame: Codable, Sendable {

    /// The frame type discriminator. See MMP v0.2.0 Section 7.
    public let type: SymFrameType

    // Handshake
    /// Sender's node ID (used in handshake). See MMP v0.2.1 Section 3.
    public var nodeId: String?
    /// Sender's display name (used in handshake).
    public var name: String?
    /// MMP spec version implemented by this node (e.g. "0.2.1"). See MMP v0.2.1 Section 5.2.
    public var version: String?
    /// Supported protocol extensions (e.g. ["consent-v0.1"]). See MMP v0.2.1 Section 15.
    public var extensions: [String]?
    /// Sender's Ed25519 identity public key (base64url). See MMP Section 3.1.3.
    public var publicKey: String?
    /// Sender's E2E public key (base64, Curve25519 raw 32 bytes) for key agreement.
    /// Present in handshake frames when E2E encryption is supported.
    public var e2ePublicKey: String?
    /// Sender's lifecycle role (observer/validator/anchor). See MMP v0.2.2 Section 3.5.
    /// Validator/anchor-origin CMBs enter at anchor weight 2.0 (Section 6.4).
    public var lifecycleRole: String?

    // State sync — DEPRECATED, see ``SymFrameType/stateSync``.
    /// CfC hidden state vector 1. **DEPRECATED in MMP v0.2.2.**
    /// Hidden states never cross the wire under SVAF (Xu, 2026, §3.4).
    /// Retained on the type for backward-compatible decoding only; senders
    /// MUST NOT populate this field.
    public var h1: [Float]?
    /// CfC hidden state vector 2. **DEPRECATED in MMP v0.2.2.** See ``h1``.
    public var h2: [Float]?
    /// Confidence score for the (deprecated) state vectors (0-1).
    public var confidence: Float?

    // Memory share
    /// Unique memory key (cmb). See MMP v0.2.0 Section 6.
    public var key: String?
    /// Memory content text (cmb, message).
    public var content: String?
    /// Source node name that created this memory.
    public var source: String?
    /// Tags for search/filtering.
    public var tags: [String]?
    /// When the original event happened (epoch ms, L0 time). See MMP v0.2.0 Section 6.
    public var originTimestamp: UInt64?
    /// When the memory entry was created (epoch ms, L1 time).
    public var storedAt: UInt64?
    /// Backward-compatible timestamp (epoch ms).
    public var timestamp: UInt64?

    // Mood
    /// Mood label (mood frame). See MMP v0.2.0 Section 9.3.
    public var mood: String?
    /// Optional context describing the mood trigger.
    public var context: String?

    // Message
    /// Sender's node ID (message frame).
    public var from: String?
    /// Sender's display name (message frame).
    public var fromName: String?

    /// SVAF v2 Cognitive Memory Block. See MMP v0.2.0 Section 9.
    public var cmb: CognitiveMemoryBlock?

    /// A boundary (two-section, §7.1) record that arrived on the `cmb`
    /// channel — the REAL SYMCore type since v0.3.90; the temporary
    /// WireRecordV2 shim is gone. NOT in CodingKeys — synthesized Codable
    /// never touches it (the `= nil` default is what makes that legal); the
    /// frame parser attaches it on the second-pass decode when the flat
    /// decode fails on a v2 payload. Exactly one of `cmb` / `cmbV2` is set
    /// for a cmb frame.
    public var cmbV2: CMBRecordV2? = nil

    /// Encrypted CMB fields (base64 ciphertext with appended auth tag).
    /// When present, `cmb.fields` is empty and must be decrypted using `_e2e.nonce`.
    public var encryptedFields: String?
    /// E2E encryption metadata for encrypted CMB frames.
    /// Wire format: `_e2e: { nonce: "base64..." }`.
    public var e2e: E2EMetadata?

    /// Anchor flag — true when this CMB is a historical replay sent on peer reconnect.
    /// Receiving agents SHOULD NOT remix anchor CMBs (they are context, not new signals).
    /// See MMP v0.2.1 Section 13.6.
    public var isAnchor: Bool?

    private enum CodingKeys: String, CodingKey {
        case type, nodeId, name, version, extensions, publicKey, e2ePublicKey, lifecycleRole
        case h1, h2, confidence
        case key, content, source, tags, originTimestamp, storedAt, timestamp
        case mood, context
        case from, fromName
        case cmb, encryptedFields
        case e2e = "_e2e"
        case isAnchor = "_anchor"
        case trajectory, patterns, anomaly, outcome, coherence
        case platform, token, environment, reason
        case code
        case peers
        case stats
    }

    // xMesh insight (peer agent's cognitive state from its own LNN)
    /// LNN trajectory vector (xmesh-insight). See MMP v0.2.0 Section 12.
    public var trajectory: [Float]?
    /// LNN pattern activations (xmesh-insight). See MMP v0.2.0 Section 12.
    public var patterns: [Float]?
    /// Anomaly score 0-1 (xmesh-insight).
    public var anomaly: Float?
    /// Predicted outcome label (xmesh-insight).
    public var outcome: String?
    /// Mesh coherence score 0-1 (xmesh-insight).
    public var coherence: Float?

    // Wake
    /// Push platform identifier (wake-channel, wake).
    public var platform: String?
    /// Device push token (wake-channel).
    public var token: String?
    /// Push environment: "production" or "sandbox" (wake-channel).
    public var environment: String?
    /// Reason for a wake request (wake).
    public var reason: String?

    // Error (MMP Section 7.2)
    /// Error code. 1xxx = connection-level (close). 2xxx = evaluation-level (informational).
    public var code: Int?

    // Peer info (gossip)
    /// Known peers for gossip (peer-info). See MMP v0.2.1 Section 5.
    public var peers: [SymPeerGossip]?

    // Node stats (self-report)
    /// Store tally payload (node-stats). See ``SymNodeStats``.
    public var stats: SymNodeStats?

    /// Create a frame with the given type. All other fields default to nil.
    /// - Parameter type: The ``SymFrameType`` for this frame.
    public init(type: SymFrameType) {
        self.type = type
    }

    // MARK: - Factory Methods

    static func handshake(nodeId: String, name: String, publicKey: String? = nil, e2ePublicKey: String? = nil, lifecycleRole: String = "observer") -> SymFrame {
        var frame = SymFrame(type: .handshake)
        frame.nodeId = nodeId
        frame.name = name
        frame.version = "0.2.2"
        frame.extensions = []
        frame.publicKey = publicKey
        frame.e2ePublicKey = e2ePublicKey
        frame.lifecycleRole = lifecycleRole
        return frame
    }

    /// Create an error frame. See MMP v0.2.1 Section 7.2.
    /// Codes 1xxx close connection; codes 2xxx are informational.
    static func error(code: Int, message: String, detail: String? = nil) -> SymFrame {
        var frame = SymFrame(type: .error)
        frame.code = code
        frame.content = message
        frame.reason = detail
        return frame
    }

    /// **DEPRECATED in MMP v0.2.2.** Hidden states never cross the wire under
    /// SVAF (Xu, 2026, §3.4). Construct CMBs via ``SymNode/remember(fields:tags:parents:originTimestamp:)``
    /// and let the node broadcast them on the ``cmb`` channel; cognitive
    /// coupling is performed at Layer 4 over CMBs, not over hidden states.
    @available(*, deprecated, message: "MMP v0.2.2: hidden states do not cross the wire. Use SymNode.remember() to broadcast CMBs.")
    static func stateSync(h1: [Float], h2: [Float], confidence: Float) -> SymFrame {
        var frame = SymFrame(type: .stateSync)
        frame.h1 = h1
        frame.h2 = h2
        frame.confidence = confidence
        return frame
    }

    static func cmb(key: String, content: String, source: String, tags: [String],
                    originTimestamp: UInt64, storedAt: UInt64) -> SymFrame {
        var frame = SymFrame(type: .cmb)
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

    /// Self-report tally frame. Byte-compatible with Node.js
    /// `{ type: 'node-stats', stats: { name, nodeId, emitted, admitted, memory, at } }`.
    static func nodeStats(name: String, nodeId: String, emitted: Int, admitted: Int, memory: Int) -> SymFrame {
        var frame = SymFrame(type: .nodeStats)
        frame.stats = SymNodeStats(
            name: name, nodeId: nodeId, emitted: emitted, admitted: admitted, memory: memory,
            at: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        return frame
    }
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
/// See MMP v0.2.0 Section 4 (Transport, Layer 1).
/// Feed raw TCP data, get parsed ``SymFrame`` callbacks.
final class SymFrameParser {

    private var buffer = Data()
    private static let maxFrameSize: UInt32 = 65536
    private let logger = Logger(subsystem: "bot.sym", category: "FrameParser")

    /// Parse any complete frames from the accumulated buffer.
    func feed(_ data: Data) -> [SymFrame] {
        buffer.append(data)

        var frames: [SymFrame] = []

        while buffer.count >= 4 {
            let length = buffer.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            guard length > 0, length <= Self.maxFrameSize else {
                logger.error("[SYM] frame: invalid length \(length), clearing buffer")
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
                // Second pass: a boundary (two-section) record in the `cmb`
                // member fails the flat decode and — under synthesized
                // Codable — used to kill the WHOLE frame, so iOS silently
                // dropped every v2 record from current JS nodes. Detect that
                // exact shape, decode the v2 record separately, and re-decode
                // the frame with the member excised. Anything else still
                // fails loudly, exactly as before.
                if let rescued = rescueV2CMBFrame(jsonData) {
                    frames.append(rescued)
                    continue
                }
                let preview = String(data: jsonData.prefix(200), encoding: .utf8) ?? "binary"
                logger.error("[SYM] frame: decode failed: \(error) — \(preview)")
            }
        }

        return frames
    }

    /// Reset the parser state.
    func reset() {
        buffer.removeAll()
    }

    /// Rescue a frame whose `cmb` member is a v2 two-section record.
    /// Returns nil unless the payload is exactly that shape — this is a
    /// narrow rescue, not a general tolerant decode. (v2 iff the member
    /// carries a metadata object with a string key; the flat model has
    /// neither.)
    private func rescueV2CMBFrame(_ jsonData: Data) -> SymFrame? {
        guard var obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              let cmbObj = obj["cmb"] as? [String: Any],
              let metadata = cmbObj["metadata"] as? [String: Any],
              metadata["key"] is String else { return nil }

        let cmbJSON = obj["cmb"]
        obj.removeValue(forKey: "cmb")

        guard let strippedData = try? JSONSerialization.data(withJSONObject: obj),
              var frame = try? JSONDecoder().decode(SymFrame.self, from: strippedData),
              let cmbData = try? JSONSerialization.data(withJSONObject: cmbJSON as Any),
              let record = try? JSONDecoder().decode(CMBRecordV2.self, from: cmbData) else {
            return nil
        }
        frame.cmbV2 = record
        logger.info("[SYM] frame: boundary (v2) record rescued from \(frame.name ?? frame.source ?? "peer")")
        return frame
    }
}

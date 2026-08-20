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
    /// A discriminator this build does not recognise. Never emitted: the raw
    /// value carries a NUL that no wire producer can send. Decoding maps every
    /// unrecognized `type` here, so a frame type added to the protocol after
    /// this client shipped is ignored rather than fatal.
    case unknown = "\u{0}unknown"

    /// Tolerant discriminator.
    ///
    /// A `String`-raw-value enum throws `DecodingError.dataCorrupted` on an
    /// unrecognized value, and because ``SymFrame/type`` is non-optional that
    /// kills the WHOLE frame — so any frame type added to the wire after a
    /// Swift client ships breaks that client's decode of those frames,
    /// silently, for as long as it is in the field.
    ///
    /// `attestation` was the second instance of that class; the first was
    /// patched narrowly by ``rescueV2CMBFrame``. A rescue per shape does not
    /// converge, so the discriminator itself is made tolerant: unknown maps to
    /// a case instead of throwing, and every future wire addition becomes a
    /// no-op for old clients rather than a dropped frame plus an error per
    /// copy per peer.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SymFrameType(rawValue: raw) ?? .unknown
    }
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
    /// MUST NOT populate this category.
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

    /// Encrypted CMB categories (base64 ciphertext with appended auth tag).
    /// When present, `cmb.categories` is empty and must be decrypted using `_e2e.nonce`.
    ///
    /// KNOWN DIVERGENCE from @sym-bot/core, on the record (2026-08-12): the canonical
    /// e2e shape encrypts IN PLACE — `cmb.categories` becomes the ciphertext string and
    /// `_e2e` rides INSIDE the cmb — and the canonical never emits this top-level member.
    /// Today the divergence is LATENT: the JS side announces no e2ePublicKey, so a
    /// Swift↔JS pair never derives a secret and always falls back to plaintext. The
    /// moment that changes, Swift e2e frames are silently dropped by JS peers. Aligning
    /// this shape is a protocol change owned by the wire review, deliberately NOT folded
    /// into the vocabulary rename.
    public var encryptedCategories: String?
    /// E2E encryption metadata for encrypted CMB frames.
    /// Wire format: `_e2e: { nonce: "base64..." }`.
    public var e2e: E2EMetadata?

    /// Anchor flag — true when this CMB is a historical replay sent on peer reconnect.
    /// Receiving agents SHOULD NOT remix anchor CMBs (they are context, not new signals).
    /// See MMP v0.2.1 Section 13.6.
    public var isAnchor: Bool?

    /// Opaque application payload riding INSIDE the wire `cmb` object as a
    /// sibling of the CAT7 categories — the Node convention (`frame-handler.js`
    /// reads `msg.cmb.payload`; the llm-sidecar writes `payload:{request_id:…}`).
    /// JSON bytes of a top-level object. NOT in CodingKeys: the payload is
    /// NEVER part of the cmbKey hash or any signing preimage — signing binds
    /// CAT7 content only, so ``serialize()`` joins it to the `cmb` object
    /// after the (already-signed) CMB encodes, and the parser lifts it back
    /// out on receive. A pre-0.5.0 receiver's Codable ignores the key.
    public var cmbPayload: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case type, nodeId, name, version, extensions, publicKey, e2ePublicKey, lifecycleRole
        case h1, h2, confidence
        case key, content, source, tags, originTimestamp, storedAt, timestamp
        case mood, context
        case from, fromName
        case cmb
        // FROZEN Swift↔Swift wire key: every 0.3.x peer sends and reads
        // `encryptedFields`; the identifier follows the 0.4.0 vocabulary,
        // the byte does not move.
        case encryptedCategories = "encryptedFields"
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

    /// Create a frame with the given type. All other categories default to nil.
    /// - Parameter type: The ``SymFrameType`` for this frame.
    public init(type: SymFrameType) {
        self.type = type
    }

    // MARK: - Factory Methods

    static func handshake(nodeId: String, name: String, publicKey: String? = nil, e2ePublicKey: String? = nil, lifecycleRole: String = "observer") -> SymFrame {
        var frame = SymFrame(type: .handshake)
        frame.nodeId = nodeId
        frame.name = name
        // The legacy handshake label, from the single public constant rather than a literal here.
        // It was "0.2.2" while the JS reference sent "0.2.3" — a drift nothing detected, because no
        // receiver validates this field. Aligning it is tidiness, not a compatibility fix; what a
        // peer actually agrees with is MMP.protocolVersion inside the signed §5.2 transcript.
        frame.version = MMP.legacyHandshakeRevision
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
    /// SVAF (Xu, 2026, §3.4). Construct CMBs via ``SymNode/remember(categories:tags:parents:originTimestamp:)``
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
        var json = try encoder.encode(self)

        // cmbV2 and cmbPayload are outside CodingKeys (the flat decode must
        // never trip on them), so a frame carrying either is assembled here.
        // The v2 record encodes separately and joins the frame object under
        // the same "cmb" key the rescue parser reads on the far side; exactly
        // one of cmb/cmbV2 is ever set, so the key cannot collide. The
        // payload joins INSIDE the "cmb" object as a sibling of the CAT7
        // content — after the CMB was signed, so it can never enter a
        // signing preimage. An encrypted frame has cleared `cmb`, in which
        // case the payload becomes the object's only member (the receive
        // path reconstructs the CMB from the outer frame regardless).
        if cmbV2 != nil || cmbPayload != nil,
           var obj = try JSONSerialization.jsonObject(with: json) as? [String: Any] {
            if let record = cmbV2 {
                let recordJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                obj["cmb"] = recordJSON
            }
            if let payloadData = cmbPayload,
               let payloadJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                if var cmbObj = obj["cmb"] as? [String: Any] {
                    cmbObj["payload"] = payloadJSON
                    obj["cmb"] = cmbObj
                } else {
                    // No cmb object to be a sibling of — the E2E path clears
                    // it (categories became `encryptedFields`). Synthesizing
                    // a `cmb` holding only a payload makes the WHOLE frame
                    // undecodable on the far side: the flat decode fails on
                    // a CMB missing every required member and the frame is
                    // dropped, silently, payload and all. So a cmb-less
                    // frame carries the payload at top level instead. The
                    // Node-facing plaintext path always has a cmb and always
                    // uses `cmb.payload`; this branch is Swift↔Swift E2E,
                    // where the frame shape already diverges by design.
                    obj["cmbPayload"] = payloadJSON
                }
            }
            json = try JSONSerialization.data(withJSONObject: obj)
        }

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

    /// Unrecognized discriminators already reported on this connection.
    ///
    /// One line per novel type, not per frame: every peer on a roster relays
    /// the same frame, so the failure this change removes was amplified by the
    /// peer count (one attestation, eight peers, eight logged failures). A log
    /// per occurrence would reproduce that flood at a quieter level.
    private var reportedUnknownTypes: Set<String> = []

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
                var frame = try JSONDecoder().decode(SymFrame.self, from: jsonData)
                if frame.type == .unknown {
                    noteUnknownFrameType(jsonData)
                    continue
                }
                // cmbPayload is outside CodingKeys (it lives INSIDE the wire
                // "cmb" object, which decodes as a SYMCore type that ignores
                // it), so a cmb frame gets a second look at the raw bytes.
                if frame.type == .cmb {
                    frame.cmbPayload = Self.extractCMBPayload(jsonData)
                }
                frames.append(frame)
            } catch {
                // Second pass: a boundary (two-section) record in the `cmb`
                // member fails the flat decode and — under synthesized
                // Codable — used to kill the WHOLE frame, so iOS silently
                // dropped every v2 record from current JS nodes. Detect that
                // exact shape, decode the v2 record separately, and re-decode
                // the frame with the member excised. Anything else still
                // fails loudly, exactly as before.
                if var rescued = rescueV2CMBFrame(jsonData) {
                    rescued.cmbPayload = Self.extractCMBPayload(jsonData)
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
        reportedUnknownTypes.removeAll()
    }

    /// Report an ignored frame type once per connection, at info.
    ///
    /// The frame is dropped: this build has no handler for it, and the
    /// length-prefixed stream is unaffected either way because ``feed(_:)``
    /// advances the buffer before decoding. Info rather than error — an
    /// unrecognized type is a peer running ahead of this client, which is
    /// expected on a mixed-version mesh, not a fault.
    ///
    /// The asymmetry is deliberate and worth knowing: an ignored frame is
    /// indistinguishable from one this client SHOULD have handled. The log
    /// line is what makes the difference visible without costing a failure.
    private func noteUnknownFrameType(_ jsonData: Data) {
        let object = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
        let type = (object?["type"] as? String) ?? "<unreadable>"
        guard reportedUnknownTypes.insert(type).inserted else { return }
        logger.info(
            "[SYM] frame: ignoring unrecognized type \"\(type)\" — this build predates it; frame dropped, stream intact"
        )
    }

    /// Lift the opaque application payload out of the wire `cmb` object
    /// (`cmb.payload`, the Node sibling-of-categories convention). Returns
    /// the payload re-serialized as standalone JSON-object bytes, or nil
    /// when absent or not an object.
    static func extractCMBPayload(_ jsonData: Data) -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else { return nil }
        // `cmb.payload` is the Node convention and the only shape a Node peer
        // sends; the top-level fallback exists for cmb-less (E2E) frames.
        if let cmbObj = obj["cmb"] as? [String: Any],
           let payload = cmbObj["payload"] as? [String: Any] {
            return try? JSONSerialization.data(withJSONObject: payload)
        }
        if let payload = obj["cmbPayload"] as? [String: Any] {
            return try? JSONSerialization.data(withJSONObject: payload)
        }
        return nil
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

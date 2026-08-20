//
//  SymNode.swift
//  SYM
//
//  A sovereign mesh node with cognitive coupling.
//
//  Each node encodes its memories into a hidden state vector.
//  When peers connect, the coupling engine evaluates drift between
//  their cognitive states and autonomously decides whether to couple.
//
//  Aligned peers share memories. Divergent peers stay independent.
//  The intelligence is in the decision to share, not in the sharing itself.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import CryptoKit
import Foundation
import Network
@_exported import SYMCore
import os.log

// MARK: - Events

/// Events emitted by ``SymNode`` during mesh operation.
/// See MMP v0.2.0 Section 5 (Connection) and Section 13 (Application).
public enum SymEvent {
    /// A new peer has joined the mesh. See MMP v0.2.0 Section 5.
    case peerJoined(nodeId: String, name: String)
    /// A peer has left the mesh. See MMP v0.2.0 Section 5.
    case peerLeft(nodeId: String, name: String)
    /// The SVAF coupling engine made a decision about a peer. See MMP v0.2.0 Section 9.
    case couplingDecision(peer: String, decision: String, drift: Float)
    /// A memory was received from a peer, possibly fused via SVAF. See MMP v0.2.0 Section 6 and Section 9.
    case memoryReceived(from: String, content: String, decision: String?, cmb: CognitiveMemoryBlock?)
    /// A peer's mood signal was delivered (Section 9.3 + Section 13.9: mood-delivered).
    /// Mood is always delivered from rejected CMBs — affect crosses all domain boundaries.
    case moodDelivered(from: String, mood: String, drift: Float)
    /// A peer's mood signal was rejected (drift above threshold). See MMP v0.2.0 Section 9.3.
    case moodRejected(from: String, mood: String, drift: Float)
    /// A text message was received from a peer. See MMP v0.2.0 Section 7.
    case message(from: String, content: String)
    /// xMesh insight received — a peer agent's cognitive state from its own LNN.
    /// Contains trajectory, patterns, anomaly score, predicted outcome. See MMP v0.2.0 Section 12.
    case xmeshInsight(from: String, trajectory: [Float], patterns: [Float], anomaly: Float, outcome: String, coherence: Float)
    /// Peer's cognitive state received via state-sync frame.
    /// **DEPRECATED in MMP v0.2.2.** Legacy hidden-state receive event.
    /// Hidden states never cross the wire under SVAF (Xu, 2026, §3.4); MMP
    /// v0.2.2 senders MUST NOT emit `state-sync` frames. This event is
    /// retained on the API surface only for backwards source compatibility
    /// and is no longer fired by the receiver. Subscribe to
    /// ``cmbAccepted`` or ``memoryReceived`` for cognitive signal events.
    @available(*, deprecated, message: "MMP v0.2.2: hidden states do not cross the wire. Subscribe to .cmbAccepted or .memoryReceived instead.")
    case stateSyncReceived(from: String, h1: [Float], h2: [Float], confidence: Float)
    /// A peer CMB was accepted by SVAF and stored. Application layer can remix.
    /// Per MMP v0.2.1 Section 14: remix only when agent has new domain data.
    /// Check `isAnchor` and `isRemix` before calling LLM for remix:
    /// - `isAnchor`: historical CMB replayed on peer reconnect — not a new signal
    /// - `isRemix`: CMB with lineage parents — re-remixing causes cascade storms
    case cmbAccepted(entry: SymMemoryEntry, isAnchor: Bool = false, isRemix: Bool = false)
    /// A payload-bearing CMB arrived that no pending
    /// ``SymNode/request(payload:categories:to:timeout:)`` was awaiting — an
    /// inbound request for this node to serve (or an uncorrelated late
    /// response; the payload's own protocol distinguishes them). Build the
    /// reply with ``SymNode/respond(to:payload:categories:)``. Emitted
    /// BEFORE and independent of the SVAF verdict on the carrying CMB, so
    /// the payload survives both admitted and rejected outcomes.
    case requestReceived(envelope: SymEnvelope)
    /// Protocol-level metric event for observability.
    case metric(type: String, detail: [String: String])
}

// MARK: - Protocol Metrics

/// Cumulative protocol-level metrics for observability.
/// See MMP v0.2.0 Section 13 (Application).
public struct SymNodeMetrics: Sendable {
    /// CMBs created by this agent via remember().
    public var cmbProduced: Int = 0
    /// Peer CMBs accepted by SVAF.
    public var cmbAccepted: Int = 0
    /// Remix CMBs (remember() with parents).
    public var remixProduced: Int = 0
    /// Peers that connected.
    public var peersJoined: Int = 0
    /// Peers that disconnected.
    public var peersLeft: Int = 0
    /// recall() queries.
    public var recalls: Int = 0
    /// LLM API calls reported by agent.
    public var llmCalls: Int = 0
    /// Total LLM input tokens.
    public var llmTokensIn: Int = 0
    /// Total LLM output tokens.
    public var llmTokensOut: Int = 0
    /// Last LLM model used.
    public var llmModel: String? = nil
    /// Remix attempts rejected (no new domain data).
    public var remixRejected: Int = 0
    /// When the node started.
    public var startedAt: Date? = nil
    /// Uptime since start.
    public var uptimeMs: Int {
        guard let s = startedAt else { return 0 }
        return Int(Date().timeIntervalSince(s) * 1000)
    }
}

// MARK: - Peer Info

/// Public information about a connected mesh peer.
/// See MMP v0.2.0 Section 5 (Connection) and Section 9 (Coupling).
public struct SymPeerInfo: Sendable {
    /// Truncated node ID (first 8 characters).
    public let id: String
    /// Display name of the peer.
    public let name: String
    /// Whether the peer is currently connected.
    public let connected: Bool
    /// Timestamp of the last received frame from this peer.
    public let lastSeen: Date
    /// Current SVAF coupling decision: "aligned", "guarded", "rejected", or "pending".
    public let coupling: String
    /// SVAF drift score (0 = identical, 1 = maximally divergent), or nil if not yet evaluated.
    public let drift: Float?
    /// How this peer is currently reachable.
    ///
    /// MMP §4.6: a peer MAY hold MULTIPLE transports at once, so this is a
    /// SET, not a mode. Someone on your Wi-Fi who is also relay-connected is
    /// genuinely both, and a two-state field would have to pick one and
    /// misreport the other — the node itself prefers Bonjour when both
    /// exist, but that is a routing choice, not a fact about the peer.
    ///
    /// The mesh EXPERIENCE does not vary by transport (coupling, presence
    /// and harmonizing are identical either way); this exists so an app can
    /// show WHERE a peer is reachable from, not to gate what it may do.
    public let reachability: Set<SymPeerReachability>

    /// PUBLIC because a consumer must be able to build one — for a test, a
    /// SwiftUI preview, or a fixture. The memberwise init was internal, which
    /// made this public struct unconstructible outside the package: an app
    /// could receive a SymPeerInfo and never make one, so peer-facing UI had
    /// no way to be tested at all. Found while testing MeloTune's peer
    /// classification.
    public init(id: String, name: String, connected: Bool, lastSeen: Date,
                coupling: String, drift: Float?,
                reachability: Set<SymPeerReachability> = []) {
        self.id = id
        self.name = name
        self.connected = connected
        self.lastSeen = lastSeen
        self.coupling = coupling
        self.drift = drift
        self.reachability = reachability
    }
}

/// The ways a peer can be reachable. Additive: a peer may be several at once.
public enum SymPeerReachability: String, Sendable, Hashable, CaseIterable {
    /// Discovered and connected on the local network (Bonjour).
    case localNetwork
    /// Connected through the relay, from anywhere.
    case relay
}

// MARK: - Relay Close

/// How a relay connection ended.
///
/// A client that cannot tell "the relay refused me" from "nobody answered"
/// cannot tell its user anything true, so the close code is surfaced rather
/// than collapsed into a bool. Application close codes (4xxx) are the relay
/// declining this node — a bad token, a duplicate identity — and are worth
/// showing; a transport drop is worth retrying quietly.
public struct SymRelayClose: Sendable, Equatable {
    /// WebSocket close code, when the socket reported one.
    public let code: Int?
    /// Human-readable reason — from the relay when it stated one, otherwise
    /// from the transport.
    public let reason: String?
    /// True when this came from the relay's own `relay-error` message rather
    /// than from the socket closing. A stated refusal is kept in preference
    /// to the transport close that follows it.
    public let statedByRelay: Bool

    public init(code: Int?, reason: String?, statedByRelay: Bool = false) {
        self.code = code
        self.reason = reason
        self.statedByRelay = statedByRelay
    }

    /// True when the relay declined this node rather than the connection
    /// merely dropping: an application close code (4000–4999), or the relay
    /// saying so in its own words.
    public var wasRefused: Bool {
        if statedByRelay { return true }
        guard let code else { return false }
        return (4000...4999).contains(code)
    }
}

// MARK: - Node Status

/// Full node status snapshot. See MMP v0.2.0 Section 13 (Application).
public struct SymNodeStatus: Sendable {
    /// Display name of this node.
    public let name: String
    /// Full node ID (UUID). See MMP v0.2.0 Section 3.
    public let nodeId: String
    /// Whether the node is currently running.
    public let running: Bool
    /// Local Bonjour listening port (0 if relay-only).
    public let port: UInt16
    /// Relay URL string, or nil if no relay configured.
    public let relay: String?
    /// Whether the relay socket is up **right now** — NOT whether this node
    /// is on the mesh. Do not read it alone.
    ///
    /// It used to report whether a relay session OBJECT existed, which is
    /// true from the moment a relay is configured and stays true after the
    /// relay closes the socket refusing the node. It now tracks the real
    /// socket, but a socket is still not a membership, and against a real
    /// deployment the difference is stark: measured on the deployed relay,
    /// a node with a token the relay will NEVER accept reads
    /// `true → false → true` on a ~20 s cycle, indefinitely, and is `true`
    /// most of the time. The edge holds the refused socket open for ~20 s,
    /// so the close arrives late, and the session then reconnects into the
    /// same hopeless auth.
    ///
    /// **A client asking "am I on the mesh?" must consult ``relayClose``**,
    /// which is populated within half a second of the refusal and stays
    /// stable and correct across every flip. Reading `relayConnected` alone
    /// gives a flickering `true` for a relay that is refusing you — the same
    /// wrong conclusion the original defect produced, reached by a different
    /// route.
    public let relayConnected: Bool
    /// How the relay connection last ended, or nil while it has never
    /// closed. Distinguishes a refusal (bad token, duplicate identity) from
    /// a transport drop — see ``SymRelayClose/wasRefused``.
    ///
    /// In production this is the **only reliable refusal signal**: unlike
    /// ``relayConnected`` it does not oscillate while a refused session
    /// retries. Gate a "you are connected" indicator on
    /// `relayConnected && relayClose?.wasRefused != true`.
    public let relayClose: SymRelayClose?
    /// Connected peers with coupling state.
    public let peers: [SymPeerInfo]
    /// Number of currently connected peers.
    public let peerCount: Int
    /// Total memory count across local and peer stores. See MMP v0.2.0 Section 6.
    public let memoryCount: Int
    /// Mesh coherence score (0-1), or nil if no peers. See MMP v0.2.0 Section 9.
    public let coherence: Float?
}

// MARK: - xMesh Insight

/// Output from a peer agent's xMesh LNN — cognitive state evolved from bidirectional CMB flows.
/// See MMP v0.2.0 Section 12 (xMesh).
public struct XMeshInsight: Sendable {
    /// Trajectory vector: [valence, arousal, v_vel, a_vel, stability, confidence].
    public let trajectory: [Float]
    /// 8 pattern activation values from the peer's LNN.
    public let patterns: [Float]
    /// Anomaly score (0-1) measuring deviation from expected cognitive state.
    public let anomaly: Float
    /// Predicted outcome label from the peer's LNN.
    public let outcome: String
    /// Mesh coherence score (0-1) across all peers in the mesh.
    public let coherence: Float
}

// MARK: - Synthesis Delegate

/// Protocol for agents to participate in the xMesh synthesis loop.
/// See MMP v0.2.0 Section 12 (xMesh).
///
/// When a peer's xMesh insight arrives, the agent processes it through its own
/// domain intelligence and returns a domain-specific interpretation (new outbound CMB),
/// or nil to skip. SYM shares the synthesis back to the mesh — completing the
/// bidirectional CMB flow.
///
/// Example:
/// ```swift
/// class MyAgent: SYMSynthesisDelegate {
///     func synthesizeInsight(from insight: XMeshInsight) -> String? {
///         if insight.anomaly > 0.6 {
///             return "fitness: high anomaly, movement break recommended"
///         }
///         return nil
///     }
/// }
/// ```
public protocol SYMSynthesisDelegate: AnyObject {
    /// Process a peer's xMesh insight through domain intelligence.
    /// - Parameter insight: The peer's cognitive state from its LNN.
    /// - Returns: A domain-specific interpretation string to share back to the mesh, or nil to skip.
    func synthesizeInsight(from insight: XMeshInsight) -> String?
}

// MARK: - SymNode

/// A sovereign mesh node. Embed in any iOS/macOS app to join the SYM mesh.
///
/// ```swift
/// let node = SymNode(name: "my-agent")
/// try await node.start()
///
/// node.remember(categories: [
///     .focus: CMBEncoder.encodeCategory("race condition in order processing"),
///     .issue: CMBEncoder.encodeCategory("concurrent writes to order state"),
///     .mood: CMBEncoder.encodeCategory("concerned"),
/// ])
/// let results = node.recall("order")
///
/// node.on { event in
///     switch event {
///     case .message(let from, let content):
///         print("\(from): \(content)")
///     default: break
///     }
/// }
///
/// await node.stop()
/// ```
public final class SymNode {

    // MARK: - Properties

    /// Display name of this node, used in handshake and peer identification. See MMP v0.2.0 Section 3.
    public let name: String

    /// Globally unique node ID (full UUID). Available immediately after init. See MMP Section 3.1.
    public let nodeId: String

    /// Cognitive profile — declares what this agent understands.
    /// Encoded into the cognitive state so the coupling engine knows
    /// what mood/intent signals are relevant to this agent.
    private let cognitiveProfile: String?
    private let moodThreshold: Float

    // SVAF parameters (MMP v0.2.0 Section 9)
    private let svafStableThreshold: Float      // ≤ this: aligned (default 0.25)
    private let svafGuardedThreshold: Float     // ≤ this: guarded; > this: rejected (default 0.5)
    private let svafTemporalLambda: Float       // Weight of temporal drift in combined score (default 0.3)
    private let svafFreshnessSeconds: Float     // τ_freshness for temporal decay (default 1800 = 30min)
    private let svafCategoryWeights: CMBCategoryWeights  // Per-category α_f weights
    // SVAF fourth outcome: semantic redundancy (paper §4.5). Fires BEFORE
    // the fusion classifier because SVAF's fusion-based drift formula
    // collapses identical and orthogonal inputs to the same drift value,
    // so redundancy has to be detected via similarity, not drift.
    private let svafRedundancyThreshold: Float   // Redundant if max per-category cosSim > (1 − this) across all categories
    private let svafRedundancyCheckEnabled: Bool // Feature flag — default off for backward compat
    private let retentionSeconds: TimeInterval    // How long to keep CMBs in local storage (default 86400 = 24h)
    private var purgeTimer: Timer?

    private let identity: SymIdentity
    private let store: any CMBStore
    private let meshNode: MeshNode
    private let discovery: SymDiscovery
    private let logger: Logger

    // Protocol metrics — MMP v0.2.0 Section 13 (Application).
    private var _metrics = SymNodeMetrics()

    // Remix guard — MMP v0.2.0 Section 14.7: agents MUST NOT remix without new domain data.
    private var _hasNewDomainData = false

    // E2E encryption (Curve25519 + AES-256-GCM)
    private let e2ePrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let e2ePublicKeyData: Data
    /// Base64-encoded public key for handshake frames.
    private let e2ePublicKeyB64: String
    /// Per-peer shared secrets derived from ECDH. Keyed by peer nodeId.
    /// Access only via peerQueue (same lock as peers dict).
    private var peerSharedSecrets: [String: SymmetricKey] = [:]

    /// Active peer sessions keyed by nodeId. Access only via peerQueue.
    private var peers: [String: PeerState] = [:]
    private let peerQueue = DispatchQueue(label: "bot.sym.peers", qos: .userInitiated)
    /// Relay peers we have already introduced ourselves to THIS relay session (handshake +
    /// wake-channel sent). A handshake is sent once per peer per session: the directory re-announces
    /// stale entries every refresh, and a sym-swift peer answers a handshake by adding us — so two
    /// sym-swift nodes echoed handshake+wake-channel at each other until the relay's rate limit
    /// closed both (0.4.6; 100 handshakes in 26 ms, measured by dev-team-2). Cleared on relay
    /// disconnect, and per peer when the relay loses it, so a returning peer is greeted again.
    private var relayHandshakeSent: Set<String> = []

    /// Protects non-peer mutable state: eventHandlers, _running, wakeChannel, pendingSessions.
    private let stateQueue = DispatchQueue(label: "bot.sym.state", qos: .userInitiated)

    /// Inbound sessions awaiting handshake. Retained here to prevent ARC deallocation.
    /// Access only via peerQueue.
    private var pendingSessions: [ObjectIdentifier: SymPeerSession] = [:]

    /// NodeIds for which an outbound discovery session is currently in
    /// flight (created but not yet handshaked or torn down). Used to
    /// dedup `discoveryDidFindPeer` callbacks that fire repeatedly for
    /// the same peer (mDNS `.changed` events, transient remove+re-add)
    /// and to look up pending sessions when the peer goes away.
    /// Mutated only under `peerQueue`.
    private var pendingOutboundNodeIds: Set<String> = []

    /// Track last coupling decision per peer — only log/emit on change.
    private var lastCouplingDecisions: [String: String] = [:]

    /// Section 3.5 + 11.1: peer lifecycle roles from handshake.
    /// Used to apply validator-origin anchor weight 2.0 (Section 6.4).
    private var peerLifecycleRoles: [String: String] = [:]
    /// Peer Ed25519 signing public keys (base64url), captured from each peer's
    /// handshake. Used to verify the signatures on CMBs they author (MMP §8.3).
    private var peerSigningKeys: [String: String] = [:]

    /// MMP §8.3 rejection stance, in ONE place for both record shapes.
    ///
    /// Reject ONLY present-but-invalid — a forged or tampered CMB. `no-public-key` means this
    /// node cannot verify YET (the author's key has not been learned — e.g. a broadcast arriving
    /// via a relay roster before any handshake with the author): that is UNVERIFIED, never
    /// forged, and it must not be rejected — rejecting it made every Swift↔Swift broadcast
    /// between freshly-met nodes fail as "bad signature", which reads as forgery in the logs
    /// while actually meaning key-distribution latency. The JS reference and the v2 path here
    /// already held this stance; the flat path had drifted because the stance lived as two
    /// copies. Now it is one predicate; both paths call it.
    private func rejectsSignature(signed: Bool, valid: Bool, error: String?) -> Bool {
        return signed && !valid && error != "no-public-key"
    }

    /// Test seam for the stance above — the predicate is the security decision, so it is pinned
    /// by tests rather than re-derived in them.
    internal func testHook_rejectsSignature(signed: Bool, valid: Bool, error: String?) -> Bool {
        rejectsSignature(signed: signed, valid: valid, error: error)
    }

    /// Test seam: build the payload-carrying frame without a live peer.
    internal func testHook_makePayloadCMBFrame(payload: Data,
                                               categories: [CMBCategory: CMBCategoryVector],
                                               for peerId: String) -> SymFrame {
        makePayloadCMBFrame(payload: payload, categories: categories, for: peerId)
    }

    /// Test seam: drive the inbound payload router without a live peer.
    internal func testHook_handleIncomingPayload(_ payload: Data, from nodeId: String,
                                                 peerName: String, cmbKey: String?) {
        handleIncomingPayload(payload, from: nodeId, peerName: peerName, cmbKey: cmbKey)
    }

    /// Section 6.4: CMB keys from validator/anchor nodes — anchor weight multiplier 2.0.
    /// Can't add property to CMBStoreEntry (binary framework), so track externally.
    private var validatorOriginKeys: Set<String> = []

    /// Event handlers. Access only via stateQueue.
    private var eventHandlers: [(SymEvent) -> Void] = []

    /// Pending request/response correlations. Lives in its own lock-protected
    /// type so the async surface can be vended as a `Sendable` handle — see
    /// ``SymExchange``.
    let correlationRegistry = SymCorrelationRegistry()

    /// Synthesis delegate for the xMesh synthesis loop. See MMP v0.2.0 Section 12.
    /// Agent processes peer xMesh insight through its own domain intelligence.
    /// Returns domain-specific insight as a new outbound CMB. SYM shares it back to mesh.
    public weak var synthesisDelegate: SYMSynthesisDelegate?

    /// LLM category extractor for CMB category extraction. See MMP v0.2.0 Section 9.
    /// App provides LLM implementation; falls back to heuristic keyword extraction if nil.
    public weak var categoryExtractor: CMBCategoryExtractor?

    /// Periodic re-encode timer (30s — re-encodes context and broadcasts).
    private var encodeTimer: Timer?

    /// **DEPRECATED in MMP v0.2.2.** Periodic state-sync timer. Hidden
    /// states never cross the wire under SVAF (Xu, 2026, §3.4); the timer
    /// is no longer scheduled and `stateSyncInterval` is a no-op preserved
    /// for source compatibility.
    private var stateSyncTimer: Timer?
    private var statsTimer: Timer?
    private let stateSyncInterval: TimeInterval

    private var _running = false
    /// Whether this node is currently running (started and not stopped).
    public var isRunning: Bool { stateQueue.sync { _running } }

    // Relay
    private let relayURL: URL?
    private let relayToken: String?
    /// The room PARTITION this node joins on the relay, inside `relayToken`'s channel.
    ///
    /// The token gates WHICH CHANNEL the relay lets this node reach; the room subdivides that
    /// already-authenticated channel. A client may safely name it because it can only narrow what
    /// this node receives, never widen it. `nil` is the unnamed partition — the behaviour of every
    /// build before rooms existed.
    ///
    /// Requires a relay running 0.1.3 or newer. An older relay IGNORES the field, which means every
    /// room silently shares one channel — connected, but not isolated.
    private let relayRoom: String?
    private let relayOnly: Bool
    private var relaySession: SymRelaySession?

    // Wake
    private var wakeChannel: (platform: String, token: String, environment: String)?

    /// Known peer wake channels learned from peer-info gossip. Keyed by nodeId.
    /// Access only via stateQueue.
    private var peerWakeChannels: [String: SymWakeChannel] = [:]

    // MARK: - Internal Peer State

    /// Per MMP Section 4.6: a peer MAY have multiple transports (LAN + WAN).
    /// Peer-left only when ALL transports close (Section 5.5).
    private struct PeerState {
        var transports: [String: SymPeerSession?] // source → session (nil for relay)
        let name: String
        let isOutbound: Bool
        var lastSeen: Date

        /// The primary source — first transport added.
        var source: String { transports.keys.first ?? "unknown" }

        /// Best session for sending: bonjour > relay.
        var session: SymPeerSession? {
            if let s = transports["bonjour"] { return s }
            for (_, s) in transports { if let s { return s } }
            return nil
        }
    }

    // MARK: - Init

    /// Create a sovereign mesh node.
    ///
    /// - Parameters:
    ///   - name: Node display name.
    ///   - cognitiveProfile: What this agent understands — encoded into cognitive state.
    ///   - moodThreshold: Drift threshold for accepting mood signals (default 0.8).
    ///   - svafStableThreshold: SVAF drift ≤ this is "aligned" (default 0.25 = 75% similarity).
    ///   - svafGuardedThreshold: SVAF drift ≤ this is "guarded"; above is rejected (default 0.5 = 50% similarity).
    ///   - svafTemporalLambda: Weight of temporal drift in combined score (default 0.3).
    ///   - svafFreshnessSeconds: τ for temporal decay — signals older than this are stale (default 1800 = 30min).
    ///   - svafCategoryWeights: Per-category α_f weights for SVAF evaluation (default: uniform).
    ///   - svafRedundancyThreshold: Paper §4.5 fourth outcome. An incoming CMB is
    ///     classified as *redundant* when every CAT7 category's vector has cosine
    ///     similarity greater than `(1 − svafRedundancyThreshold)` with at least
    ///     one existing anchor category's vector. Default `0.02` — conservative, meaning
    ///     inputs must be ≥ 98% similar on every category to be considered redundant.
    ///     Tune per agent based on the observed distribution of near-duplicates in
    ///     the production workload. Has no effect unless
    ///     `svafRedundancyCheckEnabled` is `true`.
    ///   - svafRedundancyCheckEnabled: Feature flag gating the redundancy pre-filter
    ///     described above. Default `false` for backward compatibility — existing
    ///     consumers upgrading the SDK version see identical behaviour. Agents that
    ///     want the fourth SVAF outcome enable it explicitly at init (e.g. MeloTune
    ///     in `SymMeshService`). When disabled, the receive handler behaves exactly
    ///     as prior SDK versions: the three-outcome classifier (aligned / guarded /
    ///     rejected) plus R5 mood passthrough.
    ///   - retentionSeconds: How long to keep CMBs in local storage (default 86400 = 24h).
    ///     Regulated domains MUST set this per compliance requirements:
    ///     legal (per jurisdiction), health (HIPAA 6yr), finance (MiFID II 5yr, SEC 7yr).
    ///   - store: Custom CMB storage implementation. Defaults to file-based storage.
    ///     Pass a read-only CMBStore for audit agents that observe without modifying.
    ///   - stateSyncInterval: **DEPRECATED in MMP v0.2.2.** No-op. Hidden
    ///     states never cross the wire under SVAF (Xu, 2026, §3.4).
    ///     Cognitive coupling propagates as CMBs via ``remember(categories:tags:parents:originTimestamp:)``;
    ///     this parameter is preserved on the API surface only for source
    ///     compatibility with MMP v0.2.0/v0.2.1 clients.
    ///   - relay: WebSocket relay URL for internet-scale mesh (e.g. `wss://sym-relay.onrender.com`).
    ///   - relayToken: Shared secret for relay authentication — selects the channel.
    ///   - relayRoom: Optional room partition inside that channel (relay 0.1.3+).
    ///   - relayOnly: If true, skip Bonjour discovery and only use the relay.
    ///   - discoveryServiceType: Bonjour service type for LAN discovery.
    ///     Defaults to `_sym._tcp` (interoperable with Node.js SYM nodes).
    ///     Apps that want isolated LAN meshes should use a custom type
    ///     (e.g. `_melotune._tcp`). Peers on different service types never
    ///     see each other on LAN.
    public init(
        name: String,
        cognitiveProfile: String? = nil,
        moodThreshold: Float = 0.8,
        svafStableThreshold: Float = 0.25,
        svafGuardedThreshold: Float = 0.5,
        svafTemporalLambda: Float = 0.3,
        svafFreshnessSeconds: Float = 1800,
        svafCategoryWeights: CMBCategoryWeights = .uniform,
        svafRedundancyThreshold: Float = 0.02,
        svafRedundancyCheckEnabled: Bool = false,
        retentionSeconds: TimeInterval = 86400,
        store: (any CMBStore)? = nil,
        stateSyncInterval: TimeInterval = 0,
        relay: URL? = nil,
        relayToken: String? = nil,
        relayRoom: String? = nil,
        relayOnly: Bool = false,
        discoveryServiceType: String = "_sym._tcp"
    ) {
        self.name = name
        self.cognitiveProfile = cognitiveProfile
        self.moodThreshold = moodThreshold
        self.svafStableThreshold = svafStableThreshold
        self.svafGuardedThreshold = svafGuardedThreshold
        self.svafTemporalLambda = svafTemporalLambda
        self.svafFreshnessSeconds = svafFreshnessSeconds
        self.svafCategoryWeights = svafCategoryWeights
        self.svafRedundancyThreshold = svafRedundancyThreshold
        self.svafRedundancyCheckEnabled = svafRedundancyCheckEnabled
        self.retentionSeconds = retentionSeconds
        self.stateSyncInterval = stateSyncInterval
        self.relayURL = relay
        self.relayToken = relayToken
        self.relayRoom = relayRoom
        self.relayOnly = relayOnly
        self.identity = SymIdentityManager.loadOrCreate(name: name)
        self.nodeId = identity.nodeId
        self.logger = Logger(subsystem: "bot.sym", category: "SymNode.\(name)")

        // E2E encryption keypair — persisted alongside identity
        let keyPair = SymIdentityManager.loadOrCreateE2EKeyPair(name: name)
        self.e2ePrivateKey = keyPair.privateKey
        self.e2ePublicKeyData = keyPair.publicKey
        self.e2ePublicKeyB64 = keyPair.publicKey.base64EncodedString()

        let nodeDir = SymIdentityManager.nodeDirectory(for: name)
        self.store = store ?? SymMemoryStore(nodeDir: nodeDir, sourceName: name)
        self.meshNode = MeshNode(options: MeshNodeOptions(hiddenDim: ContextEncoder.dim))
        self.discovery = SymDiscovery(identity: identity, serviceType: discoveryServiceType)

        initLocalState()
    }

    // MARK: - SVAF Redundancy Pre-Filter (Paper §4.5 fourth outcome)

    /// Tag applied to memory entries that were absorbed by the
    /// redundancy pre-filter. Kept as a type constant so tests and
    /// future store-level filters can reference the same string.
    internal static let absorbedTag = "sym.absorbed"

    /// Classify an incoming CMB as redundant relative to a set of
    /// anchors. Returns `true` when every CAT7 category's vector has
    /// cosine similarity greater than `(1 − svafRedundancyThreshold)`
    /// with at least one anchor category's vector. In other words, the
    /// incoming adds no new information to any of the seven semantic
    /// dimensions the receiver tracks.
    ///
    /// Runs only when `svafRedundancyCheckEnabled` is true. When the
    /// flag is off, the method always returns `false` — preserving
    /// backward compatibility with SDK consumers who have not opted
    /// in to the fourth outcome.
    ///
    /// Design notes:
    ///   - The check is AND over all categories, not OR. A single novel
    ///     category saves the CMB from the redundancy classification —
    ///     this protects against losing a CMB that shares six out of
    ///     seven categories with an existing anchor but carries a
    ///     genuinely new signal in the seventh.
    ///   - The check succeeds as long as ANY anchor in the set
    ///     covers the incoming. Unrelated anchors in the set must
    ///     not block the classification.
    ///   - Uses similarity (not SVAF's fusion-based drift) because
    ///     the fusion formula collapses identical and orthogonal
    ///     inputs to the same drift value. See
    ///     SVAFFusionDriftSemanticsTests for the locked-in behaviour
    ///     that motivates this design.
    ///
    /// Exposed as `internal` rather than `private` so the dedicated
    /// test suite (SVAFRedundancyTests) can exercise it directly
    /// without spinning up a live peer session. Production code
    /// calls it from a single site in the receive handler.
    internal func isCMBRedundant(
        incoming: CognitiveMemoryBlock,
        anchors: [CognitiveMemoryBlock]
    ) -> Bool {
        guard self.svafRedundancyCheckEnabled, !anchors.isEmpty else { return false }
        let similarityFloor = 1.0 - self.svafRedundancyThreshold
        for category in CMBCategory.allCases {
            guard let incomingCategory = incoming.categories[category] else { continue }
            let bestSim = anchors
                .compactMap { $0.categories[category]?.vector }
                .map { CMBEncoder.cosineSimilarity(incomingCategory.vector, $0) }
                .max() ?? 0
            if bestSim < similarityFloor {
                return false  // this category is novel → not redundant overall
            }
        }
        return true  // all populated categories are near-duplicates of some anchor
    }

    // MARK: - Context Encoding

    private func initLocalState() {
        let context = buildContext()
        if context.count > 5 {
            let (h1, h2) = ContextEncoder.encode(context)
            meshNode.updateLocalState(h1, h2, confidence: 0.8)
        } else {
            let h1 = (0..<ContextEncoder.dim).map { _ in Float.random(in: -0.05...0.05) }
            let h2 = (0..<ContextEncoder.dim).map { _ in Float.random(in: -0.05...0.05) }
            meshNode.updateLocalState(h1, h2, confidence: 0.3)
        }
    }

    private func buildContext() -> String {
        var parts: [String] = []
        if let profile = cognitiveProfile { parts.append(profile) }
        parts.append(contentsOf: store.allEntries().prefix(20).map(\.content))
        return parts.joined(separator: "\n")
    }

    /// Periodic re-encoding of the local cognitive state from accumulated
    /// memory. Updates the local CfC's hidden state in-place; **never**
    /// broadcasts it. Cognitive signals propagate to peers only as CMBs via
    /// ``remember(categories:tags:parents:originTimestamp:)``.
    private func reencodeAndBroadcast() {
        let context = buildContext()
        guard context.count > 5 else { return }

        let (h1, h2) = ContextEncoder.encode(context)
        meshNode.updateLocalState(h1, h2, confidence: 0.8)
        // MMP v0.2.2: do not broadcast hidden state. SVAF (Xu, 2026, §3.4)
        // requires that hidden states stay private to each agent. The local
        // state update above is sufficient for the local CfC to evaluate
        // future incoming CMBs at SVAF Layer 4.
    }

    // MARK: - Lifecycle

    /// Start the node — begins discovery and listens for peers.
    ///
    /// If `relay` was provided, connects to the relay for internet-scale mesh.
    /// If `relayOnly` is false (default), also starts Bonjour for local peers.
    public func start() {
        guard !_running else { return }
        _running = true
        _metrics.startedAt = Date()

        if !relayOnly {
            discovery.delegate = self
            discovery.start()
        }

        if let relayURL {
            let relay = SymRelaySession(url: relayURL, identity: identity, token: relayToken, room: relayRoom)
            relay.delegate = self
            relay.start()
            self.relaySession = relay
        }

        encodeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.reencodeAndBroadcast()
        }

        // MMP v0.2.2: the periodic state-sync broadcast is removed. Hidden
        // states never cross the wire under SVAF (Xu, 2026, §3.4). The
        // `stateSyncInterval` constructor parameter is preserved for
        // source-compatibility but is now a no-op. A v0.2.0 peer that still
        // sends state-sync frames will have those frames silently dropped
        // by the receive handler.
        _ = stateSyncInterval  // intentionally unused

        // Retention purge — run on start + every hour
        store.purge(retentionSeconds: retentionSeconds)
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.purge(retentionSeconds: self.retentionSeconds)
        }

        // Node-stats self-report — emit on start + every 15s so mesh observers can
        // display this (possibly sovereign/cross-device) node's emitted/admitted/memory.
        // Matches Node.js SymNode._emitNodeStats() / _statsTimer (lib/node.js).
        emitNodeStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.emitNodeStats()
        }

        let relayInfo = relayURL != nil ? ", relay: \(relayURL!.absoluteString)" : ""
        logger.info("[SYM] node: started: \(self.name) (\(self.identity.nodeId.prefix(8))\(relayInfo))")
    }

    /// Stop the node — disconnects all peers and stops discovery.
    public func stop() {
        guard _running else { return }
        _running = false

        encodeTimer?.invalidate()
        encodeTimer = nil
        stateSyncTimer?.invalidate()
        stateSyncTimer = nil
        purgeTimer?.invalidate()
        purgeTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil

        relaySession?.stop()
        relaySession = nil

        peerQueue.sync {
            for (_, peer) in self.peers {
                peer.session?.disconnect()
            }
            self.peers.removeAll()
            self.peerSharedSecrets.removeAll()
        }

        if !relayOnly {
            discovery.stop()
        }

        // Pending requests never survive a stop (or the app suspension that
        // calls it): fail every awaiting caller now rather than leaving a
        // continuation that can only be resumed by a peer this node is no
        // longer connected to. Fail-fast on resume is the contract; surviving
        // suspension is an application-layer retry.
        let orphaned = correlationRegistry.drain()
        for continuation in orphaned {
            continuation.resume(throwing: SymRequestError.interrupted)
        }
        if !orphaned.isEmpty {
            logger.info("[SYM] node: stopped with \(orphaned.count) pending request(s) — failed as interrupted")
        }

        logger.info("[SYM] node: stopped: \(self.name)")
    }

    // MARK: - Event Handling

    /// Register an event handler for mesh events. See MMP v0.2.0 Section 13.
    ///
    /// Multiple handlers can be registered; all are called for each event.
    /// - Parameter handler: Closure invoked on each ``SymEvent``.
    public func on(_ handler: @escaping (SymEvent) -> Void) {
        stateQueue.async { [weak self] in
            self?.eventHandlers.append(handler)
        }
    }

    private func emit(_ event: SymEvent) {
        let handlers = stateQueue.sync { eventHandlers }
        for handler in handlers {
            handler(event)
        }
    }

    // MARK: - Memory

    /// Store a memory with structured CAT7 categories and broadcast to coupled peers.
    /// See MMP v0.2.0 Section 6 (Memory) and Section 14 (Remix).
    ///
    /// The agent extracts categories — the protocol does not parse raw text.
    /// After storing, re-encodes cognitive state and shares with peers based on SVAF coupling decisions.
    ///
    /// - Parameters:
    ///   - categories: CAT7 category vectors (agent extracts these via ``CMBEncoder``).
    ///   - tags: Optional tags for search/filtering.
    ///   - parents: Parent CMBs this is a remix of. Lineage is computed automatically per Section 14.
    ///   - originTimestamp: When the event happened (epoch ms). Defaults to now.
    /// - Returns: The stored ``SymMemoryEntry``.
    @discardableResult
    public func remember(categories: [CMBCategory: CMBCategoryVector], tags: [String] = [], parents: [CognitiveMemoryBlock] = [], originTimestamp: UInt64? = nil) -> SymMemoryEntry? {
        let ts = originTimestamp ?? UInt64(Date().timeIntervalSince1970 * 1000)

        // MMP Section 14.7: enforce remix requires new domain data.
        // If parents are specified (this is a remix), the agent MUST have
        // produced new domain observations since its last remix.
        if !parents.isEmpty && !_hasNewDomainData {
            _metrics.remixRejected += 1
            logger.warning("[SYM] Remix rejected: no new domain data (MMP Section 14.7)")
            emit(.metric(type: "remix-rejected", detail: ["reason": "no-new-domain-data"]))
            return nil
        }

        // Compute lineage from parents per MMP spec Section 14
        let lineage: CMBLineage? = parents.isEmpty ? nil : CMBLineage(
            parents: parents.map(\.key),
            ancestors: parents.flatMap { ($0.lineage?.ancestors ?? []) + [$0.key] },
            method: "SVAF-v2"
        )

        var cmb = CMBEncoder.createCMB(categories: categories, source: name, originTimestamp: ts, lineage: lineage)
        // MMP §8.3: sign with our Ed25519 identity key so peers can verify
        // authenticity. Unsigned only if the identity has no private key.
        if let privateKey = identity.privateKey {
            cmb = CMBSigning.sign(cmb, privateKeyBase64URL: privateKey)
        }
        let content = CMBEncoder.renderContent(from: cmb)
        logger.info("[SYM] remember: \"\(content.prefix(80))\"")
        let entry = CMBStoreEntry(content: content, source: name, tags: tags, originTimestamp: originTimestamp, cmb: cmb)
        guard let stored = store.write(entry: entry) else { return entry }

        // Protocol metrics + remix guard
        _metrics.cmbProduced += 1
        if !parents.isEmpty { _metrics.remixProduced += 1 }
        _hasNewDomainData = true
        emit(.metric(type: "cmb-produced", detail: ["key": stored.key, "hasLineage": parents.isEmpty ? "false" : "true"]))

        return _afterRemember(stored)
    }

    /// Shared post-remember logic: re-encode, evaluate coupling, broadcast to peers.
    private func _afterRemember(_ entry: SymMemoryEntry) -> SymMemoryEntry {
        let context = buildContext()
        let (h1, h2) = ContextEncoder.encode(context)
        meshNode.updateLocalState(h1, h2, confidence: 0.8)

        _ = meshNode.coupledState()
        let decisions = meshNode.couplingDecisions

        var shared = 0
        let (currentPeers, currentSecrets): ([String: PeerState], [String: SymmetricKey]) = peerQueue.sync {
            (self.peers, self.peerSharedSecrets)
        }

        // Build base frame (plaintext — used for peers without E2E)
        var baseFrame = SymFrame.cmb(
            key: entry.key, content: entry.content,
            source: entry.source, tags: entry.tags,
            originTimestamp: entry.originTimestamp, storedAt: entry.storedAt
        )
        baseFrame.cmb = entry.cmb

        for (peerId, peer) in currentPeers {
            let d = decisions[peerId]
            if let d, d.decision == .rejected {
                logger.info("[SYM] memory: not sharing with \(peer.name) — rejected (drift: \(d.drift))")
                continue
            }

            // Encrypt categories per-peer if shared secret exists
            if let sharedSecret = currentSecrets[peerId],
               let categories = entry.cmb?.categories,
               let encrypted = E2ECrypto.encryptCategories(categories, sharedSecret: sharedSecret) {
                // Build encrypted frame: categories replaced with ciphertext, _e2e metadata added
                var encFrame = baseFrame
                encFrame.encryptedCategories = encrypted.ciphertext
                encFrame.e2e = E2EMetadata(nonce: encrypted.nonce)
                // Clear the plaintext CMB from the encrypted frame — key/createdBy/createdAt/lineage stay on the outer frame
                encFrame.cmb = nil
                sendToPeer(nodeId: peerId, frame: encFrame)
                logger.info("[SYM] e2e: encrypted CMB categories for \(peer.name)")
            } else {
                // Plaintext fallback for peers without E2E
                sendToPeer(nodeId: peerId, frame: baseFrame)
            }

            shared += 1
            if let d {
                logger.info("[SYM] memory: shared with \(peer.name) — \(d.decision.rawValue) (drift: \(d.drift))")
            }
        }

        logger.info("[SYM] memory: stored: \"\(entry.content.prefix(50))\" → \(shared)/\(currentPeers.count) peers")
        return entry
    }

    /// Relay an already-created CMB to this node's peers WITHOUT storing it or minting a
    /// new key. Lets ONE logical emission propagate across multiple meshes (one SymNode per
    /// room) as a SINGLE CMB: call `remember()` once on the primary node, then `relay(cmb)`
    /// on the others — instead of re-`remember`-ing per node, which mints a fresh key each
    /// time and double-counts a shared store (emitted N×, an observer on one mesh sees 1/N).
    public func relay(_ cmb: CognitiveMemoryBlock) {
        let (currentPeers, currentSecrets): ([String: PeerState], [String: SymmetricKey]) = peerQueue.sync {
            (self.peers, self.peerSharedSecrets)
        }
        var baseFrame = SymFrame.cmb(
            key: cmb.key,
            content: CMBEncoder.renderContent(from: cmb),
            source: cmb.source,
            tags: [],
            originTimestamp: cmb.originTimestamp,
            storedAt: cmb.storedAt
        )
        baseFrame.cmb = cmb

        for (peerId, _) in currentPeers {
            if let sharedSecret = currentSecrets[peerId],
               let encrypted = E2ECrypto.encryptCategories(cmb.categories, sharedSecret: sharedSecret) {
                var encFrame = baseFrame
                encFrame.encryptedCategories = encrypted.ciphertext
                encFrame.e2e = E2EMetadata(nonce: encrypted.nonce)
                encFrame.cmb = nil
                sendToPeer(nodeId: peerId, frame: encFrame)
            } else {
                sendToPeer(nodeId: peerId, frame: baseFrame)
            }
        }
        logger.info("[SYM] relay: \(cmb.key.prefix(20)) → \(currentPeers.count) peers")
    }

    // MARK: - Request/Response Correlation (0.5.0, reviewed sketch §5)

    /// The `Sendable` handle carrying the async request surface.
    ///
    /// The async half lives on ``SymExchange`` rather than on this class
    /// because `await`-ing a method on a non-`Sendable` class from an
    /// actor-isolated context sends the class across an isolation boundary —
    /// rejected under the Swift 6 language mode, which is what the consumers
    /// of this surface run. Hold the handle wherever you hold the node; it
    /// stays valid for the node's lifetime.
    ///
    /// A thin layer ABOVE the send path and the event tap: delivery
    /// semantics are untouched, and a matched response still flows to
    /// ``on(_:)`` subscribers. The payload rides the wire inside the `cmb`
    /// object as a sibling of the CAT7 content (Node parity) and is never
    /// part of the cmbKey hash or a signing preimage.
    public var exchange: SymExchange {
        SymExchange(registry: correlationRegistry) { [weak self] wirePayload, categories, peerId in
            guard let self else { return .notRunning }
            guard self.isRunning else { return .notRunning }
            let peerIsRoutable: Bool = self.peerQueue.sync { self.peers[peerId] != nil }
            guard peerIsRoutable else { return .peerUnknown }
            let frame = self.makePayloadCMBFrame(payload: wirePayload, categories: categories, for: peerId)
            self.sendToPeer(nodeId: peerId, frame: frame)
            return .sent
        }
    }

    /// Responder half: reply to a payload-bearing envelope, echoing its
    /// `request_id` and targeting its sender. Everything else about the
    /// reply is caller-built.
    /// - Throws: ``SymRequestError/invalidPayload`` when the payload bytes
    ///   do not encode a top-level JSON object.
    public func respond(to request: SymEnvelope,
                        payload: Data,
                        categories: [CMBCategory: CMBCategoryVector]) throws {
        guard var payloadObject = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw SymRequestError.invalidPayload
        }
        payloadObject["request_id"] = request.requestId
        let wirePayload = try JSONSerialization.data(withJSONObject: payloadObject)
        let frame = makePayloadCMBFrame(payload: wirePayload, categories: categories, for: request.from)
        sendToPeer(nodeId: request.from, frame: frame)
    }

    /// Build the signed, payload-carrying CMB frame both halves send —
    /// same per-peer E2E stance as ``relay(_:)``: categories encrypt when a
    /// shared secret exists; the payload itself rides plaintext either way
    /// (Node parity — the sidecar reads it as a plain sibling).
    private func makePayloadCMBFrame(payload: Data,
                                     categories: [CMBCategory: CMBCategoryVector],
                                     for peerId: String) -> SymFrame {
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        var cmb = CMBEncoder.createCMB(categories: categories, source: name, originTimestamp: ts, lineage: nil)
        if let privateKey = identity.privateKey {
            cmb = CMBSigning.sign(cmb, privateKeyBase64URL: privateKey)
        }
        var frame = SymFrame.cmb(
            key: cmb.key, content: CMBEncoder.renderContent(from: cmb),
            source: name, tags: [], originTimestamp: ts, storedAt: ts
        )
        frame.cmb = cmb
        frame.cmbPayload = payload

        let sharedSecretForPeer: SymmetricKey? = peerQueue.sync { self.peerSharedSecrets[peerId] }
        if let sharedSecret = sharedSecretForPeer,
           let encrypted = E2ECrypto.encryptCategories(cmb.categories, sharedSecret: sharedSecret) {
            frame.encryptedCategories = encrypted.ciphertext
            frame.e2e = E2EMetadata(nonce: encrypted.nonce)
            frame.cmb = nil
        }
        return frame
    }

    /// Route an inbound payload: resolve the pending request it answers, or
    /// surface it as ``SymEvent/requestReceived(envelope:)``. Called from the
    /// cmb receive path AFTER signature verification and BEFORE the SVAF
    /// verdict — the payload survives admitted and rejected outcomes alike
    /// (Node parity: `_preserveIncomingPayload`).
    private func handleIncomingPayload(_ payloadData: Data, from nodeId: String, peerName: String, cmbKey: String?) {
        guard let payloadObject = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let requestId = payloadObject["request_id"] as? String, !requestId.isEmpty else {
            logger.info("[SYM] payload: CMB payload from \(peerName) carries no request_id — ignoring")
            return
        }
        let envelope = SymEnvelope(from: nodeId, fromName: peerName, requestId: requestId,
                                   payload: payloadData, cmbKey: cmbKey)
        if let pending = correlationRegistry.take(requestId) {
            pending.resume(returning: envelope)
            logger.info("[SYM] payload: response matched request \(requestId.prefix(8))… from \(peerName)")
            emit(.metric(type: "request-correlated", detail: ["request_id": requestId, "from": peerName]))
        } else {
            logger.info("[SYM] payload: inbound request \(requestId.prefix(8))… from \(peerName)")
            emit(.requestReceived(envelope: envelope))
        }
    }

    /// Search memories across local and peer stores by keyword. See MMP v0.2.0 Section 6.
    /// - Parameter query: Search keyword matched against content, key, and tags.
    /// - Returns: Matching entries sorted by most recent first.
    public func recall(_ query: String) -> [SymMemoryEntry] {
        _metrics.recalls += 1
        return store.search(query: query)
    }

    // MARK: - State Sync (DEPRECATED)

    /// **DEPRECATED in MMP v0.2.2.** No-op. Hidden states never cross the
    /// wire under SVAF (Xu, 2026, *Symbolic-Vector Attention Fusion for
    /// Collective Intelligence*, arXiv:2604.03955, §3.4). Cognitive signals
    /// propagate as CMBs via ``remember(categories:tags:parents:originTimestamp:)``;
    /// the receiver evaluates them per-category at SVAF Layer 4 and the local
    /// CfC at Layer 6 integrates the fused categories. The `state-sync` frame
    /// type is preserved on the wire only so that v0.2.0 peers do not break
    /// the parser.
    @available(*, deprecated, message: "MMP v0.2.2: hidden states do not cross the wire. Call remember(categories:) to broadcast a CMB.")
    public func broadcastCurrentState() {
        // Intentionally a no-op. See doc comment.
    }

    // MARK: - Rule A (§7.5) — v2 emission on the author's own HEAD

    /// The last v2 address this node minted, persisted so the chain survives
    /// a restart. One HEAD per agent: the sequence, without a sequence number
    /// — parents ride inside signingPayloadV2, so an author's emissions form
    /// a SIGNED chain and position in it IS the ordering (the Node control
    /// plane reads exactly this; an unchained iOS node shows up as
    /// permanently unaccounted-for in its gauges).
    private var v2Head: String? = nil
    private var v2HeadLoaded = false

    private var v2HeadFile: URL {
        SymIdentityManager.nodeDirectory(for: name).appendingPathComponent("v2-head.json")
    }

    private func loadV2HeadIfNeeded() {
        guard !v2HeadLoaded else { return }
        v2HeadLoaded = true
        if let data = try? Data(contentsOf: v2HeadFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            v2Head = obj["head"]
        }
    }

    private func persistV2Head() {
        guard let head = v2Head,
              let data = try? JSONSerialization.data(withJSONObject: ["head": head]) else { return }
        try? data.write(to: v2HeadFile)
    }

    /// The Ed25519 signing key this node announces in its handshake — the
    /// key peers verify its emissions against. Public because it already is:
    /// every handshake broadcasts it.
    public var signingPublicKey: String? { identity.publicKey }

    public struct V2Emission {
        public let key: String
        public let record: CMBRecordV2
        /// True → re-assertion of the node's own HEAD: cited, not minted.
        /// Nothing stored, nothing broadcast, HEAD unmoved, lineage cleared
        /// (a caller may persist what it is handed; it must not leave here
        /// claiming descent from itself).
        public let collapsed: Bool
    }

    /// Emit a v2 two-section record, signed, parented on this node's own
    /// HEAD (Rule A). OPT-IN: flat emission stays the default until the
    /// fleet census clears — a pre-boundary iOS peer cannot read a v2 frame,
    /// and that rollout call is the gate-keeper's, not this code's.
    @discardableResult
    public func rememberV2(categories: [String: Any],
                           to: String? = nil,
                           extraParents: [String] = []) -> V2Emission? {
        loadV2HeadIfNeeded()

        // Rule A: the agent's own HEAD is always a parent; explicit parents
        // (peer descent) join it. Order is irrelevant — signing sorts bytewise.
        var parents = extraParents
        if let head = v2Head, !parents.contains(head) { parents.append(head) }
        let lineage = parents.isEmpty ? nil : CMBLineageV2(parents: parents, method: "SVAF-v2")

        guard var record = try? CMBRecordV2.create(
            categories: categories, createdBy: name, lineage: lineage, to: to) else {
            logger.error("[SYM] rememberV2: record creation failed (missing categories or author)")
            return nil
        }

        // §7.5 COLLAPSE-BEFORE-MINT [MUST]: re-asserting content identical to
        // your own HEAD produces the SAME ADDRESS as your HEAD; parenting it
        // on [own HEAD] writes the self-edge K→K. A mint-level refusal, not a
        // store-level dedup — nothing minted, HEAD unmoved, the caller handed
        // the address that already says this.
        if let head = v2Head, record.metadata.key == head {
            record.metadata.lineage = nil
            emit(.metric(type: "cmb-collapsed", detail: ["key": record.metadata.key, "reason": "identical-to-own-head"]))
            logger.info("[SYM] rememberV2: collapsed — re-assertion of own HEAD \(record.metadata.key.prefix(16))… cited, not minted")
            return V2Emission(key: record.metadata.key, record: record, collapsed: true)
        }

        // Sign: parents are inside signingPayloadV2, so the chain is
        // unforgeable — rewriting it breaks the signature.
        if let privateKey = identity.privateKey {
            if let signed = try? CMBSigningV2.sign(record, privateKeyB64url: privateKey) {
                record = signed
            } else {
                logger.error("[SYM] rememberV2: signing failed — emitting unsigned")
            }
        }

        // Store the receiver-local flat projection so this node's own SVAF
        // anchors and recall see its emissions (vectors receiver-local, per
        // §7.1 — same posture as the receive bridge).
        var flatCategories: [CMBCategory: CMBCategoryVector] = [:]
        for (categoryName, category) in record.categories {
            guard let cat7 = CMBCategory(rawValue: categoryName) else { continue }
            flatCategories[cat7] = CMBEncoder.encodeCategory(category.text,
                                                      valence: category.valence.map { Float($0) },
                                                      arousal: category.arousal.map { Float($0) })
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let flat = CognitiveMemoryBlock(
            key: record.metadata.key, categories: flatCategories, source: name, createdBy: name,
            createdAt: record.metadata.createdTimestamp,
            lineage: record.metadata.lineage.map { CMBLineage(parents: $0.parents) },
            originTimestamp: record.metadata.createdTimestamp, storedAt: now, confidence: 0.9)
        let entry = SymMemoryEntry(
            key: record.metadata.key,
            content: flatCategories.map { "\($0.key.rawValue): \($0.value.text)" }.sorted().joined(separator: "; "),
            source: name, tags: [], originTimestamp: record.metadata.createdTimestamp,
            storedAt: now, cmb: flat)
        _ = store.write(entry: entry)

        // HEAD advances only when something was actually minted.
        v2Head = record.metadata.key
        persistV2Head()

        // Broadcast the v2 record (serialize() carries cmbV2 under "cmb").
        var frame = SymFrame(type: .cmb)
        frame.source = name
        frame.cmbV2 = record
        broadcastToPeers(frame)

        emit(.metric(type: "cmb-produced-v2", detail: ["key": record.metadata.key]))
        return V2Emission(key: record.metadata.key, record: record, collapsed: false)
    }

    // MARK: - Mood

    /// Broadcast mood to all peers. See MMP v0.2.0 Section 9.3.
    ///
    /// Receiving agents evaluate this against their cognitive state and autonomously
    /// decide whether to act. Mood crosses domain boundaries — even rejected CMBs
    /// deliver their mood category.
    /// - Parameters:
    ///   - mood: Mood label (e.g. "tired", "focused", "stressed").
    ///   - context: Optional context string describing the mood trigger.
    public func broadcastMood(_ mood: String, context: String? = nil) {
        var frame = SymFrame(type: .mood)
        frame.from = identity.nodeId
        frame.fromName = name
        frame.mood = mood
        frame.context = context
        frame.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        let peerCount = peerQueue.sync { self.peers.count }
        let relayConnected = relaySession?.isConnected ?? false
        broadcastToPeers(frame)
        logger.info("[SYM] mood: broadcast: \(mood.prefix(50)) → \(peerCount) peer(s), relay: \(relayConnected)")
    }

    // MARK: - Wake

    /// Set the APNs/FCM device token for P2P wake. See MMP v0.2.0 Section 5.
    ///
    /// Called from AppDelegate when the device registers for remote notifications.
    /// The token is broadcast to already-connected peers so they can wake this node.
    /// - Parameters:
    ///   - platform: Push platform identifier (e.g. "apns", "fcm").
    ///   - token: Device push token string.
    ///   - environment: Push environment ("production" or "sandbox"). Defaults to "production".
    public func setWakeToken(platform: String, token: String, environment: String = "production") {
        wakeChannel = (platform: platform, token: token, environment: environment)
        logger.info("[SYM] wake: set: \(platform)")

        // Send to already-connected peers
        let frame = SymFrame.wakeChannel(platform: platform, token: token, environment: environment)
        broadcastToPeers(frame)
    }

    /// Reconnect to the relay after a P2P wake. See MMP v0.2.0 Section 5.
    ///
    /// Typically called from a silent push handler (e.g. `didReceiveRemoteNotification`).
    /// Tears down the current relay session and creates a fresh one.
    public func reconnect() {
        guard _running else { return }
        relaySession?.stop()
        if let url = relayURL {
            relaySession = SymRelaySession(url: url, identity: identity, token: relayToken, room: relayRoom)
            relaySession?.delegate = self
            relaySession?.start()
            logger.info("[SYM] relay: reconnecting after wake")
        }
    }

    // MARK: - Communication

    /// Send a text message to all peers or a specific peer. See MMP v0.2.0 Section 7.
    /// - Parameters:
    ///   - message: The message content string.
    ///   - peerId: Target peer node ID, or nil to broadcast to all peers.
    public func send(_ message: String, to peerId: String? = nil) {
        let frame = SymFrame.message(from: identity.nodeId, fromName: name, content: message)

        if let peerId {
            sendToPeer(nodeId: peerId, frame: frame)
        } else {
            broadcastToPeers(frame)
        }
    }

    // MARK: - Monitoring

    /// List connected peers with their current SVAF coupling state. See MMP v0.2.0 Section 9.
    /// - Returns: Array of ``SymPeerInfo`` for each connected peer.
    public func peerList() -> [SymPeerInfo] {
        let decisions = meshNode.couplingDecisions
        let currentPeers: [String: PeerState] = peerQueue.sync { self.peers }

        return currentPeers.map { (id, peer) in
            let d = decisions[id]
            // Read from the transports the peer actually holds, rather
            // than from how it was first discovered: a peer that gained a
            // relay path after joining on LAN is both, and stays both until
            // a transport closes.
            var reachability: Set<SymPeerReachability> = []
            for source in peer.transports.keys {
                reachability.insert(source == "bonjour" ? .localNetwork : .relay)
            }
            return SymPeerInfo(
                id: id,
                name: peer.name,
                connected: true,
                lastSeen: peer.lastSeen,
                coupling: d?.decision.rawValue ?? "pending",
                drift: d?.drift,
                reachability: reachability
            )
        }
    }

    /// Total memory count across local and peer stores. See MMP v0.2.0 Section 6.
    public var memoryCount: Int { store.count }

    /// Mesh coherence score (0-1), or nil if no peers connected. See MMP v0.2.0 Section 9.
    public var coherence: Float? { meshNode.coherence }

    /// Full node status snapshot including peers, memory count, and coherence. See MMP v0.2.0 Section 13.
    /// - Returns: A ``SymNodeStatus`` with the current state of this node.
    public func status() -> SymNodeStatus {
        let peerInfo = peerList()
        return SymNodeStatus(
            name: name,
            nodeId: identity.nodeId,
            running: _running,
            port: relayOnly ? 0 : discovery.port,
            relay: relayURL?.absoluteString,
            relayConnected: relaySession?.isConnected ?? false,
            relayClose: relaySession?.lastClose,
            peers: peerInfo,
            peerCount: peerInfo.count,
            memoryCount: memoryCount,
            coherence: coherence
        )
    }

    // MARK: - Internal Networking

    /// Broadcast this node's store tally (emitted/admitted/memory) to all peers so a mesh
    /// observer can display it. Matches Node.js SymNode._emitNodeStats() (lib/node.js).
    private func emitNodeStats() {
        let tally: (emitted: Int, admitted: Int, memory: Int)
        if let ms = store as? SymMemoryStore {
            tally = ms.stats
        } else {
            tally = (0, 0, 0)
        }
        let frame = SymFrame.nodeStats(
            name: name, nodeId: identity.nodeId,
            emitted: tally.emitted, admitted: tally.admitted, memory: tally.memory
        )
        broadcastToPeers(frame)
    }

    private func broadcastToPeers(_ frame: SymFrame) {
        let currentPeers: [String: PeerState] = peerQueue.sync { self.peers }
        for (nodeId, peer) in currentPeers {
            // Section 4.6: send via best transport (bonjour > relay)
            if let session = peer.session {
                session.send(frame)
            } else if peer.transports.keys.contains("relay") {
                relaySession?.send(frame, to: nodeId)
            }
        }
    }

    // MARK: - Remix Guard (MMP v0.2.0 Section 14.7)

    /// Check whether this agent has new domain data available for remix.
    /// Per MMP Section 14.7: agents MUST NOT remix peer signals unless they
    /// have new observations from their own domain to intersect with.
    public func canRemix() -> Bool { _hasNewDomainData }

    /// Mark that the agent has completed a remix cycle. Resets the flag
    /// so the agent stays silent until it has fresh domain observations.
    public func markRemixed() { _hasNewDomainData = false }

    // MARK: - Protocol Metrics (MMP v0.2.0 Section 13)

    /// Report an LLM API call for protocol-level cost tracking.
    /// Called by the agent after each LLM invocation.
    public func reportLLMUsage(tokensIn: Int, tokensOut: Int, model: String = "gpt-4o-mini") {
        _metrics.llmCalls += 1
        _metrics.llmTokensIn += tokensIn
        _metrics.llmTokensOut += tokensOut
        _metrics.llmModel = model
        emit(.metric(type: "llm-call", detail: ["tokensIn": "\(tokensIn)", "tokensOut": "\(tokensOut)", "model": model]))
    }

    /// Get cumulative protocol-level metrics since node start.
    public func metrics() -> SymNodeMetrics { _metrics }

    private func sendToPeer(nodeId: String, frame: SymFrame) {
        let peer: PeerState? = peerQueue.sync { self.peers[nodeId] }
        guard let peer else { return }
        // Section 4.6: send via best transport (bonjour > relay)
        if let session = peer.session {
            session.send(frame)
        } else if peer.transports.keys.contains("relay") {
            relaySession?.send(frame, to: nodeId)
        }
    }

    // MARK: - Multi-Transport Peer Management (MMP Section 4.6)

    /// Deterministic tie-break for simultaneous-dial collisions. Both peers
    /// observe the same `(localNodeId, remoteNodeId)` pair (with the local
    /// and remote roles swapped on each side) and call this function with
    /// their respective `newIsOutbound` value. The function picks the same
    /// *physical* TCP connection on both sides — the outbound from the
    /// lower nodeId, which is the inbound on the higher nodeId — so neither
    /// peer needs to coordinate via a frame exchange.
    ///
    /// Returns `true` if the new session should replace the prior one,
    /// `false` if the prior should be kept and the new session disconnected.
    /// Internal-access for `@testable` unit tests.
    static func preferNewSessionInDualDial(
        localNodeId: String,
        remoteNodeId: String,
        newIsOutbound: Bool
    ) -> Bool {
        let localIsClient = localNodeId < remoteNodeId
        let keepOutbound = localIsClient
        return (keepOutbound == newIsOutbound)
    }

    /// Outcome of the addPeer state-machine. Threading note: the dict
    /// mutation happens inside `peerQueue.sync`; the cleanup actions
    /// (cancelling losers, sending frames, emitting events) happen after
    /// the lock is released so we don't hold `peerQueue` across I/O.
    private enum AddPeerOutcome {
        case firstTime                                  // never seen before — new peer-joined
        case secondaryTransport                         // existing peer, no prior bonjour
        case replacedPriorBonjour(prev: SymPeerSession) // simultaneous dial: new wins
        case rejectedNew                                // simultaneous dial: existing wins
    }

    /// Stale-prior detection threshold for dedup. If the existing peer entry
    /// has not been touched within this many seconds, treat it as stale and
    /// let the new connection replace it regardless of dedup tie-break.
    /// Matches `@sym-bot/sym` v0.5.3 `_heartbeatInterval` default (10s) so
    /// cross-runtime peers agree on the same staleness window.
    ///
    /// Without this, a peer process killed without graceful FIN (iOS app
    /// suspension, Mac Catalyst rebuild, network drop) leaves the survivor
    /// with a dead-but-ESTABLISHED TCP entry that the OS doesn't reap for
    /// hours. The dedup logic then keeps rejecting the live new dial.
    /// TCP keepalive (set in SymPeerSession.tcpParametersWithKeepalive)
    /// reaps within ~4s, but until that fires the lastSeen-age check is
    /// the application-level guard.
    /// 1-second threshold (NOT heartbeat-interval=10s). When a peer
    /// process is killed and quickly relaunches, its old run sent a CMB
    /// seconds before death, so lastSeen is still recent. A 10s threshold
    /// missed this and the dedup-reject path killed the legitimate redial.
    /// 1s tolerates sub-second TCP-retry races during initial handshake
    /// while letting normal peer-restart (≥1s gap between kill and re-dial)
    /// recover within the application layer.
    static let staleAfterSeconds: TimeInterval = 1

    private func addPeer(_ session: SymPeerSession, nodeId: String, peerName: String, isOutbound: Bool) {
        let outcome: AddPeerOutcome = peerQueue.sync {
            if var existing = self.peers[nodeId] {
                if let prev = existing.transports["bonjour"] ?? nil {
                    // Two cases land here:
                    //
                    // (1) Dual-dial collision (different directions): both peers
                    //     Bonjour-discovered each other and both initiated outbound
                    //     TCP. Each side holds one outbound + one inbound for the
                    //     same nodeId. Tie-break deterministically by nodeId — the
                    //     lower nodeId keeps its outbound, the higher its inbound —
                    //     so both peers select the same physical socket without
                    //     exchanging coordination frames.
                    //
                    // (2) Same-direction duplicate: a second connection in the same
                    //     direction as the established one. Happens when the OS
                    //     newConnectionHandler fires twice for the same advertised
                    //     service (multipath / TCP-retry / Bonjour-republish), or
                    //     when discoveryDidFindPeer fires repeatedly and the dedup
                    //     guard's window let one through. The first is healthy and
                    //     in active use — replacing it with the duplicate would
                    //     disconnect the wire pair on the remote side and trigger
                    //     a peer-left storm. Always reject the duplicate.
                    //
                    // BUT: both cases assume the prior is alive. A prior that
                    // hasn't been touched within `staleAfterSeconds` is treated
                    // as stale and replaced — the remote re-dialling is itself
                    // strong evidence its prior is dead, and rejecting blocks
                    // legitimate reconnects after a peer restart for hours
                    // until OS keepalive reaps the zombie.
                    //
                    // The losing session has its delegate detached before disconnect
                    // (see fall-through below) so its teardown can't ripple through
                    // removeTransport and clobber the surviving registered session.
                    let staleByLastSeen = Date().timeIntervalSince(existing.lastSeen) > Self.staleAfterSeconds
                    let preferNew: Bool
                    if staleByLastSeen {
                        // Prior is stale — the new dial is the live one. Replace.
                        preferNew = true
                    } else {
                        let isDualDial = prev.isOutbound != session.isOutbound
                        if isDualDial {
                            preferNew = SymNode.preferNewSessionInDualDial(
                                localNodeId: self.identity.nodeId,
                                remoteNodeId: nodeId,
                                newIsOutbound: isOutbound
                            )
                        } else {
                            // Same direction → keep the established prior, reject duplicate.
                            preferNew = false
                        }
                    }
                    if preferNew {
                        existing.transports["bonjour"] = session
                        existing.lastSeen = Date()
                        self.peers[nodeId] = existing
                        return .replacedPriorBonjour(prev: prev)
                    }
                    return .rejectedNew
                }
                // Section 4.6: add Bonjour as secondary transport on top of relay
                existing.transports["bonjour"] = session
                existing.lastSeen = Date()
                self.peers[nodeId] = existing
                return .secondaryTransport
            }
            self.peers[nodeId] = PeerState(
                transports: ["bonjour": session], name: peerName,
                isOutbound: isOutbound, lastSeen: Date()
            )
            return .firstTime
        }

        switch outcome {
        case .rejectedNew:
            // Detach the delegate so this session's eventual cancellation does NOT
            // fire didDisconnectWith → removeTransport, which would strip the
            // still-registered winner from the transports dict.
            logger.info("[SYM] peer: simultaneous-dial dedup — keeping prior, cancelling redundant \(isOutbound ? "outbound" : "inbound") to \(peerName)")
            session.delegate = nil
            session.disconnect()
            return
        case .replacedPriorBonjour(let prev):
            logger.info("[SYM] peer: simultaneous-dial dedup — replacing prior with new \(isOutbound ? "outbound" : "inbound") to \(peerName)")
            prev.delegate = nil
            prev.disconnect()
        case .secondaryTransport, .firstTime:
            break
        }

        // Handshake was already sent in sessionDidBecomeReady (on TCP connect).
        // Send wake channel now that the peer is registered.
        if let wc = wakeChannel {
            session.send(.wakeChannel(platform: wc.platform, token: wc.token, environment: wc.environment))
        }

        let isNew: Bool
        switch outcome {
        case .firstTime:                                isNew = true
        case .secondaryTransport, .replacedPriorBonjour: isNew = false
        case .rejectedNew:                               return // unreachable, returned above
        }

        if isNew {
            let knownPeers = buildPeerGossip(excluding: nodeId)
            if !knownPeers.isEmpty { session.send(.peerInfo(peers: knownPeers)) }

            logger.info("[SYM] peer: connected: \(peerName) (\(isOutbound ? "outbound" : "inbound"), bonjour)")
            _metrics.peersJoined += 1
            emit(.peerJoined(nodeId: nodeId, name: peerName))
            emit(.metric(type: "peer-joined", detail: ["name": peerName, "source": "bonjour"]))
        } else {
            logger.info("[SYM] transport added for \(peerName): bonjour")
        }
    }

    private func addRelayPeer(nodeId: String, peerName: String) {
        guard nodeId != identity.nodeId else { return }
        guard !peerName.isEmpty, peerName != "unknown" else { return }

        let isNew = peerQueue.sync { () -> Bool in
            if var existing = self.peers[nodeId] {
                // Section 4.6: add relay as secondary transport
                existing.transports["relay"] = nil as SymPeerSession?
                existing.lastSeen = Date()
                self.peers[nodeId] = existing
                return false
            }
            self.peers[nodeId] = PeerState(
                transports: ["relay": nil], name: peerName,
                isOutbound: true, lastSeen: Date()
            )
            return true
        }

        // Send handshake + wake channel via relay — ONCE per peer per relay session. MMP v0.2.2: no
        // state-sync — hidden states never cross the wire (SVAF, Xu 2026, §3.4). Unconditional
        // sending here was the echo: A's handshake → B adds A and handshakes → A adds B and
        // handshakes → … until the relay closed both. The exchange now terminates after one
        // handshake each way: the receiver's reply lands on a sender that already has it in the set.
        let firstIntroduction = peerQueue.sync { () -> Bool in
            if self.relayHandshakeSent.contains(nodeId) { return false }
            self.relayHandshakeSent.insert(nodeId)
            return true
        }
        if firstIntroduction {
            relaySession?.send(.handshake(nodeId: identity.nodeId, name: name, publicKey: identity.publicKey, e2ePublicKey: e2ePublicKeyB64, lifecycleRole: "observer"), to: nodeId)
            if let wc = wakeChannel {
                relaySession?.send(.wakeChannel(platform: wc.platform, token: wc.token, environment: wc.environment), to: nodeId)
            }
        }

        if isNew {
            let knownPeers = buildPeerGossip(excluding: nodeId)
            if !knownPeers.isEmpty { relaySession?.send(.peerInfo(peers: knownPeers), to: nodeId) }

            logger.info("[SYM] peer: connected: \(peerName) (outbound, relay)")
            _metrics.peersJoined += 1
            emit(.peerJoined(nodeId: nodeId, name: peerName))
            emit(.metric(type: "peer-joined", detail: ["name": peerName, "source": "relay"]))
        } else {
            logger.info("[SYM] transport added for \(peerName): relay")
        }
    }

    /// Section 4.6 + 5.5: remove a single transport. Peer-left only when ALL transports close.
    private func removeTransport(nodeId: String, source: String) {
        let shouldRemovePeer = peerQueue.sync { () -> Bool in
            guard var peer = self.peers[nodeId] else { return false }
            peer.transports.removeValue(forKey: source)
            if peer.transports.isEmpty {
                return true // will be removed by removePeer below
            }
            self.peers[nodeId] = peer
            return false
        }

        if shouldRemovePeer {
            removePeer(nodeId: nodeId)
        } else {
            let peerName = peerQueue.sync { self.peers[nodeId]?.name ?? "unknown" }
            logger.info("[SYM] transport closed for \(peerName): \(source) (other transports remain)")
        }
    }

    /// Section 5.5: on relay disconnect, close relay transports only — Bonjour survives.
    private func removeRelayTransports() {
        let peerIds: [String] = peerQueue.sync {
            self.relayHandshakeSent.removeAll()   // a new relay session greets everyone once again
            return self.peers.filter { $0.value.transports.keys.contains("relay") }.map(\.key)
        }
        for nodeId in peerIds {
            removeTransport(nodeId: nodeId, source: "relay")
        }
    }

    /// Build gossip payload of known peers (excluding `excludeId`) for peer-info frames.
    private func buildPeerGossip(excluding excludeId: String) -> [SymPeerGossip] {
        let currentPeers: [String: PeerState] = peerQueue.sync { self.peers }
        let wakeChannels: [String: SymWakeChannel] = stateQueue.sync { self.peerWakeChannels }

        return currentPeers.compactMap { (id, state) -> SymPeerGossip? in
            guard id != excludeId else { return nil }
            return SymPeerGossip(
                nodeId: id,
                name: state.name,
                wakeChannel: wakeChannels[id]
            )
        }
    }

    private func removePeer(nodeId: String) {
        let peer: PeerState? = peerQueue.sync {
            self.peerSharedSecrets.removeValue(forKey: nodeId)
            return self.peers.removeValue(forKey: nodeId)
        }
        meshNode.removePeer(id: nodeId)
        lastCouplingDecisions.removeValue(forKey: nodeId)

        if let peer {
            logger.info("[SYM] peer: disconnected: \(peer.name)")
            _metrics.peersLeft += 1
            emit(.peerLeft(nodeId: nodeId, name: peer.name))
            emit(.metric(type: "peer-left", detail: ["name": peer.name]))
        }

        // Auto-reconnect: after a peer drops, re-scan Bonjour browse results
        // in case the mDNS record is still visible (common with iOS backgrounding
        // or transient TCP resets). 5s delay lets network state settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.discovery.retryVisiblePeers()
        }
    }

    // Internal (not private) so the receive path is drivable from tests:
    // the CTO demonstrated that with this private, the v2 verification call
    // could be replaced by a constant and the whole suite stayed green — the
    // verifier was proven, the node's USE of it was not.
    func handlePeerFrame(nodeId: String, peerName: String, frame: SymFrame) {
        peerQueue.sync { self.peers[nodeId]?.lastSeen = Date() }

        switch frame.type {
        case .handshake:
            // Derive E2E shared secret if peer advertises a public key
            if let peerPubKeyB64 = frame.e2ePublicKey,
               let peerPubKeyData = Data(base64Encoded: peerPubKeyB64) {
                if let sharedSecret = E2ECrypto.deriveSharedSecret(
                    myPrivateKey: e2ePrivateKey,
                    peerPublicKey: peerPubKeyData
                ) {
                    peerQueue.sync { self.peerSharedSecrets[nodeId] = sharedSecret }
                    logger.info("[SYM] e2e: derived shared secret with \(peerName) (\(nodeId.prefix(8)))")
                } else {
                    logger.warning("[SYM] e2e: failed to derive shared secret with \(peerName)")
                }
            }
            // Section 3.5 + 6.4: store peer lifecycle role for validator-origin weight
            if let role = frame.lifecycleRole {
                peerQueue.sync { self.peerLifecycleRoles[nodeId] = role }
            }
            // MMP §8.3: remember the peer's Ed25519 signing key so we can verify
            // the signatures on the CMBs it authors.
            if let signingKey = frame.publicKey {
                peerQueue.sync { self.peerSigningKeys[nodeId] = signingKey }
            }
            break

        case .stateSync:
            // MMP v0.2.2: state-sync is deprecated. Hidden states never cross
            // the wire under SVAF (Xu, 2026, §3.4). Frames received from
            // older v0.2.0 peers are silently dropped — they are NOT fed
            // into the local CfC and the deprecated `.stateSyncReceived`
            // event is NOT emitted. The peer's mood and other cognitive
            // signals will arrive on the canonical `.cmb` channel.
            logger.info("[SYM] state-sync: dropping deprecated frame from \(peerName) (MMP v0.2.0; upgrade peer to v0.2.2+)")
            break

        case .cmb:
            // Detect encrypted CMB: encryptedCategories present with _e2e nonce
            var incomingCMB: CognitiveMemoryBlock
            if let encryptedCategories = frame.encryptedCategories,
               let e2eMeta = frame.e2e {
                // Decrypt categories using peer's shared secret
                let sharedSecret: SymmetricKey? = peerQueue.sync { self.peerSharedSecrets[nodeId] }
                guard let sharedSecret else {
                    logger.warning("[SYM] e2e: received encrypted CMB from \(peerName) but no shared secret — skipping")
                    break
                }
                guard let decryptedCategories = E2ECrypto.decryptCategories(
                    ciphertext: encryptedCategories,
                    nonce: e2eMeta.nonce,
                    sharedSecret: sharedSecret
                ) else {
                    logger.error("[SYM] e2e: failed to decrypt CMB categories from \(peerName)")
                    break
                }
                logger.info("[SYM] e2e: decrypted \(decryptedCategories.count) CMB categories from \(peerName)")

                // FAIL CLOSED on identity — never fabricate it. This used to
                // fall back to an invented `cmb-<UUID8>` key and to the
                // DELIVERING PEER as author. Both are the defect class the
                // boundary release deletes (sym-core e907a12 killed the same
                // shape in JS): an invented address is a block nobody minted,
                // and holder-as-author is exactly what §7.2 forbids — the
                // author is signature-bound, the deliverer is just transport.
                // A frame that names neither its key nor its author is not a
                // CMB; drop it loudly rather than store a forgery of one.
                guard let frameKey = frame.key, !frameKey.isEmpty else {
                    logger.warning("[SYM] e2e: encrypted CMB from \(peerName) carries no key — dropping (identity is never fabricated)")
                    break
                }
                guard let author = frame.source, !author.isEmpty else {
                    logger.warning("[SYM] e2e: encrypted CMB from \(peerName) names no author — dropping (the delivering peer is transport, not authorship)")
                    break
                }

                // Reconstruct CMB with decrypted categories
                incomingCMB = CognitiveMemoryBlock(
                    key: frameKey,
                    categories: decryptedCategories,
                    source: author,
                    createdBy: author,
                    originTimestamp: frame.originTimestamp ?? frame.timestamp ?? UInt64(Date().timeIntervalSince1970 * 1000),
                    storedAt: UInt64(Date().timeIntervalSince1970 * 1000),
                    confidence: frame.confidence ?? 0.8
                )
            } else if let v2 = frame.cmbV2 {
                // Boundary (two-section) record — VERIFIED path, live since
                // SYMCore v0.3.90 ships CMBRecordV2 + CMBSigningV2. Identity
                // comes from the record's OWN metadata and fails closed: no
                // key or no author means no CMB, never a fabricated one.
                guard !v2.metadata.key.isEmpty, !v2.metadata.createdBy.isEmpty else {
                    logger.warning("[SYM] cmb: v2 record from \(peerName) missing key/author in metadata — dropping")
                    break
                }

                // §7.6 verification with the REAL v2 verifier, against the
                // key the peer announced in its handshake. Same stance as the
                // flat path below: present-but-invalid → rejected outright;
                // unsigned or no-known-key → unverified, not rejected. Note
                // content integrity is checked INSIDE verify (recomputed
                // block key) — a tampered category fails as content-mismatch
                // even before the signature is examined.
                let v2SigningKey: String? = peerQueue.sync { self.peerSigningKeys[nodeId] }
                let v2Verdict = CMBSigningV2.verify(v2, publicKeyB64url: v2SigningKey)
                if rejectsSignature(signed: v2Verdict.signed, valid: v2Verdict.valid, error: v2Verdict.error) {
                    logger.error("[SYM] cmb: REJECTED v2 \(v2.metadata.key.prefix(20)) from \(peerName) — \(v2Verdict.error ?? "invalid")")
                    emit(.metric(type: "cmb-signature-rejected", detail: ["from": peerName, "key": v2.metadata.key, "reason": v2Verdict.error ?? "invalid"]))
                    break
                }

                var categories: [CMBCategory: CMBCategoryVector] = [:]
                for (name, category) in v2.categories {
                    guard let cat7 = CMBCategory(rawValue: name) else { continue }
                    // RECEIVER-LOCAL ENCODING (§7.1, store-none): a v2 record
                    // carries no vectors — deliberately, so nothing a relay
                    // could tamper with reaches drift computation. This node
                    // encodes from the category's own text, with its own kernel,
                    // at receive time. Without this the bridged categories carried
                    // empty vectors and SVAF scored every category maximally
                    // drifted — intact records were rejected downstream of a
                    // VERIFIED signature (found by the wiring tests).
                    categories[cat7] = CMBEncoder.encodeCategory(category.text,
                                                          valence: category.valence.map { Float($0) },
                                                          arousal: category.arousal.map { Float($0) })
                }
                let now = UInt64(Date().timeIntervalSince1970 * 1000)
                incomingCMB = CognitiveMemoryBlock(
                    key: v2.metadata.key,
                    categories: categories,
                    source: v2.metadata.createdBy,
                    createdBy: v2.metadata.createdBy,
                    lineage: (v2.metadata.lineage?.parents).map { CMBLineage(parents: $0, ancestors: [], method: v2.metadata.lineage?.method ?? "v2-bridge") },
                    originTimestamp: v2.metadata.createdTimestamp,
                    storedAt: now,
                    confidence: frame.confidence ?? 0.8
                )
                logger.info("[SYM] cmb: v2 record \(v2.metadata.key.prefix(20)) from \(v2.metadata.createdBy) — \(v2Verdict.valid ? "VERIFIED" : "unverified (\(v2Verdict.error ?? "unsigned"))")")
            } else {
                guard let plainCMB = frame.cmb else {
                    logger.warning("[SYM] cmb: missing CMB in frame from \(peerName)")
                    break
                }
                incomingCMB = plainCMB
            }

            // MMP §8.3: verify the author's Ed25519 signature against the key it
            // announced in its handshake. A present-but-invalid signature is a
            // forged or tampered CMB — reject it outright (audit-logged, never
            // surfaced or stored). An unsigned CMB is treated as unverified, not
            // rejected, for backward compatibility with pre-§8.3 peers. Encrypted
            // CMBs carry no `sig` (E2E AEAD already authenticates) → unverified.
            let peerSigningKey: String? = peerQueue.sync { self.peerSigningKeys[nodeId] }
            let verdict = CMBSigning.verify(incomingCMB, publicKeyBase64URL: peerSigningKey)
            if rejectsSignature(signed: verdict.signed, valid: verdict.valid, error: verdict.error) {
                logger.error("[SYM] cmb: REJECTED \(incomingCMB.key.prefix(20)) from \(peerName) — bad signature (\(verdict.error ?? "invalid"))")
                emit(.metric(type: "cmb-signature-rejected", detail: ["from": peerName, "key": incomingCMB.key, "reason": verdict.error ?? "invalid"]))
                break
            }

            let categoryCount = incomingCMB.categories.count
            let moodText = incomingCMB.categories[.mood]?.text ?? "none"
            logger.info("[SYM] cmb: received CMB \(incomingCMB.key.prefix(20)) from \(peerName) (\(categoryCount) categories, mood: \(moodText))")

            // Application payload (0.5.0) — routed HERE, downstream of
            // signature verification (a forged CMB delivers nothing) and
            // upstream of echo detection and the SVAF verdict, so a payload
            // survives BOTH outcomes. Node dropped payloads on exactly one
            // of those paths once (admitted remixes were rebuilt from CAT7
            // and lost the sibling); routing before the split is what makes
            // that class unrepresentable here rather than merely fixed.
            if let payloadData = frame.cmbPayload {
                handleIncomingPayload(payloadData, from: nodeId, peerName: peerName, cmbKey: incomingCMB.key)
            }

            // Echo loop prevention (MMP Section 14): if the incoming CMB's
            // lineage parents include a key that exists in our local meshmem,
            // this CMB is a derivative of our own broadcast. Skip all
            // processing — including mood delivery — to prevent ping-pong
            // curation between same-app peers.
            if let parents = incomingCMB.lineage?.parents, !parents.isEmpty,
               let localStore = store as? SymMemoryStore {
                let isEcho = parents.contains { localStore.hasLocalKey($0) }
                if isEcho {
                    logger.info("[SYM] cmb: echo detected — parent key found in local meshmem, skipping \(incomingCMB.key.prefix(20)) from \(peerName)")
                    break
                }
            }

            // ── SVAF v2: Per-Category CMB Fusion ──────────────────────
            // MMP v0.2.0 Section 9: λ_j = α_f · cos(x_new, x_j) · g(l_j) · exp(-λ(t_now - t_j)) · c_j
            // Per-category drift evaluation + category-wise weighted fusion → NEW synthesized memory

            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let originTs = frame.originTimestamp ?? frame.timestamp ?? now
            let ageSeconds = now >= originTs ? Float(now - originTs) / 1000.0 : 0.0
            let temporalDecay: Float = exp(-ageSeconds / self.svafFreshnessSeconds)
            let temporalDrift: Float = 1.0 - temporalDecay
            let confidence: Float = frame.confidence ?? 0.8

            // 1. Get anchor CMBs from local memory.
            //    When the redundancy pre-filter is enabled, we exclude
            //    entries tagged `sym.absorbed` so that previously-absorbed
            //    redundant CMBs don't participate in fusion against future
            //    incoming signals. Absorbed entries remain discoverable by
            //    the lineage-based echo filter (via `hasLocalKey`) so they
            //    still contribute to echo detection for their descendants.
            let anchors: [CognitiveMemoryBlock]
            if self.svafRedundancyCheckEnabled {
                anchors = store.allEntries()
                    .filter { !$0.tags.contains(Self.absorbedTag) }
                    .sorted { $0.storedAt > $1.storedAt }
                    .prefix(5)
                    .compactMap { $0.cmb }
            } else {
                anchors = store.recentCMBs(limit: 5)
            }

            // 1a. Paper §4.5 fourth outcome — semantic redundancy pre-filter.
            //     Runs BEFORE the fusion classifier because SVAF's fusion-
            //     based drift formula (drift = 1 − cosSim(fused, incoming))
            //     collapses identical and orthogonal inputs to the same
            //     near-zero drift, so redundancy cannot be detected from
            //     drift output. This similarity-based check fires only
            //     when the feature flag is enabled.
            if self.svafRedundancyCheckEnabled && isCMBRedundant(incoming: incomingCMB, anchors: anchors) {
                // Store as "absorbed" — preserves the CMB key in local
                // memory so future descendants are still caught by the
                // lineage echo filter, but marks the entry so it does not
                // participate in fusion. No cmbAccepted, no memoryReceived,
                // no mood passthrough — redundant mood is by definition
                // already delivered.
                let absorbedContent = "[absorbed] " + String(CMBEncoder.renderContent(from: incomingCMB).prefix(80))
                let absorbedEntry = SymMemoryEntry(
                    key: frame.key ?? "absorbed-\(now)",
                    content: absorbedContent,
                    source: "\(self.name)+\(frame.source ?? peerName)",
                    tags: [Self.absorbedTag],
                    originTimestamp: originTs,
                    storedAt: now,
                    cmb: incomingCMB
                )
                store.receiveFromPeer(peerId: nodeId, entry: absorbedEntry)
                _metrics.cmbAccepted += 1

                logger.info("[SYM] memory: SVAF REDUNDANT from \(peerName) — absorbed with no fusion (threshold: \(self.svafRedundancyThreshold))")
                emit(.metric(type: "cmb-redundant", detail: ["from": peerName, "key": absorbedEntry.key]))
                break
            }

            // 2. Per-category drift evaluation and fusion
            var categoryDrifts: [CMBCategory: Float] = [:]
            var fusedCategories: [CMBCategory: CMBCategoryVector] = [:]
            var anchorWeightsLog: [CMBCategory: [Float]] = [:]

            for category in CMBCategory.allCases {
                guard let incomingCategory = incomingCMB.categories[category] else { continue }

                let alphaF = self.svafCategoryWeights[category]
                var weightedVec = incomingCategory.vector.map { $0 * 1.0 as Float }  // λ_new = 1.0
                var totalWeight: Float = 1.0
                var categoryAnchorWeights: [Float] = []

                for anchor in anchors {
                    guard let anchorCategory = anchor.categories[category] else {
                        categoryAnchorWeights.append(0)
                        continue
                    }

                    let cosSim = CMBEncoder.cosineSimilarity(incomingCategory.vector, anchorCategory.vector)
                    let anchorAge = now >= anchor.storedAt ? Float(now - anchor.storedAt) / 1000.0 : 0.0
                    let anchorDecay = exp(-anchorAge / self.svafFreshnessSeconds)
                    // Section 6.4: validator-origin CMBs have anchor weight 2.0
                    let validatorMultiplier: Float = validatorOriginKeys.contains(anchor.key) ? 2.0 : 1.0
                    let w = alphaF * max(cosSim, 0) * anchorDecay * anchor.confidence * validatorMultiplier

                    let minDim = min(weightedVec.count, anchorCategory.vector.count)
                    for d in 0..<minDim {
                        weightedVec[d] += w * anchorCategory.vector[d]
                    }
                    totalWeight += w
                    categoryAnchorWeights.append(w)
                }

                // Normalize fused vector
                var fused = weightedVec.map { $0 / max(totalWeight, 1e-8) }
                fused = CMBEncoder.l2Normalize(fused)

                // Per-category drift: distance between fused and local (anchors' average)
                let categoryDrift = 1.0 - CMBEncoder.cosineSimilarity(fused, incomingCategory.vector)
                categoryDrifts[category] = categoryDrift
                anchorWeightsLog[category] = categoryAnchorWeights

                // Synthesize category text
                // TODO: v2 — LLM synthesis of category text
                let fusedText = incomingCategory.text
                // MMP §8.2: preserve mood category's valence/arousal structured floats
                fusedCategories[category] = CMBCategoryVector(
                    text: fusedText,
                    vector: fused,
                    valence: incomingCategory.valence,
                    arousal: incomingCategory.arousal
                )
            }

            // 4. Aggregate drift: weighted average of per-category drifts
            var weightedDriftSum: Float = 0
            var weightSum: Float = 0
            for category in CMBCategory.allCases {
                let alphaF = self.svafCategoryWeights[category]
                weightedDriftSum += alphaF * (categoryDrifts[category] ?? 0)
                weightSum += alphaF
            }
            let aggregateCategoryDrift = weightSum > 0 ? weightedDriftSum / weightSum : 1.0

            // 5. Combined: content-category drift + temporal drift
            let totalDrift = (1.0 - self.svafTemporalLambda) * aggregateCategoryDrift + self.svafTemporalLambda * temporalDrift

            // 6. Threshold decision
            if totalDrift > self.svafGuardedThreshold {
                let categoryLog = categoryDrifts.map { "\($0.key.rawValue):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
                logger.info("[SYM] memory: SVAF rejected from \(peerName) — drift \(String(format: "%.3f", totalDrift)) [\(categoryLog)] temporal:\(String(format: "%.2f", temporalDrift))")

                // Mood crosses all domain boundaries (MMP spec).
                // Even when the full CMB is rejected, mood-aware agents must
                // still receive the mood category for autonomous processing.
                if let moodCategory = incomingCMB.categories[.mood], moodCategory.text != "neutral" {
                    logger.info("[SYM] memory: mood extracted from rejected CMB: \"\(moodCategory.text)\" from \(peerName)")
                    emit(.memoryReceived(from: peerName, content: moodCategory.text, decision: "mood-only", cmb: incomingCMB))
                }
                break
            }

            let decision = totalDrift <= self.svafStableThreshold ? "aligned" : "guarded"

            // 7. Create FUSED CMB — this is a NEW synthesized memory
            // Lineage: fused CMB is a child of the incoming CMB (MMP Section 14)
            let fusedLineage = CMBLineage(
                parents: [incomingCMB.key],
                ancestors: (incomingCMB.lineage?.ancestors ?? []) + [incomingCMB.key]
            )
            let fusedCMB = CognitiveMemoryBlock(
                categories: fusedCategories,
                source: "\(self.name)+\(frame.source ?? peerName)",
                lineage: fusedLineage,
                originTimestamp: originTs,
                storedAt: now,
                confidence: confidence * (1.0 - aggregateCategoryDrift),
                provenance: CMBProvenance(
                    fusedFrom: [incomingCMB.key] + anchors.map(\.key),
                    fusionWeights: anchorWeightsLog,
                    categoryDrift: categoryDrifts,
                    totalDrift: totalDrift,
                    temporalDrift: temporalDrift
                )
            )

            // 8. Store the FUSED entry (not the original)
            // Section 6.4 + 11.1: validator/anchor-origin CMBs enter at weight 2.0
            let creatorRole: String = peerQueue.sync { self.peerLifecycleRoles[nodeId] ?? "observer" }
            let isValidatorOrigin = creatorRole == "validator" || creatorRole == "anchor"

            let fusedContent = CMBEncoder.renderContent(from: fusedCMB)
            let entry = SymMemoryEntry(
                key: frame.key ?? "memory-\(now)",
                content: fusedContent,
                source: fusedCMB.source,
                tags: frame.tags ?? [],
                originTimestamp: originTs,
                storedAt: now,
                cmb: fusedCMB
            )
            if isValidatorOrigin {
                validatorOriginKeys.insert(entry.key)
            }
            store.receiveFromPeer(peerId: nodeId, entry: entry)

            // Protocol metrics + cmb-accepted event
            _metrics.cmbAccepted += 1
            let isAnchor = frame.isAnchor ?? false
            let isRemix = fusedCMB.lineage?.parents.isEmpty == false
            emit(.cmbAccepted(entry: entry, isAnchor: isAnchor, isRemix: isRemix))
            emit(.metric(type: "cmb-accepted", detail: ["from": peerName, "key": entry.key]))

            let categoryLog = categoryDrifts.sorted(by: { $0.key.rawValue < $1.key.rawValue })
                .map { "\($0.key.rawValue):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
            logger.info("[SYM] memory: SVAF fused from \(peerName): \"\(fusedContent.prefix(50))\" [\(decision), drift:\(String(format: "%.3f", totalDrift)), categories: \(categoryLog), age:\(String(format: "%.0f", ageSeconds))s]")
            emit(.memoryReceived(from: peerName, content: fusedContent, decision: decision, cmb: fusedCMB))

        case .mood:
            guard let mood = frame.mood else { break }

            // Legacy `.mood` frame handling — accepted for backward
            // compatibility with MMP v0.2.0 peers. The relevance gate
            // below uses a *local* synthesis of (h1, h2) from the mood
            // text and feeds them to the local CfC coupler purely as a
            // similarity oracle; these synthesised vectors are never
            // broadcast and never persisted. They are not the peer's
            // actual hidden state — the peer's hidden state never
            // crosses the wire under SVAF (Xu, 2026, §3.4).
            //
            // TODO(MMP v0.3.0): replace this local-synthesis relevance
            // gate with a synthetic one-category CMB whose `.mood` category
            // carries the received text + valence/arousal, and run it
            // through the canonical SVAF Layer-4 evaluator on the same
            // path as `.cmb` frames. The legacy `.mood` frame type
            // should then be removed from the wire entirely.
            let (moodH1, moodH2) = ContextEncoder.encode(mood)
            let moodPeerId = "mood-\(nodeId)"

            // Add mood as temporary peer state in the SDK's coupling engine
            meshNode.addPeer(id: moodPeerId, h1: moodH1, h2: moodH2, confidence: 0.8)
            _ = meshNode.coupledState() // trigger SDK evaluation
            let d = meshNode.couplingDecisions[moodPeerId]
            meshNode.removePeer(id: moodPeerId) // clean up

            let from = frame.fromName ?? peerName

            let drift = d?.drift ?? 1

            // Mood uses moodThreshold (default 0.8) — more permissive than
            // memory sharing (0.5). User wellbeing crosses domain boundaries.
            if drift <= moodThreshold {
                logger.info("[SYM] mood: from \(from): \"\(mood.prefix(50))\" → ACCEPTED (drift: \(String(format: "%.2f", drift)) ≤ threshold \(String(format: "%.1f", self.moodThreshold))) — passing to music pipeline")
                emit(.moodDelivered(from: from, mood: mood, drift: drift))
            } else {
                logger.info("[SYM] mood: from \(from): \"\(mood.prefix(50))\" → IGNORED (drift: \(String(format: "%.2f", drift)) > threshold \(String(format: "%.1f", self.moodThreshold))) — mood too distant from our cognitive profile")
                emit(.moodRejected(from: from, mood: mood, drift: drift))
            }

        case .message:
            if let content = frame.content {
                let from = frame.fromName ?? peerName
                logger.info("[SYM] message: from \(from): \(content.prefix(60))")
                emit(.message(from: from, content: content))
            }

        case .xmeshInsight:
            let from = frame.fromName ?? peerName
            let trajectory = frame.trajectory ?? []
            let patterns = frame.patterns ?? []
            let anomaly = frame.anomaly ?? 0
            let outcome = frame.outcome ?? "unknown"
            let coherence = frame.coherence ?? 0
            logger.info("[SYM] xmesh: insight from \(from): anomaly=\(anomaly), outcome=\(outcome)")

            // 1. Emit event for agent UI/domain actions
            emit(.xmeshInsight(from: from, trajectory: trajectory, patterns: patterns, anomaly: anomaly, outcome: outcome, coherence: coherence))

            // 2. Synthesis loop: call delegate, share insight back to mesh
            let insight = XMeshInsight(trajectory: trajectory, patterns: patterns, anomaly: anomaly, outcome: outcome, coherence: coherence)
            if let synthesis = synthesisDelegate?.synthesizeInsight(from: insight) {
                remember(categories: [
                    .focus: CMBEncoder.encodeCategory(synthesis),
                    .mood: CMBEncoder.encodeCategory("neutral"),
                ], tags: ["xmesh-synthesis"])
                logger.info("[SYM] xmesh: synthesis: shared domain insight back to mesh")
            }

        case .peerInfo:
            let gossipPeers = frame.peers ?? []
            for peer in gossipPeers {
                if let wc = peer.wakeChannel, let peerId = peer.nodeId {
                    stateQueue.async { [weak self] in
                        self?.peerWakeChannels[peerId] = wc
                    }
                }
            }
            logger.info("[SYM] gossip: learned \(gossipPeers.count) peer(s) from \(peerName)")

        case .wakeChannel:
            // Peer declared their wake channel — store it (survives disconnect)
            if let platform = frame.platform, let token = frame.token {
                let wc = SymWakeChannel(platform: platform, token: token, environment: frame.environment)
                stateQueue.async { [weak self] in
                    self?.peerWakeChannels[nodeId] = wc
                }
                logger.info("[SYM] wake: from \(peerName): \(platform)")
            }

        case .wake:
            // Received out-of-band — handled by AppDelegate, not here
            break

        case .ping:
            sendToPeer(nodeId: nodeId, frame: .pong())

        case .pong:
            break

        case .nodeStats:
            // Emit-only on this node: we broadcast our own tally for observers, but do
            // not ingest peers' tallies (no local display surface needs them yet).
            break

        case .error:
            let code = frame.code ?? 0
            let msg = frame.content ?? "unknown"
            logger.warning("[SYM] error frame from \(peerName): \(code) \(msg)")
            emit(.metric(type: "error-received", detail: ["code": "\(code)", "peer": peerName]))

        case .unknown:
            // Unreachable in practice — the parser drops unrecognized types and
            // logs them once per connection. Present so this switch stays
            // exhaustive, and so a frame reaching here is ignored rather than
            // trapped if a future caller builds a SymFrame outside the parser.
            break
        }
    }
}

// MARK: - Discovery Delegate

extension SymNode: SymDiscoveryDelegate {

    func discoveryDidFindPeer(nodeId: String, name: String, browseResult: NWBrowser.Result) {
        // Dedup against both already-handshaked peers AND in-flight outbound
        // attempts. Bonjour `.changed` events fire repeatedly for the same
        // peer; without this guard each one spawns a fresh NWConnection.
        let shouldConnect: Bool = peerQueue.sync {
            guard self.peers[nodeId] == nil else { return false }
            guard !self.pendingOutboundNodeIds.contains(nodeId) else { return false }
            self.pendingOutboundNodeIds.insert(nodeId)
            return true
        }
        guard shouldConnect else { return }

        logger.info("[SYM] peer: connecting to \(name) via service endpoint")
        let session = SymPeerSession(outboundTo: browseResult.endpoint, identity: identity)
        session.outboundTargetNodeId = nodeId
        session.delegate = self
        // Retain until handshake identifies the peer
        let key = ObjectIdentifier(session)
        peerQueue.sync { self.pendingSessions[key] = session }
        session.start()
    }

    func discoveryDidLosePeer(nodeId: String) {
        // Active handshaked sessions are left alone — heartbeat detects real
        // loss and mDNS sends transient remove+re-add events that we don't
        // want to thrash on. But pending unhandshaked outbound attempts to
        // a peer that just left the network should be cancelled immediately
        // so we stop banging on a dead endpoint for the full TCP timeout.
        let pending: SymPeerSession? = peerQueue.sync {
            guard self.pendingOutboundNodeIds.contains(nodeId) else { return nil }
            return self.pendingSessions.values.first { $0.outboundTargetNodeId == nodeId }
        }
        if let pending {
            logger.info("[SYM] peer: cancelling pending connect to \(nodeId.prefix(8)) — Bonjour removed")
            pending.disconnect()
        }
    }

    func discoveryDidAcceptConnection(_ connection: NWConnection) {
        let session = SymPeerSession(inbound: connection, identity: identity)
        session.delegate = self
        // Retain until handshake identifies the peer
        let key = ObjectIdentifier(session)
        peerQueue.sync { self.pendingSessions[key] = session }
        session.start()
    }
}

// MARK: - Session Delegate

extension SymNode: SymPeerSessionDelegate {

    func session(_ session: SymPeerSession, didHandshakeWith nodeId: String, name: String) {
        // Release from pending (both inbound and outbound) and clear
        // the in-flight outbound dedup entry now that the handshake
        // either confirmed the expected nodeId or revealed a different one.
        let key = ObjectIdentifier(session)
        peerQueue.sync {
            _ = self.pendingSessions.removeValue(forKey: key)
            if let target = session.outboundTargetNodeId {
                self.pendingOutboundNodeIds.remove(target)
            }
            self.pendingOutboundNodeIds.remove(nodeId)
        }

        addPeer(session, nodeId: nodeId, peerName: name, isOutbound: session.isOutbound)
    }

    func sessionDidBecomeReady(_ session: SymPeerSession) {
        // Send handshake immediately when TCP connection is established.
        // Both sides send before either receives, breaking the deadlock
        // where each waits for the other's handshake frame.
        session.send(.handshake(
            nodeId: identity.nodeId,
            name: name,
            publicKey: identity.publicKey,
            e2ePublicKey: e2ePublicKeyB64,
            lifecycleRole: "observer"
        ))
    }

    func session(_ session: SymPeerSession, didReceive frame: SymFrame) {
        guard let nodeId = session.peerNodeId, let peerName = session.peerName else { return }
        handlePeerFrame(nodeId: nodeId, peerName: peerName, frame: frame)
    }

    func session(_ session: SymPeerSession, didDisconnectWith reason: String) {
        // Release from pending if never handshaked, and clear the outbound
        // dedup entry so a future Bonjour event can attempt a fresh connect.
        let key = ObjectIdentifier(session)
        peerQueue.sync {
            _ = self.pendingSessions.removeValue(forKey: key)
            if let target = session.outboundTargetNodeId {
                self.pendingOutboundNodeIds.remove(target)
            }
        }

        guard let nodeId = session.peerNodeId else { return }
        // Section 4.6 + 5.5: remove Bonjour transport only — peer survives if relay exists
        removeTransport(nodeId: nodeId, source: "bonjour")
    }
}

// MARK: - Relay Delegate

extension SymNode: SymRelaySessionDelegate {

    func relayDidConnect() {
        logger.info("[SYM] relay connected")
    }

    func relayDidFindPeer(nodeId: String, name: String) {
        addRelayPeer(nodeId: nodeId, peerName: name)
    }

    func relayDidLosePeer(nodeId: String, name: String) {
        // Section 4.6 + 5.5: remove relay transport only — Bonjour survives
        peerQueue.sync { _ = self.relayHandshakeSent.remove(nodeId) }   // greet it again if it returns
        removeTransport(nodeId: nodeId, source: "relay")
    }

    func relay(didReceiveFrame frame: SymFrame, from nodeId: String, fromName: String) {
        // Handle handshake from relay peer — they may not be in our peers map yet
        if frame.type == .handshake, let peerNodeId = frame.nodeId, let peerName = frame.name {
            addRelayPeer(nodeId: peerNodeId, peerName: peerName)
            return
        }

        handlePeerFrame(nodeId: nodeId, peerName: fromName, frame: frame)
    }

    func relayDidDisconnect(reason: String) {
        logger.info("[SYM] relay disconnected: \(reason)")
        removeRelayTransports()
    }
}

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
//  Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.
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
    /// A peer's mood signal was accepted (drift within threshold). See MMP v0.2.0 Section 9.3.
    case moodAccepted(from: String, mood: String, drift: Float)
    /// A peer's mood signal was rejected (drift above threshold). See MMP v0.2.0 Section 9.3.
    case moodRejected(from: String, mood: String, drift: Float)
    /// A text message was received from a peer. See MMP v0.2.0 Section 7.
    case message(from: String, content: String)
    /// xMesh insight received — a peer agent's cognitive state from its own LNN.
    /// Contains trajectory, patterns, anomaly score, predicted outcome. See MMP v0.2.0 Section 12.
    case xmeshInsight(from: String, trajectory: [Float], patterns: [Float], anomaly: Float, outcome: String, coherence: Float)
    /// Peer's cognitive state received via state-sync frame.
    /// h1/h2 are CfC hidden state vectors for neural coupling. See MMP v0.2.0 Section 5.
    case stateSyncReceived(from: String, h1: [Float], h2: [Float], confidence: Float)
    /// A peer CMB was accepted by SVAF and stored. Application layer can remix.
    /// Per MMP v0.2.0 Section 14: remix only when agent has new domain data.
    case cmbAccepted(entry: SymMemoryEntry)
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
    /// Whether the relay WebSocket is currently connected.
    public let relayConnected: Bool
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
/// node.remember(fields: [
///     .focus: CMBEncoder.encodeField("race condition in order processing"),
///     .issue: CMBEncoder.encodeField("concurrent writes to order state"),
///     .mood: CMBEncoder.encodeField("concerned"),
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
    private let svafFieldWeights: CMBFieldWeights  // Per-field α_f weights
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

    /// Protects non-peer mutable state: eventHandlers, _running, wakeChannel, pendingSessions.
    private let stateQueue = DispatchQueue(label: "bot.sym.state", qos: .userInitiated)

    /// Inbound sessions awaiting handshake. Retained here to prevent ARC deallocation.
    /// Access only via peerQueue.
    private var pendingSessions: [ObjectIdentifier: SymPeerSession] = [:]

    /// Track last coupling decision per peer — only log/emit on change.
    private var lastCouplingDecisions: [String: String] = [:]

    /// Event handlers. Access only via stateQueue.
    private var eventHandlers: [(SymEvent) -> Void] = []

    /// Synthesis delegate for the xMesh synthesis loop. See MMP v0.2.0 Section 12.
    /// Agent processes peer xMesh insight through its own domain intelligence.
    /// Returns domain-specific insight as a new outbound CMB. SYM shares it back to mesh.
    public weak var synthesisDelegate: SYMSynthesisDelegate?

    /// LLM field extractor for CMB field extraction. See MMP v0.2.0 Section 9.
    /// App provides LLM implementation; falls back to heuristic keyword extraction if nil.
    public weak var fieldExtractor: CMBFieldExtractor?

    /// Periodic re-encode timer (30s — re-encodes context and broadcasts).
    private var encodeTimer: Timer?

    /// Periodic state-sync timer (configurable — broadcasts current hidden state to peers).
    /// Enables real-time neural coupling when set to a short interval (e.g. 1s).
    private var stateSyncTimer: Timer?
    private let stateSyncInterval: TimeInterval

    private var _running = false
    /// Whether this node is currently running (started and not stopped).
    public var isRunning: Bool { stateQueue.sync { _running } }

    // Relay
    private let relayURL: URL?
    private let relayToken: String?
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
    ///   - svafFieldWeights: Per-field α_f weights for SVAF evaluation (default: uniform).
    ///   - retentionSeconds: How long to keep CMBs in local storage (default 86400 = 24h).
    ///     Regulated domains MUST set this per compliance requirements:
    ///     legal (per jurisdiction), health (HIPAA 6yr), finance (MiFID II 5yr, SEC 7yr).
    ///   - store: Custom CMB storage implementation. Defaults to file-based storage.
    ///     Pass a read-only CMBStore for audit agents that observe without modifying.
    ///   - stateSyncInterval: Seconds between state-sync broadcasts to peers (default 0, disabled).
    ///     Set to 1.0 for real-time neural coupling. 0 means state is only sent on handshake and re-encode.
    ///   - relay: WebSocket relay URL for internet-scale mesh (e.g. `wss://sym-relay.onrender.com`).
    ///   - relayToken: Shared secret for relay authentication.
    ///   - relayOnly: If true, skip Bonjour discovery and only use the relay.
    public init(
        name: String,
        cognitiveProfile: String? = nil,
        moodThreshold: Float = 0.8,
        svafStableThreshold: Float = 0.25,
        svafGuardedThreshold: Float = 0.5,
        svafTemporalLambda: Float = 0.3,
        svafFreshnessSeconds: Float = 1800,
        svafFieldWeights: CMBFieldWeights = .uniform,
        retentionSeconds: TimeInterval = 86400,
        store: (any CMBStore)? = nil,
        stateSyncInterval: TimeInterval = 0,
        relay: URL? = nil,
        relayToken: String? = nil,
        relayOnly: Bool = false
    ) {
        self.name = name
        self.cognitiveProfile = cognitiveProfile
        self.moodThreshold = moodThreshold
        self.svafStableThreshold = svafStableThreshold
        self.svafGuardedThreshold = svafGuardedThreshold
        self.svafTemporalLambda = svafTemporalLambda
        self.svafFreshnessSeconds = svafFreshnessSeconds
        self.svafFieldWeights = svafFieldWeights
        self.retentionSeconds = retentionSeconds
        self.stateSyncInterval = stateSyncInterval
        self.relayURL = relay
        self.relayToken = relayToken
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
        self.discovery = SymDiscovery(identity: identity)

        initLocalState()
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

    private func reencodeAndBroadcast() {
        let context = buildContext()
        guard context.count > 5 else { return }

        let (h1, h2) = ContextEncoder.encode(context)
        meshNode.updateLocalState(h1, h2, confidence: 0.8)
        broadcastCurrentState()
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
            let relay = SymRelaySession(url: relayURL, identity: identity, token: relayToken)
            relay.delegate = self
            relay.start()
            self.relaySession = relay
        }

        encodeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.reencodeAndBroadcast()
        }

        // Real-time state sync for neural coupling (if configured)
        if stateSyncInterval > 0 {
            stateSyncTimer = Timer.scheduledTimer(withTimeInterval: stateSyncInterval, repeats: true) { [weak self] _ in
                self?.broadcastCurrentState()
            }
        }

        // Retention purge — run on start + every hour
        store.purge(retentionSeconds: retentionSeconds)
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.purge(retentionSeconds: self.retentionSeconds)
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

    /// Store a memory with structured CAT7 fields and broadcast to coupled peers.
    /// See MMP v0.2.0 Section 6 (Memory) and Section 14 (Remix).
    ///
    /// The agent extracts fields — the protocol does not parse raw text.
    /// After storing, re-encodes cognitive state and shares with peers based on SVAF coupling decisions.
    ///
    /// - Parameters:
    ///   - fields: CAT7 field vectors (agent extracts these via ``CMBEncoder``).
    ///   - tags: Optional tags for search/filtering.
    ///   - parents: Parent CMBs this is a remix of. Lineage is computed automatically per Section 14.
    ///   - originTimestamp: When the event happened (epoch ms). Defaults to now.
    /// - Returns: The stored ``SymMemoryEntry``.
    @discardableResult
    public func remember(fields: [CMBField: CMBFieldVector], tags: [String] = [], parents: [CognitiveMemoryBlock] = [], originTimestamp: UInt64? = nil) -> SymMemoryEntry? {
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

        let cmb = CMBEncoder.createCMB(fields: fields, source: name, originTimestamp: ts, lineage: lineage)
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

            // Encrypt fields per-peer if shared secret exists
            if let sharedSecret = currentSecrets[peerId],
               let fields = entry.cmb?.fields,
               let encrypted = E2ECrypto.encryptFields(fields, sharedSecret: sharedSecret) {
                // Build encrypted frame: fields replaced with ciphertext, _e2e metadata added
                var encFrame = baseFrame
                encFrame.encryptedFields = encrypted.ciphertext
                encFrame.e2e = E2EMetadata(nonce: encrypted.nonce)
                // Clear the plaintext CMB from the encrypted frame — key/createdBy/createdAt/lineage stay on the outer frame
                encFrame.cmb = nil
                sendToPeer(nodeId: peerId, frame: encFrame)
                logger.info("[SYM] e2e: encrypted CMB fields for \(peer.name)")
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

    /// Search memories across local and peer stores by keyword. See MMP v0.2.0 Section 6.
    /// - Parameter query: Search keyword matched against content, key, and tags.
    /// - Returns: Matching entries sorted by most recent first.
    public func recall(_ query: String) -> [SymMemoryEntry] {
        _metrics.recalls += 1
        return store.search(query: query)
    }

    // MARK: - State Sync

    /// Broadcast current cognitive state to all peers.
    /// Called periodically when stateSyncInterval > 0 for real-time neural coupling.
    /// Also called by reencodeAndBroadcast() after context re-encoding.
    public func broadcastCurrentState() {
        let (h1, h2) = meshNode.coupledState()
        broadcastToPeers(.stateSync(h1: h1, h2: h2, confidence: 0.8))
    }

    // MARK: - Mood

    /// Broadcast mood to all peers. See MMP v0.2.0 Section 9.3.
    ///
    /// Receiving agents evaluate this against their cognitive state and autonomously
    /// decide whether to act. Mood crosses domain boundaries — even rejected CMBs
    /// deliver their mood field.
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
        let relayConnected = relaySession != nil
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
            relaySession = SymRelaySession(url: url, identity: identity, token: relayToken)
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
            return SymPeerInfo(
                id: id,
                name: peer.name,
                connected: true,
                lastSeen: peer.lastSeen,
                coupling: d?.decision.rawValue ?? "pending",
                drift: d?.drift
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
            relayConnected: relaySession != nil,
            peers: peerInfo,
            peerCount: peerInfo.count,
            memoryCount: memoryCount,
            coherence: coherence
        )
    }

    // MARK: - Internal Networking

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

    private func addPeer(_ session: SymPeerSession, nodeId: String, peerName: String, isOutbound: Bool) {
        let isNew = peerQueue.sync { () -> Bool in
            if var existing = self.peers[nodeId] {
                // Section 4.6: add Bonjour as secondary transport
                existing.transports["bonjour"] = session
                existing.lastSeen = Date()
                self.peers[nodeId] = existing
                return false
            }
            self.peers[nodeId] = PeerState(
                transports: ["bonjour": session], name: peerName,
                isOutbound: isOutbound, lastSeen: Date()
            )
            return true
        }

        // Send handshake + cognitive state + wake channel
        session.send(.handshake(nodeId: identity.nodeId, name: name, publicKey: identity.publicKey, e2ePublicKey: e2ePublicKeyB64))
        let (h1, h2) = meshNode.coupledState()
        session.send(.stateSync(h1: h1, h2: h2, confidence: 0.8))
        if let wc = wakeChannel {
            session.send(.wakeChannel(platform: wc.platform, token: wc.token, environment: wc.environment))
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

        // Send handshake + cognitive state + wake channel via relay
        relaySession?.send(.handshake(nodeId: identity.nodeId, name: name, publicKey: identity.publicKey, e2ePublicKey: e2ePublicKeyB64), to: nodeId)
        let (h1, h2) = meshNode.coupledState()
        relaySession?.send(.stateSync(h1: h1, h2: h2, confidence: 0.8), to: nodeId)
        if let wc = wakeChannel {
            relaySession?.send(.wakeChannel(platform: wc.platform, token: wc.token, environment: wc.environment), to: nodeId)
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
            self.peers.filter { $0.value.transports.keys.contains("relay") }.map(\.key)
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
    }

    private func handlePeerFrame(nodeId: String, peerName: String, frame: SymFrame) {
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
            break

        case .stateSync:
            guard let h1 = frame.h1, let h2 = frame.h2,
                  h1.count == ContextEncoder.dim, h2.count == ContextEncoder.dim else { break }

            meshNode.addPeer(id: nodeId, h1: h1, h2: h2, confidence: frame.confidence ?? 0.5)
            _ = meshNode.coupledState()

            // Emit raw state-sync for consumers (e.g. neural coupling engine)
            emit(.stateSyncReceived(from: peerName, h1: h1, h2: h2, confidence: frame.confidence ?? 0.5))

            if let d = meshNode.couplingDecisions[nodeId] {
                let prev = lastCouplingDecisions[nodeId]
                if prev != d.decision.rawValue {
                    lastCouplingDecisions[nodeId] = d.decision.rawValue
                    let context: String
                    switch d.decision {
                    case .aligned:
                        context = "cognitive states are similar — memories and mood will be shared"
                    case .guarded:
                        context = "partially related context — sharing with caution"
                    case .rejected:
                        context = "different cognitive domains — no state blending, CMB mood field still delivered (MMP v0.2.0 Section 9.3)"
                    @unknown default:
                        context = "unknown coupling state"
                    }
                    logger.info("[SYM] coupling:: \(peerName) → \(d.decision.rawValue) (drift: \(String(format: "%.2f", d.drift)), threshold: 0.50) — \(context)")
                    emit(.couplingDecision(peer: peerName, decision: d.decision.rawValue, drift: d.drift))
                }
            }

        case .cmb:
            // Detect encrypted CMB: encryptedFields present with _e2e nonce
            var incomingCMB: CognitiveMemoryBlock
            if let encryptedFields = frame.encryptedFields,
               let e2eMeta = frame.e2e {
                // Decrypt fields using peer's shared secret
                let sharedSecret: SymmetricKey? = peerQueue.sync { self.peerSharedSecrets[nodeId] }
                guard let sharedSecret else {
                    logger.warning("[SYM] e2e: received encrypted CMB from \(peerName) but no shared secret — skipping")
                    break
                }
                guard let decryptedFields = E2ECrypto.decryptFields(
                    ciphertext: encryptedFields,
                    nonce: e2eMeta.nonce,
                    sharedSecret: sharedSecret
                ) else {
                    logger.error("[SYM] e2e: failed to decrypt CMB fields from \(peerName)")
                    break
                }
                logger.info("[SYM] e2e: decrypted \(decryptedFields.count) CMB fields from \(peerName)")

                // Reconstruct CMB with decrypted fields
                incomingCMB = CognitiveMemoryBlock(
                    key: frame.key ?? "cmb-\(UUID().uuidString.prefix(8))",
                    fields: decryptedFields,
                    source: frame.source ?? peerName,
                    createdBy: frame.source ?? peerName,
                    originTimestamp: frame.originTimestamp ?? frame.timestamp ?? UInt64(Date().timeIntervalSince1970 * 1000),
                    storedAt: UInt64(Date().timeIntervalSince1970 * 1000),
                    confidence: frame.confidence ?? 0.8
                )
            } else {
                guard let plainCMB = frame.cmb else {
                    logger.warning("[SYM] cmb: missing CMB in frame from \(peerName)")
                    break
                }
                incomingCMB = plainCMB
            }
            let fieldCount = incomingCMB.fields.count
            let moodText = incomingCMB.fields[.mood]?.text ?? "none"
            logger.info("[SYM] cmb: received CMB \(incomingCMB.key.prefix(20)) from \(peerName) (\(fieldCount) fields, mood: \(moodText))")
            let content = CMBEncoder.renderContent(from: incomingCMB)

            // ── SVAF v2: Per-Field CMB Fusion ──────────────────────
            // MMP v0.2.0 Section 9: λ_j = α_f · cos(x_new, x_j) · g(l_j) · exp(-λ(t_now - t_j)) · c_j
            // Per-field drift evaluation + field-wise weighted fusion → NEW synthesized memory

            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let originTs = frame.originTimestamp ?? frame.timestamp ?? now
            let ageSeconds = now >= originTs ? Float(now - originTs) / 1000.0 : 0.0
            let temporalDecay: Float = exp(-ageSeconds / self.svafFreshnessSeconds)
            let temporalDrift: Float = 1.0 - temporalDecay
            let confidence: Float = frame.confidence ?? 0.8

            // 1. Get anchor CMBs from local memory
            let anchors = store.recentCMBs(limit: 5)

            // 2. Per-field drift evaluation and fusion
            var fieldDrifts: [CMBField: Float] = [:]
            var fusedFields: [CMBField: CMBFieldVector] = [:]
            var anchorWeightsLog: [CMBField: [Float]] = [:]

            for field in CMBField.allCases {
                guard let incomingField = incomingCMB.fields[field] else { continue }

                let alphaF = self.svafFieldWeights[field]
                var weightedVec = incomingField.vector.map { $0 * 1.0 as Float }  // λ_new = 1.0
                var totalWeight: Float = 1.0
                var fieldAnchorWeights: [Float] = []

                for anchor in anchors {
                    guard let anchorField = anchor.fields[field] else {
                        fieldAnchorWeights.append(0)
                        continue
                    }

                    let cosSim = CMBEncoder.cosineSimilarity(incomingField.vector, anchorField.vector)
                    let anchorAge = now >= anchor.storedAt ? Float(now - anchor.storedAt) / 1000.0 : 0.0
                    let anchorDecay = exp(-anchorAge / self.svafFreshnessSeconds)
                    let w = alphaF * max(cosSim, 0) * anchorDecay * anchor.confidence

                    for d in 0..<weightedVec.count {
                        weightedVec[d] += w * anchorField.vector[d]
                    }
                    totalWeight += w
                    fieldAnchorWeights.append(w)
                }

                // Normalize fused vector
                var fused = weightedVec.map { $0 / max(totalWeight, 1e-8) }
                fused = CMBEncoder.l2Normalize(fused)

                // Per-field drift: distance between fused and local (anchors' average)
                let fieldDrift = 1.0 - CMBEncoder.cosineSimilarity(fused, incomingField.vector)
                fieldDrifts[field] = fieldDrift
                anchorWeightsLog[field] = fieldAnchorWeights

                // Synthesize field text
                // TODO: v2 — LLM synthesis of field text
                let fusedText = incomingField.text
                fusedFields[field] = CMBFieldVector(text: fusedText, vector: fused)
            }

            // 4. Aggregate drift: weighted average of per-field drifts
            var weightedDriftSum: Float = 0
            var weightSum: Float = 0
            for field in CMBField.allCases {
                let alphaF = self.svafFieldWeights[field]
                weightedDriftSum += alphaF * (fieldDrifts[field] ?? 0)
                weightSum += alphaF
            }
            let aggregateFieldDrift = weightSum > 0 ? weightedDriftSum / weightSum : 1.0

            // 5. Combined: content-field drift + temporal drift
            let totalDrift = (1.0 - self.svafTemporalLambda) * aggregateFieldDrift + self.svafTemporalLambda * temporalDrift

            // 6. Threshold decision
            if totalDrift > self.svafGuardedThreshold {
                let fieldLog = fieldDrifts.map { "\($0.key.rawValue):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
                logger.info("[SYM] memory: SVAF rejected from \(peerName) — drift \(String(format: "%.3f", totalDrift)) [\(fieldLog)] temporal:\(String(format: "%.2f", temporalDrift))")

                // Mood crosses all domain boundaries (MMP spec).
                // Even when the full CMB is rejected, mood-aware agents must
                // still receive the mood field for autonomous processing.
                if let moodField = incomingCMB.fields[.mood], moodField.text != "neutral" {
                    logger.info("[SYM] memory: mood extracted from rejected CMB: \"\(moodField.text)\" from \(peerName)")
                    emit(.memoryReceived(from: peerName, content: moodField.text, decision: "mood-only", cmb: incomingCMB))
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
                fields: fusedFields,
                source: "\(self.name)+\(frame.source ?? peerName)",
                lineage: fusedLineage,
                originTimestamp: originTs,
                storedAt: now,
                confidence: confidence * (1.0 - aggregateFieldDrift),
                provenance: CMBProvenance(
                    fusedFrom: [incomingCMB.key] + anchors.map(\.key),
                    fusionWeights: anchorWeightsLog,
                    fieldDrift: fieldDrifts,
                    totalDrift: totalDrift,
                    temporalDrift: temporalDrift
                )
            )

            // 8. Store the FUSED entry (not the original)
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
            store.receiveFromPeer(peerId: nodeId, entry: entry)

            // Protocol metrics + cmb-accepted event
            _metrics.cmbAccepted += 1
            emit(.cmbAccepted(entry: entry))
            emit(.metric(type: "cmb-accepted", detail: ["from": peerName, "key": entry.key]))

            let fieldLog = fieldDrifts.sorted(by: { $0.key.rawValue < $1.key.rawValue })
                .map { "\($0.key.rawValue):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
            logger.info("[SYM] memory: SVAF fused from \(peerName): \"\(fusedContent.prefix(50))\" [\(decision), drift:\(String(format: "%.3f", totalDrift)), fields: \(fieldLog), age:\(String(format: "%.0f", ageSeconds))s]")
            emit(.memoryReceived(from: peerName, content: fusedContent, decision: decision, cmb: fusedCMB))

        case .mood:
            guard let mood = frame.mood else { break }

            // Use the SDK's coupling engine to evaluate whether this mood
            // is relevant to our cognitive state. No manual math.
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
                emit(.moodAccepted(from: from, mood: mood, drift: drift))
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
                remember(fields: [
                    .focus: CMBEncoder.encodeField(synthesis),
                    .mood: CMBEncoder.encodeField("neutral"),
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
        }
    }
}

// MARK: - Discovery Delegate

extension SymNode: SymDiscoveryDelegate {

    func discoveryDidFindPeer(nodeId: String, name: String, browseResult: NWBrowser.Result) {
        let exists: Bool = peerQueue.sync { self.peers[nodeId] != nil }
        guard !exists else { return }

        logger.info("[SYM] peer: connecting to \(name) via service endpoint")
        let session = SymPeerSession(outboundTo: browseResult.endpoint, identity: identity)
        session.delegate = self
        // Retain until handshake identifies the peer
        let key = ObjectIdentifier(session)
        peerQueue.sync { self.pendingSessions[key] = session }
        session.start()
    }

    func discoveryDidLosePeer(nodeId: String) {
        // Don't tear down active sessions on Bonjour removal —
        // mDNS sends transient remove+re-add. Heartbeat handles real loss.
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
        // Release from pending (inbound sessions)
        let key = ObjectIdentifier(session)
        peerQueue.sync { _ = self.pendingSessions.removeValue(forKey: key) }

        addPeer(session, nodeId: nodeId, peerName: name, isOutbound: session.isOutbound)
    }

    func session(_ session: SymPeerSession, didReceive frame: SymFrame) {
        guard let nodeId = session.peerNodeId, let peerName = session.peerName else { return }
        handlePeerFrame(nodeId: nodeId, peerName: peerName, frame: frame)
    }

    func session(_ session: SymPeerSession, didDisconnectWith reason: String) {
        // Release from pending if never handshaked
        let key = ObjectIdentifier(session)
        peerQueue.sync { _ = self.pendingSessions.removeValue(forKey: key) }

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

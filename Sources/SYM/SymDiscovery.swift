//
//  SymDiscovery.swift
//  SYM
//
//  Bonjour/mDNS discovery for SYM mesh.
//  Service type: _sym._tcp — same as Node.js SYM.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation
import Network
import os.log

// MARK: - Discovery Delegate

/// Delegate for Bonjour discovery lifecycle events.
protocol SymDiscoveryDelegate: AnyObject {
    /// A new peer was discovered via Bonjour.
    func discoveryDidFindPeer(nodeId: String, name: String, browseResult: NWBrowser.Result)
    /// A previously discovered peer's Bonjour record was removed.
    func discoveryDidLosePeer(nodeId: String)
    /// An inbound TCP connection was accepted from a peer.
    func discoveryDidAcceptConnection(_ connection: NWConnection)
}

// MARK: - Discovery Service

/// Handles Bonjour advertisement and browsing for SYM peers on the local network.
/// See MMP v0.2.0 Section 5 (Connection, Layer 2).
///
/// Service type: configurable per app. Defaults to `_sym._tcp` for
/// interoperability with Node.js SYM nodes. Apps that want isolated
/// LAN discovery (e.g. MeloTune using `_melotune._tcp`) pass a custom
/// type at init. Peers on different service types never see each other.
/// TXT record carries: node-id, node-name, hostname.
final class SymDiscovery {

    public static let defaultServiceType = "_sym._tcp"

    let serviceType: String
    private let identity: SymIdentity
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "bot.sym.discovery", qos: .userInitiated)
    private var isRunning = false
    private let logger = Logger(subsystem: "bot.sym", category: "Discovery")

    /// The port this node is listening on (available after start).
    private(set) var port: UInt16 = 0

    weak var delegate: SymDiscoveryDelegate?

    init(identity: SymIdentity, serviceType: String = SymDiscovery.defaultServiceType) {
        self.identity = identity
        self.serviceType = serviceType
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.startListener()
            self.startBrowser()
            self.logger.info("[SYM] discovery: started (nodeId=\(self.identity.nodeId.prefix(8)))")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.listener?.cancel()
            self.listener = nil
            self.browser?.cancel()
            self.browser = nil
            self.logger.info("[SYM] discovery: stopped")
        }
    }

    // MARK: - Listener

    private func startListener() {
        do {
            // Keepalive applied to the listener parameters so accepted inbound
            // NWConnections inherit it. Without this, a peer that crashes leaves
            // us with a dead-but-ESTABLISHED inbound socket that survives ~2h
            // before macOS keepalive reaps it — the addPeer dedup logic then
            // rejects every live redial against the zombie. See SymPeerSession
            // tcpParametersWithKeepalive() for full rationale.
            let parameters = SymPeerSession.tcpParametersWithKeepalive()
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)

            var txtRecord = NWTXTRecord()
            txtRecord["node-id"] = identity.nodeId
            txtRecord["node-name"] = identity.name
            txtRecord["public-key"] = identity.publicKey
            txtRecord["hostname"] = identity.hostname

            // Bonjour instance name must be unique among the services THIS device
            // advertises. An app that joins cross-app groups runs one SymNode —
            // hence one listener — per group, all sharing the device's identity.
            // Keying the instance name on nodeId alone makes those co-resident
            // listeners collide, and the Network framework publishes only the
            // first: the group's `_<group>._tcp` service never reaches the LAN
            // (the main `_melotune._tcp` node still does, masking the bug). Make
            // it unique per (node, service type). Peers identify the node via the
            // `node-id` TXT entry, and self-filtering is by `node-id` too (see
            // handlePeerFound), so this label change is transparent to interop.
            let groupToken = serviceType
                .replacingOccurrences(of: "._tcp", with: "")
                .replacingOccurrences(of: ".", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let instanceName = groupToken.isEmpty ? identity.nodeId : "\(identity.nodeId)-\(groupToken)"

            listener.service = NWListener.Service(
                name: instanceName,
                type: serviceType,
                txtRecord: txtRecord
            )

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener?.port {
                        self?.port = port.rawValue
                        self?.logger.info("[SYM] discovery: listening on port \(port.rawValue)")
                    }
                case .failed(let error):
                    self?.logger.error("[SYM] discovery: listener failed: \(error.localizedDescription)")
                case .cancelled:
                    break
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.delegate?.discoveryDidAcceptConnection(connection)
            }

            listener.start(queue: queue)
            self.listener = listener

        } catch {
            logger.error("[SYM] discovery: listener start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Browser

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: serviceType,
            domain: nil
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] (state: NWBrowser.State) in
            if case .ready = state {
                self?.logger.info("[SYM] discovery: browser active, scanning for peers")
            }
        }

        browser.browseResultsChangedHandler = { [weak self] (_: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) in
            self?.handleBrowseChanges(changes)
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    /// Re-scan current Bonjour browse results to reconnect peers whose TCP
    /// connection dropped but whose mDNS record is still visible. Called
    /// after peer disconnect with a delay to allow network state to settle.
    func retryVisiblePeers() {
        queue.async { [weak self] in
            guard let self, let browser = self.browser else { return }
            let results = browser.browseResults
            guard !results.isEmpty else { return }
            self.logger.info("[SYM] discovery: retrying \(results.count) visible peer(s)")
            for result in results {
                self.handlePeerFound(result)
            }
        }
    }

    private func handleBrowseChanges(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handlePeerFound(result)
            case .removed(let result):
                handlePeerLost(result)
            case .changed(old: _, new: let result, flags: _):
                handlePeerFound(result)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func handlePeerFound(_ result: NWBrowser.Result) {
        guard let (nodeId, name) = parseTXT(from: result) else { return }

        // Self-filter
        guard nodeId != identity.nodeId else { return }

        logger.info("[SYM] discovery: found peer: \(name) (\(nodeId.prefix(8)))")

        // Connect via NWConnection to the Bonjour service endpoint directly.
        // This works when the peer advertises via Apple's native mDNS (dns-sd).
        // Falls back to NetService resolver for non-Apple mDNS implementations.
        delegate?.discoveryDidFindPeer(nodeId: nodeId, name: name, browseResult: result)
    }

    private func handlePeerLost(_ result: NWBrowser.Result) {
        guard let (nodeId, _) = parseTXT(from: result) else { return }
        guard nodeId != identity.nodeId else { return }

        logger.info("[SYM] discovery: lost peer: \(nodeId.prefix(8))")
        delegate?.discoveryDidLosePeer(nodeId: nodeId)
    }

    private func parseTXT(from result: NWBrowser.Result) -> (nodeId: String, name: String)? {
        guard case .bonjour(let record) = result.metadata else { return nil }
        guard let nodeId = record["node-id"] else { return nil }
        let name = record["node-name"] ?? "unknown"
        return (nodeId, name)
    }
}

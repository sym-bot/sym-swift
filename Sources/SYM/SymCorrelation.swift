//
//  SymCorrelation.swift
//  SYM
//
//  Request/response correlation over payload-bearing CMBs.
//  Reviewed surface: sym-swift 0.5.0 API sketch §5 (dev2 + dev3 verdicts).
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation

/// A payload-bearing CMB delivered to this node — one direction-neutral type
/// on all three seats of an exchange: the value a ``SymNode/request(payload:categories:to:timeout:)``
/// await resolves to, the value ``SymEvent/requestReceived(envelope:)`` hands a
/// responder, and the argument ``SymNode/respond(to:payload:categories:)`` takes.
///
/// `payload` is the full JSON-object bytes as they crossed the wire —
/// including the injected snake_case `request_id`, which is also surfaced
/// parsed as ``requestId`` so consumers never re-parse just to correlate.
public struct SymEnvelope: Sendable, Equatable {
    /// Node ID of the peer this envelope arrived from (the transport peer —
    /// also the target ``SymNode/respond(to:payload:categories:)`` replies to).
    public let from: String
    /// Display name of the sending peer.
    public let fromName: String
    /// The correlation id (`request_id` inside ``payload``).
    public let requestId: String
    /// JSON bytes of the payload object exactly as received.
    public let payload: Data
    /// Key of the CMB that carried this payload, when the receive path
    /// resolved one. The CMB itself is not carried here: the envelope is
    /// `Sendable` across strict-concurrency boundaries and the block, when
    /// admitted, is reachable through the store by this key.
    public let cmbKey: String?

    public init(from: String, fromName: String, requestId: String, payload: Data, cmbKey: String?) {
        self.from = from
        self.fromName = fromName
        self.requestId = requestId
        self.payload = payload
        self.cmbKey = cmbKey
    }
}

/// Failures of the correlation surface. Timeout is the only failure a live
/// exchange produces — peer departure deliberately does NOT fast-fail (relay
/// presence flaps during upstream cold starts while the response may still
/// arrive; the caller's timeout is the contract).
public enum SymRequestError: Error, Equatable {
    /// No matching response arrived within the caller's window.
    case timeout(after: TimeInterval)
    /// The awaiting Task was cancelled (structured concurrency).
    case cancelled
    /// The node stopped (or the app suspended through it) with the request
    /// pending. Pending requests never survive a stop: fail fast on resume,
    /// no zombie awaits — a request that must survive suspension is an
    /// application-layer retry.
    case interrupted
    /// The node is not running.
    case notRunning
    /// The payload bytes do not encode a top-level JSON object. The Node
    /// convention puts `request_id` INSIDE the payload object, so a
    /// non-object payload has nowhere to carry the correlation id.
    case invalidPayload
    /// The target peer is not connected on any transport — the frame cannot
    /// be addressed at all, so failing now beats a guaranteed timeout. This
    /// is NOT the peer-departure fast-fail the review rejected: it fires only
    /// when no route exists at send time, never on presence flap mid-flight.
    case peerUnknown
}

/// Outcome of handing a built frame to the node's send path.
enum SymDispatchOutcome: Sendable {
    case sent
    case notRunning
    case peerUnknown
}

// MARK: - Correlation registry

/// The pending-request table: request ids to suspended continuations.
///
/// A separate, deliberately tiny type rather than state on ``SymNode``,
/// because the async surface has to be reachable from an actor-isolated
/// consumer (MeloMove's mesh layer is `@MainActor` under the Swift 6
/// language mode). `SymNode` is a large class with unguarded public members
/// and claiming `Sendable` for it would be an assertion nothing backs; this
/// class holds one dictionary under one lock and has no public surface at
/// all, so the `@unchecked` is auditable in a single screen.
///
/// Every continuation is resumed EXACTLY once: each resume site removes the
/// entry under the lock first, so match / timeout / cancel / stop collapse
/// to whoever removes it.
final class SymCorrelationRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<SymEnvelope, Error>] = [:]
    /// Requests whose Task was cancelled before the continuation registered
    /// (the cancellation handler can run first).
    private var cancelledBeforeRegistration: Set<String> = []

    /// Register a continuation, or refuse it because cancellation already
    /// arrived. Returns false when the caller must resume with `.cancelled`.
    func register(_ requestId: String, _ continuation: CheckedContinuation<SymEnvelope, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelledBeforeRegistration.remove(requestId) != nil { return false }
        pending[requestId] = continuation
        return true
    }

    /// Remove and return the continuation awaiting `requestId`, if any.
    func take(_ requestId: String) -> CheckedContinuation<SymEnvelope, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: requestId)
    }

    /// Record that cancellation arrived, taking the continuation if it is
    /// already registered.
    func cancel(_ requestId: String) -> CheckedContinuation<SymEnvelope, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if let continuation = pending.removeValue(forKey: requestId) { return continuation }
        cancelledBeforeRegistration.insert(requestId)
        return nil
    }

    /// Drain every pending request — the node is stopping.
    func drain() -> [CheckedContinuation<SymEnvelope, Error>] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(pending.values)
        pending.removeAll()
        cancelledBeforeRegistration.removeAll()
        return all
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

// MARK: - Exchange handle

/// The `Sendable` handle for the request/response surface.
///
/// Vended by ``SymNode/exchange``. It exists because `await`-ing a method
/// directly on ``SymNode`` from an actor-isolated context would send a
/// non-`Sendable` class across an isolation boundary — which the Swift 6
/// language mode rejects, and which is exactly the context the consumers of
/// this surface run in. Hold the handle wherever you hold the node:
///
/// ```swift
/// @MainActor final class MeshCAT7Provider {
///     private let exchange: SymExchange
///     init(node: SymNode) { self.exchange = node.exchange }
///
///     func ask(_ prompt: String, of peer: String) async throws -> Data {
///         try await exchange.request(payload: …, categories: …, to: peer, timeout: 20).payload
///     }
/// }
/// ```
///
/// Sendability audit: the handle stores the lock-protected registry and one
/// `@Sendable` closure whose captures reach the node only through its
/// serial queues (peer lookup and per-peer secrets are read under
/// `peerQueue`; encoding and signing are pure).
public struct SymExchange: Sendable {

    let registry: SymCorrelationRegistry
    /// Build and send the payload-bearing frame. Returns why it could not
    /// be sent, so the caller fails before suspending rather than after a
    /// guaranteed-empty wait.
    let dispatch: @Sendable (_ wirePayload: Data,
                             _ categories: [CMBCategory: CMBCategoryVector],
                             _ peerId: String) -> SymDispatchOutcome

    /// Send a directed payload-bearing CMB and await the directed response
    /// whose payload echoes the generated `request_id`.
    ///
    /// - Parameters:
    ///   - payload: JSON bytes of a top-level object. `request_id` is
    ///     generated and injected; a non-object throws
    ///     ``SymRequestError/invalidPayload`` (the correlation id has to
    ///     live inside the object, which is where a Node peer reads it).
    ///   - categories: CAT7 category vectors for the carrying CMB.
    ///   - peerId: Target peer node ID.
    ///   - timeout: Caller-set window, per call — deliberately no default,
    ///     because only the caller knows whether this is an impatient query
    ///     or one that should ride out an upstream cold start.
    /// - Returns: The matched ``SymEnvelope``.
    /// - Throws: ``SymRequestError``.
    public func request(payload: Data,
                        categories: [CMBCategory: CMBCategoryVector],
                        to peerId: String,
                        timeout: TimeInterval) async throws -> SymEnvelope {
        guard var payloadObject = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw SymRequestError.invalidPayload
        }
        let requestId = UUID().uuidString
        payloadObject["request_id"] = requestId
        let wirePayload = try JSONSerialization.data(withJSONObject: payloadObject)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard registry.register(requestId, continuation) else {
                    continuation.resume(throwing: SymRequestError.cancelled)
                    return
                }
                switch dispatch(wirePayload, categories, peerId) {
                case .sent:
                    break
                case .notRunning:
                    registry.take(requestId)?.resume(throwing: SymRequestError.notRunning)
                    return
                case .peerUnknown:
                    registry.take(requestId)?.resume(throwing: SymRequestError.peerUnknown)
                    return
                }
                let registry = self.registry
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    registry.take(requestId)?.resume(throwing: SymRequestError.timeout(after: timeout))
                }
            }
        } onCancel: {
            registry.cancel(requestId)?.resume(throwing: SymRequestError.cancelled)
        }
    }
}

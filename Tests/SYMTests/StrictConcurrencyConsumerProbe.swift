import XCTest
@testable import SYM

// MARK: - Strict-concurrency consumer probe
//
// MeloMove's mesh layer is Swift 6 strict concurrency with @MainActor
// services, so the 0.5.0 surface has to be CALLABLE from there — a library
// that compiles cleanly on its own but cannot be called from the consumer's
// isolation context has shipped nothing. This probe is that call site.
//
// Run under complete checking with:
//   swift build --build-tests -Xswiftc -strict-concurrency=complete

@MainActor
final class StrictConcurrencyConsumerProbe: XCTestCase {

    /// Stands in for MeshCAT7Provider: a MainActor-isolated service holding
    /// a node and awaiting a request across the isolation boundary.
    @MainActor
    final class ConsumerService {
        let node: SymNode
        /// The Sendable handle, held alongside the node — this is the shape
        /// the API forces, and the reason it exists.
        let exchange: SymExchange

        init(node: SymNode) {
            self.node = node
            self.exchange = node.exchange
        }

        func ask(_ prompt: String, of peerId: String) async throws -> Data {
            let payload = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
            let envelope = try await exchange.request(
                payload: payload,
                categories: [.focus: CMBEncoder.encodeCategory(prompt)],
                to: peerId,
                timeout: 20
            )
            return envelope.payload
        }

        func serve(_ envelope: SymEnvelope) throws {
            let payload = try JSONSerialization.data(withJSONObject: ["answer": "served"])
            try node.respond(to: envelope, payload: payload,
                             categories: [.focus: CMBEncoder.encodeCategory("answer")])
        }
    }

    func testMainActorConsumerCanDriveTheCorrelationSurface() async throws {
        let node = SymNode(name: "test-strict-\(UUID().uuidString)")
        let service = ConsumerService(node: node)

        // Not running → the surface refuses rather than hanging. What is
        // being proven here is that the call COMPILES and returns from a
        // MainActor context, which is the consumer's actual constraint.
        do {
            _ = try await service.ask("how did my human move today", of: "peer-x")
            XCTFail("expected notRunning")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .notRunning)
        }
    }

    func testEnvelopeCrossesIsolationBoundaries() async {
        // SymEnvelope is Sendable-for-real (Data, not [String: Any]), so it
        // can be handed from the node's delivery context to a MainActor
        // service without an @unchecked escape hatch.
        let envelope = SymEnvelope(
            from: "peer-1", fromName: "peer-one", requestId: "r-1",
            payload: try! JSONSerialization.data(withJSONObject: ["request_id": "r-1"]),
            cmbKey: "cmb-1")

        let received = await Task.detached { () -> SymEnvelope in
            envelope
        }.value

        XCTAssertEqual(received.requestId, "r-1")
    }

    func testInviteURLCrossesIsolationBoundaries() async {
        let invite = SymInviteURL(relay: URL(string: "wss://relay.example.com")!,
                                  token: "t", room: "r", name: "n")
        let received = await Task.detached { () -> SymInviteURL in
            invite
        }.value
        XCTAssertEqual(received, invite)
    }
}

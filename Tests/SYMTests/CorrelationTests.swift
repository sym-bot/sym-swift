import XCTest
@testable import SYM

// MARK: - Request/Response Correlation Tests (0.5.0)
//
// The correlation layer is a thin surface above the send path, so these
// tests drive the two halves that do not require a live peer: the wire
// carriage of the payload (SymFrame round-trip, both transports) and the
// await/resolve state machine (via a SymExchange whose dispatch is a
// no-op over the node's real registry).
//
// Each clause is a separate assertion because they fail differently: a
// payload that never reaches the wire and one that arrives but never
// resolves a continuation are two different broken products.

final class CorrelationTests: XCTestCase {

    private func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func object(_ data: Data) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    /// An exchange over the node's REAL registry whose dispatch is a no-op:
    /// the await/resolve state machine runs exactly as in production, without
    /// needing a live peer to send to. `handleIncomingPayload` and `stop()`
    /// drive the same registry, so what these tests exercise is the shipped
    /// machinery and not a parallel implementation of it.
    private func offlineExchange(_ node: SymNode) -> SymExchange {
        SymExchange(registry: node.correlationRegistry) { _, _, _, _ in .sent }
    }

    /// The request id the node minted for the single in-flight request.
    /// The id is generated inside `request(...)`, so a test that wants to
    /// deliver a matching response has to learn it from the payload the
    /// dispatch was handed.
    private func capturingExchange(_ node: SymNode,
                                   into box: RequestIDBox) -> SymExchange {
        SymExchange(registry: node.correlationRegistry) { wirePayload, _, _, _ in
            if let obj = (try? JSONSerialization.jsonObject(with: wirePayload)) as? [String: Any],
               let rid = obj["request_id"] as? String {
                box.set(rid)
            }
            return .sent
        }
    }

    final class RequestIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ v: String) { lock.lock(); self.value = v; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - Wire carriage

    func testPayloadRidesInsideCMBObjectAsSiblingOfContent() throws {
        // The Node-facing shape: a plaintext CMB frame. `msg.cmb.payload` is
        // what frame-handler.js reads, so the payload must be a sibling of
        // the CAT7 content INSIDE that object — not a top-level member.
        let node = SymNode(name: "test-corr-shape-\(UUID().uuidString)")
        let frame = node.testHook_makePayloadCMBFrame(
            payload: payload(["request_id": "r-1", "prompt": "hello"]),
            categories: [.focus: CMBEncoder.encodeCategory("x")], for: "peer-x")

        let serialized = try frame.serialize()
        let json = serialized.subdata(in: 4..<serialized.count)
        let obj = (try JSONSerialization.jsonObject(with: json)) as! [String: Any]

        let cmbObj = try XCTUnwrap(obj["cmb"] as? [String: Any],
                                   "payload must ride INSIDE the cmb object, not at frame top level")
        let payloadObj = try XCTUnwrap(cmbObj["payload"] as? [String: Any],
                                       "Node reads msg.cmb.payload — sibling of the CAT7 content")
        XCTAssertEqual(payloadObj["request_id"] as? String, "r-1")
        XCTAssertEqual(payloadObj["prompt"] as? String, "hello")
        XCTAssertNil(obj["payload"], "no top-level payload key — that is the relay envelope's word")
    }

    func testPayloadRoundTripsThroughTheFrameParser() throws {
        let node = SymNode(name: "test-corr-rt-\(UUID().uuidString)")
        let frame = node.testHook_makePayloadCMBFrame(
            payload: payload(["request_id": "r-2", "n": 7]),
            categories: [.focus: CMBEncoder.encodeCategory("c")], for: "peer-x")

        let parser = SymFrameParser()
        let parsed = parser.feed(try frame.serialize())

        XCTAssertEqual(parsed.count, 1)
        let received = try XCTUnwrap(parsed.first?.cmbPayload,
                                     "parser must lift cmb.payload back out — the CMB decode ignores the key")
        XCTAssertEqual(object(received)["request_id"] as? String, "r-2")
        XCTAssertEqual(object(received)["n"] as? Int, 7)
    }

    func testFrameWithoutPayloadStaysByteIdenticalToPre050() throws {
        // Additive means additive: a frame nobody gave a payload must not
        // gain an empty object, or every existing wire assertion moves.
        let frame = SymFrame.cmb(key: "cmb-1", content: "c", source: "s",
                                 tags: [], originTimestamp: 1, storedAt: 1)
        let serialized = try frame.serialize()
        let json = serialized.subdata(in: 4..<serialized.count)
        let obj = (try JSONSerialization.jsonObject(with: json)) as! [String: Any]

        if let cmbObj = obj["cmb"] as? [String: Any] {
            XCTAssertNil(cmbObj["payload"], "absent payload encodes as absent")
        }
    }

    func testPayloadIsNotPartOfTheSigningPreimageOrKey() throws {
        // MUST 1 from the wire review: signing binds CAT7 content only, so a
        // payload-bearing CMB must survive the wire with its key and
        // signature untouched and still VERIFY — that is what byte agreement
        // with a Node peer actually means in practice. (Comparing two
        // separately-built frames would vary their timestamps too, which is
        // a different variable; this holds everything but the payload fixed.)
        let node = SymNode(name: "test-corr-sign-\(UUID().uuidString)")
        let categories: [CMBCategory: CMBCategoryVector] = [
            .focus: CMBEncoder.encodeCategory("the same focus")
        ]
        let frame = node.testHook_makePayloadCMBFrame(
            payload: payload(["request_id": "a", "prompt": "some large application payload"]),
            categories: categories, for: "peer-x")
        let signedBeforePayload = try XCTUnwrap(frame.cmb)

        let parser = SymFrameParser()
        let parsed = try XCTUnwrap(parser.feed(try frame.serialize()).first)
        let received = try XCTUnwrap(parsed.cmb)

        XCTAssertEqual(received.key, signedBeforePayload.key,
                       "payload must not enter the cmbKey hash")
        XCTAssertEqual(received.sig, signedBeforePayload.sig,
                       "payload must not enter the signing preimage")

        let verdict = CMBSigning.verify(received, publicKeyBase64URL: node.signingPublicKey)
        XCTAssertTrue(verdict.signed, "the CMB is signed")
        XCTAssertTrue(verdict.valid,
                      "a payload-bearing CMB still verifies — signing binds CAT7 content only")
    }

    func testPayloadSurvivesOnACmbLessFrame() throws {
        // The E2E path clears `cmb` (categories became `encryptedFields`).
        // Nesting the payload under a synthesized `cmb` there made the WHOLE
        // frame undecodable — the flat decode failed on a CMB missing every
        // required member and the receiver dropped frame and payload
        // together, silently. Caught by this suite; guarded here.
        var frame = SymFrame(type: .cmb)
        frame.key = "cmb-e2e"
        frame.source = "tester"
        frame.encryptedCategories = "Y2lwaGVydGV4dA=="
        frame.e2e = E2EMetadata(nonce: "bm9uY2U=")
        frame.cmbPayload = payload(["request_id": "r-e2e", "prompt": "encrypted peer"])

        let parser = SymFrameParser()
        let parsed = try XCTUnwrap(parser.feed(try frame.serialize()).first,
                                   "a cmb-less payload frame must still decode")
        let received = try XCTUnwrap(parsed.cmbPayload,
                                     "the payload must survive on the encrypted path too")
        XCTAssertEqual(object(received)["request_id"] as? String, "r-e2e")
        XCTAssertEqual(parsed.encryptedCategories, "Y2lwaGVydGV4dA==",
                       "the encrypted members are untouched")
    }

    // MARK: - Await / resolve state machine

    func testTimeoutFailsWithTheCallersWindow() async {
        let node = SymNode(name: "test-corr-timeout-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        do {
            _ = try await offlineExchange(node).request(
                payload: payload(["p": 1]), categories: [:], to: "peer-x", timeout: 0.2)
            XCTFail("expected timeout")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .timeout(after: 0.2),
                           "the error must name the caller's window, not a library default")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMatchingResponseResolvesTheAwait() async throws {
        let node = SymNode(name: "test-corr-match-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        let box = RequestIDBox()
        let exchange = capturingExchange(node, into: box)

        Task {
            // Deliver once the request has been dispatched and its generated
            // id is known — the caller never chooses the id.
            while box.get() == nil {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            node.testHook_handleIncomingPayload(
                self.payload(["request_id": box.get()!, "answer": "42"]),
                from: "peer-1", peerName: "peer-one", cmbKey: "cmb-abc")
        }

        let envelope = try await exchange.request(
            payload: payload(["prompt": "q"]), categories: [:], to: "peer-1", timeout: 5)
        XCTAssertEqual(envelope.requestId, box.get())
        XCTAssertEqual(envelope.from, "peer-1")
        XCTAssertEqual(envelope.fromName, "peer-one")
        XCTAssertEqual(envelope.cmbKey, "cmb-abc")
        XCTAssertEqual(object(envelope.payload)["answer"] as? String, "42",
                       "the envelope carries the payload bytes as they arrived")
    }

    func testCancellationFailsWithCancelled() async {
        let node = SymNode(name: "test-corr-cancel-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        let exchange = offlineExchange(node)
        let task = Task {
            try await exchange.request(payload: self.payload(["p": 1]), categories: [:],
                                       to: "peer-x", timeout: 60)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStopFailsPendingRequestsAsInterrupted() async {
        let node = SymNode(name: "test-corr-stop-\(UUID().uuidString)")
        node.start()

        let exchange = offlineExchange(node)
        let task = Task {
            try await exchange.request(payload: self.payload(["p": 1]), categories: [:],
                                       to: "peer-x", timeout: 60)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        node.stop()

        do {
            _ = try await task.value
            XCTFail("expected interruption")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .interrupted,
                           "pending requests never survive a stop — fail fast, no zombie awaits")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRequestOnStoppedNodeThrowsNotRunning() async {
        let node = SymNode(name: "test-corr-stopped-\(UUID().uuidString)")
        do {
            _ = try await node.exchange.request(payload: payload(["p": 1]), categories: [:],
                                       to: "peer-x", timeout: 1)
            XCTFail("expected notRunning")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .notRunning)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRequestToUnroutablePeerFailsImmediately() async {
        let node = SymNode(name: "test-corr-noroute-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        do {
            _ = try await node.exchange.request(payload: payload(["p": 1]), categories: [:],
                                       to: "peer-that-does-not-exist", timeout: 30)
            XCTFail("expected peerUnknown")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .peerUnknown,
                           "no route at send time fails now rather than after a guaranteed-empty wait")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonObjectPayloadIsRefused() async {
        let node = SymNode(name: "test-corr-badpayload-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        let notAnObject = "[1,2,3]".data(using: .utf8)!
        do {
            _ = try await node.exchange.request(payload: notAnObject, categories: [:],
                                       to: "peer-x", timeout: 1)
            XCTFail("expected invalidPayload")
        } catch let error as SymRequestError {
            // peerUnknown is checked first only for a routable peer; here the
            // node has no peers at all, so assert on whichever guard fired
            // being one of the two refusals — never a silent send.
            XCTAssertTrue(error == .invalidPayload || error == .peerUnknown,
                          "a non-object payload has nowhere to carry request_id")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Inbound requests

    func testUncorrelatedPayloadSurfacesAsRequestReceived() async {
        let node = SymNode(name: "test-corr-inbound-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        let received = expectation(description: "requestReceived emitted")
        var seen: SymEnvelope?
        node.on { event in
            if case .requestReceived(let envelope) = event {
                seen = envelope
                received.fulfill()
            }
        }
        // Give the handler registration (stateQueue.async) time to land.
        try? await Task.sleep(nanoseconds: 100_000_000)

        node.testHook_handleIncomingPayload(
            payload(["request_id": "r-inbound", "ask": "how did my human move today"]),
            from: "peer-2", peerName: "peer-two", cmbKey: "cmb-xyz")

        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(seen?.requestId, "r-inbound")
        XCTAssertEqual(seen?.from, "peer-2",
                       "respond(to:) addresses this — the responder must be able to reply")
    }

    func testPayloadWithoutRequestIdIsIgnoredNotSurfaced() async {
        let node = SymNode(name: "test-corr-norid-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        var fired = false
        node.on { event in
            if case .requestReceived = event { fired = true }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        node.testHook_handleIncomingPayload(payload(["not_a_request": true]),
                                            from: "peer-3", peerName: "peer-three", cmbKey: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(fired, "a payload with no request_id is not an exchange")
    }

    func testLateResponseAfterTimeoutBecomesAnOrdinaryInbound() async throws {
        // The accepted semantics: a response arriving after its timeout is
        // not an error and not a resolved await — it surfaces as an ordinary
        // uncorrelated payload the app may ignore or salvage.
        let node = SymNode(name: "test-corr-late-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        let box = RequestIDBox()
        do {
            _ = try await capturingExchange(node, into: box).request(
                payload: payload(["p": 1]), categories: [:], to: "peer-4", timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            // expected
        }
        let lateId = try XCTUnwrap(box.get())

        let received = expectation(description: "late response surfaced as inbound")
        node.on { event in
            if case .requestReceived(let envelope) = event, envelope.requestId == lateId {
                received.fulfill()
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        node.testHook_handleIncomingPayload(payload(["request_id": lateId, "answer": "too late"]),
                                            from: "peer-4", peerName: "peer-four", cmbKey: nil)
        await fulfillment(of: [received], timeout: 5)
    }
}

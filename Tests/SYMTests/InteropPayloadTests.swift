//
//  InteropPayloadTests.swift
//  SYMTests
//
//  The Swift half of the Swift↔Node payload interop gate. Two jobs:
//
//   1. EMIT the fixture `scripts/interop-payload-gate.mjs` feeds to Node's
//      own FrameParser and `_preserveIncomingPayload` — real bytes, not a
//      description of them.
//   2. CONSUME a frame shaped exactly as the llm-sidecar writes one and
//      assert the payload survives.
//
//  Set SYM_INTEROP_FIXTURE_DIR to write the emission; without it the
//  emitting test still runs its own assertions and skips the write, so the
//  suite stays green in environments with no Node checkout.
//

import Foundation
import SYMCore
import XCTest
@testable import SYM

final class InteropPayloadTests: XCTestCase {

    private var fixtureDir: URL? {
        ProcessInfo.processInfo.environment["SYM_INTEROP_FIXTURE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    // MARK: - 1. Emit for Node

    func testEmitSwiftPayloadFramesForNode() throws {
        let node = SymNode(name: "interop-emitter")

        // Plaintext: the Node-facing shape, payload inside the cmb object.
        let plaintext = node.testHook_makePayloadCMBFrame(
            payload: try JSONSerialization.data(withJSONObject: [
                "request_id": "swift-to-node-1",
                "kind": "llm-request",
                "prompt": "how did my human move today",
            ]),
            categories: [
                .focus: CMBEncoder.encodeCategory("llm request"),
                .intent: CMBEncoder.encodeCategory("answer the prompt"),
            ],
            for: "peer-node")

        // E2E-shaped: Swift clears `cmb`, so the payload rides top level.
        // Emitted so the KNOWN divergence is asserted on the Node side
        // rather than discovered later as a silent drop.
        var encrypted = SymFrame(type: .cmb)
        encrypted.key = "cmb-swift-e2e"
        encrypted.source = "interop-emitter"
        encrypted.encryptedCategories = "Y2lwaGVydGV4dA=="
        encrypted.e2e = E2EMetadata(nonce: "bm9uY2U=")
        encrypted.cmbPayload = try JSONSerialization.data(withJSONObject: [
            "request_id": "swift-to-node-e2e",
            "kind": "llm-request",
        ])

        var bytes = Data()
        bytes.append(try plaintext.serialize())
        bytes.append(try encrypted.serialize())

        // Assert the emission is what we claim before handing it to Node —
        // a bad fixture would otherwise read as a Node-side defect.
        let parsed = SymFrameParser().feed(bytes)
        XCTAssertEqual(parsed.count, 2, "both frames must survive our own parser first")
        XCTAssertNotNil(parsed.first?.cmbPayload)
        XCTAssertNotNil(parsed.last?.cmbPayload)

        guard let dir = fixtureDir else {
            // No Node checkout wired in — the assertions above still hold.
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: dir.appendingPathComponent("swift-payload-frames.bin"))
    }

    // MARK: - 2. Consume from Node

    /// Bytes produced by Node's OWN `createCMB` + the sidecar's payload
    /// convention, checked in as a fixture rather than hand-written here.
    ///
    /// The first attempt at this test invented the shape — a flat CMB with
    /// text/valence/arousal categories — and it did not decode at all.
    /// Node's `createCMB` mints a **v2 two-section record** (`categories` +
    /// `metadata`), so the invented literal was testing a shape no Node peer
    /// has sent for some time. Regenerate with
    /// `scripts/interop-payload-gate.mjs --emit-node-fixture`.
    private func nodeAuthoredFrame() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SYMTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Tests/Fixtures/node-payload-frame.bin")
        return try Data(contentsOf: url)
    }

    func testSwiftLiftsThePayloadFromANodeAuthoredFrame() throws {
        let parsed = SymFrameParser().feed(try nodeAuthoredFrame())

        XCTAssertEqual(parsed.count, 1, "a node-authored cmb frame must decode")
        let payload = try XCTUnwrap(parsed.first?.cmbPayload,
                                    "Swift must read the sidecar's msg.cmb.payload")
        let object = (try JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        XCTAssertEqual(object?["request_id"] as? String, "node-to-swift-1",
                       "snake_case request_id, byte-matched to the Node convention")
        XCTAssertEqual(object?["prompt"] as? String, "how did my human move today")
    }

    func testNodeAuthoredPayloadReachesTheApplicationThroughTheReceivePath() throws {
        // Not just the parser: the whole receive path, ending at the event
        // an app subscribes to. A payload that parses but never surfaces is
        // the same product defect as one that never arrived.
        let frame = try XCTUnwrap(SymFrameParser().feed(try nodeAuthoredFrame()).first)
        let node = SymNode(name: "interop-receiver-\(UUID().uuidString.prefix(8))")

        var envelopes: [SymEnvelope] = []
        let lock = NSLock()
        node.on { event in
            if case .requestReceived(let envelope) = event {
                lock.lock(); envelopes.append(envelope); lock.unlock()
            }
        }

        // Unsigned, from a peer whose key we do not know → unverified, not
        // rejected (the §8.3 stance), so it reaches the payload router.
        node.handlePeerFrame(nodeId: "node-peer", peerName: "sym-llm-sidecar", frame: frame)

        let settle = expectation(description: "events settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(envelopes.count, 1,
                       "a Node-authored request must surface to the app as requestReceived")
        XCTAssertEqual(envelopes.first?.requestId, "node-to-swift-1")
    }
}

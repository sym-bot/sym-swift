//
//  PayloadReceiveWiringTests.swift
//  SYMTests
//
//  Same lesson as V2VerifyWiringTests: proving the router and proving the
//  NODE'S USE of the router are different things. CorrelationTests drives
//  `handleIncomingPayload` directly, so it would stay green even if the
//  receive path never called it — the payload would reach the wire, arrive,
//  and vanish, which is exactly the "arrives but is never admitted" split.
//
//  These tests push real frames through `handlePeerFrame` and assert the
//  payload comes out the other end.
//

import Foundation
import SYMCore
import XCTest
@testable import SYM

final class PayloadReceiveWiringTests: XCTestCase {

    private func payload(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// Build a signed, payload-bearing frame as a PEER would send it, and
    /// return it with the key the receiver must be told to trust.
    private func peerFrame(payload: Data, focus: String = "peer asks")
        -> (frame: SymFrame, publicKey: String?, author: String) {
        let author = SymNode(name: "payload-peer-\(UUID().uuidString.prefix(8))")
        let frame = author.testHook_makePayloadCMBFrame(
            payload: payload,
            categories: [.focus: CMBEncoder.encodeCategory(focus)],
            for: "receiver")
        return (frame, author.signingPublicKey, author.name)
    }

    /// Drive a frame through the real receive path, announcing the author's
    /// signing key first so §8.3 verification passes.
    private func drive(_ frame: SymFrame, publicKey: String?,
                       onNode node: SymNode) -> [SymEnvelope] {
        var envelopes: [SymEnvelope] = []
        let lock = NSLock()
        node.on { event in
            if case .requestReceived(let envelope) = event {
                lock.lock(); envelopes.append(envelope); lock.unlock()
            }
        }

        var handshake = SymFrame(type: .handshake)
        handshake.nodeId = "peer-1"
        handshake.name = "peer"
        handshake.publicKey = publicKey
        node.handlePeerFrame(nodeId: "peer-1", peerName: "peer", frame: handshake)

        node.handlePeerFrame(nodeId: "peer-1", peerName: "peer", frame: frame)

        let settle = expectation(description: "events settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)

        lock.lock(); defer { lock.unlock() }
        return envelopes
    }

    // MARK: - The wiring itself

    func testPayloadBearingFrameReachesTheRequestReceivedEvent() throws {
        let built = peerFrame(payload: payload(["request_id": "r-wire", "ask": "how did my human move today"]))
        let node = SymNode(name: "payload-recv-\(UUID().uuidString.prefix(8))")

        let envelopes = drive(built.frame, publicKey: built.publicKey, onNode: node)

        XCTAssertEqual(envelopes.count, 1,
                       "the receive path must route the payload — not just carry it")
        XCTAssertEqual(envelopes.first?.requestId, "r-wire")
        XCTAssertEqual(envelopes.first?.from, "peer-1",
                       "addressed to the transport peer, so respond(to:) can reply")
        let object = (try JSONSerialization.jsonObject(with: try XCTUnwrap(envelopes.first?.payload))) as? [String: Any]
        XCTAssertEqual(object?["ask"] as? String, "how did my human move today")
    }

    func testPayloadArrivingOverTheWireResolvesAPendingRequest() async throws {
        // The full loop on the requester's side: a request is in flight, the
        // response arrives as a real frame through handlePeerFrame, and the
        // await resolves. Nothing here reaches into the registry directly.
        let node = SymNode(name: "payload-loop-\(UUID().uuidString.prefix(8))")
        node.start()
        defer { node.stop() }

        let box = CorrelationTests.RequestIDBox()
        let exchange = SymExchange(registry: node.correlationRegistry) { wirePayload, _, _, _ in
            if let obj = (try? JSONSerialization.jsonObject(with: wirePayload)) as? [String: Any],
               let rid = obj["request_id"] as? String { box.set(rid) }
            return .sent
        }

        Task {
            while box.get() == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            let built = self.peerFrame(payload: self.payload(["request_id": box.get()!, "answer": "42"]))
            var handshake = SymFrame(type: .handshake)
            handshake.nodeId = "peer-1"
            handshake.name = "peer"
            handshake.publicKey = built.publicKey
            node.handlePeerFrame(nodeId: "peer-1", peerName: "peer", frame: handshake)
            node.handlePeerFrame(nodeId: "peer-1", peerName: "peer", frame: built.frame)
        }

        let envelope = try await exchange.request(
            payload: payload(["prompt": "q"]), categories: [:], to: "peer-1", timeout: 5)

        let object = (try JSONSerialization.jsonObject(with: envelope.payload)) as? [String: Any]
        XCTAssertEqual(object?["answer"] as? String, "42",
                       "a response arriving as a real frame resolves the await")
    }

    // MARK: - Survival across both SVAF verdicts

    func testPayloadSurvivesWhenTheCarryingCMBIsAlsoAdmitted() throws {
        // Verdict one: nothing about admission may consume the payload.
        let built = peerFrame(payload: payload(["request_id": "r-admitted"]), focus: "a novel observation")
        let node = SymNode(name: "payload-admit-\(UUID().uuidString.prefix(8))")

        var accepted = 0
        let lock = NSLock()
        node.on { event in
            if case .cmbAccepted = event { lock.lock(); accepted += 1; lock.unlock() }
        }

        let envelopes = drive(built.frame, publicKey: built.publicKey, onNode: node)
        XCTAssertEqual(envelopes.count, 1, "payload delivered on the admitted path")
        lock.lock(); let admitted = accepted; lock.unlock()
        XCTAssertGreaterThan(admitted, 0,
                             "the carrying CMB really did go through admission — otherwise this "
                             + "test proves nothing about the admitted path and is misnamed")
    }

    func testPayloadSurvivesWhenTheCarryingCMBIsAnEcho() throws {
        // Verdict two: the echo guard `break`s out of the cmb case before
        // SVAF ever runs. Routing the payload upstream of that break is what
        // keeps this from being a payload-dropping path — the exact class
        // that bit the Node implementation, where one verdict rebuilt the
        // block from CAT7 and lost the sibling.
        let built = peerFrame(payload: payload(["request_id": "r-echo"]))
        let node = SymNode(name: "payload-echo-\(UUID().uuidString.prefix(8))")

        // Make the incoming CMB look like a derivative of our own broadcast
        // by giving it a lineage parent, then storing that parent locally.
        var frame = built.frame
        let parentKey = "cmb-localparent"
        if let original = frame.cmb {
            frame.cmb = CognitiveMemoryBlock(
                key: original.key,
                categories: original.categories,
                source: original.source,
                createdBy: original.createdBy,
                lineage: CMBLineage(parents: [parentKey], ancestors: [], method: "SVAF-v2"),
                originTimestamp: original.originTimestamp,
                storedAt: original.storedAt,
                confidence: 0.8)
        }

        // An unsigned CMB is "unverified, not rejected", so the frame still
        // reaches the echo guard — which is the path under test here.
        let envelopes = drive(frame, publicKey: nil, onNode: node)
        XCTAssertEqual(envelopes.count, 1,
                       "the payload is routed before the verdict splits — every outcome keeps it")
    }

    // MARK: - Forged CMBs deliver nothing

    func testPayloadOnAForgedCMBIsNotDelivered() throws {
        // Upstream of the verdict, but DOWNSTREAM of signature verification:
        // a tampered CMB is dropped outright and its payload with it, or a
        // forger could drive a responder by wearing someone else's name.
        let built = peerFrame(payload: payload(["request_id": "r-forged"]))
        var frame = built.frame

        // Tamper: keep the signature, change the content it signed.
        if let original = frame.cmb {
            var categories = original.categories
            categories[.focus] = CMBEncoder.encodeCategory("tampered after signing")
            var tampered = CognitiveMemoryBlock(
                key: original.key,
                categories: categories,
                source: original.source,
                createdBy: original.createdBy,
                originTimestamp: original.originTimestamp,
                storedAt: original.storedAt,
                confidence: 0.8)
            tampered.sig = original.sig
            tampered.sigAlg = original.sigAlg
            frame.cmb = tampered
        }

        let node = SymNode(name: "payload-forged-\(UUID().uuidString.prefix(8))")
        let envelopes = drive(frame, publicKey: built.publicKey, onNode: node)

        XCTAssertEqual(envelopes.count, 0,
                       "a CMB that fails verification delivers no payload")
    }
}

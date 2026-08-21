import Foundation
import CryptoKit
import SYMCore
import XCTest
@testable import SYM

// MARK: - Is the seal actually WIRED?
//
// PayloadSealTests proves the crypto. That is not the same as proving the send path uses
// it — the primitive shipped in 0.5.1 and sat unused, and every test stayed green because
// no test asserted a frame on the wire was sealed.
//
// These assert the property a user cares about: given a peer we can key, a spoken thought
// does not appear in the bytes that leave. And given a peer we cannot key, the frame is
// still plaintext, which is the truth Node peers depend on and callers must be able to
// discover BEFORE they send.

final class PayloadSealWiringTests: XCTestCase {

    typealias RequestIDBox = CorrelationTests.RequestIDBox

    private let secret = "how did my human move today"

    private func payload() -> Data {
        try! JSONSerialization.data(withJSONObject: ["request_id": "r-1", "prompt": secret])
    }

    /// Wire bytes of the frame, as a peer would receive them.
    private func wireJSON(_ frame: SymFrame) throws -> String {
        let d = try frame.serialize()
        return String(data: d.subdata(in: 4..<d.count), encoding: .utf8) ?? ""
    }

    // MARK: - Sealed when we can key the peer

    func testPayloadIsSEALEDForAPeerWeCanKey() throws {
        let node = SymNode(name: "seal-wire-\(UUID().uuidString.prefix(8))")
        let peer = Curve25519.KeyAgreement.PrivateKey()
        node.testHook_setPeerE2EPublicKey(peer.publicKey.rawRepresentation, for: "peer-1")

        let frame = node.testHook_makePayloadCMBFrame(
            payload: payload(),
            categories: [.focus: CMBEncoder.encodeCategory("ask")],
            for: "peer-1")

        let json = try wireJSON(frame)
        XCTAssertFalse(json.contains(secret),
                       "the spoken thought must NOT appear in the bytes that leave")
        XCTAssertFalse(json.contains("r-1"), "nor the request id")
        XCTAssertTrue(json.contains("payload-seal-v1"),
                      "and the frame must name the scheme so a receiver can tell")
    }

    func testSealedPayloadRoundTripsBackToPlaintextAtTheFarEnd() throws {
        // Both ends derive the same key, so what was sealed opens — otherwise the seal
        // would be indistinguishable from data loss.
        let node = SymNode(name: "seal-rt-\(UUID().uuidString.prefix(8))")
        let peer = Curve25519.KeyAgreement.PrivateKey()
        node.testHook_setPeerE2EPublicKey(peer.publicKey.rawRepresentation, for: "peer-1")

        let frame = node.testHook_makePayloadCMBFrame(
            payload: payload(),
            categories: [.focus: CMBEncoder.encodeCategory("ask")],
            for: "peer-1")

        let sealedData = try XCTUnwrap(frame.cmbPayload)
        let sealed = try XCTUnwrap((try JSONSerialization.jsonObject(with: sealedData)) as? [String: Any])
        XCTAssertTrue(PayloadSeal.isSealed(sealed))

        let key = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: peer,
            peerPublicKey: Data(base64Encoded: try XCTUnwrap(node.e2ePublicKeyBase64))!,
            myNodeId: "peer-1", peerNodeId: node.nodeId))
        let opened = try XCTUnwrap(PayloadSeal.open(
            sealed, key: key,
            aad: PayloadSeal.aad(cmbKey: try XCTUnwrap(frame.cmb?.key), recipientNodeId: "peer-1")))

        let obj = (try JSONSerialization.jsonObject(with: opened)) as? [String: Any]
        XCTAssertEqual(obj?["prompt"] as? String, secret, "the far end recovers exactly what was sent")
    }

    // MARK: - Plaintext when we cannot, and the caller can find out

    func testPayloadIsPLAINTEXTForAPeerWeCannotKey() throws {
        // Every Node peer today. The sidecar reads msg.cmb.payload as a plain sibling, so
        // sealing to it would be silent data loss rather than privacy.
        let node = SymNode(name: "seal-plain-\(UUID().uuidString.prefix(8))")
        let frame = node.testHook_makePayloadCMBFrame(
            payload: payload(),
            categories: [.focus: CMBEncoder.encodeCategory("ask")],
            for: "unknown-peer")

        let json = try wireJSON(frame)
        XCTAssertTrue(json.contains(secret),
                      "unsealed is the honest behaviour here — and this test exists so it is never a surprise")
        XCTAssertFalse(json.contains("payload-seal-v1"))
    }

    func testACallerCanASKWhetherASendWouldBeSealed() {
        // Sealing is invisible either way on the wire, so a caller carrying private
        // content must be able to decide BEFORE sending rather than discover afterwards.
        let node = SymNode(name: "seal-state-\(UUID().uuidString.prefix(8))")
        XCTAssertFalse(node.payloadSealState(for: "unknown-peer"),
                       "no key advertised → false, and false is the truth for every Node peer today")

        let peer = Curve25519.KeyAgreement.PrivateKey()
        node.testHook_setPeerE2EPublicKey(peer.publicKey.rawRepresentation, for: "peer-1")
        XCTAssertTrue(node.payloadSealState(for: "peer-1"))
    }

    // MARK: - A seal we cannot open is not an empty payload

    func testAnUnopenableSealIsDROPPED_neverDeliveredAsEmpty() async {
        // The dangerous failure: routing an unopened seal onward would hand an awaiting
        // caller silence that looks like a slow peer.
        let node = SymNode(name: "seal-badopen-\(UUID().uuidString.prefix(8))")
        node.start()
        defer { node.stop() }

        var fired = false
        var metric = false
        node.on { event in
            if case .requestReceived = event { fired = true }
            if case .metric(let type, _) = event, type == "payload-seal-open-failed" { metric = true }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // A well-formed seal from a peer whose key we do not hold.
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let key = PayloadSeal.payloadKey(myPrivateKey: stranger,
                                         peerPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                         myNodeId: "a", peerNodeId: "b")!
        let sealed = PayloadSeal.seal(payload(), key: key,
                                      aad: PayloadSeal.aad(cmbKey: "cmb-x", recipientNodeId: "b"))!
        let sealedData = try! JSONSerialization.data(withJSONObject: sealed)

        node.testHook_handleIncomingPayload(sealedData, from: "peer-x", peerName: "stranger", cmbKey: "cmb-x")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(fired, "an unopenable seal must NOT surface as a request")
        XCTAssertTrue(metric, "and it must be visible as arrived-but-unopenable, not as silence")
    }
}

// MARK: - requireSeal: an unsealed send becomes impossible, not merely detectable

extension PayloadSealWiringTests {

    func testRequireSealREFUSESTOSENDWhenThePeerCannotBeKeyed() async {
        // The claim an app wants to make is "only the two of you can read this". Reading a
        // would-this-be-sealed flag and then sending is an inference about the next
        // moment; requiring the seal makes the unsealed send impossible, which is what
        // lets the app say it rather than believe it.
        let node = SymNode(name: "seal-req-\(UUID().uuidString.prefix(8))")
        node.start()
        defer { node.stop() }

        var dispatched = false
        let exchange = SymExchange(registry: node.correlationRegistry) { _, _, peerId, requireSeal in
            if requireSeal, !node.payloadSealState(for: peerId) { return .cannotSeal }
            dispatched = true
            return .sent
        }

        do {
            _ = try await exchange.request(payload: payload(), categories: [:],
                                           to: "unkeyable-peer", timeout: 5, requireSeal: true)
            XCTFail("expected cannotSeal")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .cannotSeal)
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertFalse(dispatched, "NOTHING may go out — not even plaintext, not even once")
    }

    func testWithoutRequireSealTheSamePeerStillGetsAPlaintextSend() async {
        // The default stays permissive on purpose: the sidecar reads the payload as
        // plaintext by design, so requiring a seal there would refuse every LLM call.
        let node = SymNode(name: "seal-noreq-\(UUID().uuidString.prefix(8))")
        node.start()
        defer { node.stop() }

        let box = RequestIDBox()
        let exchange = SymExchange(registry: node.correlationRegistry) { wire, _, peerId, requireSeal in
            if requireSeal, !node.payloadSealState(for: peerId) { return .cannotSeal }
            if let o = (try? JSONSerialization.jsonObject(with: wire)) as? [String: Any],
               let rid = o["request_id"] as? String { box.set(rid) }
            return .sent
        }

        do {
            _ = try await exchange.request(payload: payload(), categories: [:],
                                           to: "unkeyable-peer", timeout: 0.3)
            XCTFail("expected a timeout, not a refusal")
        } catch let error as SymRequestError {
            XCTAssertEqual(error, .timeout(after: 0.3),
                           "it SENT and then timed out — the refusal is opt-in, not the default")
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertNotNil(box.get(), "the send happened")
    }
}

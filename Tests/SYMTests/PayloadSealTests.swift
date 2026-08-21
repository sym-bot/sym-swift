import XCTest
import CryptoKit
@testable import SYM

// MARK: - payload-seal-v1
//
// The payload crossed the relay readable while the categories beside it were encrypted.
// These pin the properties that make the seal worth having, not just that it round-trips:
// that a wrong key fails, that a seal cannot be moved to another frame, and that the
// payload key is not the category key.

final class PayloadSealTests: XCTestCase {

    private func pair() -> (a: Curve25519.KeyAgreement.PrivateKey, b: Curve25519.KeyAgreement.PrivateKey) {
        (Curve25519.KeyAgreement.PrivateKey(), Curve25519.KeyAgreement.PrivateKey())
    }

    private func payload(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o)
    }

    // MARK: - Both ends derive the same key, from opposite sides

    func testBothEndsDeriveTheSameKeyRegardlessOfWhoAsks() throws {
        let (a, b) = pair()
        let keyFromA = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            myNodeId: "node-alpha", peerNodeId: "node-beta"))
        let keyFromB = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: b, peerPublicKey: a.publicKey.rawRepresentation,
            myNodeId: "node-beta", peerNodeId: "node-alpha"))

        // Node ids are sorted into `info`, so the two ends agree without exchanging
        // anything about ordering. Compare by using one to open what the other sealed.
        let aad = PayloadSeal.aad(cmbKey: "cmb-1", recipientNodeId: "node-beta")
        let sealed = try XCTUnwrap(PayloadSeal.seal(payload(["prompt": "hello"]), key: keyFromA, aad: aad))
        let opened = try XCTUnwrap(PayloadSeal.open(sealed, key: keyFromB, aad: aad),
                                   "the far end must derive an identical key")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: opened) as? [String: Any])?["prompt"] as? String,
                       "hello")
    }

    func testPayloadKeyIsNOTTheCategoryKey() throws {
        // Same X25519 agreement, different HKDF info. If these ever collide, a payload
        // key doubles as a category key and one compromise reaches both.
        let (a, b) = pair()
        let payloadK = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            myNodeId: "n1", peerNodeId: "n2"))
        let categoryK = try XCTUnwrap(E2ECrypto.deriveSharedSecret(
            myPrivateKey: a, peerPublicKey: b.publicKey.rawRepresentation))

        let aad = PayloadSeal.aad(cmbKey: "cmb-1", recipientNodeId: "n2")
        let sealed = try XCTUnwrap(PayloadSeal.seal(payload(["x": 1]), key: payloadK, aad: aad))
        XCTAssertNil(PayloadSeal.open(sealed, key: categoryK, aad: aad),
                     "the category key must NOT open a payload seal")
    }

    func testADifferentPeerCannotDeriveTheKey() throws {
        let (a, b) = pair()
        let (eve, _) = pair()
        let good = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            myNodeId: "n1", peerNodeId: "n2"))
        let evesKey = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: eve, peerPublicKey: b.publicKey.rawRepresentation,
            myNodeId: "eve", peerNodeId: "n2"))

        let aad = PayloadSeal.aad(cmbKey: "cmb-1", recipientNodeId: "n2")
        let sealed = try XCTUnwrap(PayloadSeal.seal(payload(["secret": "spoken thought"]), key: good, aad: aad))
        XCTAssertNil(PayloadSeal.open(sealed, key: evesKey, aad: aad))
    }

    // MARK: - The seal is bound to its frame

    func testASealCannotBeMovedToAnotherFrame() throws {
        // The relay forwards payloads verbatim, so without AAD binding it could lift a
        // seal off one CMB and staple it onto another it also carries.
        let (a, b) = pair()
        let key = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            myNodeId: "n1", peerNodeId: "n2"))

        let sealed = try XCTUnwrap(PayloadSeal.seal(
            payload(["prompt": "q"]),
            key: key,
            aad: PayloadSeal.aad(cmbKey: "cmb-ORIGINAL", recipientNodeId: "n2")))

        XCTAssertNil(PayloadSeal.open(sealed, key: key,
                                      aad: PayloadSeal.aad(cmbKey: "cmb-DIFFERENT", recipientNodeId: "n2")),
                     "a seal must not open against a different CMB key")
        XCTAssertNil(PayloadSeal.open(sealed, key: key,
                                      aad: PayloadSeal.aad(cmbKey: "cmb-ORIGINAL", recipientNodeId: "someone-else")),
                     "a seal must not open for a different recipient")
    }

    func testTamperedCiphertextFails() throws {
        let (a, b) = pair()
        let key = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            myNodeId: "n1", peerNodeId: "n2"))
        let aad = PayloadSeal.aad(cmbKey: "cmb-1", recipientNodeId: "n2")
        var sealed = try XCTUnwrap(PayloadSeal.seal(payload(["prompt": "q"]), key: key, aad: aad))

        var ct = Data(base64Encoded: sealed["ct"] as! String)!
        ct[0] ^= 0xFF
        sealed["ct"] = ct.base64EncodedString()

        XCTAssertNil(PayloadSeal.open(sealed, key: key, aad: aad),
                     "GCM must reject a flipped bit — nil means did-not-arrive, never arrived-empty")
    }

    // MARK: - Shape

    func testSealedObjectIsSelfDescribingAndCarriesNoPlaintext() throws {
        let (a, b) = pair()
        let key = try XCTUnwrap(PayloadSeal.payloadKey(
            myPrivateKey: a, peerPublicKey: b.publicKey.rawRepresentation,
            myNodeId: "n1", peerNodeId: "n2"))
        let secret = "how did my human move today"
        let sealed = try XCTUnwrap(PayloadSeal.seal(
            payload(["request_id": "r-1", "prompt": secret]),
            key: key, aad: PayloadSeal.aad(cmbKey: "cmb-1", recipientNodeId: "n2")))

        XCTAssertTrue(PayloadSeal.isSealed(sealed), "a receiver must tell sealed from plaintext")
        XCTAssertEqual(Set(sealed.keys), ["_seal", "n", "ct"], "no extra members leak")

        let asJSON = String(data: try JSONSerialization.data(withJSONObject: sealed), encoding: .utf8)!
        XCTAssertFalse(asJSON.contains(secret), "the spoken thought must not appear on the wire")
        XCTAssertFalse(asJSON.contains("r-1"), "not even the request id is left in the clear")
    }

    func testPlaintextPayloadIsNotMistakenForASeal() {
        XCTAssertFalse(PayloadSeal.isSealed(["request_id": "r-1", "prompt": "hi"]))
        XCTAssertFalse(PayloadSeal.isSealed(["_seal": "some-other-scheme", "n": "x", "ct": "y"]),
                       "only this scheme's marker counts")
    }
}

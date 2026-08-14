//
//  SignatureRejectionStanceTests.swift
//  SYMTests
//
//  The §8.3 rejection stance, pinned. It existed as two copies — the v2 path carved out
//  `no-public-key`, the flat path did not — and the drift rejected EVERY Swift↔Swift broadcast
//  between freshly-met nodes as "bad signature (no-public-key)": forgery in the logs,
//  key-distribution latency in reality. The stance is now one predicate; these tests hold it.
//

import XCTest
import SYMCore
@testable import SYM

final class SignatureRejectionStanceTests: XCTestCase {

    /// The verifier's contract for the freshly-met case: a signed CMB with no known author key
    /// is (signed, !valid, "no-public-key") — the input the stance must NOT reject.
    func testVerifierReportsNoPublicKeyForUnknownAuthor() {
        var cmb = CognitiveMemoryBlock(
            key: "cmb-test", categories: [:], source: "peer", createdBy: "peer",
            originTimestamp: 1, storedAt: 1, confidence: 0.8
        )
        cmb.sig = "c2ln" // present signature — the CMB is signed
        cmb.sigAlg = "ed25519"
        let v = CMBSigning.verify(cmb, publicKeyBase64URL: nil)
        XCTAssertTrue(v.signed)
        XCTAssertFalse(v.valid)
        XCTAssertEqual(v.error, "no-public-key")
    }

    /// The stance table. One axis is the defect: no-public-key admits as unverified.
    func testStance() {
        let node = SymNode(name: "stance-test")
        // present-but-invalid: forged or tampered → reject
        XCTAssertTrue(node.testHook_rejectsSignature(signed: true, valid: false, error: "bad-signature"))
        XCTAssertTrue(node.testHook_rejectsSignature(signed: true, valid: false, error: "content-mismatch"))
        XCTAssertTrue(node.testHook_rejectsSignature(signed: true, valid: false, error: "bad-public-key"))
        // signed but THIS NODE cannot verify yet → unverified, never rejected (the MeloTune defect)
        XCTAssertFalse(node.testHook_rejectsSignature(signed: true, valid: false, error: "no-public-key"))
        // unsigned → unverified, never rejected (pre-§8.3 compatibility)
        XCTAssertFalse(node.testHook_rejectsSignature(signed: false, valid: false, error: nil))
        // valid → obviously admitted
        XCTAssertFalse(node.testHook_rejectsSignature(signed: true, valid: true, error: nil))
    }
}

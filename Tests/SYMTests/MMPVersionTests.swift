//
//  MMPVersionTests.swift
//  SYMTests
//
//  The version surface is public so an app can assert what it speaks. These
//  tests are that assertion, kept here so the constant cannot drift silently
//  again — which is exactly how the handshake label reached 0.2.2 while the JS
//  reference sent 0.2.3 with nothing failing.
//

import XCTest
@testable import SYM

final class MMPVersionTests: XCTestCase {

    /// The founder's ruling: the product speaks MMP 2.0. This is the version that
    /// enters the signed §5.2 transcript and v2.0 records, so it is the one that
    /// is load-bearing rather than decorative.
    func testProtocolVersionIsTwoPointZero() {
        XCTAssertEqual(MMP.protocolVersion, "2.0")
    }

    /// The suite and address scheme must match the published contract exactly —
    /// a record declaring anything else is not an MMP v2.0 record.
    func testPublishedSuiteIdentifiers() {
        XCTAssertEqual(MMP.signatureSuite, "mmp-sig-v2.0")
        XCTAssertEqual(MMP.addressScheme, "mmp-cmb-merkle-v2")
    }

    /// The handshake carries the legacy label from the single constant, not a
    /// literal. This is what actually prevents the drift returning.
    func testHandshakeUsesTheSharedLegacyRevision() {
        let frame = SymFrame.handshake(nodeId: "n1", name: "test-node")
        XCTAssertEqual(frame.version, MMP.legacyHandshakeRevision)
        XCTAssertEqual(frame.version, "0.2.3", "aligned with the JS reference implementation")
    }
}

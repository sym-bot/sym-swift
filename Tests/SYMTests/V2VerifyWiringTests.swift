//
//  V2VerifyWiringTests.swift
//  SYMTests
//
//  The owed regression guard: the CTO replaced the node's
//  `CMBSigningV2.verify(...)` call with a constant `(signed:true,
//  valid:true, error:nil)` and the whole suite stayed green — the verifier
//  was proven (BoundaryRecordRescueTests), the NODE'S USE of it was not.
//  Same failure shape as testing the listener and not the event.
//
//  These tests drive frames through the actual receive path
//  (handlePeerFrame): a handshake announces the author's key, then a
//  tampered v2 record must be REJECTED with the audit metric, and an intact
//  one must be admitted. Mutate the verify call into a constant and the
//  tamper test fails — that is the whole point of its existence.
//

import Foundation
import SYMCore
import XCTest
@testable import SYM

final class V2VerifyWiringTests: XCTestCase {

    private let privB64 = "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI"
    private let pubB64 = "IVL40Zt5HSRFMkLhXy6rbLfP-ntqXtMAl5YOBpiB2xI"

    private func signedRecord(focus: String) throws -> CMBRecordV2 {
        let record = try CMBRecordV2.create(
            fields: ["focus": focus, "issue": "none", "intent": "wire",
                     "motivation": "guard", "commitment": "exact", "perspective": "test",
                     "mood": ["text": "calm"]],
            createdBy: "vector-author@conformance",
            now: 1_785_700_000_000)
        return try CMBSigningV2.sign(record, privateKeyB64url: privB64)
    }

    /// Drive: handshake (announces the signing key) → cmb frame with the v2
    /// record. Returns the metrics + accepted keys the node emitted.
    private func drive(_ record: CMBRecordV2,
                       announceKey: Bool = true) -> (rejectedReasons: [String], acceptedKeys: [String]) {
        let node = SymNode(name: "wiring-test-\(UUID().uuidString.prefix(8))")
        var rejected: [String] = []
        var accepted: [String] = []
        let lock = NSLock()
        node.on { event in
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .metric(let type, let detail) where type == "cmb-signature-rejected":
                rejected.append(detail["reason"] ?? "?")
            case .cmbAccepted(let entry, _, _):
                accepted.append(entry.cmb?.key ?? entry.key)
            default: break
            }
        }

        if announceKey {
            var handshake = SymFrame(type: .handshake)
            handshake.nodeId = "peer-1"
            handshake.name = "peer"
            handshake.publicKey = pubB64
            node.handlePeerFrame(nodeId: "peer-1", peerName: "peer", frame: handshake)
        }

        var frame = SymFrame(type: .cmb)
        frame.source = record.metadata.createdBy
        frame.cmbV2 = record
        node.handlePeerFrame(nodeId: "peer-1", peerName: "peer", frame: frame)

        // Event handlers register + fire through the node's queues.
        let settle = expectation(description: "events settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)

        lock.lock(); defer { lock.unlock() }
        return (rejected, accepted)
    }

    func testTamperedV2RecordIsRejectedByTheNodeItself() throws {
        var tampered = try signedRecord(focus: "original statement")
        tampered.fields["focus"]?.text = "tampered in flight"

        let outcome = drive(tampered)
        XCTAssertFalse(outcome.rejectedReasons.isEmpty,
                       "the NODE must reject a tampered v2 record — if this fails, verify() has been disconnected from the receive path")
        XCTAssertEqual(outcome.rejectedReasons.first, "content-mismatch")
        XCTAssertTrue(outcome.acceptedKeys.isEmpty, "a rejected record must never be admitted")
    }

    func testIntactSignedV2RecordIsAdmittedByTheNode() throws {
        let record = try signedRecord(focus: "original statement")
        let outcome = drive(record)
        XCTAssertTrue(outcome.rejectedReasons.isEmpty, "an intact signed record must not be rejected")
        XCTAssertFalse(outcome.acceptedKeys.isEmpty, "…and must be admitted to the store")
    }

    func testUnknownKeyAdmitsUnverifiedRatherThanRejecting() throws {
        // No handshake → no announced key → "no-public-key" is a trust state,
        // not a forgery: unverified admission, mirroring the flat path.
        let record = try signedRecord(focus: "original statement")
        let outcome = drive(record, announceKey: false)
        XCTAssertTrue(outcome.rejectedReasons.isEmpty,
                      "no known key is unverifiable, not forged — never rejected")
        XCTAssertFalse(outcome.acceptedKeys.isEmpty)
    }
}

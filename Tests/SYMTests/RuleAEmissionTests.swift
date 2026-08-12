//
//  RuleAEmissionTests.swift
//  SYMTests
//
//  Rule A (§7.5) on the emit side: every v2 emission parents on its
//  author's own HEAD, the chain is signed (parents ride inside
//  signingPayloadV2 — rewriting it breaks the signature), re-asserting the
//  HEAD collapses to a citation, and the HEAD survives a restart. This is
//  what makes an iOS node ACCOUNTED-FOR in the Node control plane's gauges.
//

import Foundation
import SYMCore
import XCTest
@testable import SYM

final class RuleAEmissionTests: XCTestCase {

    private func freshNode() -> SymNode {
        SymNode(name: "rule-a-test-\(UUID().uuidString.prefix(8))")
    }

    private func categories(_ focus: String) -> [String: Any] {
        ["focus": focus, "issue": "none", "intent": "chain", "motivation": "rule-a",
         "commitment": "sequenced", "perspective": "test", "mood": ["text": "calm"]]
    }

    func testEmissionsFormAChainOnTheAuthorsOwnHead() throws {
        let node = freshNode()
        let first = try XCTUnwrap(node.rememberV2(categories: categories("first statement")))
        XCTAssertNil(first.record.metadata.lineage, "the first emission is a ROOT — no head yet")

        let second = try XCTUnwrap(node.rememberV2(categories: categories("second statement")))
        XCTAssertEqual(second.record.metadata.lineage?.parents, [first.key],
                       "the second emission parents on the first — one continuous line")

        let third = try XCTUnwrap(node.rememberV2(categories: categories("third statement")))
        XCTAssertEqual(third.record.metadata.lineage?.parents, [second.key],
                       "…and the third on the second, never a scatter of unrooted blocks")
    }

    func testReassertingOwnHeadCollapsesToACitation() throws {
        let node = freshNode()
        _ = node.rememberV2(categories: categories("first statement"))
        let minted = try XCTUnwrap(node.rememberV2(categories: categories("second statement")))

        // Same content again: same address as HEAD → cited, not minted.
        let again = try XCTUnwrap(node.rememberV2(categories: categories("second statement")))
        XCTAssertTrue(again.collapsed)
        XCTAssertEqual(again.key, minted.key)
        XCTAssertNil(again.record.metadata.lineage,
                     "a collapsed record must not leave claiming descent from itself (K→K)")

        // HEAD did not move: the next novel emission parents on the ORIGINAL.
        let next = try XCTUnwrap(node.rememberV2(categories: categories("third statement")))
        XCTAssertEqual(next.record.metadata.lineage?.parents, [minted.key],
                       "a collapse never advances HEAD — nothing was minted")
    }

    func testTheChainIsSignedAndUnforgeable() throws {
        let node = freshNode()
        _ = node.rememberV2(categories: categories("first statement"))
        let second = try XCTUnwrap(node.rememberV2(categories: categories("second statement")))

        let pubKey = node.signingPublicKey
        let verdict = CMBSigningV2.verify(second.record, publicKeyB64url: pubKey)
        XCTAssertTrue(verdict.valid, "an emission verifies under its author's announced key: \(verdict.error ?? "")")

        // Rewriting the chain breaks the signature — parents are INSIDE the
        // signed payload. This is what makes position-in-chain the ordering.
        var rewritten = second.record
        rewritten.metadata.lineage = CMBLineageV2(parents: ["cmb-" + String(repeating: "66", count: 32)])
        let forged = CMBSigningV2.verify(rewritten, publicKeyB64url: pubKey)
        XCTAssertFalse(forged.valid, "a rewritten chain must not verify")
    }

    func testHeadSurvivesARestart() throws {
        let name = "rule-a-restart-\(UUID().uuidString.prefix(8))"
        let first = SymNode(name: name)
        let last = try XCTUnwrap(first.rememberV2(categories: categories("before the restart")))

        // Same identity, new process-lifetime: the chain continues, it does
        // not restart as a scatter of new roots.
        let second = SymNode(name: name)
        let resumed = try XCTUnwrap(second.rememberV2(categories: categories("after the restart")))
        XCTAssertEqual(resumed.record.metadata.lineage?.parents, [last.key],
                       "HEAD persists across restarts — the control plane sees one line, not a gap")
    }

    func testEmittedFrameRoundTripsTheWire() throws {
        let node = freshNode()
        let emission = try XCTUnwrap(node.rememberV2(categories: categories("over the wire")))

        var frame = SymFrame(type: .cmb)
        frame.source = node.name
        frame.cmbV2 = emission.record
        let wire = try frame.serialize()

        let parsed = SymFrameParser().feed(wire)
        XCTAssertEqual(parsed.count, 1, "a v2-carrying frame serializes and parses")
        let arrived = try XCTUnwrap(parsed.first?.cmbV2)
        XCTAssertEqual(arrived.metadata.key, emission.key)
        XCTAssertEqual(arrived.metadata.sig, emission.record.metadata.sig,
                       "the signature survives the wire byte-for-byte")
    }
}

//
//  SVAFRedundancyTests.swift
//  SYMTests
//
//  Tests for the SVAF fourth outcome — the semantic-redundancy
//  pre-filter that runs BEFORE SVAFFusion.evaluate in SymNode's
//  receive handler. Paper §4.5 describes four outcomes (redundant,
//  aligned, guarded, rejected); this file verifies that the fourth
//  is implemented correctly when the feature flag is enabled.
//
//  ## Why a pre-filter (not a fourth classifier case)
//
//  SVAFFusion.evaluate computes drift as `1 − cosSim(fused, incoming)`
//  where `fused = (incoming + Σ weight_i · anchor_i) / totalWeight`
//  and each anchor's weight is its cosine similarity with the incoming.
//  This formula collapses identical and orthogonal anchors to the same
//  drift value (≈ 0 in both cases), so redundancy cannot be detected
//  from the drift output. Instead, the pre-filter runs a similarity-
//  based check over incoming-vs-anchor field vectors BEFORE fusion.
//
//  ## What this file tests
//
//  The `isCMBRedundant(incoming:anchors:)` helper on `SymNode` is
//  intentionally `internal` so tests can exercise it in isolation
//  without spinning up a live peer session. The receive-handler
//  integration (the actual branch that drops redundant CMBs and
//  writes the absorbed entry) is wired into `SymNode`'s private
//  `case .cmb` flow and exercised indirectly via the live
//  MultiTransportTests suite.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import XCTest
import SYMCore
@testable import SYM

final class SVAFRedundancyTests: XCTestCase {

    // MARK: - Fixtures

    /// Deterministic l2-normalized vector of canonical field dimension.
    private func baseVector(seed: Float = 0.1) -> [Float] {
        let dim = CMBEncoder.fieldDim
        var v = [Float](repeating: seed, count: dim)
        for i in 0..<dim {
            v[i] = seed + Float(i % 7) * 0.01
        }
        return CMBEncoder.l2Normalize(v)
    }

    /// Small alternating-sign perturbation, then renormalize. Near-unit
    /// cosine similarity to base but not exactly 1.
    private func perturbed(_ base: [Float], magnitude: Float) -> [Float] {
        var v = base
        for i in 0..<v.count {
            v[i] += (i % 2 == 0 ? magnitude : -magnitude)
        }
        return CMBEncoder.l2Normalize(v)
    }

    /// Orthogonal vector via half-rotation with sign flip.
    private func orthogonal(_ base: [Float]) -> [Float] {
        let half = base.count / 2
        var v = base
        for i in 0..<half {
            v[i] = -base[i + half]
            v[i + half] = base[i]
        }
        return CMBEncoder.l2Normalize(v)
    }

    /// Build a CMB with the given vector in every CAT7 field.
    private func makeCMB(vector: [Float], source: String) -> CognitiveMemoryBlock {
        var fields: [CMBField: CMBFieldVector] = [:]
        for field in CMBField.allCases {
            let v: Float? = (field == .mood) ? 0.0 : nil
            let a: Float? = (field == .mood) ? 0.0 : nil
            fields[field] = CMBFieldVector(
                text: "test-\(field.rawValue)",
                vector: vector,
                valence: v,
                arousal: a
            )
        }
        return CMBEncoder.createCMB(
            fields: fields,
            source: source,
            originTimestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            confidence: 0.9,
            lineage: nil
        )
    }

    /// Build a CMB where `field` uses `mismatchVector` and all other
    /// fields use `baseVector`. Lets tests exercise the per-field ALL-
    /// or-nothing semantics of the redundancy check.
    private func makeCMB(
        baseVector: [Float],
        mismatchField: CMBField,
        mismatchVector: [Float],
        source: String
    ) -> CognitiveMemoryBlock {
        var fields: [CMBField: CMBFieldVector] = [:]
        for field in CMBField.allCases {
            let v: Float? = (field == .mood) ? 0.0 : nil
            let a: Float? = (field == .mood) ? 0.0 : nil
            let vector = (field == mismatchField) ? mismatchVector : baseVector
            fields[field] = CMBFieldVector(
                text: "test-\(field.rawValue)",
                vector: vector,
                valence: v,
                arousal: a
            )
        }
        return CMBEncoder.createCMB(
            fields: fields,
            source: source,
            originTimestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            confidence: 0.9,
            lineage: nil
        )
    }

    // MARK: - Feature flag gating (must be off by default)

    /// When the feature flag is OFF (default), the pre-filter must
    /// never classify anything as redundant. This protects every
    /// existing SDK consumer from a behaviour change on version bump.
    func testDisabledByDefault() {
        let node = SymNode(name: "test-off")
        defer { node.stop() }
        let base = baseVector()
        let anchor = makeCMB(vector: base, source: "anchor")
        let incoming = makeCMB(vector: base, source: "incoming")
        XCTAssertFalse(
            node.isCMBRedundant(incoming: incoming, anchors: [anchor]),
            "redundancy check must be OFF by default (backward compat invariant)"
        )
    }

    /// Explicit off is the same as default off.
    func testExplicitlyDisabled() {
        let node = SymNode(name: "test-explicit-off", svafRedundancyCheckEnabled: false)
        defer { node.stop() }
        let base = baseVector()
        let anchor = makeCMB(vector: base, source: "anchor")
        let incoming = makeCMB(vector: base, source: "incoming")
        XCTAssertFalse(node.isCMBRedundant(incoming: incoming, anchors: [anchor]))
    }

    // MARK: - Core redundancy detection (flag enabled)

    /// Identical vectors must be flagged redundant. This is the
    /// minimum-viable invariant of the fourth outcome.
    func testIdenticalCMBIsRedundant() {
        let node = SymNode(name: "test-identical", svafRedundancyCheckEnabled: true)
        defer { node.stop() }
        let base = baseVector()
        let anchor = makeCMB(vector: base, source: "anchor")
        let incoming = makeCMB(vector: base, source: "incoming")
        XCTAssertTrue(
            node.isCMBRedundant(incoming: incoming, anchors: [anchor]),
            "identical vectors must be classified as redundant"
        )
    }

    /// Orthogonal vectors must NOT be flagged redundant. This is the
    /// case that makes the pre-filter distinct from the drift-based
    /// classifier — under the fusion formula, orthogonal anchors
    /// collapse to drift ≈ 0, but they are NOT semantically redundant
    /// and must remain visible to the receiver.
    func testOrthogonalCMBIsNotRedundant() {
        let node = SymNode(name: "test-orth", svafRedundancyCheckEnabled: true)
        defer { node.stop() }
        let base = baseVector()
        let orth = orthogonal(base)
        let anchor = makeCMB(vector: base, source: "anchor")
        let incoming = makeCMB(vector: orth, source: "incoming")
        XCTAssertFalse(
            node.isCMBRedundant(incoming: incoming, anchors: [anchor]),
            "orthogonal content is NOVEL, not redundant — distinct from the fusion classifier's drift ≈ 0 behaviour"
        )
    }

    /// Small perturbation — cosSim ≈ 0.9996 — sits ABOVE the default
    /// 0.98 threshold (since `1 − 0.02 = 0.98`), so it must be
    /// flagged redundant.
    func testSmallPerturbationIsRedundantAtDefaultThreshold() {
        let node = SymNode(name: "test-pert", svafRedundancyCheckEnabled: true)
        defer { node.stop() }
        let base = baseVector()
        let small = perturbed(base, magnitude: 0.005)  // cosSim ≈ 0.9996
        let anchor = makeCMB(vector: base, source: "anchor")
        let incoming = makeCMB(vector: small, source: "incoming")
        XCTAssertTrue(
            node.isCMBRedundant(incoming: incoming, anchors: [anchor]),
            "small perturbation (cosSim ≈ 0.9996) must exceed default redundancy threshold (0.98)"
        )
    }

    /// With an extremely tight threshold (0.0001), even a small
    /// perturbation must escape the redundancy classification. This
    /// verifies the threshold parameter is actually load-bearing.
    func testTightThresholdRejectsSmallPerturbation() {
        let node = SymNode(
            name: "test-tight",
            svafRedundancyThreshold: 0.0001,  // require ≥ 99.99% similarity
            svafRedundancyCheckEnabled: true
        )
        defer { node.stop() }
        let base = baseVector()
        let small = perturbed(base, magnitude: 0.005)  // cosSim ≈ 0.9996, drift ≈ 0.0004
        let anchor = makeCMB(vector: base, source: "anchor")
        let incoming = makeCMB(vector: small, source: "incoming")
        XCTAssertFalse(
            node.isCMBRedundant(incoming: incoming, anchors: [anchor]),
            "threshold 0.0001 must reject a perturbation with drift 0.0004"
        )
    }

    // MARK: - Per-field all-or-nothing semantics

    /// A single novel field must save the CMB from the redundancy
    /// classification — the check is AND over all fields, not OR.
    /// This protects against losing a CMB that happens to share six
    /// out of seven fields with an existing anchor but carries a
    /// genuinely new signal in the seventh.
    func testSingleNovelFieldBlocksRedundancy() {
        let node = SymNode(name: "test-single-novel", svafRedundancyCheckEnabled: true)
        defer { node.stop() }
        let base = baseVector()
        let orth = orthogonal(base)
        let anchor = makeCMB(vector: base, source: "anchor")
        // All 7 fields use base EXCEPT `mood` which is orthogonal.
        let incoming = makeCMB(
            baseVector: base,
            mismatchField: .mood,
            mismatchVector: orth,
            source: "incoming-novel-mood"
        )
        XCTAssertFalse(
            node.isCMBRedundant(incoming: incoming, anchors: [anchor]),
            "a single novel field must prevent the CMB from being classified as redundant"
        )
    }

    // MARK: - Anchor set edge cases

    /// Empty anchor set means there's nothing to be redundant against.
    /// Must return false regardless of flag state.
    func testEmptyAnchorsReturnsFalse() {
        let node = SymNode(name: "test-empty", svafRedundancyCheckEnabled: true)
        defer { node.stop() }
        let base = baseVector()
        let incoming = makeCMB(vector: base, source: "incoming")
        XCTAssertFalse(
            node.isCMBRedundant(incoming: incoming, anchors: []),
            "no anchors → no reference for redundancy → must return false"
        )
    }

    /// Multiple anchors: if ANY single anchor covers the incoming
    /// on all fields, the CMB is redundant. Other unrelated anchors
    /// in the set must not block the classification.
    func testRedundancyAgainstAnyAnchorInSet() {
        let node = SymNode(name: "test-multi-anchor", svafRedundancyCheckEnabled: true)
        defer { node.stop() }
        let base = baseVector()
        let orth = orthogonal(base)
        let matchingAnchor = makeCMB(vector: base, source: "matching-anchor")
        let unrelatedAnchor = makeCMB(vector: orth, source: "unrelated-anchor")
        let incoming = makeCMB(vector: base, source: "incoming")
        XCTAssertTrue(
            node.isCMBRedundant(incoming: incoming, anchors: [unrelatedAnchor, matchingAnchor]),
            "redundancy against ANY anchor in the set must trigger the fourth outcome"
        )
    }
}

//
//  AdmitLocalStateTests.swift
//  SYMTests
//
//  Local state must move when a peer's block enters the store.
//
//  Every `updateLocalState` call site in SymNode.swift was reached from exactly three places —
//  `initLocalState()`, `reencodeAndBroadcast()` and `_afterRemember()`: init, broadcast, and the
//  node's OWN remember. Nothing on admit. So a node that had admitted five hundred peer CMBs
//  carried the same local state as one that had admitted none, even though `buildContext()` reads
//  the very store those blocks land in.
//
//  Found in the JS substrate first (@sym-bot/sym 0.12.1, where the neural gate moved state and the
//  production heuristic gate did not) and reported against this implementation by dev-team-3 on
//  2026-08-24, because MeloMove links it. Swift has no neural/heuristic split, so here it was never
//  an asymmetry — a plain omission on the only path.
//
//  WHY THIS IS STRUCTURAL. Same lesson as PayloadReceiveWiringTests, one turn further: there is a
//  single admit path, so a behavioural test on "the" path would have passed throughout — the code
//  did what it said, and what was missing was a line nobody had written. What can be asserted is
//  the contract: a peer block that reaches the store re-encodes state. dev-team-3 holds the
//  complement — a live MeloMove node, measured before and after admitting peer blocks. Structural
//  absence and observable stillness are different claims and only one of them is tested here.
//

import XCTest
@testable import SYM

final class AdmitLocalStateTests: XCTestCase {

    private func symNodeSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SYMTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/SYM/SymNode.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every store-from-peer re-encodes local state.
    func testEveryPeerStoreReencodesLocalState() throws {
        let lines = try symNodeSource().components(separatedBy: "\n")
        let stores = lines.enumerated().filter { $0.element.contains("store.receiveFromPeer(") }

        XCTAssertGreaterThanOrEqual(stores.count, 2,
            "both the redundant-absorb and the fused-admit paths store a peer block")

        for (index, _) in stores {
            let window = lines[index..<min(index + 4, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.contains("reencodeLocalStateAfterAdmit()"),
                "line \(index + 1) stores a peer block without re-encoding local state — that is the 0.5.3 omission")
        }
    }

    /// The admit hook DELEGATES rather than carrying its own copy of the encode.
    ///
    /// A stronger assertion was tried here first and was simply false: "context is encoded into
    /// state in exactly one place". There are three, and two are legitimate — `initLocalState()`
    /// has a cold-start branch that seeds small random state at confidence 0.3 when the store is
    /// nearly empty, and `_afterRemember()` re-encodes without the short-context guard. Forcing
    /// those into one function to satisfy an invariant invented by a test would be changing
    /// behaviour to fit an assertion. What the admit path must not do is grow a fourth copy.
    func testAdmitPathDoesNotCarryItsOwnEncode() throws {
        let source = try symNodeSource()
        guard let range = source.range(of: "private func reencodeLocalStateAfterAdmit() {") else {
            return XCTFail("the admit hook is gone — the omission it closes is not guarded")
        }
        let body = String(source[range.upperBound...].prefix(200))
        XCTAssertTrue(body.contains("reencodeLocalState()"),
            "the admit hook delegates to the shared re-encode")
        XCTAssertFalse(body.contains("ContextEncoder.encode("),
            "a private copy of the encode in the admit path is how two paths begin to drift")
    }
}

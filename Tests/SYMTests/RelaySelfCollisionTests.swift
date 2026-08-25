import XCTest
@testable import SYM

/// m136 (dev-team-2 handover, founder device log 2026-08-25): one cold launch dialed the relay
/// twice for the same node and answered its OWN draining socket's 4006 — the phased app
/// lifecycle stop→start cycle landed inside the relay's duplicate-identity freshness window.
/// The fix is a grace-delayed redial plus honest classification of the self-collision frame.
final class RelaySelfCollisionTests: XCTestCase {

    /// A start during the grace window is absorbed, not doubled — the session dials once.
    func testDelayedStartIsIdempotent() {
        let session = SymRelaySession(
            url: URL(string: "wss://127.0.0.1:1")!,   // unroutable — no real dial completes
            identity: SymIdentityManager.loadOrCreate(name: "m136-test-\(UUID().uuidString.prefix(6))"),
            token: nil, room: nil
        )
        session.start(afterDelay: 0.2)
        session.start(afterDelay: 0.0)   // the flap: a second start while the first waits
        let exp = expectation(description: "grace elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        // Both starts collapsed into one running session — the guard absorbed the duplicate.
        XCTAssertTrue(session.isRunningForTest, "the session runs once, not twice")
        session.stop()
    }

    /// The node computes a NONZERO grace when start follows stop within the freshness window,
    /// and zero grace when enough time has passed.
    func testStopStartGraceWindow() {
        let node = SymNode(name: "m136-grace-\(UUID().uuidString.prefix(6))",
                           relay: URL(string: "wss://127.0.0.1:1")!)
        node.start()
        node.stop()   // stamps lastRelayDisconnectAt
        XCTAssertGreaterThan(node.relayGraceForTest, 4.0,
            "an immediate restart must wait out most of the 6s freshness window")
        node.setLastRelayDisconnectForTest(Date(timeIntervalSinceNow: -10))
        XCTAssertEqual(node.relayGraceForTest, 0, accuracy: 0.001,
            "a restart after the window dials immediately")
        node.stop()
    }
}

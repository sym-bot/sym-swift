import XCTest
@testable import SYM

// MARK: - relayConnected truthfulness (0.5.0)
//
// Reported from a real rig: a node handed a relay URL whose token the
// deployed relay does not accept was telling status() callers
// relayConnected=true — the field was bound to the existence of a session
// OBJECT, not to the connection it names. An app cannot build a reach
// indicator on that, and one nearly was.

final class RelayConnectedTests: XCTestCase {

    private let unreachableRelay = URL(string: "wss://relay.invalid.example.com/mesh")!

    func testConfiguredButUnconnectedRelayReportsDisconnected() {
        // The defect exactly: a relay is configured (so a session object
        // exists) but no socket has authenticated. Before the fix this
        // asserted true.
        let node = SymNode(name: "test-relay-conn-\(UUID().uuidString)",
                           relay: unreachableRelay, relayOnly: true)
        node.start()
        defer { node.stop() }

        let status = node.status()
        XCTAssertEqual(status.relay, unreachableRelay.absoluteString,
                       "the relay is configured — that part was never in doubt")
        XCTAssertFalse(status.relayConnected,
                       "a session object is not a connection")
    }

    func testNoRelayConfiguredReportsDisconnected() {
        let node = SymNode(name: "test-relay-none-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        XCTAssertNil(node.status().relay)
        XCTAssertFalse(node.status().relayConnected)
        XCTAssertNil(node.status().relayClose, "never connected, never closed")
    }

    func testStoppedNodeReportsDisconnected() {
        let node = SymNode(name: "test-relay-stopped-\(UUID().uuidString)",
                           relay: unreachableRelay, relayOnly: true)
        node.start()
        node.stop()

        XCTAssertFalse(node.status().relayConnected,
                       "stop() tears the session down — nothing to report connected")
    }

    // MARK: - Close classification

    func testApplicationCloseCodesReadAsRefused() {
        // 4003 invalid token, 4006 duplicate identity: the relay declining
        // this node, which is worth telling a user about.
        for code in [4000, 4003, 4006, 4999] {
            let close = SymRelayClose(code: code, reason: "closed")
            XCTAssertTrue(close.wasRefused, "\(code) is the relay declining the node")
        }
    }

    func testTransportClosesDoNotReadAsRefused() {
        for code in [1000, 1001, 1006, 1011] {
            let close = SymRelayClose(code: code, reason: "dropped")
            XCTAssertFalse(close.wasRefused, "\(code) is a transport close, worth a quiet retry")
        }
        XCTAssertFalse(SymRelayClose(code: nil, reason: "no code").wasRefused,
                       "no code is not evidence of refusal")
    }

    func testRelayStatedRefusalReadsAsRefusedWithoutACloseCode() {
        // A refusal can arrive as the relay's own relay-error message before
        // (or instead of) a 4xxx socket close. Carrying only the close code
        // would lose it.
        let stated = SymRelayClose(code: nil, reason: "invalid token", statedByRelay: true)
        XCTAssertTrue(stated.wasRefused,
                      "the relay saying so is at least as good as a close code")
        XCTAssertEqual(stated.reason, "invalid token")
    }
}

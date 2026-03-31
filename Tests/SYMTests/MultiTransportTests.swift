import XCTest
@testable import SYM

// MARK: - Multi-Transport Tests
//
// PeerState is private, so we test multi-transport behavior through the
// public SymNode API: peerList(), status(), and event callbacks.
//
// Bonjour discovery requires network entitlements that may not be available
// in all test environments, so these tests focus on observable state without
// requiring actual peer connections.

final class MultiTransportTests: XCTestCase {

    // MARK: - Unstarted node has no peers (no transports active)

    func testUnstartedNodeHasNoPeers() {
        let node = SymNode(name: "test-mt-unstarted-\(UUID().uuidString)")
        XCTAssertEqual(node.peerList().count, 0,
                       "no transports active → empty peer list")
        XCTAssertEqual(node.status().peerCount, 0)
        XCTAssertFalse(node.status().running)
    }

    // MARK: - Started node with no reachable peers has empty list

    func testStartedNodeWithNoPeersHasEmptyList() {
        let node = SymNode(name: "test-mt-empty-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        // Node is running but no peers discovered yet
        XCTAssertTrue(node.status().running)
        XCTAssertEqual(node.peerList().count, 0,
                       "started node with no peers should have empty peer list")
        XCTAssertEqual(node.status().peerCount, 0)
    }

    // MARK: - Relay-only node skips Bonjour (nil session path)

    func testRelayOnlyNodeSkipsBonjour() {
        // A relay-only node never starts Bonjour discovery.
        // Without a relay server, it should have zero peers — exercising
        // the code path where PeerState would only have relay transports
        // with nil sessions.
        let node = SymNode(
            name: "test-mt-relay-only-\(UUID().uuidString)",
            relayOnly: true
        )
        node.start()
        defer { node.stop() }

        XCTAssertTrue(node.status().running)
        XCTAssertEqual(node.status().port, 0,
                       "relay-only node should report port 0")
        XCTAssertEqual(node.peerList().count, 0,
                       "relay-only node without relay server has no peers")
        XCTAssertNil(node.status().relay,
                     "no relay URL configured → nil")
    }

    // MARK: - Relay-only node reports relay URL when configured

    func testRelayOnlyNodeReportsRelayURL() {
        let relayURL = URL(string: "wss://test-relay.example.com")!
        let node = SymNode(
            name: "test-mt-relay-url-\(UUID().uuidString)",
            relay: relayURL,
            relayOnly: true
        )
        node.start()
        defer { node.stop() }

        let status = node.status()
        XCTAssertEqual(status.relay, relayURL.absoluteString,
                       "status should report the configured relay URL")
        XCTAssertEqual(status.port, 0,
                       "relay-only should have port 0")
    }

    // MARK: - Stop clears all peers

    func testStopClearsPeers() {
        let node = SymNode(name: "test-mt-stop-\(UUID().uuidString)")
        node.start()
        XCTAssertTrue(node.status().running)

        node.stop()
        XCTAssertFalse(node.status().running)
        XCTAssertEqual(node.peerList().count, 0,
                       "stop should clear all peers regardless of transport")
        XCTAssertEqual(node.status().peerCount, 0)
    }

    // MARK: - Multiple start/stop cycles don't leak peers

    func testStartStopCyclesNoLeakedPeers() {
        let node = SymNode(name: "test-mt-cycle-\(UUID().uuidString)")

        for _ in 0..<3 {
            node.start()
            XCTAssertTrue(node.status().running)
            XCTAssertEqual(node.peerList().count, 0)
            node.stop()
            XCTAssertFalse(node.status().running)
            XCTAssertEqual(node.peerList().count, 0)
        }
    }

    // MARK: - Status coherence is nil with no peers

    func testCoherenceNilWithNoPeers() {
        let node = SymNode(name: "test-mt-coherence-\(UUID().uuidString)")
        node.start()
        defer { node.stop() }

        XCTAssertNil(node.coherence,
                     "coherence should be nil when no peers are connected")
        XCTAssertNil(node.status().coherence)
    }
}

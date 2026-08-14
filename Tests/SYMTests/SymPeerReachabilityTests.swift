//
//  SymPeerReachabilityTests.swift
//  SYMTests
//
//  Reachability is a SET because MMP §4.6 says a peer may hold several
//  transports at once. These pin the shape, so a future "simplification"
//  to a single mode has to argue with the spec rather than with a hunch.
//

import XCTest
@testable import SYM

final class SymPeerReachabilityTests: XCTestCase {

    func testAPeerCanBeBothLocalAndRelayed() {
        let both: Set<SymPeerReachability> = [.localNetwork, .relay]
        XCTAssertEqual(both.count, 2,
                       "a peer on your Wi-Fi that is also relay-connected is genuinely both")
        XCTAssertTrue(both.contains(.localNetwork))
        XCTAssertTrue(both.contains(.relay))
    }

    func testReachabilityIsAdditiveNotExclusive() {
        var reach: Set<SymPeerReachability> = [.relay]
        reach.insert(.localNetwork)
        XCTAssertEqual(reach, [.relay, .localNetwork],
                       "gaining a transport must add to the set, never replace it")
    }

    func testEveryCaseHasAStableWireName() {
        // The raw values cross into app code and logs; renaming one is a
        // contract change, not a refactor.
        XCTAssertEqual(SymPeerReachability.localNetwork.rawValue, "localNetwork")
        XCTAssertEqual(SymPeerReachability.relay.rawValue, "relay")
        XCTAssertEqual(SymPeerReachability.allCases.count, 2,
                       "a new transport needs its own case AND a decision about what apps show")
    }
}

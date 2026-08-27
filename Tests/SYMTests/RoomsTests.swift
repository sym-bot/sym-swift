//
//  RoomsTests.swift
//  SYMTests
//
//  These are CONTRACT tests, not unit tests. The expected values are the
//  outputs of `lib/rooms.js` in the sym Node package, because the room name is
//  the DNS-SD service type and two implementations that compute it differently
//  never see each other. A failure here means Swift and JS consumers have
//  stopped agreeing about which room a name refers to.
//

import XCTest
@testable import SYM

final class RoomsTests: XCTestCase {

    // MARK: - The mapping, both directions

    func testRoomToServiceTypeMatchesTheNodeImplementation() {
        XCTAssertEqual(SymRooms.roomServiceType("default"), "_sym._tcp")
        XCTAssertEqual(SymRooms.roomServiceType(""), "_sym._tcp")
        XCTAssertEqual(SymRooms.roomServiceType("backend-team"), "_backend-team._tcp")
        XCTAssertEqual(SymRooms.roomServiceType("x-review--team-02779b950c3d8d7378fd11d6"),
                       "_x-review--team-02779b950c3d8d7378fd11d6._tcp")
    }

    func testServiceTypeToRoomIsTheInverse() {
        XCTAssertEqual(SymRooms.serviceTypeToRoom("_sym._tcp"), "default")
        XCTAssertEqual(SymRooms.serviceTypeToRoom(""), "default")
        XCTAssertEqual(SymRooms.serviceTypeToRoom("_backend-team._tcp"), "backend-team")
    }

    /// Canonicity as the property rather than a list of cases: every name the
    /// SDK accepts must come back unchanged through its own service type.
    func testEveryAcceptedNameRoundTrips() {
        for name in ["default", "a", "backend-team", "melo-ios",
                     "x-review--team-02779b950c3d8d7378fd11d6", "sym-bot-room"] {
            XCTAssertTrue(SymRooms.isValidRoom(name), "\(name) should be valid")
            XCTAssertEqual(SymRooms.serviceTypeToRoom(SymRooms.roomServiceType(name)), name,
                           "\(name) did not round-trip")
        }
    }

    // MARK: - Canonicity

    /// `sym` satisfies the grammar but is a second spelling of the global mesh:
    /// it maps to `_sym._tcp`, whose inverse is `default`. Accepting it puts a
    /// node in the public square while it reports being somewhere specific.
    func testSymIsRefusedBecauseItAliasesTheGlobalMesh() {
        XCTAssertFalse(SymRooms.isValidRoom("sym"))
        XCTAssertNil(SymRooms.canonicalRoom("sym"))
        XCTAssertEqual(SymRooms.roomServiceType("sym"), SymRooms.roomServiceType("default"),
                       "the alias this rule exists to catch")
        XCTAssertTrue(SymRooms.isValidRoom("default"), "the global mesh under its canonical name")
    }

    func testGrammarRejectsWhatDNSSDAndTheRulingReject() {
        for bad in ["Bad_Room", "UPPER", "has space", "dot.name", "under_score",
                    "-lead", "trail-", "x---y", ""] {
            XCTAssertFalse(SymRooms.isValidRoom(bad), "\(bad) must be invalid")
            XCTAssertNil(SymRooms.canonicalRoom(bad), "\(bad) must not be repaired")
        }
    }

    /// The tenant-suffix double hyphen is deliberate, and deliberately outside
    /// RFC 6335 §5.1, which forbids consecutive hyphens in a Service Name.
    func testTenantSuffixDoubleHyphenIsLegal() {
        XCTAssertTrue(SymRooms.isValidRoom("x-review--team-02779b950c3d8d7378fd11d6"))
        XCTAssertTrue(SymRooms.isValidRoom("a--b"))
        XCTAssertFalse(SymRooms.isValidRoom("a---b"), "three is not the grammar")
    }

    /// Whitespace is not part of a name; nothing else may be altered. This is
    /// the line between trimming and repairing.
    func testCanonicalRoomTrimsButNeverRepairs() {
        XCTAssertEqual(SymRooms.canonicalRoom("  backend-team \n"), "backend-team")
        XCTAssertNil(SymRooms.canonicalRoom("Backend Team"),
                     "lowercasing and substituting would map several names onto one room")
    }

    // MARK: - Platform reachability

    /// A host declaring no NSBonjourServices (a daemon, a CLI, the test bundle)
    /// is unconstrained — that must read as "no allow-list applies", never as
    /// "nothing is declared", or every join would be refused.
    func testNoDeclaredListMeansUnconstrainedNotEmpty() {
        let bundle = Bundle(for: RoomsTests.self)
        if SymRooms.declaredServiceTypes(in: bundle) == nil {
            XCTAssertTrue(SymRooms.canJoinRoom("backend-team", in: bundle))
        }
        XCTAssertFalse(SymRooms.canJoinRoom("sym", in: bundle),
                       "a non-canonical name is refused regardless of the platform")
    }
}

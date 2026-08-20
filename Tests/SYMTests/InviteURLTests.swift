import XCTest
@testable import SYM

// MARK: - sym:// Invite URL Tests (0.5.0)
//
// One parser/formatter for every app. The refusals matter more than the
// happy path: a link that is half-understood joins the holder to the wrong
// place, and "the wrong place" here is a real, populated partition.

final class InviteURLTests: XCTestCase {

    private let relay = URL(string: "wss://relay.example.com/mesh")!

    // MARK: - Round trip

    func testCanonicalFormRoundTripsByteStably() throws {
        let invite = SymInviteURL(relay: relay, token: "tok-123", room: "studio", name: "Emma's circle")
        let parsed = try XCTUnwrap(SymInviteURL(parsing: invite.url))

        XCTAssertEqual(parsed, invite)
        XCTAssertEqual(parsed.url.absoluteString, invite.url.absoluteString,
                       "formatting a parsed link must reproduce it — QR codes depend on this")
    }

    func testParameterOrderIsFixed() {
        let invite = SymInviteURL(relay: relay, token: "t", room: "r", name: "n")
        let query = try! XCTUnwrap(URLComponents(url: invite.url, resolvingAgainstBaseURL: false)?.query)
        let order = query.split(separator: "&").map { $0.split(separator: "=")[0] }

        XCTAssertEqual(order, ["relay", "token", "room", "name"],
                       "fixed order is what makes Equatable and QR round-trips byte-stable")
    }

    func testOptionalFieldsAreOmittedNeverEmpty() {
        let minimal = SymInviteURL(relay: relay, token: "t")
        let query = URLComponents(url: minimal.url, resolvingAgainstBaseURL: false)?.query ?? ""

        XCTAssertFalse(query.contains("room="), "absent room is omitted, never emitted empty")
        XCTAssertFalse(query.contains("name="), "absent name is omitted, never emitted empty")
        XCTAssertNil(SymInviteURL(parsing: minimal.url)?.room)
        XCTAssertNil(SymInviteURL(parsing: minimal.url)?.name)
    }

    func testPercentEncodedValuesSurviveTheRoundTrip() throws {
        let invite = SymInviteURL(relay: relay, token: "tok/with+chars=", room: "room name", name: "Emma & Co")
        let parsed = try XCTUnwrap(SymInviteURL(parsing: invite.url))

        XCTAssertEqual(parsed.token, "tok/with+chars=")
        XCTAssertEqual(parsed.room, "room name")
        XCTAssertEqual(parsed.name, "Emma & Co")
    }

    // MARK: - The empty-partition trap

    func testPresentButEmptyRoomIsMalformedNotAbsent() {
        // The empty string is a REAL relay partition — the unnamed one every
        // pre-room client occupies. Reading `room=` as "no room" would
        // silently join the holder to everyone. This is the whole reason
        // the parser distinguishes absent from present-but-empty.
        let url = URL(string: "sym://invite/v1?relay=wss%3A%2F%2Frelay.example.com%2Fmesh&token=t&room=")!
        XCTAssertNil(SymInviteURL(parsing: url),
                     "present-but-empty room REFUSES — never absent, never the \"\" partition")
    }

    func testAbsentRoomIsNil() {
        let url = URL(string: "sym://invite/v1?relay=wss%3A%2F%2Frelay.example.com%2Fmesh&token=t")!
        let parsed = SymInviteURL(parsing: url)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.room, "absent means nil — the invite names no partition")
    }

    func testPresentButEmptyNameIsMalformed() {
        let url = URL(string: "sym://invite/v1?relay=wss%3A%2F%2Frelay.example.com%2Fmesh&token=t&name=")!
        XCTAssertNil(SymInviteURL(parsing: url),
                     "same stance for every optional field: present-but-empty is malformed")
    }

    // MARK: - Refusals

    func testUnknownVersionIsRefused() {
        let url = URL(string: "sym://invite/v2?relay=wss%3A%2F%2Frelay.example.com%2Fmesh&token=t")!
        XCTAssertNil(SymInviteURL(parsing: url),
                     "forward compatibility is by version segment, not by guessing at a newer shape")
    }

    func testNonWssRelayIsRefused() {
        for scheme in ["ws", "http", "https"] {
            let encoded = "\(scheme)%3A%2F%2Frelay.example.com%2Fmesh"
            let url = URL(string: "sym://invite/v1?relay=\(encoded)&token=t")!
            XCTAssertNil(SymInviteURL(parsing: url),
                         "\(scheme) relay would carry the token in the clear")
        }
    }

    func testWrongSchemeIsRefused() {
        let url = URL(string: "https://invite/v1?relay=wss%3A%2F%2Frelay.example.com&token=t")!
        XCTAssertNil(SymInviteURL(parsing: url))
    }

    func testMissingRequiredFieldsAreRefused() {
        let noToken = URL(string: "sym://invite/v1?relay=wss%3A%2F%2Frelay.example.com%2Fmesh")!
        XCTAssertNil(SymInviteURL(parsing: noToken))

        let noRelay = URL(string: "sym://invite/v1?token=t")!
        XCTAssertNil(SymInviteURL(parsing: noRelay))

        let emptyToken = URL(string: "sym://invite/v1?relay=wss%3A%2F%2Frelay.example.com%2Fmesh&token=")!
        XCTAssertNil(SymInviteURL(parsing: emptyToken))
    }

    func testMalformedPathIsRefused() {
        for path in ["sym://invite", "sym://invite/v1/extra", "sym://join/v1"] {
            let url = URL(string: "\(path)?relay=wss%3A%2F%2Frelay.example.com%2Fmesh&token=t")!
            XCTAssertNil(SymInviteURL(parsing: url), "\(path) is not an invite link")
        }
    }

    // MARK: - The token is a credential

    func testDescriptionRedactsTheToken() {
        let invite = SymInviteURL(relay: relay, token: "super-secret-token", room: "r", name: "n")
        let description = invite.description

        XCTAssertFalse(description.contains("super-secret-token"),
                       "the most common way a bearer credential leaks is a log line")
        XCTAssertTrue(description.contains("<redacted>"))
        XCTAssertTrue(description.contains("relay.example.com"), "the non-secret parts stay debuggable")
    }
}

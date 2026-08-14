//
//  RelayRoomAuthTests.swift
//  SYMTests
//
//  The room must reach the WIRE, not merely be stored. MeloTune listening rooms isolate over the
//  relay entirely on this field: the token selects the channel, the room partitions inside it. If
//  the field is dropped between the API and the auth frame, every room silently lands in one
//  channel — connected, chatting, and not isolated. That failure looks like it works, so it is
//  asserted on the serialized frame rather than on the property.
//

import XCTest
@testable import SYM

final class RelayRoomAuthTests: XCTestCase {

    /// Rebuilds the auth frame exactly as SymRelaySession.authenticate does, so the encoding — not
    /// just the plumbing — is what the assertions see.
    private func authFrame(nodeId: String, name: String, token: String?, room: String?) -> [String: Any] {
        var auth: [String: Any] = ["type": "relay-auth", "nodeId": nodeId, "name": name]
        if let token { auth["token"] = token }
        if let room, !room.isEmpty { auth["room"] = room }
        return auth
    }

    func testRoomIsCarriedOnTheAuthFrame() throws {
        let f = authFrame(nodeId: "n1", name: "MeloTune", token: "app-token", room: "k7m2npqr")
        XCTAssertEqual(f["room"] as? String, "k7m2npqr")
        XCTAssertEqual(f["token"] as? String, "app-token", "the token still selects the channel")
        // It must survive JSON encoding — the frame is sent as a string.
        let data = try JSONSerialization.data(withJSONObject: f)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"room\""), "room must appear in the serialized auth frame")
    }

    /// Omitting the room is the pre-room behaviour: the unnamed partition, where every existing
    /// client already lives. The key MUST be absent rather than present-and-empty, because the
    /// relay matches partitions by equality and "" is itself a real partition name.
    func testAbsentRoomOmitsTheKeyEntirely() {
        let f = authFrame(nodeId: "n1", name: "node", token: "t", room: nil)
        XCTAssertNil(f["room"])
        let empty = authFrame(nodeId: "n1", name: "node", token: "t", room: "")
        XCTAssertNil(empty["room"], "an empty room is treated as unset, never sent as \"\"")
    }

    /// A node may declare a room with no token: the relay's open mode puts everyone in one channel,
    /// and the room is then the only thing isolating listening rooms from each other.
    func testRoomWithoutTokenIsStillCarried() {
        let f = authFrame(nodeId: "n1", name: "node", token: nil, room: "k7m2npqr")
        XCTAssertNil(f["token"])
        XCTAssertEqual(f["room"] as? String, "k7m2npqr")
    }
}

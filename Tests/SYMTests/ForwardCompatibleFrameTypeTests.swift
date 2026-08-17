//
//  ForwardCompatibleFrameTypeTests.swift
//  SYMTests
//
//  `SymFrameType` was a String-raw-value enum with no tolerance for values it
//  did not know, and `SymFrame.type` is non-optional — so an unrecognized
//  discriminator threw `DecodingError.dataCorrupted` and killed the WHOLE
//  frame. Every frame type added to the wire after a Swift client shipped
//  broke that client's decode of those frames, silently, for as long as it
//  stayed in the field.
//
//  `attestation` was the second instance of that class (the first, a v2
//  record in the `cmb` member, was patched narrowly by rescueV2CMBFrame — see
//  BoundaryRecordRescueTests). A rescue per shape does not converge, so the
//  discriminator itself is tolerant now. These tests pin the mechanism, not
//  the one case: an unknown type is ignored, the stream does not desync, and
//  every known type still decodes exactly as before.
//

import Foundation
import SYMCore
import XCTest
@testable import SYM

final class ForwardCompatibleFrameTypeTests: XCTestCase {

    private func wireFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// The exact shape observed live on sym-bot-room, 2026-08-17: a JS node
    /// emitted an admission attestation and every Swift client on the roster
    /// failed to decode it, once per relaying peer.
    private let attestationFrameJSON = """
    {"type":"attestation","attestation":{
       "of":"cmb-dfb4c0ad34ec4112097eae38ca24725b5b328e9a7b62f3cc568f371db244a153",
       "by":"01a005e2-36d0-7bfe-a331-f2f2d49e7a98",
       "at":1786983717654,
       "roster":"sym-bot-room"}}
    """

    private let handshakeFrameJSON = """
    {"type":"handshake","nodeId":"019f852c-0000-7000-8000-000000000000","name":"peer-a","version":"0.4.5"}
    """

    // MARK: - The discriminator itself

    func testUnrecognizedDiscriminatorDecodesToUnknownInsteadOfThrowing() throws {
        let data = Data(attestationFrameJSON.utf8)
        let frame = try JSONDecoder().decode(SymFrame.self, from: data)
        XCTAssertEqual(frame.type, .unknown,
                       "an unrecognized `type` must map to .unknown, not throw and kill the frame")
    }

    func testEveryKnownDiscriminatorStillDecodesToItself() throws {
        // The wire values, not the Swift case names — a typo here is a wire break.
        let known: [(String, SymFrameType)] = [
            ("handshake", .handshake), ("state-sync", .stateSync), ("cmb", .cmb),
            ("mood", .mood), ("message", .message), ("wake-channel", .wakeChannel),
            ("wake", .wake), ("xmesh-insight", .xmeshInsight), ("peer-info", .peerInfo),
            ("error", .error), ("ping", .ping), ("pong", .pong), ("node-stats", .nodeStats),
        ]
        for (raw, expected) in known {
            let data = Data("{\"type\":\"\(raw)\"}".utf8)
            let frame = try JSONDecoder().decode(SymFrame.self, from: data)
            XCTAssertEqual(frame.type, expected, "wire value \"\(raw)\" must decode to \(expected)")
        }
    }

    func testUnknownSentinelCannotBeProducedByAWireValue() {
        // The sentinel carries a NUL, so no producer can collide with it by
        // sending an ordinary string.
        XCTAssertEqual(SymFrameType.unknown.rawValue, "\u{0}unknown")
        XCTAssertNil(SymFrameType(rawValue: "unknown"),
                     "the literal string \"unknown\" must NOT resolve to the sentinel")
    }

    // MARK: - The parser

    func testUnknownFrameIsDroppedRatherThanDelivered() {
        let parser = SymFrameParser()
        let frames = parser.feed(wireFrame(attestationFrameJSON))
        XCTAssertTrue(frames.isEmpty,
                      "an unhandled frame type must be ignored, not surfaced to handlers")
    }

    /// The regression that matters: the failure must not cost the frames after
    /// it. `feed` advances the buffer before decoding, so the length-prefixed
    /// stream survives — this pins that, because a desync here would tear down
    /// the session rather than drop one frame.
    func testStreamSurvivesAnUnknownFrameAndDeliversTheNextOne() {
        let parser = SymFrameParser()
        let stream = wireFrame(attestationFrameJSON) + wireFrame(handshakeFrameJSON)

        let frames = parser.feed(stream)

        XCTAssertEqual(frames.count, 1, "exactly the known frame should survive")
        XCTAssertEqual(frames.first?.type, .handshake)
        XCTAssertEqual(frames.first?.name, "peer-a",
                       "the frame after the unknown one must decode intact — no desync")
    }

    /// Interleaved and repeated, the way a roster actually delivers it: the
    /// same attestation is relayed by every peer, so the amplification was by
    /// peer count. Known frames must still come through, every time.
    func testRepeatedUnknownFramesNeverSuppressKnownOnes() {
        let parser = SymFrameParser()
        var stream = Data()
        for _ in 0..<8 {
            stream += wireFrame(attestationFrameJSON)
            stream += wireFrame(handshakeFrameJSON)
        }

        let frames = parser.feed(stream)

        XCTAssertEqual(frames.count, 8, "all eight known frames must survive eight unknown ones")
        XCTAssertTrue(frames.allSatisfy { $0.type == .handshake })
    }

    /// A frame split across two reads still parses — the unknown-type path must
    /// not consume a partial buffer.
    func testUnknownFrameArrivingInTwoChunksDoesNotCorruptTheBuffer() {
        let parser = SymFrameParser()
        let whole = wireFrame(attestationFrameJSON) + wireFrame(handshakeFrameJSON)
        let split = whole.count / 2

        let first = parser.feed(whole.prefix(split))
        let second = parser.feed(whole.suffix(from: split))

        XCTAssertTrue(first.isEmpty || first.allSatisfy { $0.type == .handshake })
        XCTAssertEqual((first + second).filter { $0.type == .handshake }.count, 1,
                       "the known frame must arrive exactly once across the split")
    }
}

//
//  BoundaryRecordRescueTests.swift
//  SYMTests
//
//  A v2 two-section record in a frame's `cmb` member used to fail the flat
//  Codable decode and — because one member's failure kills synthesized frame
//  decode — the WHOLE frame was silently dropped. iOS was deaf to every
//  boundary record from current JS nodes. These tests pin the rescue: the
//  frame survives, the record's real identity survives, and everything that
//  is not exactly that shape still fails exactly as before.
//

import Foundation
import SYMCore
import XCTest
@testable import SYM

final class BoundaryRecordRescueTests: XCTestCase {

    /// A realistic v2 frame as a current JS node emits it: two-section cmb,
    /// per-field meta, signature in metadata — length-prefixed like the wire.
    private func wireFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    private let v2FrameJSON = """
    {"type":"cmb","source":"claude-sym-research@sym-bot-team","timestamp":1785700000000,
     "cmb":{
       "fields":{
         "focus":{"text":"boundary record reaches iOS","meta":{"key":"aa11","parents":[]}},
         "issue":{"text":"none","meta":{"key":"bb22","parents":["cmb-parent#issue~d1"]}},
         "intent":{"text":"verify","meta":{"key":"cc33","parents":[]}},
         "motivation":{"text":"interop","meta":{"key":"dd44","parents":[]}},
         "commitment":{"text":"exact bytes","meta":{"key":"ee55","parents":[]}},
         "perspective":{"text":"generator","meta":{"key":"ff66","parents":[]}},
         "mood":{"text":"calm","valence":0.2,"arousal":-0.1,"meta":{"key":"0077","parents":[]}}
       },
       "metadata":{
         "key":"cmb-3123b3beb07c86c10bd02c907ece0ab81bfa9a292a97245136c5ce7a16747e34",
         "createdBy":"claude-sym-research@sym-bot-team",
         "createdTimestamp":1785700000000,
         "lineage":{"parents":["cmb-1111111111111111111111111111111111111111111111111111111111111111"]},
         "room":"sym-bot-team","to":null,
         "sig":"c2lnbmF0dXJlLWJ5dGVz","sigAlg":"ed25519",
         "someFutureMember":{"kernel":"minilm-h192"}
       }
     }}
    """

    func testV2RecordFrameIsRescuedNotDropped() {
        let parsed = SymFrameParser().feed(wireFrame(v2FrameJSON))
        XCTAssertEqual(parsed.count, 1, "the frame must survive — this is the drop that made iOS deaf")
        let frame = parsed[0]
        XCTAssertEqual(frame.type, .cmb)
        XCTAssertNil(frame.cmb, "the flat member stays nil — exactly one of cmb/cmbV2 is set")
        let v2 = frame.cmbV2
        XCTAssertNotNil(v2)
        XCTAssertEqual(v2?.metadata.key, "cmb-3123b3beb07c86c10bd02c907ece0ab81bfa9a292a97245136c5ce7a16747e34")
        XCTAssertEqual(v2?.metadata.createdBy, "claude-sym-research@sym-bot-team",
                       "identity comes from the record's own metadata, never the delivering peer")
        XCTAssertEqual(v2?.fields["focus"]?.text, "boundary record reaches iOS")
        XCTAssertEqual(v2?.fields["mood"]?.valence, 0.2)
        XCTAssertEqual(v2?.metadata.lineage?.parents.count, 1)
        XCTAssertEqual(v2?.metadata.sigAlg, "ed25519",
                       "the signature is carried for the SYMCore-v2 verifier; the bridge deliberately does not feed it to the v1 verifier")
    }

    func testUnknownMetadataMembersAreTolerated() {
        // someFutureMember (e.g. the pending kernel-provenance ruling) rides
        // in the fixture above — decode succeeding at all is the assertion,
        // but pin it explicitly so a strict-decoder regression names itself.
        let parsed = SymFrameParser().feed(wireFrame(v2FrameJSON))
        XCTAssertNotNil(parsed.first?.cmbV2, "unknown metadata members must not break the rescue")
    }

    func testFlatCMBFramesStillDecodeFirstPass() throws {
        // The rescue must never intercept the flat path.
        let flat = """
        {"type":"cmb","source":"peer-a",
         "cmb":{"key":"cmb-abc123","fields":{"focus":{"text":"flat record","vector":[]}},
                "source":"peer-a","createdBy":"peer-a","createdAt":1785700000000,
                "originTimestamp":1785700000000,"storedAt":1785700000000,"confidence":0.8}}
        """
        let parsed = SymFrameParser().feed(wireFrame(flat))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertNotNil(parsed[0].cmb, "flat records take the first-pass decode")
        XCTAssertNil(parsed[0].cmbV2)
    }

    func testGarbageStillFailsLoudly() {
        // The rescue is narrow: a broken frame that is not a v2-cmb shape
        // must fail exactly as before, not be half-rescued.
        let garbage = """
        {"type":"cmb","source":"peer-a","cmb":{"unexpected":true}}
        """
        let parsed = SymFrameParser().feed(wireFrame(garbage))
        XCTAssertTrue(parsed.isEmpty, "not-a-record shapes are not rescued")
    }

    func testSignedV2RecordSurvivesTheWireAndVerifies() throws {
        // End to end: sign with the conformance TEST keypair (never an
        // identity), serialize into a frame, parse through the rescue, then
        // verify the parsed record exactly as SymNode's bridge does. This is
        // the moment "unverified-v2" became "verified" — pin it.
        let privB64 = "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI"
        let pubB64 = "IVL40Zt5HSRFMkLhXy6rbLfP-ntqXtMAl5YOBpiB2xI"

        let record = try CMBRecordV2.create(
            fields: ["focus": "verified end to end", "issue": "none", "intent": "prove",
                     "motivation": "interop", "commitment": "exact bytes",
                     "perspective": "test", "mood": ["text": "calm"]],
            createdBy: "vector-author@conformance",
            now: 1_785_700_000_000)
        let signed = try CMBSigningV2.sign(record, privateKeyB64url: privB64)

        let cmbJSON = String(data: try JSONEncoder().encode(signed), encoding: .utf8)!
        let frameJSON = #"{"type":"cmb","source":"vector-author@conformance","cmb":"# + cmbJSON + "}"
        let parsed = SymFrameParser().feed(wireFrame(frameJSON))
        let arrived = try XCTUnwrap(parsed.first?.cmbV2)

        let verdict = CMBSigningV2.verify(arrived, publicKeyB64url: pubB64)
        XCTAssertTrue(verdict.valid, "signed on one side of the wire, verified on the other: \(verdict.error ?? "")")

        // And a tampered field fails as content-mismatch — integrity is
        // checked on the RECOMPUTED key before the signature is examined.
        var tampered = arrived
        tampered.fields["focus"]?.text = "tampered in flight"
        let bad = CMBSigningV2.verify(tampered, publicKeyB64url: pubB64)
        XCTAssertFalse(bad.valid)
        XCTAssertEqual(bad.error, "content-mismatch")
    }

    func testV2MissingIdentityIsNotRescuedIntoAForgery() {
        // metadata without a key fails the looksLikeV2 sniff — the frame
        // drops (as before), and nothing downstream can fabricate identity.
        let noKey = """
        {"type":"cmb","source":"peer-a",
         "cmb":{"fields":{"focus":{"text":"x"}},"metadata":{"createdBy":"someone"}}}
        """
        let parsed = SymFrameParser().feed(wireFrame(noKey))
        XCTAssertTrue(parsed.isEmpty, "no key → not a v2 record → no rescue, no fabrication")
    }
}

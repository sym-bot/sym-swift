//
//  WireRecordV2.swift
//  SYM
//
//  Minimal transport decode of the MMP v2 two-section record (§7.1) — just
//  enough to stop iOS DROPPING boundary records from current JS nodes
//  (core 0.5.0+ / sym 0.9.0+), and to bridge them into the existing pipeline
//  with their real identity intact.
//
//  TEMPORARY BY DESIGN: the authoritative v2 types live in sym-core-swift
//  (CMBRecordV2, merged @ 79fd9ce) and reach this package only through the
//  SYMCore xcframework, which is release-gated. When that framework ships,
//  this decoder is replaced by SYMCore.CMBRecordV2 and v2 SIGNATURE
//  VERIFICATION lands with it. Until then a bridged record is admitted as
//  UNVERIFIED-V2 — readable, clearly marked, never silently trusted — the
//  same stance the JS side takes toward pre-boundary records in reverse.
//

import Foundation

/// The wire shape of a v2 record, decoded tolerantly: field meta is ignored
/// (per-field descent is consumed by SVAF/lineage layers that arrive with the
/// SYMCore v2 framework), unknown metadata members are ignored (the pending
/// kernel-provenance addition must not break this decode).
public struct WireRecordV2: Codable, Sendable {

    public struct Field: Codable, Sendable {
        public let text: String
        public let valence: Double?
        public let arousal: Double?

        private enum CodingKeys: String, CodingKey { case text, valence, arousal }
    }

    public struct Metadata: Codable, Sendable {
        public let key: String
        public let createdBy: String
        public let createdTimestamp: UInt64?
        public let lineage: Lineage?
        public let room: String?
        public let to: String?
        public let sig: String?
        public let sigAlg: String?

        private enum CodingKeys: String, CodingKey {
            case key, createdBy, createdTimestamp, lineage, room, to, sig, sigAlg
        }
    }

    public struct Lineage: Codable, Sendable {
        public let parents: [String]?
        public let method: String?
    }

    public let fields: [String: Field]
    public let metadata: Metadata

    /// A frame's `cmb` member is v2 iff it carries a `metadata` object with a
    /// `key` — the flat model has neither. Cheap structural sniff, no schema
    /// commitment beyond what the bridge actually reads.
    public static func looksLikeV2(_ json: Any?) -> Bool {
        guard let obj = json as? [String: Any],
              let metadata = obj["metadata"] as? [String: Any] else { return false }
        return metadata["key"] is String
    }
}

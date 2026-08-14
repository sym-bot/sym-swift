//
//  MMPVersion.swift
//  SYM
//
//  What this node speaks, readable by the app that ships it.
//
//  The version was hardcoded at the one place that put it on the wire, so an app
//  could not report — or assert in a test — which protocol it actually speaks.
//  A constant an app cannot read is a fact only the wire knows, and the first
//  symptom of it drifting is a peer disagreeing in the field.
//
//  Two DIFFERENT versions live here on purpose, because conflating them is the
//  mistake this file exists to prevent:
//
//    · `protocolVersion` — the MMP protocol this implementation speaks: 2.0.
//      It is the version that appears inside the authenticated §5.2 handshake
//      transcript and in signed v2.0 records, where it is covered by the
//      signature and therefore load-bearing.
//
//    · `legacyHandshakeRevision` — the pre-2.0 handshake's `version` field.
//      It is an ADVISORY label: no receiver in the fleet reads or validates it
//      (verified against the JS reference implementation's receive path), which
//      is precisely how the Swift and JS sides drifted to 0.2.2 and 0.2.3
//      without anything failing. It is kept only so a pre-2.0 peer sees the
//      shape it expects.
//
//  Copyright (c) 2026 SYM.BOT Ltd.
//

import Foundation

/// The Mesh Memory Protocol version surface, public so an app can report and
/// assert what it speaks rather than trusting a comment.
public enum MMP {

    /// The MMP protocol version this implementation speaks.
    ///
    /// This is the version that matters: it enters the authenticated §5.2
    /// handshake transcript and every `mmp-sig-v2.0` record, where the signature
    /// covers it — so it cannot be reinterpreted in transit.
    public static let protocolVersion = "2.0"

    /// The signature suite this implementation reads and writes for v2.0 records.
    public static let signatureSuite = "mmp-sig-v2.0"

    /// The content-address scheme for v2.0 records.
    public static let addressScheme = "mmp-cmb-merkle-v2"

    /// The legacy pre-2.0 handshake `version` label.
    ///
    /// ADVISORY ONLY — nothing in the fleet validates it. Do not treat a match
    /// here as compatibility, and do not treat a mismatch as incompatibility:
    /// the Swift and JS sides carried different values (0.2.2 and 0.2.3) for
    /// releases with no observable effect, which is the evidence that this field
    /// decides nothing. Real version agreement is `protocolVersion`, inside the
    /// signed transcript.
    public static let legacyHandshakeRevision = "0.2.3"
}

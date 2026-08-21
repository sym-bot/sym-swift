//
//  PayloadSeal.swift
//  SYM
//
//  payload-seal-v1 — confidentiality for the application payload across a relay.
//
//  The cryptography lives in SYMCore (`E2ECrypto.derivePayloadKey`, `sealPayload`,
//  `openPayload`). It was briefly reimplemented here with CryptoKit to avoid a binary
//  framework release; that workaround is gone, because two implementations of one key
//  schedule is exactly the second-source-of-truth problem that drifts silently — the
//  copy that stops matching is the one nobody tests against the wire.
//
//  What remains here is the wiring: which peer a frame is bound for, and turning a
//  sealed object back into payload bytes on receive.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation
import CryptoKit
import SYMCore

/// Sealing and opening for `payload-seal-v1`, delegating the key schedule and the AEAD
/// to SYMCore so both ends of a pair run the same code.
enum PayloadSeal {

    /// Marker naming the scheme, so a receiver tells a sealed payload from a plaintext one.
    static var marker: String { E2ECrypto.payloadSealMarker }

    /// Derive the payload key for a peer. Not the category key — see SYMCore.
    static func payloadKey(myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
                           peerPublicKey: Data,
                           myNodeId: String,
                           peerNodeId: String) -> SymmetricKey? {
        E2ECrypto.derivePayloadKey(
            myPrivateKey: myPrivateKey, peerPublicKey: peerPublicKey,
            myNodeId: myNodeId, peerNodeId: peerNodeId)
    }

    /// AAD binding a seal to the CMB it rides on and its recipient.
    static func aad(cmbKey: String, recipientNodeId: String) -> Data {
        E2ECrypto.payloadSealAAD(cmbKey: cmbKey, recipientNodeId: recipientNodeId)
    }

    /// Seal payload bytes into the object that replaces the payload value.
    static func seal(_ payload: Data, key: SymmetricKey, aad: Data) -> [String: Any]? {
        E2ECrypto.sealPayload(payload, key: key, aad: aad)
    }

    /// True when a payload object is a seal rather than plaintext.
    static func isSealed(_ object: [String: Any]) -> Bool {
        E2ECrypto.isPayloadSealed(object)
    }

    /// Open a sealed payload object, returning the original bytes.
    ///
    /// nil means **this did not arrive** — a wrong key, a tampered byte, or a seal lifted
    /// from another frame. It never means "arrived empty".
    static func open(_ object: [String: Any], key: SymmetricKey, aad: Data) -> Data? {
        E2ECrypto.openPayload(object, key: key, aad: aad)
    }
}

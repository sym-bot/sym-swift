//
//  PayloadSeal.swift
//  SYM
//
//  payload-seal-v1 — confidentiality for the application payload across a relay.
//
//  The CAT7 categories have had end-to-end encryption since 0.3.x. The application
//  payload never did: `makePayloadCMBFrame` assigned it in the clear and the encryption
//  branch below it sealed only `cmb.categories`. So a transcribed spoken thought on its
//  way to a user's own sidecar crossed the relay readable, and an app claiming
//  end-to-end encryption between two phones was telling the truth about its categories
//  and not about its payloads.
//
//  The seal replaces the payload value IN THE SLOT THE PAYLOAD ALREADY OCCUPIES, because
//  both stacks already move that value opaquely — Node's `_preserveIncomingPayload`
//  copies it without looking at it, and this SDK routes it before the SVAF verdict
//  without interpreting it. A sealed object therefore transits every existing hop with
//  no change to any intermediary, which is what lets transport and sealing ship
//  separately instead of needing a flag day.
//
//  Copyright (c) 2026 SYM.BOT. Apache 2.0 License.
//

import Foundation
import CryptoKit

/// Sealing and opening for `payload-seal-v1`.
///
/// The key is deliberately NOT the category key. It is derived from the same X25519
/// agreement with a different HKDF `info`, so a payload key can never double as a
/// category key, and both node ids are bound into `info` (sorted, so both ends compute
/// the same string) so a derived key cannot be replayed against a third peer.
enum PayloadSeal {

    /// Marker naming the scheme, so a receiver can tell a sealed payload from a
    /// plaintext one without a version negotiation.
    static let marker = "payload-seal-v1"

    private static let infoPrefix = "sym-payload-seal-v1"

    /// Derive the payload key for a peer.
    ///
    /// Separate from `E2ECrypto.deriveSharedSecret`, which HKDFs the same agreement with
    /// `"sym-e2e-v1"` for categories. Same agreement, different `info` — so compromise or
    /// misuse of one key does not reach the other.
    static func payloadKey(myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
                           peerPublicKey: Data,
                           myNodeId: String,
                           peerNodeId: String) -> SymmetricKey? {
        guard let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let shared = try? myPrivateKey.sharedSecretFromKeyAgreement(with: peerKey) else {
            return nil
        }
        // Sorted so both ends derive the same key without exchanging anything.
        let lo = min(myNodeId, peerNodeId)
        let hi = max(myNodeId, peerNodeId)
        let info = Data("\(infoPrefix)\(lo)\(hi)".utf8)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }

    /// Additional authenticated data, binding the seal to the CMB it rides on and to its
    /// intended recipient. The relay therefore cannot lift a seal off one frame and
    /// staple it onto another.
    ///
    /// This does NOT touch signing: the AAD is evaluated at open time on the receiver,
    /// and the payload still joins the frame after the CMB is signed. Pulling the payload
    /// into the signing preimage would change every cmbKey and break content addressing
    /// across the fleet.
    static func aad(cmbKey: String, recipientNodeId: String) -> Data {
        Data("\(cmbKey)\(recipientNodeId)\(marker)".utf8)
    }

    /// Seal payload bytes. Returns the JSON object that replaces the payload value.
    static func seal(_ payload: Data, key: SymmetricKey, aad: Data) -> [String: Any]? {
        guard let box = try? AES.GCM.seal(payload, using: key, authenticating: aad),
              let combined = box.combined else { return nil }
        // Same framing as the category path already on the wire: nonce carried
        // separately, ciphertext and 16-byte tag concatenated.
        let nonce = combined.prefix(12)
        let ctWithTag = combined.dropFirst(12)
        return [
            "_seal": marker,
            "n": nonce.base64EncodedString(),
            "ct": ctWithTag.base64EncodedString(),
        ]
    }

    /// True when a payload object is a seal rather than plaintext.
    static func isSealed(_ object: [String: Any]) -> Bool {
        (object["_seal"] as? String) == marker
    }

    /// Open a sealed payload object. Returns the original payload bytes.
    ///
    /// Returns nil on any failure — a wrong key, a tampered ciphertext, or an AAD that
    /// does not match the frame it arrived on. The caller must treat nil as "this did not
    /// arrive", never as "this arrived empty".
    static func open(_ object: [String: Any], key: SymmetricKey, aad: Data) -> Data? {
        guard isSealed(object),
              let nB64 = object["n"] as? String, let ctB64 = object["ct"] as? String,
              let nonceData = Data(base64Encoded: nB64), let ctData = Data(base64Encoded: ctB64),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else { return nil }
        var combined = Data()
        combined.append(nonceData)
        combined.append(ctData)
        _ = nonce
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad) else { return nil }
        return plain
    }
}

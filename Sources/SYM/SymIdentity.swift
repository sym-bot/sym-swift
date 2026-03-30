//
//  SymIdentity.swift
//  SYM
//
//  Node identity — persisted UUID v7, Ed25519 keypair, hostname, display name.
//  Stored in ~/Library/Application Support/SYM/nodes/{name}/identity.json
//
//  Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.
//

import CryptoKit
import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Identity

/// Persistent node identity. Created once, reused across sessions.
/// See MMP v0.2.0 Section 3 (Identity, Layer 0).
public struct SymIdentity: Codable, Sendable {

    /// Unique node ID (UUID v7 for new nodes, UUID v4 accepted for existing).
    /// Lowercase hexadecimal with hyphens per MMP Section 3.1.1.
    public let nodeId: String

    /// Display name of this node (1-64 bytes, printable UTF-8).
    public let name: String

    /// Machine hostname at identity creation time.
    public let hostname: String

    /// Timestamp when this identity was first created.
    public let createdAt: Date

    /// Ed25519 public key (base64url-encoded, 32 bytes). See MMP Section 3.1.3.
    public var publicKey: String?

    /// Ed25519 private key (base64url-encoded, 32 bytes). Never leaves the node.
    public var privateKey: String?
}

// MARK: - Identity Manager

/// Manages node identity persistence. See MMP v0.2.0 Section 3 (Identity, Layer 0).
/// Each node name gets its own identity file under the SYM data directory.
enum SymIdentityManager {

    private static let logger = Logger(subsystem: "bot.sym", category: "SymIdentity")

    /// Generate a UUID v7 (RFC 9562).
    /// 48-bit Unix timestamp (ms) + 4-bit version (0111) + 12-bit random +
    /// 2-bit variant (10) + 62-bit random.
    static func uuidv7() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)

        // Fill with random bytes first
        var rng = SystemRandomNumberGenerator()
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255, using: &rng) }

        // Bytes 0-5: 48-bit timestamp (ms since epoch), big-endian
        bytes[0] = UInt8((now >> 40) & 0xff)
        bytes[1] = UInt8((now >> 32) & 0xff)
        bytes[2] = UInt8((now >> 24) & 0xff)
        bytes[3] = UInt8((now >> 16) & 0xff)
        bytes[4] = UInt8((now >> 8) & 0xff)
        bytes[5] = UInt8(now & 0xff)

        // Byte 6: version 7 (0111 xxxx)
        bytes[6] = (bytes[6] & 0x0f) | 0x70

        // Byte 8: variant 10xx xxxx
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let s = hex
        let i0 = s.startIndex
        let i8 = s.index(i0, offsetBy: 8)
        let i12 = s.index(i0, offsetBy: 12)
        let i16 = s.index(i0, offsetBy: 16)
        let i20 = s.index(i0, offsetBy: 20)
        return "\(s[i0..<i8])-\(s[i8..<i12])-\(s[i12..<i16])-\(s[i16..<i20])-\(s[i20...])"
    }

    /// Validate a node name per MMP Section 3.1.2.
    /// Must be valid UTF-8, 1-64 bytes, printable characters only.
    static func validateName(_ name: String) throws {
        guard !name.isEmpty else {
            throw SymIdentityError.invalidName("Node name must be a non-empty string")
        }
        let byteCount = name.utf8.count
        guard byteCount <= 64 else {
            throw SymIdentityError.invalidName("Node name must be 1-64 bytes (got \(byteCount))")
        }
        // Reject control characters (U+0000-U+001F, U+007F-U+009F)
        for scalar in name.unicodeScalars {
            if (scalar.value <= 0x1f) || (scalar.value >= 0x7f && scalar.value <= 0x9f) {
                throw SymIdentityError.invalidName("Node name must not contain control characters")
            }
        }
    }

    /// Generate an Ed25519 signing keypair. Returns raw 32-byte keys as base64url strings.
    static func generateSigningKeyPair() -> (publicKey: String, privateKey: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubData = privateKey.publicKey.rawRepresentation
        let privData = privateKey.rawRepresentation
        return (
            publicKey: pubData.base64URLEncodedString(),
            privateKey: privData.base64URLEncodedString()
        )
    }

    /// Load existing identity from disk, or create and persist a new one.
    /// New nodes get UUID v7 + Ed25519 keypair. Existing nodes with UUID v4
    /// are accepted and auto-migrated with a keypair if missing.
    /// - Parameter name: The node display name. Also used as the directory name for persistence.
    /// - Returns: The loaded or newly created ``SymIdentity``.
    static func loadOrCreate(name: String) -> SymIdentity {
        // Validate name (log warning but don't crash for backward compat)
        do { try validateName(name) } catch {
            logger.warning("[SYM] identity: \(error.localizedDescription)")
        }

        let dir = nodeDirectory(for: name)
        let path = dir.appendingPathComponent("identity.json")

        if let data = try? Data(contentsOf: path),
           var identity = try? JSONDecoder().decode(SymIdentity.self, from: data) {
            // Migrate: add Ed25519 keypair if missing (pre-v0.3.7 nodes)
            if identity.publicKey == nil {
                let kp = generateSigningKeyPair()
                identity.publicKey = kp.publicKey
                identity.privateKey = kp.privateKey
                if let encoded = try? JSONEncoder().encode(identity) {
                    try? encoded.write(to: path)
                    logger.info("[SYM] identity: migrated \(name) — added Ed25519 keypair")
                }
            }
            return identity
        }

        let kp = generateSigningKeyPair()
        let identity = SymIdentity(
            nodeId: uuidv7(),
            name: name,
            hostname: Self.hostname(),
            createdAt: Date(),
            publicKey: kp.publicKey,
            privateKey: kp.privateKey
        )

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(identity) {
            try? data.write(to: path)
        }

        return identity
    }

    /// Data directory for a named node.
    /// - Parameter name: The node display name.
    /// - Returns: File URL to `~/Library/Application Support/SYM/nodes/{name}/` (or `~/.sym/nodes/{name}/` as fallback).
    static func nodeDirectory(for name: String) -> URL {
        let base: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = appSupport.appendingPathComponent("SYM")
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".sym")
        }
        return base.appendingPathComponent("nodes").appendingPathComponent(name)
    }

    // MARK: - E2E Keypair Persistence

    private static let e2eLogger = Logger(subsystem: "bot.sym", category: "SymIdentity.E2E")

    /// Load or create a Curve25519 key pair for E2E encryption.
    ///
    /// The private key is stored as raw bytes in `e2e-private-key.bin` alongside the identity file.
    /// On first call, generates a new key pair and persists it. On subsequent calls, loads the
    /// existing key pair from disk.
    ///
    /// - Parameter name: The node display name (determines the storage directory).
    /// - Returns: A tuple of (privateKey, publicKey as raw 32-byte Data).
    static func loadOrCreateE2EKeyPair(name: String) -> (privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Data) {
        let dir = nodeDirectory(for: name)
        let keyPath = dir.appendingPathComponent("e2e-private-key.bin")

        // Try loading existing key
        if let rawKey = try? Data(contentsOf: keyPath),
           let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawKey) {
            let publicKey = privateKey.publicKey.rawRepresentation
            e2eLogger.info("[SYM] e2e: loaded persisted key pair for \(name)")
            return (privateKey, publicKey)
        }

        // Generate new key pair
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation

        // Persist private key
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try privateKey.rawRepresentation.write(to: keyPath)
            e2eLogger.info("[SYM] e2e: generated and persisted new key pair for \(name)")
        } catch {
            e2eLogger.error("[SYM] e2e: failed to persist private key: \(error)")
        }

        return (privateKey, publicKey)
    }

    private static func hostname() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
}

// MARK: - Errors

enum SymIdentityError: LocalizedError {
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let msg): return msg
        }
    }
}

// MARK: - Base64URL

extension Data {
    /// Encode to base64url (RFC 4648 Section 5) — no padding, URL-safe characters.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode from base64url (RFC 4648 Section 5).
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}

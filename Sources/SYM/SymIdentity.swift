//
//  SymIdentity.swift
//  SYM
//
//  Node identity — persisted UUID, hostname, display name.
//  Stored in ~/Library/Application Support/SYM/{name}/identity.json
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

    /// Unique node ID (lowercased UUID string). See MMP v0.2.0 Section 3.
    public let nodeId: String

    /// Display name of this node.
    public let name: String

    /// Machine hostname at identity creation time.
    public let hostname: String

    /// Timestamp when this identity was first created.
    public let createdAt: Date
}

// MARK: - Identity Manager

/// Manages node identity persistence. See MMP v0.2.0 Section 3 (Identity, Layer 0).
/// Each node name gets its own identity file under the SYM data directory.
enum SymIdentityManager {

    /// Load existing identity from disk, or create and persist a new one.
    /// - Parameter name: The node display name. Also used as the directory name for persistence.
    /// - Returns: The loaded or newly created ``SymIdentity``.
    static func loadOrCreate(name: String) -> SymIdentity {
        let dir = nodeDirectory(for: name)
        let path = dir.appendingPathComponent("identity.json")

        if let data = try? Data(contentsOf: path),
           let identity = try? JSONDecoder().decode(SymIdentity.self, from: data) {
            return identity
        }

        let identity = SymIdentity(
            nodeId: UUID().uuidString.lowercased(),
            name: name,
            hostname: Self.hostname(),
            createdAt: Date()
        )

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(identity) {
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

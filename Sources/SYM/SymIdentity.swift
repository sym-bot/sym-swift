//
//  SymIdentity.swift
//  SYM
//
//  Node identity — persisted UUID, hostname, display name.
//  Stored in ~/Library/Application Support/SYM/{name}/identity.json
//
//  Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Identity

/// Persistent node identity. Created once, reused across sessions.
public struct SymIdentity: Codable, Sendable {

    /// Unique node ID (UUID string)
    public let nodeId: String

    /// Display name
    public let name: String

    /// Machine hostname at creation time
    public let hostname: String

    /// Creation timestamp
    public let createdAt: Date
}

// MARK: - Identity Manager

/// Manages node identity persistence.
/// Each node name gets its own identity file under the SYM data directory.
enum SymIdentityManager {

    /// Load existing identity or create a new one.
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
    static func nodeDirectory(for name: String) -> URL {
        let base: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = appSupport.appendingPathComponent("SYM")
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".sym")
        }
        return base.appendingPathComponent("nodes").appendingPathComponent(name)
    }

    private static func hostname() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
}

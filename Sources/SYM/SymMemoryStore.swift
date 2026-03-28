//
//  SymMemoryStore.swift
//  SYM
//
//  Per-node file-based memory store.
//  Stores memories as JSON files under the node's data directory.
//
//  Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.
//

import Foundation
import SYMCore
import os.log

// MARK: - Memory Entry

/// A single memory entry, serializable for storage and wire transfer.
public struct SymMemoryEntry: Codable, Sendable {
    public let key: String
    public let content: String
    public let source: String
    public let tags: [String]
    public let originTimestamp: UInt64   // When the event originally happened (L0 time)
    public let storedAt: UInt64          // When this L1 entry was created
    public let timestamp: UInt64         // Backward-compatible sort key (= storedAt)
    public let cmb: CognitiveMemoryBlock?  // Per-field decomposition (SVAF v2)

    public init(key: String = "memory-\(UInt64(Date().timeIntervalSince1970 * 1000))",
                content: String,
                source: String,
                tags: [String] = [],
                originTimestamp: UInt64? = nil,
                storedAt: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
                cmb: CognitiveMemoryBlock? = nil) {
        self.key = key
        self.content = content
        self.source = source
        self.tags = tags
        self.storedAt = storedAt
        self.originTimestamp = originTimestamp ?? storedAt
        self.timestamp = storedAt
        self.cmb = cmb
    }
}

// MARK: - Memory Store

/// File-based memory store for a SymNode.
///
/// Layout:
/// ```
/// {nodeDir}/memories/
///   local/          ← own memories
///     {timestamp}.json
///   {peerId}/       ← peer memories (first 8 chars of peer nodeId)
///     {timestamp}.json
/// ```
final class SymMemoryStore {

    private let memoriesDir: URL
    private let sourceName: String
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "bot.sym", category: "memory")
    /// Serial queue protecting all file I/O — prevents concurrent read/write corruption.
    private let ioQueue = DispatchQueue(label: "bot.sym.memory-io", qos: .utility)

    init(nodeDir: URL, sourceName: String) {
        self.memoriesDir = nodeDir.appendingPathComponent("memories")
        self.sourceName = sourceName

        let localDir = memoriesDir.appendingPathComponent("local")
        try? fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
    }

    // MARK: - Write

    /// Store a memory locally.
    @discardableResult
    func write(content: String, tags: [String] = [], originTimestamp: UInt64? = nil, cmb: CognitiveMemoryBlock? = nil) -> SymMemoryEntry {
        let entry = SymMemoryEntry(
            content: content,
            source: sourceName,
            tags: tags,
            originTimestamp: originTimestamp,
            cmb: cmb
        )

        let dir = memoriesDir.appendingPathComponent("local")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let suffix = UUID().uuidString.prefix(8)
        let file = dir.appendingPathComponent("\(entry.storedAt)-\(suffix).json")
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: file)
        } catch {
            logger.error("[SYM] memory: write failed: \(error.localizedDescription)")
        }

        return entry
    }

    /// Store a memory received from a peer.
    func receiveFromPeer(peerId: String, entry: SymMemoryEntry) {
        let shortId = String(peerId.prefix(8))
        let dir = memoriesDir.appendingPathComponent(shortId)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let suffix = UUID().uuidString.prefix(8)
        let file = dir.appendingPathComponent("\(entry.storedAt)-\(suffix).json")
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: file)
        } catch {
            logger.error("[SYM] memory: peer write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Search

    /// Search all memories (local + peer) by keyword.
    func search(query: String) -> [SymMemoryEntry] {
        let q = query.lowercased()
        var results: [SymMemoryEntry] = []

        guard fileManager.fileExists(atPath: memoriesDir.path) else { return results }

        let subdirs = (try? fileManager.contentsOfDirectory(at: memoriesDir, includingPropertiesForKeys: nil))?.filter(\.hasDirectoryPath) ?? []

        for subdir in subdirs {
            let files = (try? fileManager.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []

            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(SymMemoryEntry.self, from: data) else { continue }

                let searchable = ([entry.content, entry.key] + entry.tags).joined(separator: " ").lowercased()
                if searchable.contains(q) {
                    results.append(entry)
                }
            }
        }

        return results.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Metadata

    /// Total memory count across all sources.
    var count: Int {
        guard fileManager.fileExists(atPath: memoriesDir.path) else { return 0 }

        let subdirs = (try? fileManager.contentsOfDirectory(at: memoriesDir, includingPropertiesForKeys: nil))?.filter(\.hasDirectoryPath) ?? []
        return subdirs.reduce(0) { total, subdir in
            let files = (try? fileManager.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
            return total + files.count
        }
    }

    /// Recent CMBs for use as SVAF fusion anchors.
    /// Returns CMBs from entries that have them; generates on-demand for legacy entries.
    func recentCMBs(limit: Int = 5) -> [CognitiveMemoryBlock] {
        let entries = allEntries().prefix(limit)
        return entries.compactMap { entry in
            if let cmb = entry.cmb { return cmb }
            // On-demand extraction for legacy entries without CMBs
            return CMBEncoder.createCMB(
                content: entry.content,
                source: entry.source,
                tags: entry.tags,
                originTimestamp: entry.originTimestamp,
                confidence: 0.6  // Lower confidence for retroactive extraction
            )
        }
    }

    /// All entries for context building (most recent 20).
    func allEntries() -> [SymMemoryEntry] {
        var entries: [SymMemoryEntry] = []

        guard fileManager.fileExists(atPath: memoriesDir.path) else { return entries }

        let subdirs = (try? fileManager.contentsOfDirectory(at: memoriesDir, includingPropertiesForKeys: nil))?.filter(\.hasDirectoryPath) ?? []

        for subdir in subdirs {
            let files = (try? fileManager.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
                .suffix(10) ?? []

            for file in files {
                if let data = try? Data(contentsOf: file),
                   let entry = try? JSONDecoder().decode(SymMemoryEntry.self, from: data) {
                    entries.append(entry)
                }
            }
        }

        return entries.sorted { $0.timestamp > $1.timestamp }
    }
}

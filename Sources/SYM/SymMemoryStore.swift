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

/// Alias for backward compatibility — CMBStoreEntry is the canonical type.
public typealias SymMemoryEntry = CMBStoreEntry

// MARK: - Memory Store

/// SYM's default file-based CMB store.
///
/// Layout:
/// ```
/// {nodeDir}/memories/
///   local/          ← own memories
///     {timestamp}.json
///   {peerId}/       ← peer memories (first 8 chars of peer nodeId)
///     {timestamp}.json
/// ```
final class SymMemoryStore: CMBStore, @unchecked Sendable {

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

    /// Store a CMB entry locally.
    @discardableResult
    func write(entry: CMBStoreEntry) -> CMBStoreEntry? {
        ioQueue.sync {
            let dir = memoriesDir.appendingPathComponent("local")
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

            let suffix = UUID().uuidString.prefix(8)
            let file = dir.appendingPathComponent("\(entry.storedAt)-\(suffix).json")
            do {
                let data = try JSONEncoder().encode(entry)
                try data.write(to: file)
            } catch {
                logger.error("[SYM] memory: write failed: \(error.localizedDescription)")
                return nil
            }

            return entry
        }
    }

    /// Convenience: create entry from components and write.
    @discardableResult
    func write(content: String, tags: [String] = [], originTimestamp: UInt64? = nil, cmb: CognitiveMemoryBlock? = nil) -> CMBStoreEntry {
        let entry = CMBStoreEntry(
            content: content,
            source: sourceName,
            tags: tags,
            originTimestamp: originTimestamp,
            cmb: cmb
        )
        return write(entry: entry) ?? entry
    }

    /// Store a CMB received from a peer.
    func receiveFromPeer(peerId: String, entry: CMBStoreEntry) {
        ioQueue.sync {
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
    }

    // MARK: - Search

    /// Search all memories (local + peer) by keyword.
    func search(query: String) -> [SymMemoryEntry] {
        ioQueue.sync {
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

            return results.sorted { $0.storedAt > $1.storedAt }
        }
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
            // Legacy entries without CMBs: create minimal anchor from content text
            let fields: [CMBField: CMBFieldVector] = [
                .focus: CMBEncoder.encodeField(String(entry.content.prefix(80))),
                .mood: CMBEncoder.encodeField("neutral"),
            ]
            return CMBEncoder.createCMB(
                fields: fields,
                source: entry.source,
                originTimestamp: entry.originTimestamp,
                confidence: 0.5
            )
        }
    }

    /// All entries for context building (most recent 20).
    func allEntries() -> [SymMemoryEntry] {
        ioQueue.sync {
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

            return entries.sorted { $0.storedAt > $1.storedAt }
        }
    }

    // MARK: - Retention

    /// Purge CMBs older than retention period.
    /// Preserves CMBs that are ancestors of newer CMBs (graph integrity).
    func purge(retentionSeconds: TimeInterval) {
        ioQueue.sync {
            let cutoff = UInt64((Date().timeIntervalSince1970 - retentionSeconds) * 1000)

            // Collect all ancestor keys from non-expired entries to protect graph integrity
            let allCurrent = _allEntriesUnlocked()
            var protectedKeys = Set<String>()
            for entry in allCurrent where entry.storedAt >= cutoff {
                if let ancestors = entry.cmb?.lineage?.ancestors {
                    protectedKeys.formUnion(ancestors)
                }
                if let parents = entry.cmb?.lineage?.parents {
                    protectedKeys.formUnion(parents)
                }
            }

            guard fileManager.fileExists(atPath: memoriesDir.path) else { return }
            let subdirs = (try? fileManager.contentsOfDirectory(at: memoriesDir, includingPropertiesForKeys: nil))?.filter(\.hasDirectoryPath) ?? []

            var purged = 0
            for subdir in subdirs {
                let files = (try? fileManager.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []

                for file in files {
                    guard let data = try? Data(contentsOf: file),
                          let entry = try? JSONDecoder().decode(SymMemoryEntry.self, from: data) else { continue }

                    guard entry.storedAt < cutoff else { continue }

                    // Protect CMBs referenced by newer entries' lineage
                    if let key = entry.cmb?.key, protectedKeys.contains(key) { continue }

                    try? fileManager.removeItem(at: file)
                    purged += 1
                }
            }

            if purged > 0 {
                logger.info("[SYM] memory: purged \(purged) expired CMBs (retention: \(Int(retentionSeconds))s)")
            }
        }
    }

    /// Internal unlocked variant for use within ioQueue.sync blocks (avoids deadlock).
    private func _allEntriesUnlocked() -> [SymMemoryEntry] {
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

        return entries.sorted { $0.storedAt > $1.storedAt }
    }
}

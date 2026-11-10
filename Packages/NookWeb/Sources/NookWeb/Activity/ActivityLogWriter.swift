// Licensed under GPL-3.0. See LICENSE.

import Foundation
import OSLog

/// A serial writer with a recoverable open-stretch journal. Log rows remain append-only.
public final class ActivityLogWriter: @unchecked Sendable {
    private struct Entry: Codable {
        var stretch: ActivityAccounting.Stretch
        var offset: UInt64?
        var row: Data?
    }
    private let directory: URL
    private let queue = DispatchQueue(label: "Nook.Activity", qos: .utility)
    private var entries: [UUID: Entry] = [:]
    private var pending: Set<UUID> = []
    private var needsRecovery = true
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Activity")

    public init(directory: URL) {
        self.directory = directory
        queue.async { self.perform {} }
    }

    public func write(closed: [ActivityAccounting.Stretch], open: [ActivityAccounting.Stretch]) {
        queue.async {
            self.perform {
                for stretch in closed {
                    self.entries[stretch.id] = Entry(stretch: stretch)
                    self.pending.insert(stretch.id)
                }
                // Persist pending offsets and new rows before retrying a failed append.
                try self.saveJournal()
                try self.finishPending()
                self.entries = Dictionary(uniqueKeysWithValues: open.map { ($0.id, Entry(stretch: $0)) })
                try self.saveJournal()
            }
        }
    }

    public func drain(_ completion: @escaping @Sendable () -> Void) {
        queue.async { completion() }
    }

    private var journal: URL { directory.appendingPathComponent("checkpoint.json") }

    private func perform(_ work: () throws -> Void) {
        do {
            if needsRecovery {
                try recover()
                needsRecovery = false
            }
            try work()
        }
        catch {
            log.error("Activity write failed; retaining recovery journal: \(String(describing: error), privacy: .public)")
        }
    }

    private func saveJournal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(entries.values)).write(to: journal, options: .atomic)
    }

    private func recover() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let data = try Data(contentsOf: journal)
        let saved: [Entry]
        do { saved = try JSONDecoder().decode([Entry].self, from: data) }
        catch { try setAsideJournal(); return }
        guard Set(saved.map { $0.stretch.id }).count == saved.count else { try setAsideJournal(); return }
        entries = Dictionary(uniqueKeysWithValues: saved.map { ($0.stretch.id, $0) })
        pending = Set(entries.keys)
        try finishPending()
    }

    private func finishPending() throws {
        // Repair an interrupted append before new rows choose their end-of-file offsets.
        let ordered = pending.sorted { (entries[$0]?.offset ?? .max) < (entries[$1]?.offset ?? .max) }
        for id in ordered {
            do { try append(id) }
            catch CocoaError.fileReadCorruptFile { try setAsideJournal(); return }
            pending.remove(id)
        }
    }

    private func setAsideJournal() throws {
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let aside = directory.appendingPathComponent("checkpoint-\(stamp)-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: journal, to: aside)
        entries.removeAll()
        pending.removeAll()
        log.error("Activity recovery journal set aside as \(aside.lastPathComponent, privacy: .public)")
    }

    private func completeEnd(_ handle: FileHandle) throws -> UInt64 {
        var cursor = try handle.seekToEnd()
        while cursor > 0 {
            let start = cursor > 4096 ? cursor - 4096 : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(cursor - start)) ?? Data()
            if let newline = data.lastIndex(of: 0x0a) { return start + UInt64(newline) + 1 }
            cursor = start
        }
        return 0
    }

    private func append(_ id: UUID) throws {
        guard var entry = entries[id] else { return }
        let folder = directory.appendingPathComponent("Log", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(entry.stretch.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let complete = try completeEnd(handle)
        if let offset = entry.offset {
            guard offset <= end else { throw CocoaError(.fileReadCorruptFile) }
            if offset > 0 {
                try handle.seek(toOffset: offset - 1)
                guard try handle.read(upToCount: 1) == Data([0x0a]) else { throw CocoaError(.fileReadCorruptFile) }
            }
            if entry.row == nil, offset < complete {
                // Old journals have no row bytes. Compare a completed row by its decoded value.
                try handle.seek(toOffset: offset)
                var row = Data()
                while !row.contains(0x0a) {
                    let chunk = try handle.read(upToCount: 4096) ?? Data()
                    guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    row.append(chunk)
                }
                guard let record = try? JSONDecoder().decode(ActivityRecord.self, from: row.prefix { $0 != 0x0a }),
                      record == entry.stretch.record else { throw CocoaError(.fileReadCorruptFile) }
                entries.removeValue(forKey: id)
                try saveJournal()
                return
            }
        }
        if entry.row == nil {
            var row = try JSONEncoder().encode(entry.stretch.record)
            row.append(0x0a)
            entry.row = row
            // An old partial row can be replaced safely, but never a complete line.
            if entry.offset != nil {
                guard entry.offset == complete else { throw CocoaError(.fileReadCorruptFile) }
                try handle.truncate(atOffset: complete)
                entries[id] = entry
                try saveJournal()
            }
        }
        let data = entry.row!
        guard data.last == 0x0a, data.filter({ $0 == 0x0a }).count == 1,
              let record = try? JSONDecoder().decode(ActivityRecord.self, from: data),
              record == entry.stretch.record else { throw CocoaError(.fileReadCorruptFile) }
        if entry.offset == nil {
            // Discard only an orphaned partial line before choosing the next row's offset.
            try handle.truncate(atOffset: complete)
            entry.offset = complete
            entries[id] = entry
            // Persist the exact bytes and offset before appending, including when migrating an old journal.
            try saveJournal()
        }
        let offset = entry.offset!
        try handle.seek(toOffset: offset)
        let existing = try handle.read(upToCount: data.count) ?? Data()
        if existing != data {
            guard offset == complete, data.starts(with: existing) else { throw CocoaError(.fileReadCorruptFile) }
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()
        entries.removeValue(forKey: id)
        try saveJournal()
    }
}

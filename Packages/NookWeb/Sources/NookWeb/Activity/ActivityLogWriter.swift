// Licensed under GPL-3.0. See LICENSE.

import Foundation
import OSLog

/// A serial writer with a recoverable open-stretch journal. Log rows remain append-only.
public final class ActivityLogWriter: @unchecked Sendable {
    private struct Entry: Codable {
        var stretch: ActivityAccounting.Stretch
        var offset: UInt64?
    }
    private let directory: URL
    private let queue = DispatchQueue(label: "Nook.Activity", qos: .utility)
    private var entries: [UUID: Entry] = [:]
    private var failed = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Activity")

    public init(directory: URL) {
        self.directory = directory
        queue.async { self.perform { try self.recover() } }
    }

    public func write(closed: [ActivityAccounting.Stretch], open: [ActivityAccounting.Stretch]) {
        queue.async {
            self.perform {
                for stretch in closed { self.entries[stretch.id] = Entry(stretch: stretch) }
                try self.saveJournal()
                for stretch in closed { try self.append(stretch.id) }
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
        guard !failed else { return }
        do { try work() }
        catch {
            failed = true
            log.error("Activity write failed; retaining recovery journal: \(String(describing: error), privacy: .public)")
        }
    }

    private func saveJournal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(entries.values)).write(to: journal, options: .atomic)
    }

    private func recover() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let saved = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: journal))
        entries = Dictionary(uniqueKeysWithValues: saved.map { ($0.stretch.id, $0) })
        // Repair an interrupted append before new rows choose their end-of-file offsets.
        let ordered = entries.sorted { ($0.value.offset == nil ? 1 : 0) < ($1.value.offset == nil ? 1 : 0) }
        for (id, _) in ordered { try append(id) }
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
        var data = try JSONEncoder().encode(entry.stretch.record)
        data.append(0x0a)
        if entry.offset == nil {
            entry.offset = try handle.seekToEnd()
            entries[id] = entry
            // Persist the intended offset before appending, so recovery can detect a completed write.
            try saveJournal()
        }
        let offset = entry.offset!
        try handle.seek(toOffset: offset)
        let existing = try handle.read(upToCount: data.count) ?? Data()
        if existing != data {
            guard data.starts(with: existing) else { throw CocoaError(.fileReadCorruptFile) }
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()
        entries.removeValue(forKey: id)
        try saveJournal()
    }
}

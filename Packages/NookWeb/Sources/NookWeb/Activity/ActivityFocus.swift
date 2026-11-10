// Licensed under GPL-3.0. See LICENSE.

import Foundation

public struct FocusMode: Codable, Equatable, Sendable {
    public enum OffMode: String, Codable, Sendable { case friction, block }
    public var name: String
    public var description: String
    /// Empty means any scope.
    public var allowScopes: [PageScope]
    /// Empty means any kind.
    public var allowKinds: [PageKind]
    public var offMode: OffMode
    public var blockHosts: [String]
    /// Parsed so hand edits survive; Nook does not act on it yet.
    public var forceTweaks: [String]

    public init(name: String, description: String = "", allowScopes: [PageScope] = [], allowKinds: [PageKind] = [],
                offMode: OffMode = .friction, blockHosts: [String] = [], forceTweaks: [String] = []) {
        self.name = name; self.description = description; self.allowScopes = allowScopes; self.allowKinds = allowKinds
        self.offMode = offMode; self.blockHosts = blockHosts; self.forceTweaks = forceTweaks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        allowScopes = try c.decodeIfPresent([PageScope].self, forKey: .allowScopes) ?? []
        allowKinds = try c.decodeIfPresent([PageKind].self, forKey: .allowKinds) ?? []
        offMode = (try? c.decodeIfPresent(OffMode.self, forKey: .offMode)) ?? .friction
        blockHosts = try c.decodeIfPresent([String].self, forKey: .blockHosts) ?? []
        forceTweaks = try c.decodeIfPresent([String].self, forKey: .forceTweaks) ?? []
    }

    public func isBlockedHost(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return blockHosts.contains { hostMatches(host, $0, includeSubdomains: true) }
    }
}

public struct FocusModes: Codable, Equatable, Sendable {
    public var modes: [FocusMode]

    public init(modes: [FocusMode]) { self.modes = modes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = (try c.decodeIfPresent([LenientFocusMode].self, forKey: .modes) ?? []).compactMap(\.value)
        // First of any case-insensitive duplicate wins, since modes are looked up by name.
        var seen = Set<String>()
        modes = all.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0.name.lowercased()).inserted }
    }

    public static let seed = FocusModes(modes: [
        FocusMode(name: "Focus", description: "Deep work: building and reading for work.",
                  allowScopes: [.work], allowKinds: [.building, .reading]),
        FocusMode(name: "Work", description: "Anything for work.", allowScopes: [.work]),
        FocusMode(name: "Prep", description: "Learning and preparation, for work or personal.",
                  allowScopes: [.work, .personal], allowKinds: [.reading, .building]),
    ])

    public func mode(named name: String) -> FocusMode? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return modes.first { $0.name.lowercased() == wanted }
    }
}

private struct LenientFocusMode: Decodable {
    var value: FocusMode?
    init(from decoder: Decoder) throws { value = try? FocusMode(from: decoder) }
}

public enum FocusVerdict: Equatable, Sendable {
    case allowed
    /// Covered, and "Continue anyway" is offered.
    case covered
    /// Covered with no way through: the mode blocks, or the host is in blockHosts.
    case blocked
}

/// No label, or an unsure one, lets the page through; only blockHosts ignores labels.
public func focusVerdict(for url: URL, label: ResolvedLabel?, mode: FocusMode) -> FocusVerdict {
    guard !isInternalActivityURL(url) else { return .allowed }
    if mode.isBlockedHost(url) { return .blocked }
    guard let label, !label.unsure else { return .allowed }
    let scopeFits = mode.allowScopes.isEmpty || label.scope == .either || mode.allowScopes.contains(label.scope)
    let kindFits = mode.allowKinds.isEmpty || label.kind.map(mode.allowKinds.contains) ?? true
    if scopeFits && kindFits { return .allowed }
    return mode.offMode == .block ? .blocked : .covered
}

/// One "Continue anyway", appended to Overrides/<machine>-YYYY-MM-DD.jsonl.
public struct FocusOverride: Codable, Equatable, Sendable {
    public var at: String
    public var mode: String
    public var url: String
    public var title: String
    public var reason: String

    public init(at: String, mode: String, url: String, title: String, reason: String) {
        self.at = at; self.mode = mode; self.url = url; self.title = title; self.reason = reason
    }
}

public func activityTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
    return formatter.string(from: date)
}

public func parseActivityTimestamp(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSxxx", "yyyy-MM-dd'T'HH:mm:ssxxx"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    return nil
}

/// The hand-edited files in the Activity folder. Reads never throw: a missing or broken file
/// reads as empty, so a typo in rules.json cannot stop browsing.
public struct ActivityFiles: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var rulesURL: URL { directory.appendingPathComponent("rules.json") }
    public var labelsURL: URL { directory.appendingPathComponent("labels.json") }
    public var modesURL: URL { directory.appendingPathComponent("modes.json") }
    public var overridesDirectory: URL { directory.appendingPathComponent("Overrides") }
    public var logDirectory: URL { directory.appendingPathComponent("Log") }
    public var reportsDirectory: URL { directory.appendingPathComponent("Reports") }

    /// Writes the starter rules and modes only where no file exists yet.
    public func seed() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeIfAbsent(ActivityRules.seed, to: rulesURL)
        writeIfAbsent(FocusModes.seed, to: modesURL)
    }

    private func writeIfAbsent<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        // O_EXCL so a file created between the check and the write is never replaced.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    public func loadRules() -> ActivityRules {
        (try? Data(contentsOf: rulesURL)).flatMap { try? JSONDecoder().decode(ActivityRules.self, from: $0) } ?? ActivityRules(rules: [])
    }

    public func loadModes() -> FocusModes {
        (try? Data(contentsOf: modesURL)).flatMap { try? JSONDecoder().decode(FocusModes.self, from: $0) } ?? FocusModes(modes: [])
    }

    public func loadLabels() -> [String: PageLabel] {
        (try? Data(contentsOf: labelsURL)).flatMap { try? PageLabel.decodeAll($0) } ?? [:]
    }

    public func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Adds JEV answers to labels.json. Entries already on disk win, so a manual label the owner
    /// typed meanwhile is never replaced; unknown or broken entries are kept as written.
    @discardableResult
    public func mergeJEVLabels(_ answers: [String: PageLabel]) throws -> [String: PageLabel] {
        var raw: [String: Any] = [:]
        if let data = try? Data(contentsOf: labelsURL), !data.isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Never overwrite a file the owner is halfway through editing.
                throw CocoaError(.fileReadCorruptFile)
            }
            raw = object
        }
        var added = false
        for (key, label) in answers where raw[key] == nil && label.source == .jev {
            let data = try Self.encoder.encode(label)
            raw[key] = try JSONSerialization.jsonObject(with: data)
            added = true
        }
        if added {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: labelsURL, options: .atomic)
        }
        return (try? PageLabel.decodeAll(JSONSerialization.data(withJSONObject: raw))) ?? [:]
    }

    public func appendOverride(_ line: FocusOverride, machine: String, date: Date, calendar: Calendar = .current) throws {
        let name = activityLogFileName(machine: machine, start: date, calendar: calendar)
        try FileManager.default.createDirectory(at: overridesDirectory, withIntermediateDirectories: true)
        let url = overridesDirectory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(line) + Data("\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Every override line in Overrides, from all machines, skipping lines that do not parse.
    public func loadOverrides() -> [FocusOverride] {
        jsonlFiles(in: overridesDirectory).flatMap { url -> [FocusOverride] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(FocusOverride.self, from: Data($0.utf8)) }
        }
    }

    public func jsonlFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { directory.appendingPathComponent($0) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

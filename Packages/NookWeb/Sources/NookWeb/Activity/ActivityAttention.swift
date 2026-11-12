// Licensed under GPL-3.0. See LICENSE.

import Foundation
import Darwin

public enum ActivityJudgeProvider: String, Codable, CaseIterable, Sendable {
    case openAIDecisions = "openai-decisions"
    case typeSafeJev = "typesafe-jev"
    public func makeJudge() -> any ActivityJudge {
        switch self {
        case .openAIDecisions: return OpenAIDecisionsJudge()
        case .typeSafeJev: return TypeSafeJevJudge()
        }
    }
    public var defaultModel: String {
        switch self {
        case .openAIDecisions: return "gpt-6-luna"
        case .typeSafeJev: return "jev-latest"
        }
    }
}

/// Providers supply wire formats; callers own credentials and transport.
public protocol ActivityJudge: Sendable {
    var provider: ActivityJudgeProvider { get }
    var endpoint: URL { get }
    func labelBody(url: String, title: String, profiles: [String], config: ActivityJudgeConfig) throws -> Data
    func pageLabel(from data: Data, at: String, profiles: [String], confidenceFloor: Double) -> PageLabel?
    func goalBody(url: String, title: String, goal: String, mode: String, examples: [AttentionEvent], config: ActivityJudgeConfig) throws -> Data
    func goalDecision(from data: Data, confidenceFloor: Double) -> GoalFitDecision?
    func feedBody(posts: [FeedPost], preferences: String, goal: String?, examples: [AttentionEvent], config: ActivityJudgeConfig) throws -> Data
    func feedDecisions(from data: Data, posts: [FeedPost], confidenceFloor: Double) -> [FeedPostDecision]
}

public struct ActivityJudgeConfig: Codable, Equatable, Sendable {
    public var provider: ActivityJudgeProvider = .openAIDecisions
    public var model = "gpt-6-luna"
    public var confidenceFloor = 0.6

    public init(provider: ActivityJudgeProvider = .openAIDecisions, model: String? = nil, confidenceFloor: Double = 0.6) {
        self.provider = provider; self.model = model ?? provider.defaultModel; self.confidenceFloor = min(1, max(0, confidenceFloor))
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(ActivityJudgeProvider.self, forKey: .provider)) ?? .openAIDecisions
        model = (try? c.decode(String.self, forKey: .model)).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
        confidenceFloor = min(1, max(0, (try? c.decode(Double.self, forKey: .confidenceFloor)) ?? 0.6))
    }
}

public struct FeedSitePreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var extra = ""
    public var mutedAccounts: [String] = []
    public var keywords: [String] = []
    public init(enabled: Bool = true, extra: String = "", mutedAccounts: [String] = [], keywords: [String] = []) {
        self.enabled = enabled; self.extra = extra; self.mutedAccounts = mutedAccounts; self.keywords = keywords
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        extra = (try? c.decode(String.self, forKey: .extra)) ?? ""
        mutedAccounts = (try? c.decode([String].self, forKey: .mutedAccounts)) ?? []
        keywords = (try? c.decode([String].self, forKey: .keywords)) ?? []
    }
    public func hides(_ post: FeedPost) -> Bool {
        let author = post.author.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        return mutedAccounts.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased() == author }
            || keywords.contains { !$0.isEmpty && post.text.localizedCaseInsensitiveContains($0) }
    }
}

public struct AttentionPreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var enabledAt: String?
    public var never = ""
    public var sites: [String: FeedSitePreferences] = ["x.com": .init(), "youtube.com": .init(), "reddit.com": .init()]
    public var judge = ActivityJudgeConfig()
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        enabledAt = try? c.decode(String.self, forKey: .enabledAt)
        never = (try? c.decode(String.self, forKey: .never)) ?? ""
        if let raw = try? c.decode([String: Lenient<FeedSitePreferences>].self, forKey: .sites) {
            sites = raw.compactMapValues(\.value)
        }
        judge = (try? c.decode(ActivityJudgeConfig.self, forKey: .judge)) ?? .init()
    }
}

public struct AttentionSession: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable { case start, end, `switch` }
    public var at: String
    public var event: Event
    public var session: String
    public var mode: String
    public var goal: String?
    public init(at: String, event: Event, session: String, mode: String, goal: String? = nil) {
        self.at = at; self.event = event; self.session = session; self.mode = mode; self.goal = goal
    }
}

public struct AttentionEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case cover, block, allowJudged = "allow-judged", `continue`
        case wrongBlock = "wrong-block", wrongAllow = "wrong-allow", blockSite = "block-site"
        case feedHidden = "feed-hidden", feedWrong = "feed-wrong", feedShow = "feed-show", feedMute = "feed-mute"
    }
    public enum DecidedBy: String, Codable, Sendable { case rule, judge, fixed, you }
    public var at: String
    public var session: String?
    public var mode: String?
    public var kind: Kind
    public var url: String?
    public var title: String?
    public var site: String?
    public var decidedBy: DecidedBy
    public var confidence: Double?
    public var reason: String?
    public var count: Int?
    public init(at: String, session: String? = nil, mode: String? = nil, kind: Kind, url: String? = nil,
                title: String? = nil, site: String? = nil, decidedBy: DecidedBy, confidence: Double? = nil,
                reason: String? = nil, count: Int? = nil) {
        self.at = at; self.session = session; self.mode = mode; self.kind = kind; self.url = url; self.title = title
        self.site = site; self.decidedBy = decidedBy; self.confidence = confidence; self.reason = reason; self.count = count
    }
}

extension ActivityFiles {
    public var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    public var sessionsDirectory: URL { directory.appendingPathComponent("Sessions") }
    public var eventsDirectory: URL { directory.appendingPathComponent("Events") }

    public func loadPreferences() -> AttentionPreferences {
        (try? Data(contentsOf: preferencesURL)).flatMap { try? JSONDecoder().decode(AttentionPreferences.self, from: $0) } ?? .init()
    }
    public func savePreferences(_ preferences: AttentionPreferences) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(preferences).write(to: preferencesURL, options: .atomic)
    }
    /// Merge against the current file so a mute cannot erase another site's edits or unknown fields.
    public func muteFeedAuthor(_ author: String, site: String) throws {
        guard ["x.com", "youtube.com", "reddit.com"].contains(site), !author.isEmpty else { return }
        var raw: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            let data = try Data(contentsOf: preferencesURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            raw = object
        }
        var sites = raw["sites"] as? [String: Any] ?? [:]
        var rules = sites[site] as? [String: Any] ?? [:]
        var accounts = rules["mutedAccounts"] as? [String] ?? []
        let normalized = author.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
        if !accounts.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased() == normalized }) {
            accounts.append(author)
        }
        rules["mutedAccounts"] = accounts; sites[site] = rules; raw["sites"] = sites
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: preferencesURL, options: .atomic)
    }
    public func saveModes(_ modes: FocusModes) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(modes).write(to: modesURL, options: .atomic)
    }
    public func saveRules(_ rules: ActivityRules) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(rules).write(to: rulesURL, options: .atomic)
    }
    /// Preserve unknown fields and path-specific rules when adding a site block.
    public func blockSite(host: String) throws -> ActivityRules {
        var raw: [String: Any] = [:]
        if let data = try? Data(contentsOf: rulesURL) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            raw = object
        }
        var rules = raw["rules"] as? [Any] ?? []
        rules.removeAll { value in
            guard let rule = value as? [String: Any] else { return false }
            return (rule["host"] as? String)?.lowercased() == host.lowercased() && rule["pathPrefix"] == nil
        }
        let rule = ActivityRule(host: host, handling: .block, source: .you)
        rules.insert(try JSONSerialization.jsonObject(with: Self.encoder.encode(rule)) as! [String: Any], at: 0)
        raw["rules"] = rules
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: rulesURL, options: .atomic)
        return loadRules()
    }
    public func appendSession(_ line: AttentionSession, machine: String, date: Date, calendar: Calendar = .current) throws {
        try appendLine(line, in: sessionsDirectory, machine: machine, date: date, calendar: calendar)
    }
    public func appendEvent(_ line: AttentionEvent, machine: String, date: Date, calendar: Calendar = .current) throws {
        try appendLine(line, in: eventsDirectory, machine: machine, date: date, calendar: calendar)
    }
    public func loadSessions() -> [AttentionSession] { loadLines(in: sessionsDirectory) }
    public func loadEvents() -> [AttentionEvent] { loadLines(in: eventsDirectory) }
    public func judgeExamples(limit: Int = 20) -> [AttentionEvent] {
        Array(loadEvents().filter { [.wrongBlock, .wrongAllow, .feedWrong].contains($0.kind) }
            .sorted { (parseActivityTimestamp($0.at) ?? .distantPast) > (parseActivityTimestamp($1.at) ?? .distantPast) }
            .prefix(max(0, min(20, limit))))
    }
    private func loadLines<T: Decodable>(in directory: URL) -> [T] {
        jsonlFiles(in: directory).flatMap { url -> [T] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
        }
    }
    func appendLine<T: Encodable>(_ line: T, in directory: URL, machine: String, date: Date, calendar: Calendar) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(activityLogFileName(machine: machine, start: date, calendar: calendar))
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN); try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try handle.write(contentsOf: encoder.encode(line) + Data("\n".utf8))
    }
}

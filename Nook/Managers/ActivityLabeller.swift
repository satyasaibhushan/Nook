// Licensed under GPL-3.0. See LICENSE.

import Foundation
import NookWeb
import Observation
import OSLog
import Security

/// The JEV key in the login Keychain. It is read only to make a request and never logged.
enum JEVKeychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.gstudios.nook.jev",
        kSecAttrAccount as String: "openai",
    ]

    static var hasKey: Bool { SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess }

    static func key() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8), !data.isEmpty else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Page labels for Focus and the report: manual labels and rules from the Activity folder, and
/// JEV answers remembered in labels.json.
@MainActor
@Observable
final class ActivityLabeller {
    private(set) var rules = ActivityRules(rules: [])
    private(set) var remembered: [String: PageLabel] = [:]
    private(set) var preferences = AttentionPreferences()
    private(set) var hasJudgeKey = false
    private(set) var goalRevision = 0
    private(set) var goalDecisions: [String: GoalFitDecision] = [:]
    let files: ActivityFiles

    @ObservationIgnored private var inFlight: Set<String> = []
    /// URLs JEV gave no answer for, and when; retried only after a pause so a missing key or
    /// network does not turn every navigation into a request.
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var goalAttempts: Set<String> = []
    @ObservationIgnored private var preferencesDate: Date?
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var rulesDate: Date?
    @ObservationIgnored private var labelsDate: Date?
    @ObservationIgnored private var feedCache: [String: FeedPostDecision] = [:]
    @ObservationIgnored private var feedOrder: [String] = []
    @ObservationIgnored private var feedContexts: [String: Data] = [:]
    @ObservationIgnored private var feedFailedAt: Date?
    @ObservationIgnored private let gate = JEVGate(limit: 4)
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Activity")

    init(directory: URL) {
        files = ActivityFiles(directory: directory)
    }

    /// File reads, metadata and seeding stay off the main thread.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration, files = files
        let snapshot = await Task.detached(priority: .utility) {
            files.seed()
            return (files.loadRules(), files.loadLabels(), files.loadPreferences(),
                    files.modificationDate(files.rulesURL), files.modificationDate(files.labelsURL),
                    files.modificationDate(files.preferencesURL), JEVKeychain.hasKey)
        }.value
        guard generation == reloadGeneration else { return }
        rules = snapshot.0; remembered = snapshot.1; preferences = snapshot.2
        rulesDate = snapshot.3; labelsDate = snapshot.4; preferencesDate = snapshot.5; hasJudgeKey = snapshot.6
    }

    func reloadIfChanged() async {
        let files = files
        let current = await Task.detached(priority: .utility) {
            (files.modificationDate(files.rulesURL), files.modificationDate(files.labelsURL),
             files.modificationDate(files.preferencesURL), JEVKeychain.hasKey)
        }.value
        if current.0 != rulesDate || current.1 != labelsDate || current.2 != preferencesDate { await reload() }
        else if hasJudgeKey != current.3 { hasJudgeKey = current.3 }
    }

    func goalDecision(session: String, url: URL) -> GoalFitDecision? {
        goalDecisions[goalKey(session: session, url: url)]
    }

    func needsGoalDecision(session: String, url: URL) -> Bool {
        guard hasJudgeKey, !isInternalActivityURL(url) else { return false }
        if let rule = rules.match(url), rule.handling != .judge { return false }
        return !goalAttempts.contains(goalKey(session: session, url: url))
    }

    func requestGoal(session: String, url: URL, title: String, goal: String, mode: String) async -> GoalFitDecision? {
        let cacheKey = goalKey(session: session, url: url)
        if let cached = goalDecisions[cacheKey] { return cached }
        guard needsGoalDecision(session: session, url: url) else { return nil }
        goalAttempts.insert(cacheKey)
        defer {
            if Task.isCancelled { goalAttempts.remove(cacheKey); goalRevision += 1 }
        }
        let config = preferences.judge, files = files
        let examples = await Task.detached(priority: .utility) { files.judgeExamples() }.value
        guard !Task.isCancelled, hasJudgeKey, rules.match(url).map({ $0.handling == .judge }) ?? true else { return nil }
        let judge = config.provider.makeJudge()
        guard let body = try? judge.goalBody(url: url.absoluteString, title: title, goal: goal, mode: mode,
                                            examples: examples, config: config),
              let data = await send(body: body, endpoint: judge.endpoint) else { return nil }
        guard !Task.isCancelled else { return nil }
        let answer = judge.goalDecision(from: data, confidenceFloor: config.confidenceFloor)
        goalDecisions[cacheKey] = answer
        return answer
    }

    /// Shared transport, bounded decisions, and a failure pause without a retry timer.
    func requestFeed(posts: [FeedPost], site: String, goal: String?, context: Data) async -> [FeedPostDecision] {
        let snapshot = preferences
        guard snapshot.enabled, let rules = snapshot.sites[site], rules.enabled else { return [] }
        if feedContexts[site] != context {
            feedContexts[site] = context
            let prefix = site + "|"
            feedCache = feedCache.filter { !$0.key.hasPrefix(prefix) }
            feedOrder.removeAll { $0.hasPrefix(prefix) }
        }
        let batch = FeedPostBatch(posts: Array(posts.prefix(20)), preferences: rules)
        var decisions = batch.fixed
        let remaining = batch.posts.filter { post in
            if let cached = feedCache[site + "|" + post.id] { decisions.append(cached); return false }
            return true
        }
        guard !remaining.isEmpty else { return decisions }
        let show = remaining.map { FeedPostDecision(id: $0.id, choice: .show, reason: "") }
        guard hasJudgeKey, feedFailedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return decisions + show }
        let config = snapshot.judge, files = files, judge = config.provider.makeJudge()
        await gate.wait()
        defer { Task { await gate.signal() } }
        guard preferences == snapshot, feedContexts[site] == context, !Task.isCancelled else { return decisions + show }
        let body = await Task.detached(priority: .utility) {
            let examples = files.judgeExamples().filter { $0.kind == .feedWrong && $0.site == site }
            return try? judge.feedBody(posts: remaining, preferences: [snapshot.never, rules.extra].filter { !$0.isEmpty }.joined(separator: "\n"),
                                       goal: goal, examples: examples, config: config)
        }.value
        guard preferences == snapshot, feedContexts[site] == context, hasJudgeKey, !Task.isCancelled else { return decisions + show }
        guard let body, let data = await send(body: body, endpoint: judge.endpoint) else {
            feedFailedAt = Date(); return decisions + show
        }
        guard preferences == snapshot, feedContexts[site] == context, !Task.isCancelled else { return decisions + show }
        let answers = await Task.detached(priority: .utility) {
            judge.feedDecisions(from: data, posts: remaining, confidenceFloor: config.confidenceFloor)
        }.value
        guard preferences == snapshot, feedContexts[site] == context, !Task.isCancelled else { return decisions + show }
        for answer in answers {
            let key = site + "|" + answer.id
            if feedCache[key] == nil { feedOrder.append(key) }
            feedCache[key] = answer
        }
        while feedOrder.count > 1500 { feedCache.removeValue(forKey: feedOrder.removeFirst()) }
        return decisions + answers
    }

    func invalidateFeed(site: String, id: String) {
        let key = site + "|" + id
        feedCache.removeValue(forKey: key); feedOrder.removeAll { $0 == key }
    }

    func clearGoalDecisions() { goalDecisions = [:]; goalAttempts = [] }

    private func goalKey(session: String, url: URL) -> String { session + "|" + (normalizedActivityURL(url) ?? url).absoluteString }

    func blockSite(host: String) async throws {
        let files = files
        rules = try await Task.detached(priority: .utility) { try files.blockSite(host: host) }.value
    }

    /// The label a page has now, without asking JEV. `url` must already be normalised.
    func label(for url: URL) -> ResolvedLabel? {
        resolveActivityLabel(url, rules: rules, remembered: remembered)
    }

    /// Asks JEV about one page in the background when nothing on disk decides it.
    func request(url: URL, title: String) {
        let key = url.absoluteString
        guard hasJudgeKey, activityLabelNeedsJEV(url, rules: rules, remembered: remembered), !inFlight.contains(key),
              failedAt[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        inFlight.insert(key)
        Task {
            let answer = await ask(url: key, title: title)
            inFlight.remove(key)
            guard let answer else { failedAt[key] = Date(); return }
            await remember([key: answer])
        }
    }

    /// Labels every page that has none: rules first, then JEV for the rest, a few at a time.
    /// Pages a fixed rule decides are never sent.
    func labelNow(_ pages: [(url: URL, title: String)]) async {
        await reload()
        var wanted: [String: String] = [:]
        for page in pages where activityLabelNeedsJEV(page.url, rules: rules, remembered: remembered) {
            if wanted[page.url.absoluteString]?.isEmpty != false { wanted[page.url.absoluteString] = page.title }
        }
        guard !wanted.isEmpty, hasJudgeKey else { return }
        let answers = await withTaskGroup(of: (String, PageLabel?).self) { group in
            for (url, title) in wanted {
                group.addTask { (url, await self.ask(url: url, title: title)) }
            }
            var found: [String: PageLabel] = [:]
            for await (url, label) in group { if let label { found[url] = label } }
            return found
        }
        await remember(answers)
    }

    private func remember(_ answers: [String: PageLabel]) async {
        guard !answers.isEmpty else { return }
        let files = files
        let merged = await Task.detached(priority: .utility) { () -> [String: PageLabel]? in
            do { return try files.mergeJEVLabels(answers) }
            catch {
                Self.log.error("Could not save JEV labels: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
        if let merged {
            remembered = merged
            let files = files
            labelsDate = await Task.detached(priority: .utility) { files.modificationDate(files.labelsURL) }.value
        } else {
            // labels.json is unreadable; keep the answers for this run without touching the file.
            for (key, label) in answers where remembered[key] == nil { remembered[key] = label }
        }
    }

    /// Nil on a missing key, a network failure, the timeout, a refusal or anything unexpected.
    nonisolated private func ask(url: String, title: String) async -> PageLabel? {
        await gate.wait()
        defer { Task { await gate.signal() } }
        let config = await preferences.judge
        let profiles = await knownProfiles
        let judge = config.provider.makeJudge()
        guard let body = try? judge.labelBody(url: url, title: title, profiles: profiles, config: config),
              let data = await send(body: body, endpoint: judge.endpoint) else { return nil }
        return judge.pageLabel(from: data, at: activityTimestamp(Date()), profiles: profiles, confidenceFloor: config.confidenceFloor)
    }

    /// Space names are supplied by FocusController, with legacy defaults for the report path.
    var profileNames: [String] = ["work", "personal"]
    private var knownProfiles: [String] { normalizedActivityProfiles(profileNames + rules.rules.flatMap(\.profiles)) }

    nonisolated private func send(body: Data, endpoint: URL) async -> Data? {
        guard !Task.isCancelled, let key = JEVKeychain.key() else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch { return nil }
    }

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
}

/// Caps JEV requests in flight.
private actor JEVGate {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func signal() {
        if waiting.isEmpty { available += 1 } else { waiting.removeFirst().resume() }
    }
}

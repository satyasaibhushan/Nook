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
    let files: ActivityFiles

    @ObservationIgnored private var inFlight: Set<String> = []
    /// URLs JEV gave no answer for, and when; retried only after a pause so a missing key or
    /// network does not turn every navigation into a request.
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var rulesDate: Date?
    @ObservationIgnored private var labelsDate: Date?
    @ObservationIgnored private let gate = JEVGate(limit: 4)
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Activity")

    init(directory: URL) {
        files = ActivityFiles(directory: directory)
    }

    /// Seeds the starter files once and reads rules and labels from disk.
    func reload() {
        files.seed()
        rulesDate = files.modificationDate(files.rulesURL)
        labelsDate = files.modificationDate(files.labelsURL)
        rules = files.loadRules()
        remembered = files.loadLabels()
    }

    /// Picks up hand edits; cheap enough to call every couple of seconds.
    func reloadIfChanged() {
        let newRules = files.modificationDate(files.rulesURL), newLabels = files.modificationDate(files.labelsURL)
        if newRules != rulesDate { rulesDate = newRules; rules = files.loadRules() }
        if newLabels != labelsDate { labelsDate = newLabels; remembered = files.loadLabels() }
    }

    /// The label a page has now, without asking JEV. `url` must already be normalised.
    func label(for url: URL) -> ResolvedLabel? {
        resolveActivityLabel(url, rules: rules, remembered: remembered)
    }

    /// Asks JEV about one page in the background when nothing on disk decides it.
    func request(url: URL, title: String) {
        let key = url.absoluteString
        guard activityLabelNeedsJEV(url, rules: rules, remembered: remembered), !inFlight.contains(key),
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
        reload()
        var wanted: [String: String] = [:]
        for page in pages where activityLabelNeedsJEV(page.url, rules: rules, remembered: remembered) {
            if wanted[page.url.absoluteString]?.isEmpty != false { wanted[page.url.absoluteString] = page.title }
        }
        guard !wanted.isEmpty, JEVKeychain.hasKey else { return }
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
            labelsDate = files.modificationDate(files.labelsURL)
        } else {
            // labels.json is unreadable; keep the answers for this run without touching the file.
            for (key, label) in answers where remembered[key] == nil { remembered[key] = label }
        }
    }

    /// Nil on a missing key, a network failure, the timeout, a refusal or anything unexpected.
    nonisolated private func ask(url: String, title: String) async -> PageLabel? {
        await gate.wait()
        defer { Task { await gate.signal() } }
        guard let key = JEVKeychain.key(), let body = try? ActivityJEV.requestBody(url: url, title: title) else { return nil }
        var request = URLRequest(url: ActivityJEV.endpoint, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Self.log.info("JEV gave no label: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            return ActivityJEV.label(from: data, at: activityTimestamp(Date()))
        } catch {
            Self.log.info("JEV gave no label: \((error as? URLError)?.code.rawValue ?? -1)")
            return nil
        }
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

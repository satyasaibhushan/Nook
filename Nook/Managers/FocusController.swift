// Licensed under GPL-3.0. See LICENSE.

import AppKit
import NookWeb
import NookTweaks
import Observation
import OSLog
import WebKit

/// What covers a page while a Focus mode is on.
struct FocusCover: Equatable {
    let mode: FocusMode
    let label: ResolvedLabel?
    let url: URL
    /// False in a mode that blocks, and for a host in the mode's blockHosts.
    let canContinue: Bool
    let reason: String
    let decidedBy: AttentionEvent.DecidedBy
    let confidence: Double?
}

/// The running Focus mode. Modes come from modes.json; the running one and its start live in
/// state.json so a relaunch resumes it. Pages that do not fit are covered by a native view.
@MainActor
@Observable
final class FocusController {
    private(set) var activeMode: FocusMode?
    private(set) var startedAt: Date?
    private(set) var goal: String?
    private(set) var sessionID: String?
    private(set) var modes = FocusModes(modes: [])
    let labeller: ActivityLabeller

    /// Normalised URLs let through with "Continue anyway" in this mode session.
    private var overridden: Set<String> = []
    /// Peek and mini window pages, which live outside the tab tree; their cover registers them.
    private var detached: [UUID: PageSession] = [:]
    @ObservationIgnored private var mutedByFocus: Set<UUID> = []
    @ObservationIgnored private var lastCovered: [UUID: URL] = [:]
    @ObservationIgnored private var pendingGoal: Task<Void, Never>?
    @ObservationIgnored private var pendingGoalGeneration = 0
    @ObservationIgnored private var pendingGoalKey: String?
    @ObservationIgnored private var lastVisibleDecision: String?
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var transitionGeneration = 0
    @ObservationIgnored private var fileGeneration = 0
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let recorder: ActivityRecorder
    @ObservationIgnored private let writer: ActivityLogWriter
    @ObservationIgnored private var fileMonitors: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private let tabs: TabsController
    @ObservationIgnored private let stateStore: ActivityStateStore
    @ObservationIgnored private let machine: String
    @ObservationIgnored private let queue = DispatchQueue(label: "Nook.FocusState", qos: .utility)
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Focus")

    static let refocusCover = Notification.Name("NookFocusRefocusCover")
    /// For hosts outside the main window's environment: the mini window and split panes.
    private(set) static weak var shared: FocusController?

    init(tabs: TabsController, recorder: ActivityRecorder) {
        self.tabs = tabs
        self.recorder = recorder
        stateStore = recorder.stateStore
        writer = recorder.writer
        machine = recorder.machine
        labeller = ActivityLabeller(directory: recorder.stateStore.url.deletingLastPathComponent())
        Self.shared = self
        recorder.modeProvider = { [weak self] in self?.activeMode?.name }
        recorder.sessionProvider = { [weak self] in self?.sessionID }
        let initialGeneration = transitionGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.labeller.reload()
            await self.reloadModes()
            await self.resume(generation: initialGeneration)
            self.watchFiles()
        }
        observe()
        observeFeeds()
        watchFiles()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.watchFiles(); self?.reconcileFiles(); self?.observe() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.observe() }
            })
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var result: NSEvent? = event
            MainActor.assumeIsolated { if let self { result = self.interceptKey(event) } }
            return result
        }
    }

    private func watchFiles() {
        fileGeneration += 1
        let generation = fileGeneration
        fileMonitors.forEach { $0.cancel() }; fileMonitors = []
        let files = labeller.files, queue = queue
        let paths = [files.directory, files.rulesURL, files.labelsURL, files.modesURL, files.preferencesURL]
        queue.async { [weak self] in
            let monitors = paths.compactMap { path -> DispatchSourceFileSystemObject? in
                let descriptor = open(path.path, O_EVTONLY)
                guard descriptor >= 0 else { return nil }
                let monitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
                monitor.setEventHandler { [weak self] in
                    Task { @MainActor in self?.reconcileFiles() }
                }
                monitor.setCancelHandler { close(descriptor) }
                return monitor
            }
            Task { @MainActor [weak self] in
                guard let self, self.fileGeneration == generation else {
                    monitors.forEach { $0.cancel(); $0.resume() }; return
                }
                self.fileMonitors = monitors
                monitors.forEach { $0.resume() }
            }
        }
    }

    private func reconcileFiles() {
        Task { [weak self] in
            guard let self else { return }
            await self.labeller.reloadIfChanged()
            await self.reloadModes()
            self.watchFiles()
        }
    }

    // MARK: - Modes

    func start(named name: String, goal: String? = nil) {
        transitionGeneration += 1
        let generation = transitionGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.labeller.reload()
            await self.reloadModes()
            guard generation == self.transitionGeneration, let mode = self.modes.mode(named: name) else { return }
            let trimmed = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = trimmed?.isEmpty == false ? trimmed : nil
            // Existing nook://focus/<name> links keep the running session when no goal is supplied.
            if self.activeMode?.name == mode.name, goal == nil || self.goal == goal { self.activeMode = mode; return }
            self.logSession(.switch)
            self.activate(mode, since: Date(), goal: goal, sessionID: UUID().uuidString, overrides: [])
            self.logSession(.start)
            self.persist()
        }
    }

    func end() {
        transitionGeneration += 1
        guard activeMode != nil else { persist(); return }
        recorder.flush {}
        logSession(.end)
        pendingGoal?.cancel(); pendingGoal = nil; pendingGoalKey = nil
        activeMode = nil; startedAt = nil; goal = nil; sessionID = nil; overridden = []
        labeller.clearGoalDecisions()
        persist()
    }

    private func activate(_ mode: FocusMode, since: Date, goal: String?, sessionID: String, overrides: Set<String>) {
        recorder.flush {}
        pendingGoal?.cancel(); pendingGoal = nil; pendingGoalKey = nil
        labeller.clearGoalDecisions(); lastVisibleDecision = nil
        activeMode = mode; startedAt = since; self.goal = goal; self.sessionID = sessionID; overridden = overrides
    }

    private func logSession(_ event: AttentionSession.Event) {
        guard let sessionID, let mode = activeMode else { return }
        let now = Date()
        writer.writeSession(.init(at: activityTimestamp(now), event: event, session: sessionID, mode: mode.name, goal: goal), machine: machine, date: now)
    }

    private func persist() {
        let name = activeMode?.name, started = startedAt.map { activityTimestamp($0) }, goal = goal, sessionID = sessionID
        let store = stateStore
        queue.async {
            do {
                try store.update {
                    $0["mode"] = name ?? NSNull(); $0["modeStartedAt"] = started ?? NSNull()
                    $0["goal"] = goal ?? NSNull(); $0["sessionID"] = sessionID ?? NSNull()
                }
            } catch { Self.log.error("Could not save Focus state: \(String(describing: error), privacy: .public)") }
        }
    }

    private func resume(generation: Int) async {
        guard transitionGeneration == generation else { return }
        let store = stateStore, files = labeller.files, modes = modes
        let restored = await Task.detached(priority: .utility) { () -> (FocusMode, Date, String?, String, Set<String>)? in
            guard let state = try? store.read(), let name = state["mode"] as? String else { return nil }
            let started = (state["modeStartedAt"] as? String).flatMap(parseActivityTimestamp) ?? Date()
            guard let mode = modes.mode(named: name) else {
                _ = try? store.update {
                    $0["mode"] = NSNull(); $0["modeStartedAt"] = NSNull(); $0["goal"] = NSNull(); $0["sessionID"] = NSNull()
                }
                return nil
            }
            let id = state["sessionID"] as? String ?? UUID().uuidString
            let overrides = Set(files.loadOverrides().filter {
                $0.session == id || ($0.session == nil && $0.mode == mode.name && (parseActivityTimestamp($0.at).map { $0 >= started } ?? false))
            }.map(\.url))
            return (mode, started, state["goal"] as? String, id, overrides)
        }.value
        guard transitionGeneration == generation, activeMode == nil, let restored else { return }
        activate(restored.0, since: restored.1, goal: restored.2, sessionID: restored.3, overrides: restored.4)
        persist()
    }

    private func reloadModes() async {
        let files = labeller.files
        let loaded = await Task.detached(priority: .utility) { files.loadModes() }.value
        modes = loaded
        labeller.profileNames = tabs.orderedSpaces.filter { !$0.isAgent }.map(\.name)
        if let name = activeMode?.name, let edited = modes.mode(named: name) { activeMode = edited }
    }

    // MARK: - Covering

    /// The cover for `session` now, or nil when the page may show.
    func cover(for session: PageSession) -> FocusCover? {
        guard let mode = activeMode, !session.isPrivate, !session.isAgentPage,
              let url = normalizedActivityURL(session.url), !isInternalActivityURL(url) else { return nil }
        let label = labeller.label(for: url), rule = labeller.rules.match(url)
        if overridden.contains(url.absoluteString), !mode.isBlockedHost(url), rule == nil || rule?.handling == .judge { return nil }
        let decision = sessionID.flatMap { labeller.goalDecision(session: $0, url: url) }
        // Without a key, judged pages always pass, including cached answers from earlier in the run.
        let verdict = focusVerdict(for: url, label: label, mode: mode, rule: rule, goalFit: labeller.hasJudgeKey ? decision : nil)
        guard verdict != .allowed else { return nil }
        let fixed = mode.isBlockedHost(url) || rule.map { $0.handling != .judge } == true
        let by: AttentionEvent.DecidedBy = fixed ? .rule : .judge
        let reason = by == .judge ? decision?.reason ?? "" : "This page is outside the rules for \(mode.name)."
        return FocusCover(mode: mode, label: label, url: url, canContinue: verdict == .covered && by == .judge,
                          reason: reason, decidedBy: by, confidence: by == .judge ? decision?.confidence : nil)
    }

    func register(_ session: PageSession) {
        guard session.isDetached, detached[session.itemID] == nil else { return }
        detached[session.itemID] = session
    }

    func unregister(_ session: PageSession) {
        guard detached[session.itemID] != nil else { return }
        detached[session.itemID] = nil
    }

    /// Go back, or close the page when it has no history.
    func leave(_ session: PageSession) {
        if let webView = session.webView, webView.canGoBack {
            webView.goBack()
        } else if session.isDetached {
            session.onClose?()
        } else {
            tabs.close(session.itemID, archive: false)
        }
    }

    /// "Continue anyway": the page stays uncovered for the rest of this mode session.
    func continueAnyway(_ session: PageSession, reason: String) {
        guard let mode = activeMode, let cover = cover(for: session), cover.canContinue else { return }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return }
        recordEvent(.continue, page: session, decidedBy: .you, reason: reason)
        overridden.insert(cover.url.absoluteString)
        let now = Date()
        let line = FocusOverride(at: activityTimestamp(now), mode: mode.name, url: cover.url.absoluteString,
                                 title: session.title, reason: reason, session: sessionID)
        let files = labeller.files, machine = machine
        queue.async {
            do { try files.appendOverride(line, machine: machine, date: now) }
            catch { Self.log.error("Could not save Focus override: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Records a correction without changing permanent rules or dismissing the cover.
    func wrongBlock() { if let page = activePage { wrongBlock(page) } }

    func wrongBlock(_ page: PageSession) {
        guard let cover = cover(for: page), cover.decidedBy == .judge else { return }
        recordEvent(.wrongBlock, page: page, decidedBy: .you, reason: cover.reason, confidence: cover.confidence)
    }

    func wrongAllow() { if let page = activePage { wrongAllow(page) } }

    func wrongAllow(_ page: PageSession) {
        guard activeMode != nil, !page.isPrivate, !page.isAgentPage,
              let url = normalizedActivityURL(page.url), !isInternalActivityURL(url), cover(for: page) == nil else { return }
        recordEvent(.wrongAllow, page: page, decidedBy: .you)
    }

    /// A correction from the Attention tab for a page that is not open any more. Recorded
    /// as an example event only; it never adds a permanent rule.
    @discardableResult
    func recordCorrection(kind: AttentionEvent.Kind, urlString: String, title: String?,
                          sessionID: String?, modeName: String?) -> Bool {
        guard kind == .wrongBlock || kind == .wrongAllow,
              let parsed = URL(string: urlString), let url = normalizedActivityURL(parsed),
              !isInternalActivityURL(url) else { return false }
        recorder.flush {}
        let now = Date()
        writer.writeEvent(.init(at: activityTimestamp(now), session: sessionID, mode: modeName, kind: kind,
                                url: url.absoluteString, title: title, site: url.host, decidedBy: .you),
                          machine: machine, date: now)
        return true
    }

    func blockSite(host: String) {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard let url = URL(string: "https://" + host), url.host == host, url.path.isEmpty,
              !isInternalActivityURL(url) else { return }
        let page = activePage
        let now = Date()
        let pageURL = page.flatMap { page -> String? in
            guard !page.isPrivate, !page.isAgentPage, page.url.host?.lowercased() == host else { return nil }
            return normalizedActivityURL(page.url)?.absoluteString
        }
        let line = AttentionEvent(at: activityTimestamp(now), session: sessionID, mode: activeMode?.name, kind: .blockSite,
                                  url: pageURL,
                                  site: host, decidedBy: .you)
        Task {
            do {
                try await labeller.blockSite(host: host)
                overridden = overridden.filter { URL(string: $0)?.host?.lowercased() != host }
                writer.writeEvent(line, machine: machine, date: now)
            } catch { Self.log.error("Could not block site: \(String(describing: error), privacy: .public)") }
        }
    }

    var activePage: PageSession? {
        guard NSApp.isActive else { return nil }
        if let window = tabs.allWindows.first(where: { $0.window?.isKeyWindow == true }),
           let id = window.selectedItemID { return tabs.session(for: id) }
        return detached.values.first { $0.webView?.window?.isKeyWindow == true }
    }

    private func recordEvent(_ kind: AttentionEvent.Kind, page: PageSession, decidedBy: AttentionEvent.DecidedBy,
                             reason: String? = nil, confidence: Double? = nil) {
        guard !page.isPrivate, !page.isAgentPage, let url = normalizedActivityURL(page.url), !isInternalActivityURL(url) else { return }
        // Close the accounting row at a visible decision so goal time does not straddle it.
        recorder.flush {}
        let now = Date()
        writer.writeEvent(.init(at: activityTimestamp(now), session: sessionID, mode: activeMode?.name, kind: kind,
                               url: url.absoluteString, title: page.title, site: url.host, decidedBy: decidedBy,
                               confidence: confidence, reason: reason), machine: machine, date: now)
    }

    private var watchedSessions: [PageSession] {
        tabs.sessions + detached.values.filter { candidate in !tabs.sessions.contains { $0 === candidate } }
    }

    /// Feed configuration changes independently of the active tab's navigation and title.
    private func observeFeeds() {
        withObservationTracking {
            _ = labeller.preferences; _ = labeller.hasJudgeKey
            _ = activeMode; _ = goal; _ = sessionID
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeFeeds() }
        }
        FeedFiltering.refresh()
    }

    private func observe() {
        observationGeneration += 1
        let generation = observationGeneration
        var active: PageSession?
        let covers = withObservationTracking {
            active = activePage
            _ = goal; _ = sessionID; _ = labeller.hasJudgeKey
            _ = labeller.rules; _ = labeller.goalDecisions; _ = labeller.goalRevision
            return watchedSessions.map { ($0, cover(for: $0)) }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                self.observe()
            }
        }
        apply(covers)
        scheduleGoal(for: active)
        recordVisibleDecision(for: active)
    }

    /// Side effects stay out of the tracked read so they cannot retrigger it.
    private func apply(_ covers: [(PageSession, FocusCover?)]) {
        var live = Set<UUID>()
        for (session, cover) in covers {
            live.insert(session.itemID)
            if let cover {
                if lastCovered[session.itemID] != cover.url { silence(session) }
                lastCovered[session.itemID] = cover.url
            } else {
                lastCovered[session.itemID] = nil
                if mutedByFocus.remove(session.itemID) != nil { session.setMuted(false) }
            }
        }
        for id in mutedByFocus.subtracting(live) { mutedByFocus.remove(id) }
        for id in Set(lastCovered.keys).subtracting(live) { lastCovered[id] = nil }
    }

    private func silence(_ session: PageSession) {
        session.webView?.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})",
            completionHandler: nil)
        guard !session.isAudioMuted else { return }
        session.setMuted(true)
        mutedByFocus.insert(session.itemID)
    }

    /// Only the foreground page with a goal and a key gets a settle task.
    private func scheduleGoal(for page: PageSession?) {
        guard let mode = activeMode, let goal, let sessionID, labeller.hasJudgeKey,
              let page, !page.isPrivate, !page.isAgentPage, let url = normalizedActivityURL(page.url),
              !isInternalActivityURL(url), !mode.isBlockedHost(url), !overridden.contains(url.absoluteString),
              labeller.rules.match(url).map({ $0.handling == .judge }) ?? true else {
            pendingGoal?.cancel(); pendingGoal = nil; pendingGoalKey = nil
            return
        }
        let key = sessionID + "|" + url.absoluteString + "|" + page.itemID.uuidString
        // An unrelated observation must not cancel the foreground request once it has started.
        guard pendingGoalKey != key else { return }
        pendingGoal?.cancel(); pendingGoal = nil; pendingGoalKey = nil
        guard labeller.needsGoalDecision(session: sessionID, url: url) else { return }
        pendingGoalGeneration += 1
        let generation = pendingGoalGeneration
        pendingGoalKey = key
        pendingGoal = Task { [weak self, weak page] in
            guard let self else { return }
            defer {
                if self.pendingGoalGeneration == generation, self.pendingGoalKey == key {
                    self.pendingGoal = nil; self.pendingGoalKey = nil
                    self.observe()
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let page, self.activePage === page,
                  self.sessionID == sessionID, normalizedActivityURL(page.url) == url else { return }
            _ = await self.labeller.requestGoal(session: sessionID, url: url, title: page.title, goal: goal, mode: mode.name)
        }
    }

    private func recordVisibleDecision(for page: PageSession?) {
        guard let sessionID, let page, !page.isPrivate, !page.isAgentPage,
              let url = normalizedActivityURL(page.url) else { return }
        let cover = cover(for: page)
        let decision = labeller.goalDecision(session: sessionID, url: url)
        let kind: AttentionEvent.Kind
        if let cover { kind = cover.canContinue ? .cover : .block }
        else if decision != nil, labeller.hasJudgeKey, !overridden.contains(url.absoluteString) { kind = .allowJudged }
        else { lastVisibleDecision = nil; return }
        let key = sessionID + "|" + page.itemID.uuidString + "|" + url.absoluteString + "|" + kind.rawValue
        guard lastVisibleDecision != key else { return }
        lastVisibleDecision = key
        recordEvent(kind, page: page, decidedBy: cover?.decidedBy ?? .judge, reason: cover?.reason ?? decision?.reason,
                    confidence: cover?.confidence ?? decision?.confidence)
    }

    // MARK: - Keyboard

    /// Keys aimed at a covered page never reach it. Return and Escape go back; anything else
    /// moves focus to the cover so it can be driven from the keyboard.
    private func interceptKey(_ event: NSEvent) -> NSEvent? {
        guard activeMode != nil, let window = event.window,
              var view = window.firstResponder as? NSView else { return event }
        while !(view is WKWebView), let parent = view.superview { view = parent }
        guard let webView = view as? WKWebView,
              let session = watchedSessions.first(where: { $0.webView === webView }) ?? tabs.session(for: webView),
              cover(for: session) != nil else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return event }
        switch event.keyCode {
        case 36, 76, 53: leave(session)
        default: NotificationCenter.default.post(name: Self.refocusCover, object: session)
        }
        return nil
    }
}

extension FocusController: FeedFilteringHost {
    private struct FeedConfiguration: Encodable {
        var enabled: Bool
        var judgeEnabled: Bool
        var rules: FeedSitePreferences
        var context: String
    }

    func feedConfiguration(site: String) -> Data {
        let preferences = labeller.preferences
        let rules = preferences.sites[site] ?? FeedSitePreferences(enabled: false)
        let goal = activeMode?.filterFeeds == true ? self.goal : nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let context = String(decoding: (try? encoder.encode(preferences)) ?? Data(), as: UTF8.self)
            + "|" + (activeMode?.filterFeeds == true ? sessionID ?? "" : "") + "|" + (goal ?? "")
        return (try? encoder.encode(FeedConfiguration(enabled: preferences.enabled && rules.enabled,
            judgeEnabled: labeller.hasJudgeKey, rules: rules, context: context))) ?? Data("{}".utf8)
    }

    private struct FeedMessage: Decodable {
        var type: String
        var posts: [FeedPost]?
        var post: FeedPost?
        var reason: String?
        var count: Int?
        var judgedCount: Int?
        var reasons: [String: Int]?
    }

    func handleFeedMessage(_ data: Data, site: String, url: URL) async -> Data {
        guard let message = try? JSONDecoder().decode(FeedMessage.self, from: data) else { return Data("{}".utf8) }
        if message.type == "batch" {
            let context = feedConfiguration(site: site)
            let posts = (message.posts ?? []).prefix(20).filter {
                !$0.id.isEmpty && $0.id.count <= 256 && $0.author.count <= 256 && $0.text.count <= 6000
            }
            let answers = await labeller.requestFeed(posts: Array(posts), site: site,
                goal: activeMode?.filterFeeds == true ? goal : nil, context: context)
            guard context == feedConfiguration(site: site) else { return Data("[]".utf8) }
            return (try? JSONEncoder().encode(answers)) ?? Data("[]".utf8)
        }
        let kind: AttentionEvent.Kind
        switch message.type {
        case "summary": kind = .feedHidden
        case "wrong":
            kind = .feedWrong
            if let id = message.post?.id { labeller.invalidateFeed(site: site, id: id) }
        case "show": kind = .feedShow
        case "mute":
            guard labeller.preferences.enabled, labeller.preferences.sites[site]?.enabled == true,
                  let author = message.post?.author, !author.isEmpty, author.count <= 256 else { return Data("{}".utf8) }
            let files = labeller.files
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async {
                        do { try files.muteFeedAuthor(author, site: site); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            } catch { return Data("{}".utf8) }
            await labeller.reload()
            FeedFiltering.refresh()
            kind = .feedMute
        default: return Data("{}".utf8)
        }
        let now = Date()
        let reason: String
        if kind == .feedHidden {
            guard let count = message.count, count > 0 else { return Data("{}".utf8) }
            reason = (message.reasons ?? [:]).sorted { $0.key < $1.key }.prefix(32)
                .map { "\($0.value): \($0.key.prefix(240))" }.joined(separator: "; ")
        } else {
            guard let post = message.post, !post.id.isEmpty else { return Data("{}".utf8) }
            reason = "\(post.author.prefix(256)) [\(post.id.prefix(256))]: \((message.reason ?? "").prefix(500))"
        }
        writer.writeEvent(.init(at: activityTimestamp(now), session: sessionID, mode: activeMode?.name,
            kind: kind, url: url.absoluteString, title: message.post.map { String($0.text.prefix(6000)) }, site: site,
            decidedBy: kind == .feedHidden ? ((message.judgedCount ?? 0) > 0 ? .judge : .fixed) : .you, reason: reason, count: kind == .feedHidden ? message.count : nil), machine: machine, date: now)
        return Data("{\"ok\":true}".utf8)
    }
}

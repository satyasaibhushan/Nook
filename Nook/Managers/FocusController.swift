// Licensed under GPL-3.0. See LICENSE.

import AppKit
import NookWeb
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
}

/// The running Focus mode. Modes come from modes.json; the running one and its start live in
/// state.json so a relaunch resumes it. Pages that do not fit are covered by a native view.
@MainActor
@Observable
final class FocusController {
    private(set) var activeMode: FocusMode?
    private(set) var startedAt: Date?
    private(set) var modes = FocusModes(modes: [])
    let labeller: ActivityLabeller

    /// Normalised URLs let through with "Continue anyway" in this mode session.
    private var overridden: Set<String> = []
    /// Peek and mini window pages, which live outside the tab tree; their cover registers them.
    private var detached: [UUID: PageSession] = [:]
    @ObservationIgnored private var mutedByFocus: Set<UUID> = []
    @ObservationIgnored private var lastCovered: [UUID: URL] = [:]
    @ObservationIgnored private var pendingLabels: [UUID: (url: URL, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var modesDate: Date?
    @ObservationIgnored private var timer: Timer?
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
        stateStore = recorder.stateStore
        machine = recorder.machine
        labeller = ActivityLabeller(directory: recorder.stateStore.url.deletingLastPathComponent())
        Self.shared = self
        labeller.reload()
        reloadModes()
        recorder.modeProvider = { [weak self] in self?.activeMode?.name }
        resume()
        observe()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.labeller.reloadIfChanged()
                self?.reloadModesIfChanged()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.interceptKey(event) ?? event }
        }
    }

    // MARK: - Modes

    func start(named name: String) {
        labeller.reload()
        reloadModes()
        guard let mode = modes.mode(named: name) else {
            Self.log.info("No Focus mode named \(name, privacy: .public)")
            return
        }
        // Starting the running mode again keeps its session and overrides.
        if activeMode?.name == mode.name { activeMode = mode; return }
        activate(mode, since: Date(), overrides: [])
        persist()
    }

    func end() {
        guard activeMode != nil else { return }
        activeMode = nil
        startedAt = nil
        overridden = []
        persist()
    }

    private func activate(_ mode: FocusMode, since: Date, overrides: Set<String>) {
        activeMode = mode
        startedAt = since
        overridden = overrides
    }

    private func persist() {
        let name = activeMode?.name, started = startedAt.map(activityTimestamp)
        let store = stateStore
        queue.async {
            do {
                try store.update {
                    $0["mode"] = name ?? NSNull()
                    $0["modeStartedAt"] = started ?? NSNull()
                }
            } catch {
                Self.log.error("Could not save Focus state: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Picks up the mode state.json names. A mode that no longer exists in modes.json ends.
    private func resume() {
        let store = stateStore, files = labeller.files, modes = modes
        queue.async { [weak self] in
            guard let state = try? store.read(), let name = state["mode"] as? String else { return }
            let started = (state["modeStartedAt"] as? String).flatMap(parseActivityTimestamp) ?? Date()
            guard let mode = modes.mode(named: name) else {
                _ = try? store.update { $0["mode"] = NSNull(); $0["modeStartedAt"] = NSNull() }
                return
            }
            // Overrides from before a relaunch still count for the rest of the mode session.
            let overrides = Set(files.loadOverrides().filter {
                $0.mode == mode.name && (parseActivityTimestamp($0.at).map { $0 >= started } ?? false)
            }.map(\.url))
            Task { @MainActor [weak self] in
                guard let self, self.activeMode == nil else { return }
                self.activate(mode, since: started, overrides: overrides)
            }
        }
    }

    private func reloadModes() {
        modesDate = labeller.files.modificationDate(labeller.files.modesURL)
        modes = labeller.files.loadModes()
    }

    private func reloadModesIfChanged() {
        guard labeller.files.modificationDate(labeller.files.modesURL) != modesDate else { return }
        reloadModes()
        // The running mode follows hand edits; renaming or removing it leaves it running as it was.
        if let name = activeMode?.name, let edited = modes.mode(named: name), edited.name == name { activeMode = edited }
    }

    // MARK: - Covering

    /// The cover for `session` now, or nil when the page may show.
    func cover(for session: PageSession) -> FocusCover? {
        guard let mode = activeMode, !session.isPrivate, !session.isAgentPage,
              let url = normalizedActivityURL(session.url), !isInternalActivityURL(url),
              !overridden.contains(url.absoluteString) else { return nil }
        let label = labeller.label(for: url)
        switch focusVerdict(for: url, label: label, mode: mode) {
        case .allowed: return nil
        case .covered: return FocusCover(mode: mode, label: label, url: url, canContinue: true)
        case .blocked: return FocusCover(mode: mode, label: label, url: url, canContinue: false)
        }
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
        overridden.insert(cover.url.absoluteString)
        let now = Date()
        let line = FocusOverride(at: activityTimestamp(now), mode: mode.name, url: cover.url.absoluteString,
                                 title: session.title, reason: reason)
        let files = labeller.files, machine = machine
        queue.async {
            do { try files.appendOverride(line, machine: machine, date: now) }
            catch { Self.log.error("Could not save Focus override: \(String(describing: error), privacy: .public)") }
        }
    }

    private var watchedSessions: [PageSession] {
        tabs.sessions + detached.values.filter { candidate in !tabs.sessions.contains { $0 === candidate } }
    }

    private func observe() {
        let covers = withObservationTracking {
            watchedSessions.map { ($0, cover(for: $0)) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(covers)
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
            scheduleLabel(for: session)
        }
        for id in mutedByFocus.subtracting(live) { mutedByFocus.remove(id) }
        for id in Set(lastCovered.keys).subtracting(live) { lastCovered[id] = nil }
        for (id, pending) in pendingLabels where !live.contains(id) {
            pending.task.cancel()
            pendingLabels[id] = nil
        }
    }

    private func silence(_ session: PageSession) {
        session.webView?.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})",
            completionHandler: nil)
        guard !session.isAudioMuted else { return }
        session.setMuted(true)
        mutedByFocus.insert(session.itemID)
    }

    /// While a mode is on, a page no rule decides is sent to JEV once it settles, so its title is
    /// the page's own rather than the previous one's.
    private func scheduleLabel(for session: PageSession) {
        guard activeMode != nil, !session.isPrivate, !session.isAgentPage,
              let url = normalizedActivityURL(session.url),
              activityLabelNeedsJEV(url, rules: labeller.rules, remembered: labeller.remembered) else {
            pendingLabels.removeValue(forKey: session.itemID)?.task.cancel()
            return
        }
        if pendingLabels[session.itemID]?.url == url { return }
        pendingLabels[session.itemID]?.task.cancel()
        let task = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, let session,
                  normalizedActivityURL(session.url) == url, !session.isPrivate else { return }
            self.pendingLabels[session.itemID] = nil
            self.labeller.request(url: url, title: session.title)
        }
        pendingLabels[session.itemID] = (url, task)
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

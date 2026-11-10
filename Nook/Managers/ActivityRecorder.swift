// Licensed under GPL-3.0. See LICENSE.

import AppKit
import NookSettings
import NookWeb
import Observation
import OSLog
import SystemConfiguration

@MainActor
@Observable
final class ActivityRecorder {
    var modeProvider: () -> String? = { nil }
    private(set) var recordingPaused = false
    let stateStore: ActivityStateStore
    let machine: String

    @ObservationIgnored private let tabs: TabsController
    @ObservationIgnored private let registry: WindowRegistry
    @ObservationIgnored private let settings: NookSettingsService
    @ObservationIgnored private let writer: ActivityLogWriter
    @ObservationIgnored private var accounting: ActivityAccounting
    @ObservationIgnored private let stateQueue = DispatchQueue(label: "Nook.ActivityState", qos: .utility)
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var pendingPause: Bool?
    @ObservationIgnored private var suspensionReasons: Set<String> = []
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var lastInput = Date.distantPast
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inputMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lockObservers: [NSObjectProtocol] = []
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Activity")

    init(tabs: TabsController, registry: WindowRegistry, settings: NookSettingsService) {
        self.tabs = tabs; self.registry = registry; self.settings = settings
        let directory = tabs.directory.deletingLastPathComponent().appendingPathComponent("Activity", isDirectory: true)
        stateStore = ActivityStateStore(directory: directory)
        writer = ActivityLogWriter(directory: directory)
        machine = SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
        accounting = ActivityAccounting(machine: machine)
        let store = stateStore
        stateQueue.async { [weak self] in
            do {
                let paused = try store.read()["recordingPaused"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.recordingPaused = self.pendingPause ?? paused
                    self.ready = true
                    self.observe()
                }
            } catch {
                Self.log.error("Could not load activity state: \(String(describing: error), privacy: .public)")
            }
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel
        ]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let idle = now.timeIntervalSince(self.lastInput) >= 1
                self.lastInput = now
                if idle { self.refresh() }
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.closeStretches()
                    self.refresh()
                }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, reason, asleep) in [
            (NSWorkspace.willSleepNotification, "system", true),
            (NSWorkspace.didWakeNotification, "system", false),
            (NSWorkspace.screensDidSleepNotification, "screen", true),
            (NSWorkspace.screensDidWakeNotification, "screen", false)
        ] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(reason: reason, suspended: asleep) }
            })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setSuspended(reason: "lock", suspended: locked)
                }
            })
        }
    }

    func setPaused(_ paused: Bool) {
        refresh()
        pendingPause = paused
        recordingPaused = paused
        closeStretches()
        let store = stateStore
        stateQueue.async {
            do { try store.update { $0["recordingPaused"] = paused } }
            catch { Self.log.error("Could not save recording pause: \(String(describing: error), privacy: .public)") }
        }
        refresh()
    }

    /// The termination reply waits for queued disk work without blocking the main thread.
    func finish(_ completion: @escaping @Sendable () -> Void) {
        stopping = true
        timer?.invalidate()
        closeStretches()
        stateQueue.async { [writer] in writer.drain(completion) }
    }

    /// Closes the open stretches so the log on disk covers everything up to now, then calls
    /// back once it is written. Recording carries on with fresh stretches.
    func flush(_ completion: @escaping @Sendable () -> Void) {
        closeStretches()
        refresh()
        stateQueue.async { [writer] in writer.drain(completion) }
    }

    private func observe() {
        withObservationTracking { refresh() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func setSuspended(reason: String, suspended: Bool) {
        if suspended {
            suspensionReasons.insert(reason)
            closeStretches()
        } else {
            suspensionReasons.remove(reason)
            lastInput = .distantPast
            refresh()
        }
    }

    private func closeStretches() {
        let closed = accounting.update(at: Date(), pages: [], lastInput: lastInput, mode: modeProvider())
        writer.write(closed: closed, open: [])
        lastCheckpoint = Date()
    }

    private func refresh() {
        let now = Date()
        var pages: [ActivityPage] = []
        if ready && !stopping && suspensionReasons.isEmpty && !recordingPaused && settings.recordActivity {
            let keyWindow = registry.allWindows.first { !$0.isIncognito && $0.window?.isKeyWindow == true }
            let spaces = Dictionary(uniqueKeysWithValues: tabs.orderedSpaces.map { ($0.id, $0.name) })
            for session in tabs.sessions {
                // A private session's temporary space never occurs in the persistent tree.
                guard !session.isUnloaded, let spaceID = tabs.spaceID(of: session.itemID),
                      let space = spaces[spaceID], tabs.item(session.itemID)?.isFolder == false else { continue }
                let foreground = NSApp.isActive && keyWindow?.selectedItemID == session.itemID ? keyWindow?.id : nil
                let playing = session.activityMediaPlaying
                // Accounting only counts pages in front or playing. Reading another page's URL and
                // title here would re-run this for every change a background page makes to them.
                guard foreground != nil || playing else { continue }
                pages.append(ActivityPage(id: session.itemID, url: session.url, title: session.title,
                    space: space, foregroundWindow: foreground, playingMedia: playing))
            }
        }
        let closed = accounting.update(at: now, pages: pages, lastInput: lastInput, mode: modeProvider())
        if !closed.isEmpty || now.timeIntervalSince(lastCheckpoint) >= 30 {
            writer.write(closed: closed, open: accounting.checkpoint)
            lastCheckpoint = now
        }
    }
}

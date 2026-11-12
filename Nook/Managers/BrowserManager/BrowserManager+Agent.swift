// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Agent.swift
//  Nook
//
//  Keeps DevMCP agents' pages rendering while the person looks at another space. WebKit treats
//  a page outside any window as hidden (no rendering, 1 Hz timers), so agent pages sit in a
//  browser window, in a view placed outside the window's content area: nothing draws, no
//  tracking area or click reaches them, and WebKit still counts them visible. After 30 s with
//  no call from its caller a page leaves the window, so an idle one costs what a background
//  tab does.
//

import AppKit
import WebKit
import NookWeb

extension BrowserManager {
    private static let agentIdleDelay: Duration = .seconds(30)
    /// How long after parking a caller's tabs are closed.
    private static let agentCloseDelay: Duration = .seconds(30 * 60)

    func installAgentPageHost() {
        tabs.onAgentPage = { [weak self] session in
            guard let self, let caller = self.tabs.agentCaller(owning: session.itemID),
                  !caller.isParked || caller.callsInFlight > 0 else { return }
            caller.isParked = false
            self.hostAgentPage(session)
            self.scheduleAgentIdle(caller)
        }
    }

    /// `caller`'s current page, loaded, in a window and counted as used. Nil while it has no
    /// tab; throws when the tab's page cannot be made.
    func agentWebView(for caller: AgentCaller) throws -> WKWebView? {
        guard let id = tabs.agentCurrentTab(of: caller) else { return nil }
        guard let session = tabs.ensureSession(for: id) else { throw AgentPageError.noPage }
        session.loadWebViewIfNeeded()
        guard let view = session.webView else { throw AgentPageError.noPage }
        compositorManager.markTabAccessed(id)
        caller.isParked = false
        hostAgentPage(session)
        scheduleAgentIdle(caller)
        return view
    }

    /// Puts an agent page in the active window's hidden host when no open window holds it; a
    /// window that shows the Agent space takes it from there itself. Pages stay until their
    /// caller parks, so every tab a caller used lately keeps rendering, whoever else is busy.
    func hostAgentPage(_ session: PageSession) {
        guard let view = session.webView,
              let window = windowRegistry?.mostRecentRegularWindow?.window,
              let content = window.contentView else { return }
        // Already in a window that is still open; a closed one no longer renders it.
        if let current = view.window, current === window || current.isVisible || current.isMiniaturized { return }
        let host = content.subviews.first { $0 is AgentPageHostView } ?? {
            let host = AgentPageHostView(frame: content.bounds.offsetBy(dx: -AgentPageHostView.offset, dy: 0))
            host.autoresizingMask = [.width, .height]
            host.alphaValue = 0
            // Clipped and outside the content area, so its visible rect, and every tracking area
            // in it, is empty.
            host.clipsToBounds = true
            content.addSubview(host, positioned: .below, relativeTo: nil)
            return host
        }()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }

    /// Takes `caller`'s pages out of the host once it has made no call for `agentIdleDelay`, and
    /// closes its tabs `agentCloseDelay` later unless a window shows the Agent space.
    private func scheduleAgentIdle(_ caller: AgentCaller) {
        caller.idleTask?.cancel()
        caller.idleTask = Task { @MainActor [weak self, weak caller] in
            repeat {
                try? await Task.sleep(for: Self.agentIdleDelay)
                if Task.isCancelled { return }
            } while caller?.callsInFlight ?? 0 > 0
            guard let self, let caller else { return }
            caller.isParked = true
            for id in self.tabs.agentTabs(of: caller) {
                if let view = self.tabs.session(for: id)?.webView, view.superview is AgentPageHostView {
                    view.removeFromSuperview()
                }
            }
            try? await Task.sleep(for: Self.agentCloseDelay)
            if Task.isCancelled { return }
            guard caller.callsInFlight == 0,
                  !self.tabs.regularWindows.contains(where: { $0.spaceID == self.tabs.agentSpaceID }) else { return }
            self.tabs.closeAgentTabs(of: caller)
        }
    }
}

enum AgentPageError: LocalizedError {
    case noPage
    var errorDescription: String? { "The agent's tab has no page" }
}

/// Holds agent pages out of sight: transparent, outside the content area, never the target
/// of a click.
final class AgentPageHostView: NSView {
    /// How far left of the content area the host sits; wider than any window.
    static let offset: CGFloat = 20_000
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
}

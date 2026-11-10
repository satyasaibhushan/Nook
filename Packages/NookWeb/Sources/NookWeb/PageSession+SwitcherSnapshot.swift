// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+SwitcherSnapshot.swift
//  NookWeb
//
//  The picture the Control-Tab switcher shows for a tab: taken as the window moves off it, while
//  the page is still on screen and drawn, at thumbnail size so it costs little to keep.
//

import WebKit

/// Set by the system's memory-pressure events; capture pauses for a minute after one.
@MainActor private enum SwitcherPressure {
    static var last: Date?
    static let source: DispatchSourceMemoryPressure = {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { last = Date() } }
        s.resume()
        return s
    }()
    static var isUnderPressure: Bool {
        _ = source
        return last.map { Date().timeIntervalSince($0) < 60 } ?? false
    }
}

extension PageSession {
    private static let switcherSnapshotWidth: CGFloat = 400
    /// A picture this recent of the same address still shows what the page looks like.
    private static let switcherSnapshotReuse: TimeInterval = 3

    /// Runs before the view leaves the window: WebKit draws nothing for a detached view.
    func captureSwitcherSnapshot() {
        guard !SwitcherPressure.isUnderPressure, let webView, webView.window != nil, webView.bounds.width > 0 else { return }
        let url = webView.url
        if switcherSnapshot != nil, let taken = switcherSnapshotTaken, taken.url == url,
           Date().timeIntervalSince(taken.date) < Self.switcherSnapshotReuse { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(Self.switcherSnapshotWidth))
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, _ in
            // A picture that arrives after the page unloaded would pin its memory again, and one
            // from a replaced view or an earlier address would show the wrong page.
            guard let self, let image, let webView, self.primaryWebView === webView, webView.url == url else { return }
            self.switcherSnapshot = image
            self.switcherSnapshotTaken = (Date(), url)
        }
    }
}

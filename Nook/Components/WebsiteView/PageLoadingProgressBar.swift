// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import WebKit
import NookDesign
import NookWeb
import NookUI

struct PageLoadingProgressBar: View {
    let session: PageSession?
    var inPageInset = false

    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) private var settings
    @StateObject private var observer = WebViewLoadingObserver()

    private var usesPageInset: Bool { !windowState.isSidebarVisible || settings.topBarAddressView }

    var body: some View {
        Group {
            if inPageInset == usesPageInset {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(NookDesign.Surface.fillPressed)
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.blue.opacity(0.7), .cyan.opacity(0.5)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * observer.state.progress)
                    }
                    .opacity(observer.state.isVisible ? 1 : 0)
                }
                .onChange(of: session?.webView) { _, _ in observer.attach(to: session) }
                .onChange(of: session?.loadingNavigationID) { _, _ in observer.refresh() }
                .onChange(of: session.map(ObjectIdentifier.init)) { _, _ in observer.attach(to: session) }
                .onAppear { observer.attach(to: session) }
                .onDisappear { observer.attach(to: nil) }
            }
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

@MainActor
private final class WebViewLoadingObserver: ObservableObject {
    @Published private(set) var state = LoadingProgressState()
    private weak var session: PageSession?
    private weak var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var showTask: Task<Void, Never>?

    func attach(to session: PageSession?) {
        guard session !== self.session || session?.webView !== webView else { return }
        showTask?.cancel()
        showTask = nil
        progressObservation?.invalidate()
        loadingObservation?.invalidate()
        self.session = session
        webView = session?.webView
        state = LoadingProgressState()
        guard let webView else { return }

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard self?.webView === view else { return }
                self?.refresh()
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard self?.webView === view else { return }
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        guard let session, let webView else { return }
        let navigationID = session.loadingNavigationID
        let newNavigation = state.navigationID != navigationID
        if newNavigation || !webView.isLoading {
            showTask?.cancel()
            showTask = nil
        }
        var next = state
        next.update(navigationID: navigationID, progress: webView.estimatedProgress,
                    isLoading: webView.isLoading, now: ProcessInfo.processInfo.systemUptime)
        // A new navigation resets immediately. Only forward progress in a visible load animates.
        withAnimation(!newNavigation && state.isVisible && next.isVisible ? NookDesign.Motion.quick : nil) {
            state = next
        }
        guard webView.isLoading, !state.isVisible, showTask == nil else { return }
        showTask = Task { [weak self, weak session, weak webView] in
            try? await Task.sleep(for: .seconds(LoadingProgressState.showDelay))
            guard !Task.isCancelled, let self, let session, let webView,
                  self.session === session, self.webView === webView,
                  session.loadingNavigationID == navigationID else { return }
            self.showTask = nil
            self.refresh()
        }
    }

    deinit {
        showTask?.cancel()
        progressObservation?.invalidate()
        loadingObservation?.invalidate()
    }
}

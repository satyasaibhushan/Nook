// Licensed under GPL-3.0. See LICENSE.
import Observation
import WebKit

@MainActor
@Observable
public final class WebViewLoadingObserver {
    public private(set) var state = LoadingProgressState()
    @ObservationIgnored private weak var session: PageSession?
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadingObservation: NSKeyValueObservation?
    @ObservationIgnored private var showTask: Task<Void, Never>?

    public init() {}

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
        if newNavigation || !session.isLoading || !webView.isLoading {
            showTask?.cancel()
            showTask = nil
        }
        var next = state
        next.update(navigationID: navigationID, progress: webView.estimatedProgress,
                    isLoading: session.isLoading && webView.isLoading, now: ProcessInfo.processInfo.systemUptime)
        state = next
        guard session.isLoading, webView.isLoading, !state.isVisible, showTask == nil else { return }
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

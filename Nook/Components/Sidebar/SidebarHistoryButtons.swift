// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarHistoryButtons.swift
//  Nook
//
//  Created by Maciek Bagiński on 30/07/2025.
//
import SwiftUI
import WebKit
import NookDesign
import NookWeb
import NookUI

/// Back, forward and reload in the title row, as separate icon buttons. A sidebar dragged too
/// narrow for them drops them from the row.
struct SidebarHistoryButtons: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        HStack(spacing: NookDesign.SidebarChrome.gap) {
            Button("Go Back", systemImage: "arrow.left", action: goBack)
                .disabled(!canGoBack)
                .contextMenu {
                    NavigationHistoryContextMenu(historyType: .back, windowState: windowState)
                }
            Button("Go Forward", systemImage: "arrow.right", action: goForward)
                .disabled(!canGoForward)
                .contextMenu {
                    NavigationHistoryContextMenu(historyType: .forward, windowState: windowState)
                }
            ReloadButton(session: session)
        }
        .nookSidebarIconButtons()
    }

    /// Nil while another window holds the page: its controls stay inert until Move Here.
    private var session: PageSession? {
        browserManager.tabs.controllableSession(in: windowState)
    }

    private var canGoBack: Bool { session?.canGoBackOrReturn ?? false }
    private var canGoForward: Bool { session?.canGoForward ?? false }

    /// This window's own view of the page, so a clone navigates in its window.
    private var windowWebView: WKWebView? {
        session.flatMap { browserManager.webViewCoordinator?.getWebView(for: $0.itemID, in: windowState.id) }
    }

    private func goBack() {
        session?.goBack(in: windowWebView)
    }

    private func goForward() {
        if let webView = windowWebView { webView.goForward() } else { session?.goForward() }
    }
}

/// The displayed glyph owns the action, including during the progress show delay.
struct ReloadButton: View {
    let session: PageSession?

    var body: some View {
        let showsStop = session?.loadingProgress.state.showsStopLoading(isLoading: session?.isLoading == true) == true
        Button {
            if showsStop { session?.stop() } else { session?.refresh() }
        } label: {
            Image(systemName: showsStop ? "xmark" : "arrow.clockwise")
                .contentTransition(.identity)
        }
        .accessibilityLabel(showsStop ? "Stop Loading" : "Reload")
        .animation(nil, value: showsStop)
    }
}

// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookDesign
import NookWeb

struct WebsiteLoadingIndicator: View {
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        // The row is the page's top inset, so it keeps its height when the bar draws in the
        // docked sidebar instead: an empty bar collapses its frame, and the page would lose it.
        Color.clear
            .frame(height: NookDesign.Chrome.pageInset)
            .overlay {
                PageLoadingProgressBar(session: tabs.selectedSession(in: windowState), inPageInset: true)
                    .padding(.horizontal, NookDesign.Chrome.pageInset)
            }
    }
}

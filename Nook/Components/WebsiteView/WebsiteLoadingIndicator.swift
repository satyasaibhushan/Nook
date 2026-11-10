// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookDesign
import NookWeb

struct WebsiteLoadingIndicator: View {
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        PageLoadingProgressBar(session: tabs.selectedSession(in: windowState), inPageInset: true)
            .padding(.horizontal, NookDesign.Chrome.pageInset)
            .frame(height: NookDesign.Chrome.pageInset)
    }
}

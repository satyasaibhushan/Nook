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
                            .frame(width: geo.size.width * (session?.loadingProgress.state.progress ?? 0))
                            .animation(session?.loadingProgress.state.isVisible == true ? NookDesign.Motion.quick : nil,
                                       value: session?.loadingProgress.state.progress)
                    }
                    .opacity(session?.loadingProgress.state.isVisible == true ? 1 : 0)
                }
            }
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

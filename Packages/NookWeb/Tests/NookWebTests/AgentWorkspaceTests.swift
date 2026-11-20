// Licensed under GPL-3.0. See LICENSE.
import Combine
import Foundation
import NookBlocker
import NookSettings
import NookTweaks
import Testing
import WebKit
@testable import NookWeb

@MainActor
struct AgentWorkspaceTests {
    private let blank = URL(string: "about:blank")!

    @Test(arguments: [true, false])
    func popupKeepsItsOpenerAndWebKitsInitialNavigation(hasWindow: Bool) async throws {
        let fixture = Workspace()
        defer { fixture.cleanUp() }
        let tabs = fixture.tabs
        let window = BrowserWindowState()
        if hasWindow {
            tabs.attach(window: window)
            tabs.windowRegistry.register(window)
            tabs.windowRegistry.setActive(window)
        }
        let visibleSpace = window.spaceID

        let caller = try await tabs.startAgentCaller(id: "test", name: "Test", logins: nil)
        let openerID = try #require(tabs.openAgentTab(blank, for: caller))
        let opener = try #require(tabs.session(for: openerID))
        let openerView = try #require(opener.webView)
        #expect(await opener.waitForLoad(timeout: .seconds(3), startGrace: .milliseconds(100)))

        let hasPopup = try await openerView.evaluateJavaScript("""
            window.addEventListener('message', event => {
                window.reply = event.source === window.popup && event.data;
            });
            window.popup = window.open('about:blank#oauth', 'oauth', 'width=480,height=600');
            window.popup !== null;
            """) as? Bool
        #expect(hasPopup == true)

        let popupID = try #require(tabs.agentTabs(of: caller).first { $0 != openerID })
        let popup = try #require(tabs.session(for: popupID))
        let popupView = try #require(popup.webView as? RecordingWebView)
        #expect(popupView.requests.isEmpty)
        #expect(popupView.configuration.websiteDataStore === openerView.configuration.websiteDataStore)
        #expect(popupView.configuration.userContentController !== openerView.configuration.userContentController)
        #expect(window.spaceID == visibleSpace)
        #expect(await popup.waitForLoad(timeout: .seconds(3), startGrace: .milliseconds(100)))
        #expect(popupView.url?.absoluteString == "about:blank#oauth")
        _ = try await popupView.evaluateJavaScript("window.opener.postMessage('signed-in', '*');")
        let reply = try await openerView.callAsyncJavaScript("""
            for (let i = 0; i < 50 && !window.reply; ++i) {
                await new Promise(resolve => setTimeout(resolve, 20));
            }
            return window.reply;
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(reply == "signed-in")

        _ = try? await popupView.evaluateJavaScript("window.close();")
        let deadline = ContinuousClock.now + .seconds(2)
        while tabs.session(for: popupID) != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tabs.agentTabs(of: caller) == [openerID])
        #expect(tabs.agentCurrentTab(of: caller) == openerID)
    }
}

@MainActor
private final class Workspace: WebViewProvider, PageSessionDelegate {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceID = UUID()
    let tabs: TabsController

    init() {
        let settings = NookSettingsService()
        tabs = TabsController(settings: settings, windowRegistry: WindowRegistry(),
                              blocker: ContentBlockerManager(settings: settings),
                              sponsorBlock: SponsorBlockManager(settings: settings),
                              siteRouting: SiteRoutingManager(settings: settings),
                              legacyProfiles: [(sourceID, "Source")], directory: directory)
        tabs.webViews = self
        tabs.sessionDelegate = self
    }

    func cleanUp() {
        for id in Array(tabs.agentCallers.keys) { tabs.endAgentCaller(id) }
        try? FileManager.default.removeItem(at: directory)
    }

    func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        return RecordingWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }
    func webView(for itemID: UUID, in windowID: UUID) -> WKWebView? { nil }
    func allWebViews(for itemID: UUID) -> [WKWebView] { [] }
    func releaseWebViews(for session: PageSession) {}
    func removeFromContainers(_ webView: WKWebView) {}

    var currentProfile: Profile? { nil }
    var currentProfilePublisher: AnyPublisher<Profile?, Never> { Empty().eraseToAnyPublisher() }
    func navigateAcrossWindows(_ itemID: UUID, to url: URL) {}
    func windowSpaceChanged(_ window: BrowserWindowState) {}
    func addDownload(_ download: WKDownload, originalURL: URL, suggestedFilename: String) {}
    func saveFile(_ data: Data, suggestedFilename: String, originalURL: URL, from webView: WKWebView) {}
    func toggleFullScreen(for webView: WKWebView) -> Bool { false }
    func presentPeek(url: URL, from session: PageSession) {}
    func presentPopupWindow(_ session: PageSession) { Issue.record("Agent popups stay in the workspace") }
    func handleAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge, for session: PageSession,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool { false }
    func loadZoom(for itemID: UUID) {}
    func setMuteState(_ muted: Bool, for itemID: UUID) {}
    func requestPictureInPicture(for session: PageSession, webView: WKWebView?) {}
    func configureShortcutDetection(in webView: WKWebView) {}
    func shortcutDetectorDidNavigate(to url: URL) {}
    func updateDetectedShortcuts(for url: String, shortcuts: Set<String>) {}
    func installWebStoreScript(in webView: WKWebView) -> AnyObject? { nil }
    func removeWebStoreHandler(from controller: WKUserContentController) {}
}

private final class RecordingWebView: WKWebView {
    private(set) var requests: [URLRequest] = []

    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        return super.load(request)
    }
}

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

    enum WindowMode: CaseIterable {
        case noWindow, otherSpace, agentSpace, collapsedAgentSpace
    }

    @Test(arguments: WindowMode.allCases)
    func popupKeepsItsOpenerAndWebKitsInitialNavigation(mode: WindowMode) async throws {
        let fixture = Workspace()
        defer { fixture.cleanUp() }
        let tabs = fixture.tabs
        let window = BrowserWindowState()
        if mode != .noWindow {
            tabs.attach(window: window)
            tabs.windowRegistry.register(window)
            tabs.windowRegistry.setActive(window)
        }
        let caller = try tabs.startAgentCaller(id: "test", name: "Test", logins: nil)
        let agentSpace = try #require(tabs.agentSpaceID)
        if mode == .agentSpace || mode == .collapsedAgentSpace {
            tabs.setSpace(agentSpace, in: window)
        }
        let visibleSpace = window.spaceID
        let firstID = try #require(await tabs.openAgentTab(blank, for: caller))
        let openerID = try #require(await tabs.openAgentTab(blank, for: caller))
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

        let popupID = try #require(tabs.agentCurrentTab(of: caller))
        #expect(tabs.agentTabs(of: caller) == [firstID, openerID, popupID])
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

        if mode == .collapsedAgentSpace {
            tabs.toggleFolder(caller.folderID)
            #expect(tabs.displayOrder(in: window).isEmpty)
            #expect(window.selectedItemID == popupID)
        }
        _ = try? await popupView.evaluateJavaScript("window.close();")
        let deadline = ContinuousClock.now + .seconds(2)
        while tabs.session(for: popupID) != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tabs.agentTabs(of: caller) == [firstID, openerID])
        #expect(tabs.agentCurrentTab(of: caller) == openerID)
        if mode == .otherSpace { tabs.setSpace(agentSpace, in: window) }
        if mode != .noWindow { #expect(window.selectedItemID == openerID) }
    }

    @Test func emptyWorkspaceRecopiesTheSourceCookiesOnNextOpen() async throws {
        let fixture = Workspace()
        defer { fixture.cleanUp() }
        let tabs = fixture.tabs
        let space = try #require(tabs.tree.orderedSpaces.first)
        let source = try #require(tabs.profile(forSpace: space.id))
        defer { fixture.removeSourceStore() }
        let sourceCookies = source.dataStore.httpCookieStore
        await sourceCookies.setCookie(cookie("session", "first"))
        await sourceCookies.setCookie(cookie("removed", "first"))

        let caller = try tabs.startAgentCaller(id: "test", name: "Test", logins: space.name)
        _ = try #require(await tabs.openAgentTab(blank, for: caller))
        let firstStore = caller.profile.dataStore
        let firstCookies = firstStore.httpCookieStore
        #expect(await values(firstCookies) == ["session": "first", "removed": "first"])

        await sourceCookies.setCookie(cookie("session", "second"))
        await sourceCookies.deleteCookie(cookie("removed", "first"))
        await firstCookies.setCookie(cookie("session", "agent"))
        await firstCookies.setCookie(cookie("agent-only", "agent"))
        _ = try #require(await tabs.openAgentTab(blank, for: caller, name: "second"))
        #expect(caller.profile.dataStore === firstStore)
        #expect(await values(firstCookies)["session"] == "agent")
        #expect(await values(sourceCookies) == ["session": "second"])

        tabs.closeAgentTabs(of: caller)
        async let firstOpen = tabs.openAgentTab(blank, for: caller, name: "reopened")
        async let secondOpen = tabs.openAgentTab(blank, for: caller, name: "parallel")
        let (firstID, secondID) = try await (firstOpen, secondOpen)
        let refreshedStore = caller.profile.dataStore
        #expect(refreshedStore !== firstStore)
        #expect(await values(refreshedStore.httpCookieStore) == ["session": "second"])
        for id in [try #require(firstID), try #require(secondID)] {
            let view = try #require(tabs.session(for: id)?.webView)
            #expect(view.configuration.websiteDataStore === refreshedStore)
        }
    }

    @Test func nativeClickPreflightExplainsObscuredAndDisabledTargets() async throws {
        let fixture = Workspace()
        defer { fixture.cleanUp() }
        let tabs = fixture.tabs
        let caller = try tabs.startAgentCaller(id: "test", name: "Test", logins: nil)
        let id = try #require(await tabs.openAgentTab(blank, for: caller))
        let page = try #require(tabs.session(for: id))
        let view = try #require(page.webView)
        #expect(await page.waitForLoad(timeout: .seconds(3), startGrace: .milliseconds(100)))
        _ = try await view.evaluateJavaScript("""
            document.body.innerHTML =
              '<button id="covered">Continue</button>' +
              '<div style="position:fixed;inset:0;z-index:1" aria-label="Overlay"></div>' +
              '<fieldset disabled><button id="disabled">Submit</button></fieldset>';
            """)

        let covered = try await page.agentScript("return __nookAgent.locate({ selector: '#covered' })") as? [String: Any]
        #expect((covered?["covered"] as? String)?.contains("Overlay") == true)
        let disabled = try await page.agentScript("return __nookAgent.locate({ selector: '#disabled' })") as? [String: Any]
        #expect(disabled?["disabled"] as? Bool == true)
    }

    private func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: "workspace.example", .path: "/"])!
    }

    private func values(_ store: WKHTTPCookieStore) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: await store.allCookies().map { ($0.name, $0.value) })
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

    func removeSourceStore() {
        tabs.forgetProfile(sourceID)
        WKWebsiteDataStore.remove(forIdentifier: sourceID) { _ in }
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

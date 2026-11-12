// Licensed under GPL-3.0. See LICENSE.

import Foundation
import NookBlocker
import WebKit

/// The app owns preferences, credentials, transport and event storage.
@MainActor
public protocol FeedFilteringHost: AnyObject {
    func feedConfiguration(site: String) -> Data
    func handleFeedMessage(_ data: Data, site: String, url: URL) async -> Data
}

@MainActor
public enum FeedFiltering {
    public static weak var host: (any FeedFilteringHost)?
    private static let marker = "// Nook Feed Filtering"
    private static let world = WKContentWorld.world(name: "NookFeedFiltering")
    private static let handlerName = "nookFeed"
    private static let views = NSHashTable<WKWebView>.weakObjects()
    private static var source: String?
    private final class PageSummary: NSObject {
        let id: String
        let site: String
        let url: URL
        var data: Data?
        var closed = false
        init(id: String, site: String, url: URL) { self.id = id; self.site = site; self.url = url }
    }
    private static let summaries = NSMapTable<WKWebView, PageSummary>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// Bundle I/O stays off the navigation callback and the main thread.
    public static func prepare() async {
        let loaded = await Task.detached(priority: .utility) {
            guard let url = Bundle.module.url(forResource: "feed-filter", withExtension: "js", subdirectory: "Resources") else { return Optional<String>.none }
            return try? String(contentsOf: url, encoding: .utf8)
        }.value
        source = loaded
        for view in views.allObjects {
            guard let url = view.url, FeedFilterHosts.site(for: url) != nil else { continue }
            apply(for: url, in: view)
            if let source { view.evaluateJavaScript(source, in: nil, in: world, completionHandler: nil) }
        }
    }

    /// Called for main-frame actions and responses, including cross-host redirects. Unlike
    /// the older tweaks, this script is removed before navigation to any other host.
    public static func apply(for url: URL, in view: WKWebView, allowed: Bool = true) {
        let site = allowed ? FeedFilterHosts.site(for: url) : nil
        if site != nil { views.add(view) } else { views.remove(view) }
        let ucc = view.configuration.userContentController
        let scripts = ucc.userScripts
        let installed = scripts.contains { $0.source.hasPrefix(marker) }
        let wanted = site != nil && source != nil && host != nil
        guard installed != wanted else { return }
        let others = scripts.nookOwned.filter { !$0.source.hasPrefix(marker) }
        ucc.removeAllUserScripts()
        others.forEach { ucc.addUserScript($0) }
        ucc.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        guard wanted, let source else { return }
        ucc.addScriptMessageHandler(Handler.shared, contentWorld: world, name: handlerName)
        ucc.addUserScript(WKUserScript(source: "\(marker)\n\(source)", injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true, in: world))
    }

    /// Called from the existing preference/session observation, never a polling timer.
    public static func refresh() {
        for view in views.allObjects {
            guard let url = view.url, let site = FeedFilterHosts.site(for: url), let host,
                  let config = try? JSONSerialization.jsonObject(with: host.feedConfiguration(site: site)) else { continue }
            view.callAsyncJavaScript("globalThis.nookFeedFilter?.configure(config)", arguments: ["config": config],
                                     in: nil, in: world, completionHandler: nil)
        }
    }

    /// Native snapshots survive handler removal on cross-host navigation and tab teardown.
    public static func flush(in view: WKWebView) {
        guard let summary = summaries.object(forKey: view), !summary.closed else { return }
        summary.closed = true
        guard let data = summary.data, let host else { return }
        Task { _ = await host.handleFeedMessage(data, site: summary.site, url: summary.url) }
    }

    public static func detach(in view: WKWebView) {
        flush(in: view)
        summaries.removeObject(forKey: view); views.remove(view)
        view.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
    }

    public static func pageChanged(in view: WKWebView) {
        guard views.contains(view) else { return }
        if summaries.object(forKey: view)?.url != view.url { flush(in: view) }
        view.evaluateJavaScript("globalThis.nookFeedFilter?.navigate()", in: nil, in: world, completionHandler: nil)
    }

    private final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Handler()
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, let view = message.webView, views.contains(view),
                  let url = message.frameInfo.request.url, let site = FeedFilterHosts.site(for: url),
                  FeedFilterHosts.site(for: view.url ?? url) == site, let host = FeedFiltering.host,
                  let body = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 160_000 else {
                replyHandler([:], nil); return
            }
            let page = (body["page"] as? String).flatMap(URL.init(string:))
            let eventURL = page.flatMap { FeedFilterHosts.site(for: $0) == site ? $0 : nil } ?? url
            guard let pageID = body["pageID"] as? String, pageID.count <= 64 else { replyHandler([:], nil); return }
            let type = body["type"] as? String
            if type == "config" {
                if summaries.object(forKey: view)?.id != pageID {
                    flush(in: view)
                    summaries.setObject(PageSummary(id: pageID, site: site, url: eventURL), forKey: view)
                }
                replyHandler((try? JSONSerialization.jsonObject(with: host.feedConfiguration(site: site))) ?? [:], nil)
                return
            }
            guard let summary = summaries.object(forKey: view), summary.id == pageID, !summary.closed else {
                replyHandler([:], nil); return
            }
            if type == "hidden" || type == "summary" {
                var snapshot = body
                snapshot["type"] = "summary"
                summary.data = try? JSONSerialization.data(withJSONObject: snapshot)
                if type == "summary" { flush(in: view) }
                replyHandler(["ok": true], nil); return
            }
            Task {
                let reply = await host.handleFeedMessage(data, site: site, url: eventURL)
                replyHandler((try? JSONSerialization.jsonObject(with: reply)) ?? [:], nil)
            }
        }
    }
}

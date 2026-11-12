// Licensed under GPL-3.0. See LICENSE.
//
//  AttentionPage.swift
//  NookWeb
//
//  The Attention tab lives at nook://attention. It is Nook's own page: never judged by
//  Focus and never counted in activity time, since neither path takes a non-http scheme.
//

import Foundation
import WebKit

/// True for the Attention page and its section deep links, and nothing else on the scheme.
public func isAttentionPageURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "nook", url.host?.lowercased() == "attention",
          url.user == nil, url.password == nil, url.port == nil else { return false }
    switch url.path.lowercased() {
    case "", "/", "/activity", "/focus": return true
    default: return false
    }
}

/// The Attention tab's address; "activity" deep links to the Activity section.
public func attentionPageURL(section: String? = nil) -> URL {
    switch section {
    case "activity": return URL(string: "nook://attention/activity")!
    case "focus": return URL(string: "nook://attention/focus")!
    default: return URL(string: "nook://attention")!
    }
}

/// Serves the bundled Attention page for nook://attention loads. Registered for the whole
/// "nook" scheme, it answers only Attention URLs; launcher commands on the scheme never
/// reach a web view, and other nook addresses fail here. The page is read from the bundle
/// on first use, so a browser that never opens the tab never pays for it.
public final class AttentionSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let shared = AttentionSchemeHandler()

    public static let pageData: Data? = {
        guard let url = Bundle.module.url(forResource: "attention", withExtension: "html", subdirectory: "Resources")
        else { return nil }
        return try? Data(contentsOf: url)
    }()

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url, request.httpMethod == "GET", isAttentionPageURL(url),
              let data = Self.pageData else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html",
                                             expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

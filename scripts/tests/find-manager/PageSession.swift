// Licensed under GPL-3.0. See LICENSE.
import Foundation

// A controllable callback boundary for the app's FindManager, without creating a web view.
@MainActor public final class PageSession {
    public typealias FindResult = Result<(matchCount: Int, currentIndex: Int), Error>
    public typealias FindCompletion = @Sendable (FindResult) -> Void
    public var callbacks: [FindCompletion] = []
    public var loadingNavigationID = UUID()
    public var webView: NSObject? = NSObject()
    public init() {}
    public func clearFindInPage() {}
    public func findInPage(_ text: String, completion: @escaping FindCompletion) { callbacks.append(completion) }
    public func findNextInPage(completion: @escaping FindCompletion) { callbacks.append(completion) }
    public func findPreviousInPage(completion: @escaping FindCompletion) { callbacks.append(completion) }
}

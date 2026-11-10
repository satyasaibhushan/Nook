// Licensed under GPL-3.0. See LICENSE.
//
//  InWindowFullscreen+macOS.swift
//  NookWeb
//
//  Element fullscreen that fills the web view where it sits, as Chrome's does, in place of
//  WebKit's own window on a new Space.
//
//  WebKit hands a page's fullscreen request to a presenter. The default one moves the web view
//  into a separate window; WebKit lets an embedder replace it, which is the only way to keep
//  the page in place. The page still goes through real fullscreen: `fullscreenElement`,
//  `:fullscreen`, `fullscreenchange` and `WKWebView.fullscreenState` all behave as usual, and
//  the element is laid out to the web view's bounds. Making the web view fill the window is the
//  app's part.
//

#if os(macOS)
import ObjectiveC
import WebKit

extension WKWebView {
    /// Whether this view presents element fullscreen in place. False means WebKit's own window.
    public var presentsFullscreenInWindow: Bool {
        objc_getAssociatedObject(self, &InWindowFullscreen.stateKey) as? Bool ?? false
    }

    /// Chooses who presents this view's element fullscreen. Left as it is while the page is
    /// fullscreen (the presenter that entered has to be the one that exits) and on a WebKit
    /// whose presenter interface is not the one this file speaks.
    @MainActor
    public func setPresentsFullscreenInWindow(_ inWindow: Bool) {
        guard inWindow != presentsFullscreenInWindow, fullscreenState == .notInFullscreen else { return }
        guard InWindowFullscreen.setPresenter(inWindow: inWindow, on: self) else { return }
        objc_setAssociatedObject(self, &InWindowFullscreen.stateKey, inWindow, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private enum InWindowFullscreen {
    nonisolated(unsafe) static var stateKey: UInt8 = 0

    /// WebKit's handle for a step it waits on; the step continues once it is completed.
    private typealias CompleteListener = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Void
    private typealias SetClient = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Void
    private typealias PageRef = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?

    private typealias WillEnter = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> Void
    private typealias BeganEnter = @convention(c) (UnsafeRawPointer, CGRect, CGRect, UnsafeRawPointer?) -> Void
    private typealias Exit = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Void
    private typealias BeganExit = @convention(c) (UnsafeRawPointer, CGRect, CGRect, UnsafeRawPointer, UnsafeRawPointer?) -> Void

    private static let completeListener: CompleteListener? = symbol("WKCompletionListenerComplete")
    private static let setClient: SetClient? = symbol("WKPageSetFullScreenClientForTesting")

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(dlopen(nil, RTLD_LAZY), name).map { unsafeBitCast($0, to: T.self) }
    }

    // The presenter has nothing to move or animate: the web view already sits where the page
    // goes. WebKit only waits for the two steps that carry a listener.
    private static let willEnter: WillEnter = { _, listener, _ in completeListener?(listener, nil) }
    private static let beganEnter: BeganEnter = { _, _, _, _ in }
    private static let exit: Exit = { _, _ in }
    private static let beganExit: BeganExit = { _, _, _, listener, _ in completeListener?(listener, nil) }

    /// WKPageFullScreenClientV0: `{ int version; const void* clientInfo; }` and the four
    /// callbacks. WebKit copies it, so it only has to live through the call.
    private static func withClient(_ body: (UnsafeRawPointer) -> Void) {
        let pointer = MemoryLayout<UnsafeRawPointer>.stride
        let client = UnsafeMutableRawPointer.allocate(byteCount: pointer * 6, alignment: pointer)
        defer { client.deallocate() }
        client.initializeMemory(as: UInt8.self, repeating: 0, count: pointer * 6)
        client.storeBytes(of: 0, as: Int32.self)
        client.storeBytes(of: willEnter, toByteOffset: pointer * 2, as: WillEnter.self)
        client.storeBytes(of: beganEnter, toByteOffset: pointer * 3, as: BeganEnter.self)
        client.storeBytes(of: exit, toByteOffset: pointer * 4, as: Exit.self)
        client.storeBytes(of: beganExit, toByteOffset: pointer * 5, as: BeganExit.self)
        body(client)
    }

    /// False when this WebKit cannot take the presenter, which leaves fullscreen as it was.
    @MainActor
    static func setPresenter(inWindow: Bool, on webView: WKWebView) -> Bool {
        // The callbacks took these arguments from Safari 26 on. Older ones differ and the
        // struct carries no version for them, so an older WebKit keeps its own window.
        guard #available(macOS 26.0, *) else { return false }
        let pageSelector = NSSelectorFromString("_pageRefForTransitionToWKWebView")
        guard let setClient, completeListener != nil,
              webView.responds(to: pageSelector),
              let implementation = webView.method(for: pageSelector),
              let page = unsafeBitCast(implementation, to: PageRef.self)(webView, pageSelector)
        else { return false }

        if inWindow {
            withClient { setClient(page, $0) }
        } else {
            // No client puts WebKit's own presenter back.
            setClient(page, nil)
        }
        return true
    }
}
#endif

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
import AppKit
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

    private typealias Retain = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void

    private static let completeListener: CompleteListener? = symbol("WKCompletionListenerComplete")
    private static let retain: Retain? = symbol("WKRetain")
    private static let release: Release? = symbol("WKRelease")
    private static let setClient: SetClient? = symbol("WKPageSetFullScreenClientForTesting")

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(dlopen(nil, RTLD_LAZY), name).map { unsafeBitCast($0, to: T.self) }
    }

    // The presenter has nothing to move or animate: the web view already sits where the page
    // goes. WebKit only waits for the two steps that carry a listener.
    private static let willEnter: WillEnter = { _, listener, _ in completeListener?(listener, nil) }
    private static let beganEnter: BeganEnter = { _, _, _, _ in }
    private static let exit: Exit = { _, _ in }
    // The page stays fullscreen until this step is completed, and the app gives the view its
    // smaller frame only after that. A busy page takes many frames to draw at the new size,
    // showing its fullscreen picture cropped meanwhile, so that picture is held over the view
    // first, as WebKit's own presenter holds one over its window.
    private static let beganExit: BeganExit = { _, _, _, listener, info in
        guard let info, let retain, let release, retain(listener) != nil else {
            completeListener?(listener, nil)
            return
        }
        let step = HeldStep(listener: listener, release: release)
        MainActor.assumeIsolated {
            guard let webView = Unmanaged<WebViewRef>.fromOpaque(info).takeUnretainedValue().webView else {
                return step.finish()
            }
            FullscreenExitCover.hold(over: webView) { step.finish() }
        }
    }

    /// A step WebKit waits on, kept alive until the cover is up.
    private struct HeldStep: @unchecked Sendable {
        let listener: UnsafeRawPointer
        let release: Release

        func finish() {
            completeListener?(listener, nil)
            release(listener)
        }
    }

    /// What the callbacks get as their client info. The web view owns it, so it lives as long
    /// as the page that calls back.
    private final class WebViewRef {
        weak var webView: WKWebView?
        init(_ webView: WKWebView) { self.webView = webView }
    }

    nonisolated(unsafe) private static var refKey: UInt8 = 0

    /// WKPageFullScreenClientV0: `{ int version; const void* clientInfo; }` and the four
    /// callbacks. WebKit copies it, so it only has to live through the call.
    private static func withClient(info: UnsafeRawPointer, _ body: (UnsafeRawPointer) -> Void) {
        let pointer = MemoryLayout<UnsafeRawPointer>.stride
        let client = UnsafeMutableRawPointer.allocate(byteCount: pointer * 6, alignment: pointer)
        defer { client.deallocate() }
        client.initializeMemory(as: UInt8.self, repeating: 0, count: pointer * 6)
        client.storeBytes(of: 0, as: Int32.self)
        client.storeBytes(of: info, toByteOffset: pointer, as: UnsafeRawPointer.self)
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
            let ref = WebViewRef(webView)
            objc_setAssociatedObject(webView, &refKey, ref, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            withClient(info: UnsafeRawPointer(Unmanaged.passUnretained(ref).toOpaque())) { setClient(page, $0) }
        } else {
            // No client puts WebKit's own presenter back.
            setClient(page, nil)
        }
        return true
    }
}

/// The page's last fullscreen picture, laid over it from the moment it leaves fullscreen until
/// it has drawn at the frame the app gives it back.
@MainActor
private final class FullscreenExitCover {
    private let view: NSImageView
    private weak var webView: WKWebView?
    private var frameObserver: NSObjectProtocol?
    private var removed = false

    static func hold(over webView: WKWebView, then proceed: @escaping @MainActor () -> Void) {
        guard let host = webView.window?.contentView else { return proceed() }
        webView.takeSnapshot(with: nil) { [weak webView] image, _ in
            defer { proceed() }
            guard let image, let webView, webView.window?.contentView === host else { return }
            FullscreenExitCover(image, over: webView, in: host).waitForRedraw()
        }
    }

    private init(_ image: NSImage, over webView: WKWebView, in host: NSView) {
        view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        view.frame = host.convert(webView.bounds, from: webView)
        self.webView = webView
        host.addSubview(view)
    }

    private func waitForRedraw() {
        // The frame change is the app putting its chrome back. A page whose frame is the same
        // either way never sends one, and no page may keep the cover for long.
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: webView, queue: .main
        ) { [self] _ in MainActor.assumeIsolated { removeAfterNextDraw() } }
        Task { [self] in
            try? await Task.sleep(for: .milliseconds(120))
            removeAfterNextDraw()
            try? await Task.sleep(for: .milliseconds(500))
            remove()
        }
    }

    private func removeAfterNextDraw() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard let webView, webView.responds(to: selector) else { return remove() }
        let done: @convention(block) () -> Void = { [self] in MainActor.assumeIsolated { remove() } }
        webView.perform(selector, with: done)
    }

    private func remove() {
        guard !removed else { return }
        removed = true
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        view.removeFromSuperview()
    }
}
#endif

// Licensed under GPL-3.0. See LICENSE.
//
//  FullscreenZoom+macOS.swift
//  NookWeb
//
//  The zoom between a page and its in-window fullscreen.
//
//  Going either way the app flips its chrome, the web view changes size and the page relays
//  itself out, which takes a busy page a few hundred milliseconds of half-finished pictures.
//  The zoom covers the window with pictures of how it looked and moves those instead: the
//  window as it was zooms in on the element going fullscreen, and coming back the fullscreen
//  picture shrinks into the element's place in that same earlier picture. The live page is
//  faded back in once it has drawn. The pictures come from the window server, which hands
//  over what is already on screen in about a millisecond, so nothing waits on the page.
//

#if os(macOS)
import AppKit
import OSLog
import WebKit

@MainActor
final class FullscreenZoom {
    private static let duration: CFTimeInterval = 0.2
    private static let fade: CFTimeInterval = 0.1
    /// Nothing may leave the cover up if WebKit drops a step.
    private static let limit: TimeInterval = 1.2

    /// How the window looked before the page went fullscreen, and where the element sat.
    private struct Origin {
        let picture: CGImage
        let element: CGRect
        /// How round the element's corners were, which the fullscreen picture takes on as
        /// it shrinks back into them.
        let corner: CGFloat
        let size: CGSize
    }

    /// What is known so far about a page on its way into fullscreen, in the cover's terms.
    private struct Entering {
        let picture: CGImage
        let page: CGRect
        var element: CGRect?
        var video: CGRect?
        var videoCorner: CGFloat = 0

        /// Where the zoom should land. A video site often sends its whole page
        /// fullscreen and resizes the player inside it, so for an element that is the
        /// page the video in it is what the eye follows.
        var target: CGRect {
            let element = element ?? page
            guard let video, element.insetBy(dx: -2, dy: -2).contains(video),
                  abs(element.width - page.width) < 2, abs(element.height - page.height) < 2
            else { return element }
            return video
        }

        var corner: CGFloat { video == target ? videoCorner : 0 }
    }

    private final class CoverView: NSView {
        let scene = CALayer()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private weak var webView: WKWebView?
    private var cover: CoverView?
    private var entering: Entering?
    private var origin: Origin?
    /// WebKit announces one exit more than once when the page asked for it.
    private var leaving = false
    private var zoomEnds = Date.distantPast
    /// Whether the zoom has set off; see `afterResize`.
    private var moving = false
    /// Counts covers, so a step scheduled for an earlier one does nothing.
    private var run = 0

    nonisolated init(_ webView: WKWebView) { self.webView = webView }

    // MARK: Steps

    /// Before the app hides its chrome. WebKit says which element is going fullscreen only
    /// once the page has drawn that way, so the zoom sets off towards the whole page and is
    /// turned towards its target as that becomes known.
    func pageWillEnter() {
        origin = nil
        leaving = false
        guard let webView, let window = visibleWindow, let picture = Self.picture(of: window),
              let cover = show(picture, in: window)
        else { return removeCover() }
        let page = cover.convert(webView.bounds, from: webView)
        entering = Entering(picture: picture, page: page)
        afterResize { [weak self] in
            self?.moving = true
            self?.aim()
        }

        let run = run
        let scale = webView.pageZoom * webView.magnification
        webView.evaluateJavaScript(Self.largestVideo, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.run == run, case .success(let value) = result,
                  let box = value as? [Double], box.count == 5, box[2] >= 1, box[3] >= 1
            else { return }
            // The page measures down from its top left, the cover up from its bottom left.
            self.entering?.video = CGRect(
                x: page.minX + box[0] * scale, y: page.maxY - (box[1] + box[3]) * scale,
                width: box[2] * scale, height: box[3] * scale)
            self.entering?.videoCorner = box[4] * scale
            self.aim()
        }
    }

    /// The page has drawn fullscreen; `screenFrame` is where the element was before.
    func pageEntered(from screenFrame: CGRect) {
        guard let cover, entering != nil, let window = cover.window else { return }
        let element = cover.convert(window.convertFromScreen(screenFrame), from: nil)
        guard element.width >= 1, element.height >= 1, cover.bounds.intersects(element) else { return uncover() }
        entering?.element = element
        aim()
        uncoverAfterNextDraw()
    }

    private func aim() {
        guard moving, let cover, let entering else { return }
        zoomIn(on: entering.target, in: cover)
        guard entering.element != nil else { return }
        origin = Origin(
            picture: entering.picture, element: entering.target, corner: entering.corner, size: cover.bounds.size)
    }

    private static let largestVideo = """
        (() => {
            let best = null, largest = null
            for (const video of document.querySelectorAll('video')) {
                const box = video.getBoundingClientRect()
                if (box.width * box.height > (best ? best.width * best.height : 0)) [best, largest] = [box, video]
            }
            if (!best) return null
            // The rounding usually sits on a wrapper about the size of the video.
            let corner = 0
            for (let node = largest; node; node = node.parentElement) {
                const box = node.getBoundingClientRect()
                if (box.width > best.width * 1.05 || box.height > best.height * 1.05) break
                corner = Math.max(corner, parseFloat(getComputedStyle(node).borderTopLeftRadius) || 0)
            }
            return [best.x, best.y, best.width, best.height, corner]
        })()
        """

    private func zoomIn(on element: CGRect, in cover: CoverView) {
        let zoom = Self.zoom(on: element, in: cover.bounds)
        guard !CATransform3DEqualToTransform(zoom, cover.scene.transform) else { return }
        animate(cover.scene, "transform", to: zoom)
        zoomEnds = Date(timeIntervalSinceNow: Self.duration)
    }

    /// Before the app puts its chrome back.
    func pageWillExit() {
        guard !leaving || cover == nil else { return }
        let origin = self.origin
        self.origin = nil
        guard let window = visibleWindow, let picture = Self.picture(of: window),
              let cover = show(picture, in: window)
        else { return removeCover() }
        leaving = true
        // A window resized since has no earlier picture that fits, so its fullscreen
        // picture stays put and fades.
        guard let origin, origin.size == cover.bounds.size else { return }

        let zoom = Self.zoom(on: origin.element, in: cover.bounds)
        let shot = CALayer()
        shot.contents = picture
        // Fills its bounds and crops, so the picture shrinks onto the element and loses
        // the bars around it on the way.
        shot.contentsGravity = .resizeAspectFill
        shot.masksToBounds = true
        shot.position = CGPoint(x: origin.element.midX, y: origin.element.midY)
        let full = CGRect(origin: .zero, size: CGSize(width: cover.bounds.width / zoom.m11, height: cover.bounds.height / zoom.m11))
        shot.bounds = full
        cover.scene.contents = origin.picture
        cover.scene.addSublayer(shot)
        cover.scene.transform = zoom
        zoomEnds = Date(timeIntervalSinceNow: Self.duration)
        afterResize { [weak self] in
            guard let self else { return }
            BrowserPerformance.signposter.emitEvent("FullscreenShrinkStart")
            self.animate(shot, "bounds", to: CGRect(origin: .zero, size: origin.element.size))
            if origin.corner > 0 { self.animate(shot, "cornerRadius", to: origin.corner) }
            self.animate(cover.scene, "transform", to: CATransform3DIdentity)
            self.zoomEnds = Date(timeIntervalSinceNow: Self.duration)
            let run = self.run
            DispatchQueue.main.asyncAfter(deadline: .now() + self.zoomEnds.timeIntervalSinceNow) { [weak self] in
                guard let self, self.run == run else { return }
                BrowserPerformance.signposter.emitEvent("FullscreenShrinkEnd")
            }
        }
    }

    /// WebKit has let the page leave fullscreen.
    func pageExited() {
        guard let webView else { return uncover() }
        let run = run
        var waiting = true
        let proceed: @MainActor () -> Void = { [weak self] in
            guard waiting else { return }
            waiting = false
            guard let self, self.run == run else { return }
            self.uncoverAfterNextDraw()
        }
        webView.callAsyncJavaScript(
            "return new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
            arguments: [:], in: nil, in: .defaultClient
        ) { _ in proceed() }
        // Hidden pages may never run animation frames, and navigation may drop the reply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proceed() }
    }

    // MARK: Cover

    private var visibleWindow: NSWindow? {
        guard let webView, !webView.isHiddenOrHasHiddenAncestor, let window = webView.window, window.isVisible else { return nil }
        return window
    }

    @discardableResult
    private func show(_ picture: CGImage, in window: NSWindow) -> CoverView? {
        removeCover()
        // The picture is of the whole window, so the cover sits over all of it.
        guard let host = window.contentView?.superview ?? window.contentView else { return nil }
        let cover = CoverView(frame: host.bounds)
        cover.autoresizingMask = [.width, .height]
        cover.wantsLayer = true
        cover.layer?.backgroundColor = .black
        cover.scene.frame = cover.bounds
        cover.scene.contents = picture
        cover.scene.contentsGravity = .resize
        cover.layer?.addSublayer(cover.scene)
        host.addSubview(cover, positioned: .above, relativeTo: nil)
        self.cover = cover
        zoomEnds = .distantPast
        moving = false

        run += 1
        let run = run
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.limit) { [weak self] in
            guard let self, self.run == run else { return }
            self.uncover()
        }
        return cover
    }

    /// Runs `body` once the main thread has finished what it is doing now and drawn it.
    /// A zoom already running would lose its first frames to the redraw of the chrome,
    /// so the cover holds still for it.
    private func afterThisTurn(_ body: @escaping @MainActor () -> Void) {
        let run = run
        // Ordered after Core Animation's own commit, which watches the same moment.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max) {
            [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.run == run else { return }
                body()
                CATransaction.flush()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Runs `body` once the app has flipped its chrome for the step just announced, which
    /// shows as the web view changing size. A view that keeps its size is not waited on
    /// for long.
    private func afterResize(_ body: @escaping @MainActor () -> Void) {
        let run = run
        let wait = ResizeWait()
        let proceed: @MainActor () -> Void = { [weak self] in
            guard wait.end(), let self, self.run == run else { return }
            self.afterThisTurn(body)
        }
        wait.observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: webView, queue: nil
        ) { _ in MainActor.assumeIsolated { proceed() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { proceed() }
    }

    private final class ResizeWait {
        var observer: NSObjectProtocol?
        private var ended = false

        /// True the first time only.
        func end() -> Bool {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            defer { ended = true }
            return !ended
        }
    }

    private func uncoverAfterNextDraw() {
        let run = run
        guard let webView else { return uncover() }
        webView.afterNextPresentation { [weak self] in
            guard let self, self.run == run else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(self.zoomEnds.timeIntervalSinceNow, 0)) { [weak self] in
                guard let self, self.run == run else { return }
                self.uncover()
            }
        }
    }

    private func uncover() {
        guard let cover, let layer = cover.layer else { return }
        BrowserPerformance.signposter.emitEvent("FullscreenUncoverStart")
        self.cover = nil
        entering = nil
        leaving = false
        run += 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { cover.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fade
        layer.opacity = 0
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    private func removeCover() {
        cover?.removeFromSuperview()
        cover = nil
        entering = nil
        leaving = false
        run += 1
    }

    private func animate(_ layer: CALayer, _ keyPath: String, to value: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        let model = layer.value(forKeyPath: keyPath)
        let shown = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        // An animation that has not reached the screen yet reports where it ends, so one
        // replaced that early would jump there. It starts over from where the last began.
        if let pending = layer.animation(forKey: keyPath) as? CABasicAnimation,
           let model = model as? NSValue, let shown = shown as? NSValue, model == shown {
            animation.fromValue = pending.fromValue
        } else {
            animation.fromValue = shown
        }
        animation.toValue = value
        animation.duration = Self.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: keyPath)
    }

    /// Scales about the centre of `bounds` so that `element` fits it, centred.
    private static func zoom(on element: CGRect, in bounds: CGRect) -> CATransform3D {
        let scale = min(bounds.width / element.width, bounds.height / element.height)
        let move = CATransform3DMakeTranslation(
            -scale * (element.midX - bounds.midX), -scale * (element.midY - bounds.midY), 0)
        return CATransform3DScale(move, scale, scale, 1)
    }

    // MARK: Picture

    private typealias Connection = @convention(c) () -> Int32
    private typealias CaptureWindows = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?

    private static let connection: Connection? = symbol("CGSMainConnectionID")
    private static let captureWindows: CaptureWindows? = symbol("CGSHWCaptureWindowList")

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(dlopen(nil, RTLD_LAZY), name).map { unsafeBitCast($0, to: T.self) }
    }

    /// What the window server has on screen for the window, video included. This is the
    /// call WebKit takes its own fullscreen pictures with; the public ones either leave
    /// video out or ask for screen recording permission.
    private static func picture(of window: NSWindow) -> CGImage? {
        guard let connection, let captureWindows else { return nil }
        var id = UInt32(window.windowNumber)
        let wholeWindow: UInt32 = 1 << 11
        let pictures = captureWindows(connection(), &id, 1, wholeWindow)?.takeRetainedValue() as? [CGImage]
        return pictures?.first
    }
}

extension WKWebView {
    /// Runs `body` once the view has shown its next frame, or at once on a WebKit that
    /// cannot say when that is.
    @MainActor
    func afterNextPresentation(_ body: @escaping @MainActor () -> Void) {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard responds(to: selector) else { return body() }
        let done: @convention(block) () -> Void = { MainActor.assumeIsolated { body() } }
        perform(selector, with: done)
    }
}
#endif

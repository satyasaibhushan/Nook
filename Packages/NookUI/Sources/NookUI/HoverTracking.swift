// Licensed under GPL-3.0. See LICENSE.
// HoverTracking.swift
// NookUI
//
// Replaces SwiftUI's .onHover with NSTrackingArea-based hover detection.
// SwiftUI's .onHover causes expensive recursive view-tree hit-testing
// (MultiViewResponder.containsGlobalPoints) on every mouse move.
// NSTrackingArea delegates hover detection to AppKit, bypassing the traversal.

import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)

// MARK: - NSViewRepresentable

struct HoverTrackingView: NSViewRepresentable {
    var always = false
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.always = always
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHover = onHover
    }
}

final class HoverTrackingNSView: NSView {
    var onHover: ((Bool) -> Void)?
    /// Tracks in a window that is not key, and while another app is in front.
    var always = false
    private var trackingArea: NSTrackingArea?
    fileprivate var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, always ? .activeAlways : .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        // AppKit sends no mouseExited for an area removed while the pointer is inside it, so a
        // relayout under the cursor would leave the row hovered until it was entered again.
        resyncHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { HoverActivationRegistry.shared.register(self) }
        resyncHover()
    }

    /// Derives hover from where the pointer actually is, for the cases no enter/exit arrives.
    fileprivate func resyncHover() {
        // Layout can request this while SwiftUI is updating. Read the final geometry on the queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = self.window, self.always || window.isKeyWindow else {
                self.setHover(false)
                return
            }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.setHover(self.visibleRect.contains(point))
        }
    }

    private func setHover(_ value: Bool) {
        guard !HoverResync.isMenuTracking, value != isHovered else { return }
        isHovered = value
        onHover?(value)
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(false)
    }
}

@MainActor
private final class HoverActivationRegistry {
    static let shared = HoverActivationRegistry()
    private let views = NSHashTable<HoverTrackingNSView>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    fileprivate var trackingMenus = Set<ObjectIdentifier>()
    fileprivate var menuWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow else { return }
                for view in self.views.allObjects where view.window === window && !view.always {
                    let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    if view.isHovered || view.visibleRect.contains(point) { view.resyncHover() }
                }
            }
        })
        observers.append(center.addObserver(forName: HoverResync.notification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.views.allObjects.forEach { $0.resyncHover() }
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu else { return }
                self?.trackingMenus.insert(ObjectIdentifier(menu))
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu else { return }
                self.trackingMenus.remove(ObjectIdentifier(menu))
                guard self.trackingMenus.isEmpty else { return }
                center.post(name: HoverResync.notification, object: nil)
                // Reconcile tile and card hover before a delayed dismissal checks its holds.
                DispatchQueue.main.async {
                    guard self.trackingMenus.isEmpty else { return }
                    let waiters = self.menuWaiters
                    self.menuWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
        })
    }

    func register(_ view: HoverTrackingNSView) { views.add(view) }
}

/// Rows that slide under a resting pointer get no enter event (`.inVisibleRect` areas move
/// without `updateTrackingAreas`), so a close asks every hover view to check the pointer again.
public enum HoverResync {
    public static let notification = Notification.Name("NookHoverResync")

    @MainActor public static var isMenuTracking: Bool {
        !HoverActivationRegistry.shared.trackingMenus.isEmpty
    }

    /// A delayed hover card must keep its current state until native menus finish tracking.
    @MainActor public static func waitForMenuTracking() async {
        guard isMenuTracking else { return }
        await withCheckedContinuation { HoverActivationRegistry.shared.menuWaiters.append($0) }
    }

    @MainActor public static func request(after delay: TimeInterval) {
        // Once when the slide should be done, once more for a frame that landed late.
        for extra in [0, 0.1] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + extra) {
                NotificationCenter.default.post(name: notification, object: nil)
            }
        }
    }
}

// MARK: - View Modifier

struct HoverTrackingModifier: ViewModifier {
    var always = false
    let onHover: (Bool) -> Void

    func body(content: Content) -> some View {
        content.background(
            HoverTrackingView(always: always, onHover: onHover)
        )
    }
}

#else

public enum HoverResync {
    @MainActor public static func request(after delay: TimeInterval) {}
}


/// Hover is a pointer notion; on iOS SwiftUI's own `.onHover` is cheap and only fires
/// with a connected pointer.
private struct HoverTrackingModifier: ViewModifier {
    var always = false
    let onHover: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onHover(perform: onHover)
    }
}

#endif

extension View {
    /// Drop-in replacement for `.onHover` that uses `NSTrackingArea` instead of
    /// SwiftUI's built-in hover hit-testing, avoiding expensive view-tree traversal.
    /// `always` keeps tracking while the window is not key, for controls used from another app.
    public func onHoverTracking(always: Bool = false, perform action: @escaping (Bool) -> Void) -> some View {
        modifier(HoverTrackingModifier(always: always, onHover: action))
    }
}

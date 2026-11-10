// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A close target is ready only at its final position, unchanged across geometry samples.
struct TabCloseGeometry {
    private var previousFrame: CGRect?
    private(set) var settledFrame: CGRect?

    mutating func reset() { self = Self() }

    mutating func sample(model: CGRect, presentation: CGRect) -> Bool {
        let wasSettled = settledFrame != nil
        settledFrame = model == presentation && previousFrame == presentation ? model : nil
        previousFrame = presentation
        return !wasSettled && settledFrame != nil
    }

    func accepts(model: CGRect, presentation: CGRect) -> Bool {
        settledFrame == model && model == presentation && !model.isEmpty
    }
}

struct TabCloseButton<Label: View>: View {
    let title: String
    let isVisible: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if os(macOS)
        label()
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay { TabCloseControl(title: title, action: action) }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { _ in
                TabCloseResync.request()
            }
        #else
        if isVisible { Button(action: action, label: label).buttonStyle(.plain) }
        #endif
    }
}

enum TabCloseResync {
    @MainActor static func request() {
        #if os(macOS)
        TabCloseGeometryMonitor.shared.request()
        #endif
    }
}

#if os(macOS)
private struct TabCloseControl: NSViewRepresentable {
    let title: String
    let action: () -> Void

    func makeNSView(context: Context) -> TabCloseNSButton {
        let button = TabCloseNSButton()
        button.isTransparent = true
        button.isBordered = false
        button.title = ""
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(TabCloseNSButton.closeTab)
        button.closeAction = action
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: TabCloseNSButton, context: Context) {
        button.closeAction = action
        button.setAccessibilityLabel(title)
    }
}

private final class TabCloseNSButton: NSButton {
    var closeAction: (() -> Void)?
    var geometry = TabCloseGeometry()
    private var pressedFrame: CGRect?

    var frames: (model: CGRect, presentation: CGRect) {
        guard let layer else {
            let frame = convert(bounds, to: nil)
            return (frame, frame)
        }
        let displayed = layer.presentation() ?? layer
        return (layer.convert(layer.bounds, to: nil), displayed.convert(displayed.bounds, to: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        if window != nil {
            TabCloseGeometryMonitor.shared.buttons.add(self)
            TabCloseResync.request()
        } else {
            TabCloseGeometryMonitor.shared.buttons.remove(self)
            geometry.reset()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let frames = frames
        guard window?.isKeyWindow == true,
              geometry.accepts(model: frames.model, presentation: frames.presentation) else {
            // Consume a premature close click so it cannot select or rename the moving row.
            TabCloseResync.request()
            return
        }
        pressedFrame = frames.model
        super.mouseDown(with: event)
        pressedFrame = nil
    }

    @objc func closeTab() {
        let frames = frames
        guard window != nil, geometry.accepts(model: frames.model, presentation: frames.presentation),
              pressedFrame == nil || pressedFrame == frames.model else { return }
        closeAction?()
    }
}

/// Samples only during a close or relayout. There is no idle mouse monitor or polling timer.
@MainActor
private final class TabCloseGeometryMonitor {
    static let shared = TabCloseGeometryMonitor()
    let buttons = NSHashTable<TabCloseNSButton>.weakObjects()
    private var timer: Timer?
    private var deadline: TimeInterval = 0

    func request() {
        for button in buttons.allObjects { button.geometry.reset() }
        deadline = ProcessInfo.processInfo.systemUptime + 1
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sample() {
        var settled = true
        var needsHover = false
        for button in buttons.allObjects where button.window != nil {
            let frames = button.frames
            needsHover = button.geometry.sample(model: frames.model, presentation: frames.presentation) || needsHover
            settled = settled && button.geometry.accepts(model: frames.model, presentation: frames.presentation)
        }
        if needsHover { NotificationCenter.default.post(name: HoverResync.notification, object: nil) }
        if settled || ProcessInfo.processInfo.systemUptime >= deadline {
            timer?.invalidate()
            timer = nil
        }
    }
}
#endif

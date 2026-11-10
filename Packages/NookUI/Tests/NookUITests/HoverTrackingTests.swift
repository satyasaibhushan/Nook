// Licensed under GPL-3.0. See LICENSE.
#if os(macOS)
import AppKit
import Testing
@testable import NookUI

@MainActor
@Suite(.serialized)
struct HoverTrackingTests {
    @Test func nestedMenusHoldHoverUntilTheLastMenuEnds() async throws {
        #expect(!HoverResync.isMenuTracking)
        let menu = NSMenu(), submenu = NSMenu()
        let center = NotificationCenter.default
        let view = HoverTrackingNSView()
        let event = NSEvent()
        var changes: [Bool] = []
        view.onHover = { changes.append($0) }
        view.mouseEntered(with: event)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        view.mouseExited(with: event)
        #expect(changes == [true])

        var finished = false
        let pending = Task {
            await HoverResync.waitForMenuTracking()
            finished = true
        }
        await Task.yield()
        center.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        try await Task.sleep(for: .milliseconds(10))
        #expect(HoverResync.isMenuTracking)
        #expect(!finished)
        view.mouseExited(with: event)
        #expect(changes == [true])
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await pending.value
        #expect(!HoverResync.isMenuTracking)
        #expect(finished)
        view.mouseExited(with: event)
        #expect(changes == [true, false])
    }

    @Test func queuedLayoutResyncCannotClearHoverUnderAMenu() async throws {
        #expect(!HoverResync.isMenuTracking)
        let menu = NSMenu()
        let center = NotificationCenter.default
        let view = HoverTrackingNSView()
        var changes: [Bool] = []
        view.onHover = { changes.append($0) }
        view.mouseEntered(with: NSEvent())
        view.viewDidMoveToWindow()
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        try await Task.sleep(for: .milliseconds(10))
        #expect(changes == [true])
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        view.viewDidMoveToWindow()
        try await Task.sleep(for: .milliseconds(10))
        #expect(changes == [true, false])
    }
}
#endif

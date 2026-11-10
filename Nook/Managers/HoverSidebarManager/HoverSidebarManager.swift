// Licensed under GPL-3.0. See LICENSE.
//
//  HoverSidebarManager.swift
//  Nook
//
//  Created by Jonathan Caudill on 2025-09-13.
//

import OSLog
import SwiftUI
import AppKit
import NookSettings
import NookWeb
import NookUI

/// Manages reveal/hide of the overlay sidebar when the real sidebar is collapsed.
/// Uses a global mouse-move monitor to handle edge hover, including slight overshoot
/// beyond the window's left boundary.
final class HoverSidebarManager: ObservableObject {
    // MARK: - Published State
    @Published var isOverlayVisible: Bool = false

    // MARK: - Configuration
    /// Width inside the window that triggers reveal when hovered.
    var triggerWidth: CGFloat = 6
    /// Horizontal slack to the left of the window to catch slight overshoot.
    var overshootSlack: CGFloat = 12
    /// Extra horizontal margin past the overlay to keep it open while interacting.
    var keepOpenHysteresis: CGFloat = 52
    /// Vertical slack to allow small overshoot above/below the window frame.
    var verticalSlack: CGFloat = 24

    // MARK: - Dependencies
    weak var browserManager: BrowserManager?
    weak var windowRegistry: WindowRegistry?
    weak var nookSettings: NookSettingsService?

    // MARK: - Monitors
    private static weak var monitorOwner: HoverSidebarManager?
    private static let resyncObserver = NotificationCenter.default.addObserver(forName: HoverResync.notification, object: nil, queue: .main) { _ in
        monitorOwner?.scheduleHandleMouseMovement()
    }
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isActive: Bool = false
    private var addressEditingWindows = Set<UUID>()

    func setAddressEditing(_ editing: Bool, in windowID: UUID) {
        if editing { addressEditingWindows.insert(windowID) }
        else {
            addressEditingWindows.remove(windowID)
            if isActive { scheduleHandleMouseMovement() }
        }
    }

    private var siteSettingsWindows = Set<UUID>()

    /// Keeps the overlay (and the URL bar's Site Settings popover and alert) up while open.
    func setSiteSettingsOpen(_ open: Bool, in windowID: UUID) {
        if open { siteSettingsWindows.insert(windowID) }
        else {
            siteSettingsWindows.remove(windowID)
            if isActive { scheduleHandleMouseMovement() }
        }
    }

    // MARK: - Lifecycle
    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    @MainActor
    func updateMonitoring(for state: BrowserWindowState) {
        let perfID = OSSignpostID(log: BrowserPerformance.hover)
        os_signpost(.begin, log: BrowserPerformance.hover, name: "UpdateMonitoring", signpostID: perfID)
        defer { os_signpost(.end, log: BrowserPerformance.hover, name: "UpdateMonitoring", signpostID: perfID) }
        _ = Self.resyncObserver
        let eligible = NSApp.isActive && state.isActive
            && !state.isSidebarVisible && !state.showsFullscreenPage
        guard eligible else { stop(); return }
        if Self.monitorOwner !== self {
            Self.monitorOwner?.stop()
            Self.monitorOwner = self
        }
        start()
        scheduleHandleMouseMovement()
    }

    func start() {
        guard !isActive else { return }
        isActive = true

        // Local monitor for responsive updates while the app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.scheduleHandleMouseMovement()
            return event
        }

        // Global monitor to detect near-edge hovers even when cursor overshoots beyond window bounds
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.scheduleHandleMouseMovement()
        }
    }

    func stop() {
        os_signpost(.event, log: BrowserPerformance.hover, name: "HoverMonitoringStop")
        isActive = false
        if Self.monitorOwner === self { Self.monitorOwner = nil }
        if let token = localMonitor { NSEvent.removeMonitor(token); localMonitor = nil }
        if let token = globalMonitor { NSEvent.removeMonitor(token); globalMonitor = nil }
        Task { @MainActor [weak self] in
            await HoverResync.waitForMenuTracking()
            // An unchanged write still redraws every view observing the manager.
            guard let self, !self.isActive, self.isOverlayVisible else { return }
            os_signpost(.event, log: BrowserPerformance.hover, name: "OverlayVisibilityWrite", "%{public}d", 0)
            self.isOverlayVisible = false
        }
    }

    deinit { stop() }

    // MARK: - Mouse Logic
    /// Re-evaluates the overlay against where the pointer is now.
    func checkPointer() { scheduleHandleMouseMovement() }

    private func scheduleHandleMouseMovement() {
        // Ensure main-actor work since we touch NSApp/window and main-actor BrowserManager
        DispatchQueue.main.async { [weak self] in
            self?.handleMouseMovementOnMain()
        }
    }

    @MainActor
    private func handleMouseMovementOnMain() {
        let perfID = OSSignpostID(log: BrowserPerformance.hover)
        os_signpost(.begin, log: BrowserPerformance.hover, name: "HoverMouseCheck", signpostID: perfID)
        defer { os_signpost(.end, log: BrowserPerformance.hover, name: "HoverMouseCheck", signpostID: perfID) }
        guard isActive, !HoverResync.isMenuTracking, browserManager != nil,
              let registry = windowRegistry,
              let activeState = registry.activeWindow else { return }

        // Never show overlay while the real sidebar is visible, or over a fullscreen page
        if activeState.isSidebarVisible || activeState.showsFullscreenPage {
            if isOverlayVisible {
                os_signpost(.event, log: BrowserPerformance.hover, name: "OverlayVisibilityWrite", "%{public}d", 0)
                isOverlayVisible = false
            }
            return
        }

        guard let window = NSApp.keyWindow else {
            if isOverlayVisible {
                os_signpost(.event, log: BrowserPerformance.hover, name: "OverlayVisibilityWrite", "%{public}d", 0)
                isOverlayVisible = false
            }
            return
        }

        // The expanded address panel extends beyond the sidebar. Keep its host alive
        // until the editor dismisses through Escape, navigation, or an outside click.
        if isOverlayVisible, addressEditingWindows.contains(activeState.id) || siteSettingsWindows.contains(activeState.id) { return }

        // Mouse and window frames are in screen coordinates
        let mouse = NSEvent.mouseLocation
        let frame = window.frame

        // Allow slight vertical overshoot
        let verticalOK = mouse.y >= frame.minY - verticalSlack && mouse.y <= frame.maxY + verticalSlack
        if !verticalOK {
            if isOverlayVisible {
                os_signpost(.event, log: BrowserPerformance.hover, name: "OverlayVisibilityWrite", "%{public}d", 0)
                isOverlayVisible = false
            }
            return
        }

        // Use saved width when sidebar is collapsed to size the overlay and sticky zone
        let overlayWidth = max(activeState.sidebarWidth, activeState.savedSidebarWidth)

        // Edge zone calculation
        var inTriggerZone = false
        var inKeepOpenZone = false
        var inSidebarContentZone = false

        // Right Side Calculations (if flag is true)
        if nookSettings?.sidebarPosition == .left {
            inTriggerZone = (mouse.x >= frame.minX - overshootSlack) && (mouse.x <= frame.minX + triggerWidth)
            // Keep-open zone: extends past the sidebar to allow moving cursor slightly into browser page
            inKeepOpenZone = (mouse.x >= frame.minX) && (mouse.x <= frame.minX + overlayWidth + keepOpenHysteresis)
            // Sidebar content zone: cursor is actually over the sidebar itself
            inSidebarContentZone = (mouse.x >= frame.minX) && (mouse.x <= frame.minX + overlayWidth)
        } else {
            let rightEdge = frame.maxX
            inTriggerZone = (mouse.x >= rightEdge - triggerWidth - overshootSlack) && (mouse.x <= rightEdge + overshootSlack)
            // Keep-open zone: extends past the sidebar to allow moving cursor slightly into browser page
            inKeepOpenZone = (mouse.x >= rightEdge - overlayWidth - keepOpenHysteresis) && (mouse.x <= rightEdge)
            // Sidebar content zone: cursor is actually over the sidebar itself
            inSidebarContentZone = (mouse.x >= rightEdge - overlayWidth) && (mouse.x <= rightEdge)
        }
        
        // Show sidebar if: in trigger zone, OR (sidebar visible AND (in keep-open zone OR over sidebar content))
        let shouldShow = inTriggerZone || (isOverlayVisible && (inKeepOpenZone || inSidebarContentZone))
        if shouldShow != isOverlayVisible {
            withAnimation(.easeInOut(duration: 0.15)) {
                os_signpost(.event, log: BrowserPerformance.hover, name: "OverlayVisibilityWrite", "%{public}d", shouldShow ? 1 : 0)
                isOverlayVisible = shouldShow
            }
        }
    }
}

// Licensed under GPL-3.0. See LICENSE.
//
//  WindowRegistry.swift
//  Nook
//
//  Tracks window states for cross-window coordination and command routing
//

import OSLog
import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
public class WindowRegistry {
    /// All registered window states (ignored from observation to avoid actor isolation issues)
    @ObservationIgnored
    private var _windows: [UUID: BrowserWindowState] = [:]
    @ObservationIgnored
    private var activationOrder: [UUID] = []

    public var windows: [UUID: BrowserWindowState] {
        get { _windows }
        set { _windows = newValue }
    }

    public init() {}

    /// ID of the currently focused window, for command routing.
    public var activeWindowId: UUID? {
        didSet {
            guard oldValue != activeWindowId else { return }
            if let oldValue { windows[oldValue]?.isActive = false }
            if let activeWindowId { windows[activeWindowId]?.isActive = true }
        }
    }

    /// The currently focused window state (computed, not observed)
    public var activeWindow: BrowserWindowState? {
        guard let id = activeWindowId else { return nil }
        return _windows[id]
    }

    /// The last-used regular window. Private-window activation never replaces this choice.
    public var mostRecentRegularWindow: BrowserWindowState? {
        activationOrder.reversed().compactMap { windows[$0] }.first { !$0.isIncognito }
    }

    /// Callback for window cleanup (set by whoever needs to clean up resources)
    @ObservationIgnored
    public var onWindowClose: ((UUID) -> Void)?

    /// Callback for post-registration setup (BrowserManager.setupWindowState)
    @ObservationIgnored
    public var onWindowRegister: ((BrowserWindowState) -> Void)?

    /// Callback when active window changes
    @ObservationIgnored
    public var onActiveWindowChange: ((BrowserWindowState) -> Void)?

    /// Register once: programmatic windows register before their SwiftUI view appears.
    public func register(_ window: BrowserWindowState) {
        guard windows[window.id] == nil else {
            return
        }

        windows[window.id] = window

        if !activationOrder.contains(window.id) {
            activationOrder.insert(window.id, at: 0)
        }

        onWindowRegister?(window)
    }

    /// Unregister a window when it closes
    public func unregister(_ id: UUID) {
        // Both the window's close notification and SwiftUI's onDisappear call this.
        guard windows[id] != nil else { return }
        // Call cleanup callback if set
        onWindowClose?(id)

        windows[id]?.isActive = false
        windows.removeValue(forKey: id)
        activationOrder.removeAll { $0 == id }

        // If this was the active window, switch to another
        if activeWindowId == id {
            activeWindowId = activationOrder.last
        }

    }

    /// Set the active (focused) window
    public func setActive(_ window: BrowserWindowState) {
        let perfID = OSSignpostID(log: BrowserPerformance.activation)
        os_signpost(.begin, log: BrowserPerformance.activation, name: "WindowRegistrySetActive", signpostID: perfID)
        defer { os_signpost(.end, log: BrowserPerformance.activation, name: "WindowRegistrySetActive", signpostID: perfID) }
        activationOrder.removeAll { $0 == window.id }
        activationOrder.append(window.id)
        activeWindowId = window.id
        onActiveWindowChange?(window)
    }

    /// Get all windows as an array
    public var allWindows: [BrowserWindowState] {
        Array(windows.values)
    }
}

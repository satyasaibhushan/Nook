// Licensed under GPL-3.0. See LICENSE.
import Observation
import Testing
@testable import NookWeb

@MainActor
struct WindowRegistryTests {
    @Test func switchingWindowsInvalidatesOnlyTheirActiveFlags() {
        let registry = WindowRegistry()
        let first = BrowserWindowState(), second = BrowserWindowState(), third = BrowserWindowState()
        [first, second, third].forEach { registry.register($0) }
        registry.setActive(first)
        var invalidated = Set<Int>()
        for (index, window) in [first, second, third].enumerated() {
            withObservationTracking {
                _ = window.isActive
            } onChange: {
                MainActor.assumeIsolated { _ = invalidated.insert(index) }
            }
        }
        registry.setActive(second)
        #expect(!first.isActive)
        #expect(second.isActive)
        #expect(!third.isActive)
        #expect(invalidated == [0, 1])
    }

    @Test func repeatedActivationDoesNotInvalidateWindowChrome() {
        let registry = WindowRegistry()
        let window = BrowserWindowState()
        registry.register(window)
        registry.setActive(window)
        var invalidated = false
        withObservationTracking {
            _ = window.isActive
        } onChange: {
            MainActor.assumeIsolated { invalidated = true }
        }
        registry.setActive(window)
        #expect(window.isActive)
        #expect(!invalidated)
    }

    @Test func closingTheActiveWindowActivatesThePreviousWindow() {
        let registry = WindowRegistry()
        let first = BrowserWindowState(), second = BrowserWindowState(), third = BrowserWindowState()
        [first, second, third].forEach { registry.register($0) }
        registry.setActive(first)
        registry.setActive(second)
        registry.unregister(second.id)
        #expect(!second.isActive)
        #expect(first.isActive)
        #expect(!third.isActive)
        #expect(registry.activeWindowId == first.id)
        registry.unregister(first.id)
        #expect(third.isActive)
        registry.unregister(third.id)
        #expect(!third.isActive)
        #expect(registry.activeWindowId == nil)
    }
}

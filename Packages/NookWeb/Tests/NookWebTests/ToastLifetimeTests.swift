// Licensed under GPL-3.0. See LICENSE.
import Testing
import Foundation
@testable import NookWeb

@MainActor
struct ToastLifetimeTests {
    @Test func repeatedFeedbackReplacesThePendingDismissal() async throws {
        let owner = NSObject()
        var dismissed: [Int] = []
        ToastLifetime.restart(for: owner, after: 0.02) { dismissed.append(1) }
        ToastLifetime.restart(for: owner, after: 0.15) { dismissed.append(2) }
        try await Task.sleep(for: .seconds(0.06))
        #expect(dismissed.isEmpty)
        try await Task.sleep(for: .seconds(0.15))
        #expect(dismissed == [2])
    }

    @Test func dismissalAndReopenCannotDismissTheNewPresentation() async throws {
        let owner = NSObject()
        var dismissed: [Int] = []
        ToastLifetime.restart(for: owner, after: 0.02) { dismissed.append(1) }
        ToastLifetime.cancel(for: owner)
        ToastLifetime.restart(for: owner, after: 0.15) { dismissed.append(2) }
        try await Task.sleep(for: .seconds(0.06))
        #expect(dismissed.isEmpty)
        try await Task.sleep(for: .seconds(0.15))
        #expect(dismissed == [2])
    }

    @Test(arguments: [false, true])
    func copyFeedbackRenewsWhileMounted(changeText: Bool) async throws {
        let window = BrowserWindowState()
        window.isShowingCopyURLToast = true
        try await Task.sleep(for: .seconds(1))
        if changeText { window.copyToastText = "Copied element" }
        else { window.isShowingCopyURLToast = true }
        try await Task.sleep(for: .seconds(1.2))
        #expect(window.isShowingCopyURLToast)
        try await Task.sleep(for: .seconds(1))
        #expect(!window.isShowingCopyURLToast)
        #expect(window.copyToastText == nil)
    }

    @Test func ownersHaveIndependentLifetimes() async throws {
        let first = NSObject(), second = NSObject()
        var dismissed: [Int] = []
        ToastLifetime.restart(for: first, after: 0.01) { dismissed.append(1) }
        ToastLifetime.restart(for: second, after: 0.01) { dismissed.append(2) }
        ToastLifetime.cancel(for: first)
        try await Task.sleep(for: .seconds(0.06))
        #expect(dismissed == [2])
    }
}

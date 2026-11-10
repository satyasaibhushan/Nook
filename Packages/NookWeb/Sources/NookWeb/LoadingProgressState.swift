// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// Progress belongs to one navigation. The clock is supplied so short loads need no timer in tests.
public struct LoadingProgressState {
    public static let showDelay: TimeInterval = 0.12
    public private(set) var navigationID: UUID?
    public private(set) var progress: Double = 0
    public private(set) var isVisible = false
    public private(set) var startedAt: TimeInterval?

    public init() {}

    public mutating func update(navigationID: UUID, progress: Double, isLoading: Bool, now: TimeInterval) {
        if self.navigationID != navigationID {
            self = Self()
            self.navigationID = navigationID
        }
        guard isLoading else {
            isVisible = false
            startedAt = nil
            return
        }
        if startedAt == nil { startedAt = now }
        if progress.isFinite { self.progress = max(self.progress, min(1, max(0, progress))) }
        isVisible = now - (startedAt ?? now) >= Self.showDelay
    }
}

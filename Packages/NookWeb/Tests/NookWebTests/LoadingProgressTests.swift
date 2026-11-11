// Licensed under GPL-3.0. See LICENSE.
import Testing
import Foundation
@testable import NookWeb

struct LoadingProgressTests {
    @Test(arguments: [0.02, 0.08, 0.25, 1.5])
    func visibilityTracksLoadDuration(_ duration: Double) {
        var state = LoadingProgressState()
        let id = UUID()
        state.update(navigationID: id, progress: 0.1, isLoading: true, now: 0)
        #expect(!state.isVisible)
        state.update(navigationID: id, progress: 0.8, isLoading: true, now: duration)
        #expect(state.isVisible == (duration >= LoadingProgressState.showDelay))
        state.update(navigationID: id, progress: 1, isLoading: false, now: duration)
        #expect(!state.isVisible)
    }

    @Test func stopControlUsesDelayedVisibilityAndRealLoading() {
        var state = LoadingProgressState()
        let id = UUID()
        state.update(navigationID: id, progress: 0.1, isLoading: true, now: 0)
        #expect(!state.showsStopLoading(isLoading: true))
        state.update(navigationID: id, progress: 0.2, isLoading: true, now: LoadingProgressState.showDelay - 0.001)
        #expect(!state.showsStopLoading(isLoading: true))
        state.update(navigationID: id, progress: 0.3, isLoading: true, now: LoadingProgressState.showDelay)
        #expect(state.showsStopLoading(isLoading: true))
        #expect(!state.showsStopLoading(isLoading: false))
        state.update(navigationID: id, progress: 1, isLoading: false, now: 0.13)
        #expect(!state.showsStopLoading(isLoading: false))
        state.update(navigationID: UUID(), progress: 0.1, isLoading: true, now: 0.14)
        #expect(!state.showsStopLoading(isLoading: true))
    }

    @Test func progressOnlyResetsForAnotherNavigation() {
        var state = LoadingProgressState()
        let id = UUID()
        state.update(navigationID: id, progress: 0.8, isLoading: true, now: 0)
        state.update(navigationID: id, progress: 0.2, isLoading: true, now: 0.2)
        #expect(state.progress == 0.8)
        #expect(state.isVisible)
        state.update(navigationID: UUID(), progress: 0.1, isLoading: true, now: 0.3)
        #expect(state.progress == 0.1)
        #expect(!state.isVisible)
    }
}

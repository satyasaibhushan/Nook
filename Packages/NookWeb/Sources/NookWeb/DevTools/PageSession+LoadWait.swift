// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+LoadWait.swift
//  NookWeb
//
//  Waiting for a page to finish loading, for agents: woken by `loadingState` changing, not by
//  polling the view.
//

import Foundation
import Observation

extension PageSession {
    /// Waits until the page stops loading; false when it is still loading after `timeout`.
    /// `startGrace`: how long to wait for a load to start when none is running, for a load a
    /// click or script asked for that WebKit has not started yet.
    public func waitForLoad(timeout: Duration, startGrace: Duration = .zero) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        if !isLoading, startGrace > .zero {
            await loadingChange(within: min(startGrace, timeout))
        }
        while isLoading {
            let left = deadline - clock.now
            guard left > .zero else { return false }
            await loadingChange(within: left)
        }
        return true
    }

    /// Returns at the next change of the loading state, or after `limit`.
    private func loadingChange(within limit: Duration) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.continuation = continuation
            withObservationTracking {
                _ = loadingState
                _ = loadingNavigationID
            } onChange: {
                // Fires before the new value is stored; the waiter reads it after this hop.
                Task { @MainActor in once.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.resume()
            }
        }
    }
}

@MainActor
private final class ResumeOnce {
    var continuation: CheckedContinuation<Void, Never>?
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

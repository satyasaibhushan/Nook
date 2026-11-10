// Licensed under GPL-3.0. See LICENSE.
//
//  AfterFrame.swift
//  NookWeb
//
//  Work a frame does not need, held until that frame has gone to the screen.
//

import Foundation
import QuartzCore

@MainActor
enum AfterFrame {
    /// Runs `body` once Core Animation has committed what the main thread changed this turn.
    /// Calls run in the order they were made.
    static func run(_ body: @escaping @MainActor () -> Void) {
        // Ordered after Core Animation's own commit, which watches the same moment. The hop
        // through the queue wakes the run loop again, so anything `body` changes is drawn on
        // the next pass instead of waiting for the next event.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

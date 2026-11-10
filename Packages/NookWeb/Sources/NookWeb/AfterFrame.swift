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
    /// Frame callbacks run in the order they were made; a deadline also bounds the wait.
    static func run(noLaterThan delay: TimeInterval? = nil, _ body: @escaping @MainActor () -> Void) {
        var pending: (@MainActor () -> Void)? = body
        var observer: CFRunLoopObserver?
        var deadline: DispatchWorkItem?
        let finish = {
            guard let body = pending else { return }
            pending = nil
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
            deadline?.cancel()
            deadline = nil
            body()
        }
        // Ordered after Core Animation's own commit, which watches the same moment. The hop
        // through the queue wakes the run loop again, so anything `body` changes is drawn on
        // the next pass instead of waiting for the next event.
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // Activation must finish housekeeping even when tracking keeps the run loop busy.
        if let delay {
            let work = DispatchWorkItem { MainActor.assumeIsolated { finish() } }
            deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

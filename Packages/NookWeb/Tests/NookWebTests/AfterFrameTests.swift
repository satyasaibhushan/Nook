// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookWeb

@MainActor
struct AfterFrameTests {
    @Test func boundedWorkRunsOnceAndPreservesOrder() async throws {
        var calls: [Int] = []
        AfterFrame.run(noLaterThan: 0.05) { calls.append(1) }
        AfterFrame.run(noLaterThan: 0.05) { calls.append(2) }
        #expect(calls.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls == [1, 2])
    }

    @Test func boundedWorkSurvivesAReentrantSchedule() async throws {
        var calls: [Int] = []
        AfterFrame.run(noLaterThan: 0.05) {
            calls.append(1)
            AfterFrame.run(noLaterThan: 0.05) { calls.append(2) }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls == [1, 2])
    }
}

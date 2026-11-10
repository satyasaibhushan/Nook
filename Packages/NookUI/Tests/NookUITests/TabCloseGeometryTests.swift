// Licensed under GPL-3.0. See LICENSE.
import Testing
import Foundation
@testable import NookUI

struct TabCloseGeometryTests {
    private let destination = CGRect(x: 100, y: 200, width: 24, height: 24)

    @Test func movingTargetNeverAcceptsClose() {
        var geometry = TabCloseGeometry()
        for offset in [40.0, 20, 10, 1, 0.01] {
            let moving = destination.offsetBy(dx: 0, dy: offset)
            let becameReady = geometry.sample(model: destination, presentation: moving)
            #expect(!becameReady)
            #expect(!geometry.accepts(model: destination, presentation: moving))
        }
        let firstSample = geometry.sample(model: destination, presentation: destination)
        let secondSample = geometry.sample(model: destination, presentation: destination)
        #expect(!firstSample)
        #expect(secondSample)
        #expect(geometry.accepts(model: destination, presentation: destination))
    }

    @Test func anotherCloseOrLayoutInvalidatesTheTarget() {
        var geometry = TabCloseGeometry()
        _ = geometry.sample(model: destination, presentation: destination)
        _ = geometry.sample(model: destination, presentation: destination)
        let moved = destination.offsetBy(dx: 0, dy: -32)
        #expect(!geometry.accepts(model: moved, presentation: moved))
        geometry.reset()
        #expect(!geometry.accepts(model: destination, presentation: destination))
        let firstSample = geometry.sample(model: moved, presentation: moved)
        let secondSample = geometry.sample(model: moved, presentation: moved)
        #expect(!firstSample)
        #expect(secondSample)
        #expect(geometry.accepts(model: moved, presentation: moved))
    }
}

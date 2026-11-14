import XCTest
import AppKit
@testable import Launchpad

final class PageScrollControllerTests: XCTestCase {
    func testLightweightBackgroundIsEnabledOnceAndResetAfterGesture() async {
        await MainActor.run {
            let state = PageScrollState()
            state.beginInteraction()
            XCTAssertTrue(state.enableLightweightBackground())
            XCTAssertFalse(state.enableLightweightBackground())
            XCTAssertTrue(state.useLightweightBackground)

            state.endInteraction()

            XCTAssertFalse(state.isInteracting)
            XCTAssertFalse(state.useLightweightBackground)
            XCTAssertEqual(state.position.value, 0)
        }
    }

    func testLongGestureAndMomentumOnlyFlipOnce() {
        var controller = PageScrollController()
        var directions: [Int] = []
        for i in 0..<100 {
            let result = controller.handle(dx: -8, dy: 1, precise: true,
                                           phase: i == 0 ? .began : .changed, momentum: [], time: Double(i) * 0.01)
            if result.direction != 0 { directions.append(result.direction) }
        }
        XCTAssertEqual(directions, [])
        let end = controller.handle(dx: 0, dy: 0, precise: true, phase: .ended,
                                    momentum: [], time: 1)
        XCTAssertEqual(end.direction, 1)
        XCTAssertTrue(end.finished)
        for i in 0..<20 {
            XCTAssertEqual(controller.handle(dx: -40, dy: 0, precise: true, phase: [],
                                             momentum: .changed, time: 1.1 + Double(i) * 0.01).direction, 0)
        }
    }

    func testVerticalGestureCannotBecomeHorizontalFromLateNoise() {
        var controller = PageScrollController()
        _ = controller.handle(dx: 1, dy: -15, precise: true, phase: .began, momentum: [], time: 0)
        let result = controller.handle(dx: -100, dy: 0, precise: true, phase: .changed, momentum: [], time: 0.1)
        XCTAssertEqual(result, .init())
    }

    func testCancelledGestureDoesNotFlipAndNextGestureWorks() {
        var controller = PageScrollController()
        _ = controller.handle(dx: -10, dy: 0, precise: true, phase: .began, momentum: [], time: 0)
        let cancelled = controller.handle(dx: -100, dy: 0, precise: true, phase: .cancelled,
                                          momentum: [], time: 0.1)
        XCTAssertEqual(cancelled.direction, 0)
        XCTAssertTrue(cancelled.finished)
        _ = controller.handle(dx: 40, dy: 0, precise: true, phase: .began,
                              momentum: [], time: 0.5)
        XCTAssertEqual(controller.handle(dx: 0, dy: 0, precise: true, phase: .ended,
                                         momentum: [], time: 0.6).direction, -1)
    }

    func testPhaseLessPreciseMouseResetsAfterIdle() {
        var controller = PageScrollController()
        XCTAssertEqual(controller.handle(dx: -40, dy: 0, precise: true, phase: [], momentum: [], time: 0).direction, 1)
        XCTAssertEqual(controller.handle(dx: -40, dy: 0, precise: true, phase: [], momentum: [], time: 0.01).direction, 0)
        XCTAssertEqual(controller.handle(dx: -40, dy: 0, precise: true, phase: [], momentum: [], time: 0.5).direction, 1)
    }

    func testShortDecisiveTrackpadGestureFlipsWithoutLongDelay() {
        var controller = PageScrollController()
        XCTAssertEqual(controller.handle(dx: -9, dy: 1, precise: true,
                                         phase: .began, momentum: [], time: 0).direction, 0)
        let changed = controller.handle(dx: -11, dy: 0, precise: true,
                                        phase: .changed, momentum: [], time: 0.02)
        XCTAssertEqual(changed.direction, 0)
        XCTAssertEqual(changed.offset, -20)
        XCTAssertEqual(controller.handle(dx: 0, dy: 0, precise: true,
                                         phase: .ended, momentum: [], time: 0.03).direction, 1)
    }

    func testVelocityCommitsFastShortSwipeButRejectsSlowShortDrag() {
        var fast = PageScrollController()
        _ = fast.handle(dx: -9, dy: 0, precise: true,
                        phase: .began, momentum: [], time: 0)
        _ = fast.handle(dx: -6, dy: 0, precise: true,
                        phase: .changed, momentum: [], time: 0.02)
        XCTAssertEqual(fast.handle(dx: 0, dy: 0, precise: true,
                                   phase: .ended, momentum: [], time: 0.03).direction, 1)

        var slow = PageScrollController()
        _ = slow.handle(dx: -9, dy: 0, precise: true,
                        phase: .began, momentum: [], time: 0)
        _ = slow.handle(dx: -6, dy: 0, precise: true,
                        phase: .changed, momentum: [], time: 0.2)
        XCTAssertEqual(slow.handle(dx: 0, dy: 0, precise: true,
                                   phase: .ended, momentum: [], time: 0.21).direction, 0)
    }

    func testMouseWheelAndReset() {
        var controller = PageScrollController()
        XCTAssertEqual(controller.handle(dx: 0, dy: -3, precise: false, phase: [], momentum: [], time: 0).direction, 1)
        XCTAssertEqual(controller.handle(dx: 0, dy: -3, precise: false, phase: [], momentum: [], time: 0.1).direction, 0)
        controller.reset()
        XCTAssertEqual(controller.handle(dx: 0, dy: 3, precise: false, phase: [], momentum: [], time: 0.11).direction, -1)
    }
}

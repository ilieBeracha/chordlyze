import XCTest

/// Exercises the production navigation bridge through a DEBUG-only offline fixture.
/// Touches use XCTest's public API, so the real UIKit transition handles every pop.
final class NavigationGestureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--navigation-gesture-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["gesture-open-detail"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        app = nil
    }

    func testEdgeSwipePopsAndRunsCleanupOnce() {
        openDetail()
        assertDisappearCount(0)

        swipeBack()

        assertRootVisible()
        assertDisappearCount(1)
    }

    func testCancelledEdgeSwipeKeepsPageAndDoesNotRunCleanup() {
        openDetail()

        // Public XCTest does not expose a multi-segment, finger-down touch path.
        // A slow drag below the completion threshold, held before release, tests
        // UIKit's cancellation path without private event injection. A right-then-
        // left reversal remains a separate manual check.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.003, dy: 0.52))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.52)),
                   withVelocity: XCUIGestureVelocity(rawValue: 90),
                   thenHoldForDuration: 0.7)

        XCTAssertTrue(app.staticTexts["gesture-detail"].exists)
        XCTAssertTrue(app.buttons["Back"].isHittable)
        assertDisappearCount(0)

        // A cancelled interaction must not strand the navigation controller.
        swipeBack()
        assertRootVisible()
        assertDisappearCount(1)
    }

    func testRootSwipeDoesNotPreventLaterNavigation() {
        for _ in 0..<2 {
            swipeBack()
            XCTAssertTrue(app.buttons["gesture-open-detail"].isHittable)
            openDetail()
            swipeBack()
            assertRootVisible()
        }
        assertDisappearCount(2)
    }

    func testNestedPagesCanBePoppedRepeatedly() {
        for _ in 0..<2 {
            openDetail()
            app.buttons["gesture-open-nested"].tap()
            XCTAssertTrue(app.staticTexts["gesture-nested"].waitForExistence(timeout: 5))

            swipeBack()

            XCTAssertTrue(app.staticTexts["gesture-detail"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["gesture-nested"].exists)
            XCTAssertTrue(app.buttons["gesture-open-nested"].isHittable)

            swipeBack()
            assertRootVisible()
        }
    }

    func testVerticalScrollingDoesNotNavigateBack() {
        openDetail()
        let bottom = app.staticTexts["gesture-bottom"]
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        for _ in 0..<12 where !bottom.isHittable {
            scroll.swipeUp(velocity: .fast)
        }

        XCTAssertTrue(bottom.isHittable, "The content should scroll to its bottom.")
        XCTAssertTrue(app.buttons["Back"].isHittable)
        assertDisappearCount(0)

        app.buttons["Back"].tap()
        assertRootVisible()
        assertDisappearCount(1)
    }

    func testSwipeDownDismissesSettingsAndKeepsDetail() {
        openDetail()
        app.buttons["gesture-open-settings"].tap()
        let settingsBar = app.navigationBars["Gesture settings"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 5))

        settingsBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.05,
                   thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)),
                   withVelocity: .fast,
                   thenHoldForDuration: 0)

        XCTAssertTrue(settingsBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["gesture-detail"].exists)
        XCTAssertTrue(app.buttons["gesture-open-settings"].isHittable)
        assertDisappearCount(0)

        // Dismissal must leave the underlying stack's edge gesture usable.
        swipeBack()
        assertRootVisible()
    }

    func testLockedBackGestureKeepsButtonEscapeAvailable() {
        openDetail()
        setBackGestureLocked(true)

        swipeBack()

        XCTAssertTrue(app.staticTexts["gesture-detail"].exists)
        assertDisappearCount(0)
        XCTAssertTrue(app.buttons["Back"].isHittable)
        app.buttons["Back"].tap()
        assertRootVisible()
        assertDisappearCount(1)
    }

    func testUnlockingRestoresBackGesture() {
        openDetail()
        setBackGestureLocked(true)
        swipeBack()
        XCTAssertTrue(app.staticTexts["gesture-detail"].exists)
        assertDisappearCount(0)

        setBackGestureLocked(false)
        swipeBack()

        assertRootVisible()
        assertDisappearCount(1)
    }

    func testVisibleSystemNavigationBarRestoresNativeBackBehavior() {
        openDetail()
        app.buttons["gesture-open-standard"].tap()
        XCTAssertTrue(app.staticTexts["gesture-standard"].waitForExistence(timeout: 5))
        let standardBar = app.navigationBars["Standard page"]
        XCTAssertTrue(standardBar.exists)
        XCTAssertTrue(standardBar.buttons.firstMatch.isHittable)

        swipeBack()

        XCTAssertTrue(app.staticTexts["gesture-detail"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["gesture-standard"].exists)
        XCTAssertFalse(standardBar.exists)
        swipeBack()
        assertRootVisible()
    }

    private func setBackGestureLocked(_ locked: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.switches["gesture-lock-back"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
        let expected = locked ? "1" : "0"
        if control.value as? String != expected {
            // SwiftUI exposes the label plus switch as one accessibility frame.
            // Hit the trailing physical control, not the center of its label.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed,
                       "The recording protection switch did not change.", file: file, line: line)
    }

    private func openDetail(file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["gesture-open-detail"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        button.tap()
        XCTAssertTrue(app.staticTexts["gesture-detail"].waitForExistence(timeout: 5), file: file, line: line)
    }

    private func assertRootVisible(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["gesture-open-detail"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(app.staticTexts["gesture-detail"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["gesture-open-detail"].isHittable, file: file, line: line)
    }

    private func assertDisappearCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        let counter = app.staticTexts["gesture-disappear-count"]
        XCTAssertTrue(counter.exists, file: file, line: line)
        XCTAssertEqual(counter.value as? String, String(expected), file: file, line: line)
    }

    private func swipeBack() {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.003, dy: 0.52))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.52)),
                   withVelocity: XCUIGestureVelocity(rawValue: 500),
                   thenHoldForDuration: 0)
    }
}

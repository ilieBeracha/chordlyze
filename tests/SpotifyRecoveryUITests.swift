import XCTest

/// Drives the real sheet and recovery view with an offline Spotify service.
/// The handoff button only simulates Spotify returning; it does not retry play.
final class SpotifyRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false, app.state == .runningForeground {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        app = nil
    }

    func testIntendedSongAlreadyPlayingClearsRecoveryWithoutRetrying() {
        openRecovery()
        assertNoPlaybackCommands()
        XCTAssertFalse(app.staticTexts["spotify-device-error"].exists)

        returnFromSpotify()

        // The correct active track is sufficient evidence. Neither a second
        // Play tap nor a seek should be necessary to remove the old warning.
        XCTAssertTrue(recoveryCard.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["live-position"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["spotify-device-error"].exists)
        XCTAssertFalse(element("spotify-recovery-waiting").exists)
        XCTAssertFalse(app.buttons["spotify-retry-playback"].exists)
        assertNoPlaybackCommands()
    }

    func testDifferentSongKeepsRecoveryAndTimesOutWithoutRetrying() {
        openRecovery(extraArguments: ["--spotify-handoff-wrong-track"])
        assertNoPlaybackCommands()
        let error = app.staticTexts["spotify-device-error"]
        XCTAssertFalse(error.exists, "This check must observe a new timeout, not an earlier warning.")

        returnFromSpotify()

        // Authorization recovery has a 12-second deadline. Allow scheduling
        // overhead without sleeps, retries, or depending on a transient spinner.
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        XCTAssertTrue(recoveryCard.exists)
        XCTAssertFalse(error.label.isEmpty)
        XCTAssertTrue(element("spotify-recovery-waiting").waitForNonExistence(timeout: 3))
        assertNoPlaybackCommands()
    }

    private var recoveryCard: XCUIElement { element("spotify-device-recovery") }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openRecovery(extraArguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        app.launchArguments = ["--song-sheet-preview", "--spotify-handoff-preview"] + extraArguments
        app.launch()
        let play = app.buttons["song-play-along"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), file: file, line: line)
        play.tap()
        XCTAssertTrue(recoveryCard.waitForExistence(timeout: 10), file: file, line: line)
    }

    private func returnFromSpotify(file: StaticString = #filePath, line: UInt = #line) {
        let handoff = app.buttons["handoff-return"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(handoff.isHittable, file: file, line: line)
        handoff.tap()
    }

    private func assertNoPlaybackCommands(file: StaticString = #filePath, line: UInt = #line) {
        for identifier in ["handoff-play-count", "handoff-seek-count"] {
            let counter = app.staticTexts[identifier]
            XCTAssertTrue(counter.exists, file: file, line: line)
            XCTAssertEqual(counter.value as? String, "0", identifier, file: file, line: line)
        }
    }
}

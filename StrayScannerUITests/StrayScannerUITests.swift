//
//  StrayScannerUITests.swift
//  StrayScannerUITests
//

import XCTest

final class StrayScannerUITests: XCTestCase {
    private let recordDuration: TimeInterval = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordShortDatasetSmokeFlow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launch()

        handleSystemPermissions(app: app)

        let newSessionButton = app.buttons["sessionList.recordNewSession"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 15), "Record new session button was not visible.")
        newSessionButton.tap()

        handleSystemPermissions(app: app)

        waitForRecordScreen(app: app)
        tapImportantFlag(app: app)
        tapRecordButton(app: app)
        sleep(UInt32(recordDuration))
        tapRecordButton(app: app)
        sleep(5)
    }

    private func handleSystemPermissions(app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButtons = [
            "Allow While Using App",
            "Allow Once",
            "OK",
            "Allow",
            "Continue"
        ]

        for _ in 0..<5 {
            var tapped = false
            for title in allowButtons {
                let button = springboard.buttons[title]
                if button.waitForExistence(timeout: 1) {
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped {
                break
            }
        }
        _ = app.wait(for: .runningForeground, timeout: 2)
    }

    private func waitForRecordScreen(app: XCUIApplication) {
        let recordButton = app.descendants(matching: .any)["recordSession.recordButton"].firstMatch
        if recordButton.waitForExistence(timeout: 5) {
            return
        }

        let fpsButton = app.buttons["recordSession.fpsButton"]
        if fpsButton.waitForExistence(timeout: 15) {
            return
        }
    }

    private func tapRecordButton(app: XCUIApplication) {
        let recordButton = app.descendants(matching: .any)["recordSession.recordButton"].firstMatch
        if recordButton.exists && recordButton.isHittable {
            recordButton.tap()
            return
        }

        let bottomCenter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        bottomCenter.tap()
    }

    private func tapImportantFlag(app: XCUIApplication) {
        let importantButton = app.buttons["recordSession.importantButton"]
        if importantButton.waitForExistence(timeout: 5), importantButton.isHittable {
            importantButton.tap()
            return
        }

        let lowerMiddle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.77))
        lowerMiddle.tap()
    }
}

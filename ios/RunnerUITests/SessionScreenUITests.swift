import XCTest

final class SessionScreenUITests: XCTestCase {
    func testSignedOutScreenOnLaunchAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        assertSignedOut(in: app)
        app.terminate()
        app.launch()
        assertSignedOut(in: app)
    }

    private func assertSignedOut(in app: XCUIApplication) {
        let signIn = app.buttons["Sign in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30))
        XCTAssertTrue(signIn.isHittable)
        XCTAssertFalse(app.buttons["Sign out"].exists)
    }
}

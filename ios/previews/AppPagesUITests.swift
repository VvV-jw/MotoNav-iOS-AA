import XCTest

/// These exercise actual production SwiftUI buttons with disposable service
/// adapters. Persistence/navigation correctness has separate production tests.
final class AppPagesUITests: XCTestCase {
    private func launch(_ scene: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [scene]
        app.launch()
        XCTAssertTrue(app.staticTexts["界面自测 · 合成输入 · 未接真机"].waitForExistence(timeout: 10))
        return app
    }
    func testMainTabsRemainReachable() {
        let app = launch("page-home-top")
        for title in ["圆屏显示", "导航语音", "圆屏设置", "地图 Key", "首页搜索"] {
            let tab = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(tab.isHittable, "Tab remains reachable: \(title)")
            tab.tap()
        }
    }
    func testContinueSavedPreparationCallsControlOnce() {
        let app = launch("page-maintenance-saved")
        let button = app.buttons["preparation-continue"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        XCTAssertFalse(button.exists)
        XCTAssertTrue(app.staticTexts["preview-action-counts"].label.contains("继续 1"))
        XCTAssertFalse(app.buttons["结束导航"].exists)
    }
    func testDiscardSavedPreparation() {
        let app = launch("page-maintenance-saved")
        app.buttons["preparation-discard"].tap()
        XCTAssertFalse(app.buttons["preparation-continue"].exists)
        XCTAssertTrue(app.staticTexts["preview-action-counts"].label.contains("放弃 1"))
    }
    func testMismatchedStyleRemainsRecoverable() {
        let app = launch("page-maintenance-mismatch")
        app.buttons["preparation-continue"].tap()
        XCTAssertTrue(app.buttons["preparation-continue"].exists)
        XCTAssertTrue(app.staticTexts["preview-action-counts"].label.contains("继续 1"))
        XCTAssertFalse(app.buttons["结束导航"].exists)
    }
    func testSavingAndFailureDoNotDisableMaintenance() {
        for scene in ["page-maintenance-saving", "page-maintenance-failed", "page-maintenance-too-large"] {
            let app = launch(scene)
            XCTAssertTrue(app.buttons["preparation-continue"].isEnabled)
            XCTAssertTrue(app.buttons["preparation-discard"].isEnabled)
        }
    }
    func testLargeFontBottomTabsRemainReachable() {
        let app = launch("page-home-large-font")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "圆屏显示")).firstMatch.isHittable)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "地图 Key")).firstMatch.isHittable)
    }
}

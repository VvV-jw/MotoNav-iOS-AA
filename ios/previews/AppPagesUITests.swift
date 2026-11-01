import XCTest

/// These exercise actual production SwiftUI buttons with disposable service
/// adapters. Persistence/navigation correctness has separate production tests.
final class AppPagesUITests: XCTestCase {
    func testDayNightSwitchPreservesActiveNavigation() {
        let app = launch("page-home-active-muted")
        app.buttons.matching(NSPredicate(format: "label == %@", "圆屏显示")).firstMatch.tap()
        let picker = app.segmentedControls["palette.mode"]
        for _ in 0..<8 {
            if picker.exists && picker.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(picker.isHittable)
        picker.buttons["夜间"].tap()
        XCTAssertEqual(app.staticTexts["preview-theme"].label, "夜间")
        XCTAssertTrue(picker.isHittable)
        picker.buttons["白天"].tap()
        XCTAssertEqual(app.staticTexts["preview-theme"].label, "白天")
        XCTAssertEqual(app.staticTexts["preview-navigation-counts"].label, "测试导航调用：开始 0 · 停止 0")
        app.buttons.matching(NSPredicate(format: "label == %@", "地图")).firstMatch.tap()
        XCTAssertTrue(app.buttons["回到导航"].isHittable)
        XCTAssertTrue(app.staticTexts["导航语音已静音"].exists)
    }
    private func launch(_ scene: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [scene]
        app.launch()
        if scene.hasPrefix("page-vias-editor") {
            XCTAssertTrue(app.buttons["vias.apply"].waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(app.staticTexts["界面自测 · 合成输入 · 未接真机"].waitForExistence(timeout: 10))
        }
        return app
    }
    func testMainTabsRemainReachable() {
        let app = launch("page-home-top")
        for title in ["圆屏显示", "导航语音", "设备设置", "地图 Key", "地图"] {
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
    func testLargeFontSimulationControlsRemainReachable() {
        let app = launch("page-navigation-drive-muted-large-font")
        let home = app.buttons["navigation.home"]
        let voice = app.buttons["navigation.resumeVoice"]
        let speed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "km/h")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.isHittable)
        XCTAssertTrue(voice.isHittable)
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        XCTAssertTrue(speed.isHittable)
    }

    func testJourneyLibraryEmptyRenameAndDelete() {
        var app = launch("page-journeys-empty")
        XCTAssertTrue(app.staticTexts["在路线方案下收藏整条行程，即可在这里使用。"].exists)
        app = launch("page-journeys-populated")
        XCTAssertTrue(app.staticTexts["测试周末三站行程"].exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "改名")).firstMatch.tap()
        let field = app.textFields["行程名称（最多80字）"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "测试周末三站行程".count) + "Renamed preview trip")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["Renamed preview trip"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["测试周末三站行程"].exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "删除")).firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Renamed preview trip"].exists)
        XCTAssertTrue(app.staticTexts["测试摩托车三站行程"].exists)
    }

    func testSavedJourneyRequiresFreshPhoneLocation() {
        let app = launch("page-journeys-populated")
        app.buttons.matching(NSPredicate(format: "label == %@", "从当前位置规划")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["请等待新的手机定位，再使用常用行程"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["测试周末三站行程"].exists)
        XCTAssertFalse(app.buttons["结束导航"].exists)
    }

    func testViaDraftCancelPreservesOriginalOrder() {
        let app = launch("page-vias-editor")
        app.buttons["vias.down.0"].tap()
        app.buttons["vias.delete.2"].tap()
        app.buttons["vias.cancel"].tap()
        let committed = app.staticTexts["preview-vias-committed"]
        XCTAssertTrue(committed.waitForExistence(timeout: 5))
        XCTAssertEqual(committed.label, "测试补给站 → 测试观景台 → 测试午餐点")
        XCTAssertEqual(app.staticTexts["preview-vias-callbacks"].label, "应用 0 · 取消 1")
        app.buttons["preview-vias-open"].tap()
        XCTAssertTrue(app.staticTexts["1. 测试补给站"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3. 测试午餐点"].exists)
    }

    func testViaDraftAppliesReorderAndDeletionOnce() {
        let app = launch("page-vias-editor")
        app.buttons["vias.down.0"].tap()
        app.buttons["vias.delete.2"].tap()
        app.buttons["vias.apply"].tap()
        let committed = app.staticTexts["preview-vias-committed"]
        XCTAssertTrue(committed.waitForExistence(timeout: 5))
        XCTAssertEqual(committed.label, "测试观景台 → 测试补给站")
        XCTAssertEqual(app.staticTexts["preview-vias-callbacks"].label, "应用 1 · 取消 0")
    }

    func testMutedHomeRestoresVoiceInPlace() {
        let app = launch("page-home-active-muted")
        XCTAssertTrue(app.staticTexts["导航语音已静音"].exists)
        app.buttons["navigation.resumeVoice"].tap()
        XCTAssertTrue(app.staticTexts["导航语音播报已开启"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation.resumeVoice"].exists)
        XCTAssertTrue(app.buttons["回到导航"].exists)
        XCTAssertEqual(app.staticTexts["preview-navigation-counts"].label, "测试导航调用：开始 0 · 停止 0")
    }

    func testReturnToDriveNavigationDoesNotStartOrStopTrip() {
        let app = launch("page-home-active-muted")
        for _ in 0..<2 {
            app.buttons["回到导航"].tap()
            if app.buttons["navigation.more"].exists { app.buttons["navigation.more"].tap() }
            let home = app.buttons["navigation.home"]
            XCTAssertTrue(home.waitForExistence(timeout: 5))
            home.tap()
            XCTAssertTrue(app.staticTexts["导航继续运行中"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["导航语音已静音"].exists)
        }
        XCTAssertEqual(app.staticTexts["preview-navigation-counts"].label, "测试导航调用：开始 0 · 停止 0")
    }

    func testIndependentNavigationRestoresVoiceWithoutStopping() {
        let app = launch("page-navigation-independent-muted")
        app.buttons["navigation.more"].tap()
        XCTAssertTrue(app.staticTexts["导航语音已静音"].exists)
        app.buttons["navigation.resumeVoice"].tap()
        XCTAssertTrue(app.staticTexts["导航语音播报已开启"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["返回首页"].exists)
        XCTAssertTrue(app.staticTexts["沿测试道路直行"].exists)
    }
    func testMapHomeSearchKeepsMotorcyclePlanningExplicit() {
        let app = launch("page-home-search-flow")
        let field = app.textFields["home.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.locate"].isHittable)
        field.tap(); field.typeText("test")
        app.buttons.matching(NSPredicate(format: "label == %@", "搜索")).firstMatch.tap()
        let result = app.buttons.containing(.staticText, identifier: "测试目的地").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
        let picker = app.segmentedControls["home.travelMode"]
        XCTAssertTrue(picker.buttons["摩托车 SDK"].exists)
        XCTAssertTrue(picker.buttons["驾车 SDK"].exists)
        XCTAssertTrue(app.textFields["sdk.motorcycle.plate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0, "SDK planning never opens the old web route flow")
        XCTAssertTrue(app.staticTexts["目的地：测试目的地"].exists)
        XCTAssertFalse(app.buttons["navigation.end"].exists)
    }

    func testIndependentCompactControlsExpandWithoutEndingTrip() {
        let app = launch("page-navigation-independent")
        XCTAssertTrue(app.buttons["navigation.overview"].isHittable)
        XCTAssertTrue(app.buttons["navigation.resumeVoice"].isHittable)
        XCTAssertFalse(app.buttons["navigation.end"].exists)
        app.buttons["navigation.more"].tap()
        XCTAssertTrue(app.buttons["navigation.home"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.buttons["navigation.end"].exists)
        app.buttons["navigation.more"].tap()
        XCTAssertTrue(app.buttons["navigation.overview"].exists)
    }

    func testCruiseStartNavigationRequiresExplicitExit() {
        checkNativeCruiseNavigation(buttonID: "navigation.start", simulate: false)
    }

    func testCruiseSimulationRequiresExplicitExit() {
        checkNativeCruiseNavigation(buttonID: "navigation.simulate", simulate: true)
    }

    func testCruiseWithoutReadyRouteStillExplainsBothNavigationActions() {
        let app = launch("page-cruise-native-unready")
        for identifier in ["navigation.start", "navigation.simulate"] {
            tapVisible(app.buttons[identifier], in: app)
            assertCruiseAlert(in: app, attachment: "unready-\(identifier)")
            dismissCruiseAlert(in: app, endingCruise: false)
            assertCruiseState(in: app, cruising: true)
            assertCruiseCalls(in: app)
        }
        tapVisible(app.buttons["navigation.start"], in: app)
        assertCruiseAlert(in: app, attachment: "unready-confirm-exit")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1)
        XCTAssertFalse(app.buttons["navigation.start"].isEnabled)
        XCTAssertFalse(app.buttons["navigation.simulate"].isEnabled)
    }

    func testCruiseSearchSelectionDoesNotReplaceDestinationOrPlan() {
        let app = launch("page-cruise-search")
        let field = app.textFields["home.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("test")
        app.buttons.matching(NSPredicate(format: "label == %@", "搜索")).firstMatch.tap()
        let result = app.buttons.containing(.staticText, identifier: "测试目的地").firstMatch
        tapVisible(result, in: app)
        assertCruiseAlert(in: app, attachment: "search-result-during-cruise")
        dismissCruiseAlert(in: app, endingCruise: false)
        assertCruiseState(in: app, cruising: true)
        assertCruiseCalls(in: app)
        XCTAssertFalse(app.staticTexts["目的地：测试目的地"].exists)
        tapVisible(result, in: app)
        assertCruiseAlert(in: app, attachment: "search-result-confirm-exit")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1)
        XCTAssertFalse(app.staticTexts["目的地：测试目的地"].exists)
        tapVisible(result, in: app)
        XCTAssertTrue(app.staticTexts["目的地：测试目的地"].waitForExistence(timeout: 5))
        assertCruiseState(in: app, cruising: false, ready: true)
        assertCruiseCalls(in: app, plans: 1, cruiseStops: 1)
    }

    func testCruiseRouteImportOnlyStopsCruiseAfterConfirmation() {
        let app = launch("page-cruise-import")
        tapVisible(app.buttons["导入路线"], in: app)
        assertCruiseAlert(in: app, attachment: "route-import-during-cruise")
        dismissCruiseAlert(in: app, endingCruise: false)
        assertCruiseState(in: app, cruising: true)
        assertCruiseCalls(in: app)
        tapVisible(app.buttons["粘贴高德分享的路线"], in: app)
        assertCruiseAlert(in: app, attachment: "route-import-confirm-exit")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1)
        XCTAssertFalse(app.staticTexts["正在读取高德分享的路线…"].exists)
        XCTAssertFalse(app.staticTexts["剪贴板里没有高德的分享链接：先在高德里打开路线 → 分享 → 复制链接"].exists)
    }

    func testCruiseRecoveryDoesNotRestoreOrNavigateUntilRetried() {
        let app = launch("page-cruise-restore")
        let restore = app.buttons["重新规划上次路线"]
        tapVisible(restore, in: app)
        assertCruiseAlert(in: app, attachment: "restore-route-during-cruise")
        dismissCruiseAlert(in: app, endingCruise: false)
        assertCruiseState(in: app, cruising: true)
        assertCruiseCalls(in: app)
        tapVisible(restore, in: app)
        assertCruiseAlert(in: app, attachment: "restore-route-confirm-exit")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1)
        XCTAssertTrue(restore.exists, "Confirming the alert must not consume the pending route")
        tapVisible(restore, in: app)
        XCTAssertTrue(app.staticTexts["目的地：测试恢复目的地"].waitForExistence(timeout: 5))
        assertCruiseState(in: app, cruising: false, ready: true)
        assertCruiseCalls(in: app, restores: 1, cruiseStops: 1)
    }

    func testCruiseSavedJourneyPlanningRequiresExplicitExit() {
        let app = launch("page-cruise-journeys")
        let plan = app.buttons.matching(NSPredicate(format: "label == %@", "从当前位置规划")).firstMatch
        tapVisible(plan, in: app)
        assertCruiseAlert(in: app, attachment: "saved-journey-during-cruise")
        dismissCruiseAlert(in: app, endingCruise: false)
        assertCruiseState(in: app, cruising: true)
        assertCruiseCalls(in: app)
        XCTAssertTrue(app.staticTexts["测试周末三站行程"].exists)
        tapVisible(plan, in: app)
        assertCruiseAlert(in: app, attachment: "saved-journey-confirm-exit")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1)
        tapVisible(plan, in: app)
        XCTAssertTrue(app.staticTexts["请等待新的手机定位，再使用常用行程"].waitForExistence(timeout: 5))
        assertCruiseCalls(in: app, cruiseStops: 1)
    }

    func testCruiseIndependentStartRequiresExplicitExit() {
        checkIndependentCruiseNavigation(buttonID: "independent.start", simulate: false)
    }

    func testCruiseIndependentSimulationRequiresExplicitExit() {
        checkIndependentCruiseNavigation(buttonID: "independent.simulate", simulate: true)
    }

    func testCruiseIndependentPlanningWithoutCandidateExplainsExit() {
        let app = launch("page-cruise-independent-empty")
        let plan = app.buttons["independent.plan"]
        tapVisible(plan, in: app)
        assertCruiseAlert(in: app, attachment: "independent-empty-during-cruise")
        dismissCruiseAlert(in: app, endingCruise: false)
        assertCruiseState(in: app, cruising: true)
        assertCruiseCalls(in: app)
        tapVisible(plan, in: app)
        assertCruiseAlert(in: app, attachment: "independent-empty-confirm-exit")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1)
        XCTAssertFalse(plan.isEnabled)
        XCTAssertFalse(app.buttons["independent.start"].exists)
    }

    private func checkNativeCruiseNavigation(buttonID: String, simulate: Bool) {
        let app = launch("page-cruise-native-ready")
        tapVisible(app.buttons[buttonID], in: app)
        assertCruiseAlert(in: app, attachment: "ready-\(buttonID)")
        dismissCruiseAlert(in: app, endingCruise: false)
        assertCruiseState(in: app, cruising: true, ready: true)
        assertCruiseCalls(in: app)
        tapVisible(app.buttons[buttonID], in: app)
        assertCruiseAlert(in: app, attachment: "ready-confirm-\(buttonID)")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false, ready: true)
        assertCruiseCalls(in: app, cruiseStops: 1)
        XCTAssertTrue(app.buttons["navigation.start"].isEnabled)
        XCTAssertTrue(app.buttons["navigation.simulate"].isEnabled)
        tapVisible(app.buttons[buttonID], in: app)
        if app.buttons["navigation.more"].waitForExistence(timeout: 5) { app.buttons["navigation.more"].tap() }
        let home = app.buttons["navigation.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5)); home.tap()
        assertCruiseState(in: app, cruising: false, navigating: true, ready: true, simulate: simulate)
        assertCruiseCalls(in: app, starts: 1, cruiseStops: 1)
    }

    private func checkIndependentCruiseNavigation(buttonID: String, simulate: Bool) {
        let app = launch("page-cruise-independent-ready")
        tapVisible(app.buttons[buttonID], in: app)
        assertCruiseAlert(in: app, attachment: "ready-\(buttonID)")
        dismissCruiseAlert(in: app, endingCruise: false)
        assertCruiseState(in: app, cruising: true)
        assertCruiseCalls(in: app)
        tapVisible(app.buttons[buttonID], in: app)
        assertCruiseAlert(in: app, attachment: "ready-confirm-\(buttonID)")
        dismissCruiseAlert(in: app, endingCruise: true)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1)
        tapVisible(app.buttons[buttonID], in: app)
        assertCruiseState(in: app, cruising: false)
        assertCruiseCalls(in: app, cruiseStops: 1, independentStarts: 1, independentRunning: true, independentSimulation: simulate)
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        var trace: [String] = []
        func attachFailure(_ reason: String) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "tap-visible-failure"; screenshot.lifetime = .keepAlways
            add(screenshot)
            let target = element.exists ? "\(element.debugDescription)\nframe: \(element.frame)" : "Target does not exist"
            let scrolls = app.scrollViews.allElementsBoundByIndex.map { scroll in
                scroll.exists ? "\(scroll.debugDescription)\nframe: \(scroll.frame)" : "Scroll view no longer exists"
            }.joined(separator: "\n\n")
            let details = XCTAttachment(string: "\(reason)\nTarget:\n\(target)\nApp frame: \(app.frame)\nGestures:\n\(trace.joined(separator: "\n"))\nScroll views:\n\(scrolls)\nUI hierarchy:\n\(app.debugDescription)")
            details.name = "tap-visible-hierarchy-and-frames"; details.lifetime = .keepAlways
            add(details)
        }
        let exists = element.waitForExistence(timeout: 5)
        if !exists { attachFailure("Target did not appear") }
        XCTAssertTrue(exists, "Target did not appear", file: file, line: line)
        guard exists else { return }
        let key = element.identifier
        let targetMatch = key.isEmpty ? NSPredicate(format: "label == %@", element.label)
            : NSPredicate(format: "identifier == %@", key)
        for attempt in 0..<12 {
            if !element.exists || element.isHittable { break }
            let viewport = app.frame
            let containers = app.scrollViews.containing(targetMatch).allElementsBoundByIndex.compactMap { scroll -> (XCUIElement, CGRect)? in
                guard scroll.exists else { return nil }
                let visible = scroll.frame.intersection(viewport)
                guard !visible.isNull, visible.width > 40, visible.height > 60 else { return nil }
                return (scroll, visible)
            }
            // A SwiftUI scroll view can expose a content-sized frame. Drag only
            // inside its on-screen intersection, using the target's own container.
            guard let (_, visible) = containers.min(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
                trace.append("Attempt \(attempt + 1): no visible scroll view contains the target")
                break
            }
            guard element.exists else { break }
            let targetFrame = element.frame
            let distance = min(visible.height * 0.55, max(60, abs(targetFrame.midY - visible.midY)))
            let upward = targetFrame.isEmpty || targetFrame.midY >= visible.midY
            let x = visible.maxX - min(18, visible.width * 0.1)
            let startY = visible.midY + (upward ? distance / 2 : -distance / 2)
            let endY = visible.midY + (upward ? -distance / 2 : distance / 2)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: x - viewport.minX, dy: startY - viewport.minY))
            let end = origin.withOffset(CGVector(dx: x - viewport.minX, dy: endY - viewport.minY))
            trace.append("Attempt \(attempt + 1): target \(targetFrame), visible scroll \(visible), drag (\(x), \(startY)) -> (\(x), \(endY))")
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let enabled = element.exists && element.isEnabled
        let hittable = element.exists && element.isHittable
        if !enabled || !hittable { attachFailure("Target enabled: \(enabled), hittable: \(hittable)") }
        XCTAssertTrue(enabled, "Target must be enabled", file: file, line: line)
        XCTAssertTrue(hittable, "Target must be visible and hittable", file: file, line: line)
        guard enabled && hittable else { return }
        element.tap()
    }

    private func assertCruiseAlert(in app: XCUIApplication, attachment name: String) {
        let alert = app.alerts["请先关闭巡航"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["继续巡航"].isHittable)
        XCTAssertTrue(alert.buttons["结束巡航"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "cruise-alert-\(name)"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissCruiseAlert(in app: XCUIApplication, endingCruise: Bool) {
        let alert = app.alerts["请先关闭巡航"]
        alert.buttons[endingCruise ? "结束巡航" : "继续巡航"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    private func assertCruiseState(in app: XCUIApplication, cruising: Bool, navigating: Bool = false, ready: Bool = false, simulate: Bool = false) {
        assertLabel(app.staticTexts["preview-cruise-state"],
            equals: "巡航 \(cruising ? 1 : 0) · SDK导航 \(navigating ? 1 : 0) · 路线就绪 \(ready ? 1 : 0) · SDK模拟 \(simulate ? 1 : 0)")
    }

    private func assertCruiseCalls(in app: XCUIApplication, starts: Int = 0, stops: Int = 0, plans: Int = 0,
                                  restores: Int = 0, cruiseStops: Int = 0, independentStarts: Int = 0,
                                  independentRunning: Bool = false, independentSimulation: Bool = false) {
        assertLabel(app.staticTexts["preview-cruise-calls"],
            equals: "SDK开始 \(starts) · SDK停止 \(stops) · 规划 \(plans) · 恢复 \(restores) · 结束巡航 \(cruiseStops)")
        assertLabel(app.staticTexts["preview-independent-calls"],
            equals: "独立导航 \(independentRunning ? 1 : 0) · 独立模拟 \(independentSimulation ? 1 : 0) · 独立开始 \(independentStarts) · 独立停止 0")
    }

    private func assertLabel(_ element: XCUIElement, equals expected: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed)
        XCTAssertEqual(element.label, expected)
    }
}

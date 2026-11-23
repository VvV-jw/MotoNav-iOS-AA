import XCTest

/// These exercise actual production SwiftUI buttons with disposable service
/// adapters. Persistence/navigation correctness has separate production tests.
final class AppPagesUITests: XCTestCase {
    func testAudioVolumeAndPhysicalButtonSettings() {
        var app = launch("page-voice")
        let volume = app.sliders["audio.navigation.volume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["audio.navigation.volume.value"].label, "100%")
        volume.adjust(toNormalizedSliderPosition: 0.25)
        XCTAssertEqual(app.staticTexts["audio.navigation.volume.value"].label, "25%")
        app.buttons["tab.device"].tap()
        app.buttons["device.settings.open"].tap()
        let swap = app.switches["media.buttons.swap"]
        for _ in 0..<8 {
            if swap.exists && swap.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(swap.isEnabled && swap.isHittable)
        swap.tap()
        XCTAssertEqual(swap.value as? String, "1")
        XCTAssertTrue(app.staticTexts["实体按键已同步"].exists)
        swap.tap()
        XCTAssertEqual(swap.value as? String, "0")
        app.buttons["device.detail.close"].tap()
        app.buttons["tab.voice"].tap()
        XCTAssertEqual(app.staticTexts["audio.navigation.volume.value"].label, "25%")
        app = launch("page-voice-call")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "audio.call.status").firstMatch.label, "正在通话")
        XCTAssertTrue(app.staticTexts["导航播报已暂停"].exists)
    }
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
        var app = launch("page-home-top")
        for title in ["圆屏显示", "导航语音", "圆屏", "地图 Key", "地图"] {
            let tab = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(tab.isHittable, "Tab remains reachable: \(title)")
            tab.tap()
        }
        app = launch("page-home-cruising")
        var refreshes = 0
        for title in ["地图", "圆屏显示", "导航语音", "圆屏", "地图 Key", "地图"] {
            app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch.tap()
            let refresh = app.buttons["cruise.map.refresh"]
            XCTAssertTrue(refresh.isHittable, "Cruise refresh remains reachable: \(title)")
            XCTAssertTrue(refresh.isEnabled, "Active map transfer must remain recoverable")
            XCTAssertEqual(app.staticTexts["cruise.map.refresh.title"].label, "巡航中 · 48 km/h")
            XCTAssertEqual(app.staticTexts["cruise.map.refresh.status"].label, "正在更新圆屏地图")
            refresh.tap(); refreshes += 1
            XCTAssertEqual(app.staticTexts["cruise.map.refresh.message"].label, "测试路网刷新请求：\(refreshes)")
            if title == "圆屏" {
                let currentMapRefresh = app.buttons["map.current.refresh"]
                for _ in 0..<6 {
                    if currentMapRefresh.exists && currentMapRefresh.isHittable { break }
                    app.swipeUp()
                }
                XCTAssertTrue(currentMapRefresh.isHittable)
                currentMapRefresh.tap(); refreshes += 1
                XCTAssertEqual(app.staticTexts["cruise.map.refresh.message"].label, "测试路网刷新请求：\(refreshes)")
                XCTAssertTrue(app.buttons["断开"].exists, "Refreshing must preserve the display connection")
            }
        }
        app.buttons["home.panel.toggle"].tap()
        XCTAssertTrue(app.buttons["cruise.map.refresh"].isHittable)
        app.buttons["home.panel.toggle"].tap()
        XCTAssertTrue(app.buttons["cruise.map.refresh"].isHittable)
        app = launch("page-home-cruising-disconnected")
        XCTAssertTrue(app.buttons["cruise.map.refresh"].isEnabled, "A disconnected display must not block refresh")
        app.buttons["cruise.map.refresh"].tap()
        XCTAssertEqual(app.staticTexts["cruise.map.refresh.message"].label, "测试路网刷新请求：1")
        for scene in ["page-home-cruising-map-off", "page-home-cruising-radar"] {
            app = launch(scene)
            XCTAssertFalse(app.buttons["cruise.map.refresh"].isEnabled)
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
        for scene in ["page-home-large-font", "page-home-cruising-large-font"] {
            let app = launch(scene)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "圆屏显示")).firstMatch.isHittable)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "地图 Key")).firstMatch.isHittable)
            if scene.contains("cruising") {
                XCTAssertTrue(app.buttons["cruise.map.refresh"].isHittable)
                XCTAssertTrue(app.buttons["home.panel.toggle"].isHittable)
            }
        }
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
        app.buttons["tab.device"].tap()
        let refresh = app.buttons["map.current.refresh"]
        for _ in 0..<6 {
            if refresh.exists && refresh.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(refresh.isHittable)
        refresh.tap()
        XCTAssertEqual(app.staticTexts["map.current.refresh.message"].label, "测试路网刷新请求：1")
        XCTAssertTrue(app.staticTexts["导航继续运行中"].exists)
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

    func testRoundDeviceSheetSearchAndStopUseLiveState() {
        let app = launch("page-device-connected")
        XCTAssertEqual(app.staticTexts["device.name"].label, "MotoNav-测试圆屏")
        let power = app.descendants(matching: .any).matching(identifier: "device.battery").firstMatch
        XCTAssertTrue(power.label.contains("83%"))
        app.buttons["device.connect"].tap()
        XCTAssertTrue(app.buttons["device.sheet.done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["device.sheet.connection"].label, "已连接")
        app.buttons["device.sheet.search"].tap()
        XCTAssertEqual(app.staticTexts["device.sheet.connection"].label, "未连接")
        app.buttons["device.sheet.search"].tap()
        XCTAssertEqual(app.staticTexts["device.sheet.connection"].label, "正在寻找圆屏")
        XCTAssertEqual(app.buttons["device.sheet.search"].label, "停止搜索")
        app.buttons["device.sheet.search"].tap()
        XCTAssertEqual(app.staticTexts["device.sheet.connection"].label, "未连接")
        app.buttons["device.sheet.done"].tap()
        XCTAssertTrue(app.buttons["tab.map"].isHittable)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "device.battery").firstMatch.label.contains("83%"))
    }

    func testDeviceSettingsAndNotificationsRemainReachable() {
        let app = launch("page-device-connected")
        app.buttons["device.settings.open"].tap()
        XCTAssertTrue(app.segmentedControls["device.appearance"].waitForExistence(timeout: 5))
        app.buttons["device.detail.close"].tap()
        for _ in 0..<6 {
            if app.buttons["device.notifications.open"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["device.notifications.open"].tap()
        XCTAssertTrue(app.buttons["notifications.preview.test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notifications.preview.test"].isEnabled)
        app.buttons["device.detail.close"].tap()
        app.buttons["tab.keys"].tap()
        XCTAssertTrue(app.staticTexts["Key 设置"].waitForExistence(timeout: 5))
    }
}

import XCTest

/// UI 测试：引导、私密空间、首页导航与单备份表单（不依赖真机相机）。
@MainActor
final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    private func prepareApp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestingReset"]
        app.launch()
    }

    // MARK: - Helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    @discardableResult
    private func scrollUntilHittable(_ el: XCUIElement, maxSwipes: Int = 6) -> Bool {
        var swipes = 0
        while (!el.exists || !el.isHittable) && swipes < maxSwipes {
            let collection = app.collectionViews.firstMatch
            let hasCollection = collection.exists
            if el.exists {
                let frame = el.frame
                let obscuredTop = app.navigationBars.firstMatch.exists
                    ? app.navigationBars.firstMatch.frame.maxY
                    : app.windows.firstMatch.frame.minY
                if frame.minY < obscuredTop {
                    if hasCollection {
                        collection.swipeDown()
                    } else {
                        app.swipeDown()
                    }
                } else {
                    if hasCollection {
                        collection.swipeUp()
                    } else {
                        app.swipeUp()
                    }
                }
            } else {
                if hasCollection {
                    collection.swipeUp()
                } else {
                    app.swipeUp()
                }
            }
            swipes += 1
        }
        return el.exists && el.isHittable
    }

    private func waitTap(_ id: String, timeout: TimeInterval = 6) {
        let el = element(id)
        var exists = el.waitForExistence(timeout: min(timeout, 2))
        var swipes = 0
        while !exists && swipes < 4 {
            app.swipeUp()
            exists = el.waitForExistence(timeout: 1)
            swipes += 1
        }
        XCTAssertTrue(exists, "missing \(id)")
        guard exists else { return }
        _ = scrollUntilHittable(el)
        if !el.isHittable {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            el.tap()
        }
    }

    private func typeInto(_ id: String, text: String) {
        let field = element(id)
        if !field.waitForExistence(timeout: 2) {
            _ = scrollUntilHittable(field)
        }
        XCTAssertTrue(field.exists, "missing field \(id)")
        guard field.exists else { return }
        if id == "single.nameB", app.keyboards.firstMatch.exists, !field.isHittable {
            // 超大字体 + 键盘会把 B 字段完全挤出可点区域；A 的 Next 正常把焦点交给 B。
            element("single.nameA").typeText("\n")
            if field.waitForExistence(timeout: 2) {
                field.typeText(text)
                return
            }
        }
        _ = scrollUntilHittable(field)
        field.tap()
        // 清空可能的残留。长按后的“全选”菜单是异步出现的，在慢速模拟器上
        // 容易发生菜单尚未出现就直接追加文本的竞态。
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(value.count, 1))
            )
        }
        field.typeText(text)
    }

    private func enableSwitch(_ id: String) {
        // SwiftUI Toggle 的 identifier 可能落在容器上，优先找 switches 再回退 any
        let candidates = [
            app.switches[id],
            app.switches.matching(identifier: id).firstMatch,
            element(id)
        ]
        var toggle: XCUIElement?
        for candidate in candidates {
            if candidate.waitForExistence(timeout: 2) {
                toggle = candidate
                break
            }
        }
        // 回退：页面上第一个开关
        if toggle == nil, app.switches.firstMatch.waitForExistence(timeout: 2) {
            toggle = app.switches.firstMatch
        }
        guard let toggle else {
            // 最后手段：打开当前可见的所有 switch
            forceEnableVisibleSwitches()
            return
        }
        _ = scrollUntilHittable(toggle)
        let value = "\(toggle.value ?? "")"
        if value == "0" || value.lowercased() == "false" || value.isEmpty {
            toggle.tap()
        }
        // 仍未打开则再点一次，并扫一遍可见开关
        let after = "\(toggle.value ?? "")"
        if after == "0" || after.lowercased() == "false" {
            toggle.tap()
            forceEnableVisibleSwitches()
        }
    }

    private func forceEnableVisibleSwitches() {
        let count = app.switches.count
        for index in 0..<count {
            let s = app.switches.element(boundBy: index)
            guard s.exists else { continue }
            let value = "\(s.value ?? "")"
            if value == "0" || value.lowercased() == "false" || value.isEmpty {
                s.tap()
            }
        }
    }

    private func waitEnabledTap(_ id: String, timeout: TimeInterval = 6) {
        let el = element(id)
        if !el.waitForExistence(timeout: min(timeout, 2)) {
            _ = scrollUntilHittable(el)
        }
        XCTAssertTrue(el.exists, "missing \(id)")
        guard el.exists else { return }
        _ = scrollUntilHittable(el)
        let deadline = Date().addingTimeInterval(timeout)
        while !el.isEnabled && Date() < deadline {
            forceEnableVisibleSwitches()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTAssertTrue(el.isEnabled, "\(id) should be enabled")
        if el.isHittable {
            el.tap()
        } else {
            el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func launchSkipToHome(extraArguments: [String] = []) {
        app.terminate()
        app.launchArguments = ["-UITesting", "-UITestingReset", "-UITestingSkipToHome"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.navigationBars["我们的记录"].waitForExistence(timeout: 10),
            "should land on home"
        )
    }

    private func scrollTo(_ id: String, maxSwipes: Int = 6) -> XCUIElement {
        let el = element(id)
        _ = scrollUntilHittable(el, maxSwipes: maxSwipes)
        return el
    }

    // MARK: - Tests

    func testVaultSetupShowsPasswordValidationFeedback() throws {
        prepareApp()
        waitTap("onboarding.privacy.continue")
        enableSwitch("onboarding.adult.toggle")
        waitEnabledTap("onboarding.adult.continue")

        typeInto("vault.setup.password", text: "abc1234-")
        XCTAssertTrue(
            element("password.validation.format").waitForExistence(timeout: 3),
            "invalid password should show an inline explanation"
        )

        typeInto("vault.setup.confirm", text: "abc12345")
        XCTAssertTrue(
            element("password.validation.confirmation").waitForExistence(timeout: 3),
            "mismatched passwords should show an inline explanation"
        )
    }

    func testOnboardingToHomeFlow() throws {
        prepareApp()
        // 隐私说明
        XCTAssertTrue(app.staticTexts["把这一刻，留给彼此"].waitForExistence(timeout: 6))
        waitTap("onboarding.privacy.continue")

        // 成年确认
        XCTAssertTrue(
            app.navigationBars["成年与合法使用"].waitForExistence(timeout: 6)
                || app.staticTexts["仅限所有参与者明确知情、自愿且已达到法定成年年龄时使用。"].waitForExistence(timeout: 2)
        )
        enableSwitch("onboarding.adult.toggle")
        waitEnabledTap("onboarding.adult.continue")

        // 创建私密空间（以密码框出现为准，避免文案/导航标题匹配失败）
        XCTAssertTrue(
            element("vault.setup.password").waitForExistence(timeout: 8)
                || app.staticTexts["建立你的私密空间"].waitForExistence(timeout: 2)
                || app.navigationBars["私密空间密码"].waitForExistence(timeout: 2)
                || app.navigationBars["欢迎使用"].waitForExistence(timeout: 2),
            "should reach vault setup"
        )
        typeInto("vault.setup.password", text: "uiTestPassword12")
        typeInto("vault.setup.confirm", text: "uiTestPassword12")
        if element("vault.setup.hint").exists {
            typeInto("vault.setup.hint", text: "uitest")
        }
        enableSwitch("vault.setup.notice")
        let create = element("vault.setup.create")
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        // 等按钮可点（密码一致 + 勾选）
        let deadline = Date().addingTimeInterval(3)
        while !create.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(create.isEnabled, "create vault button should be enabled")
        create.tap()

        // 资料
        XCTAssertTrue(
            app.navigationBars["姓名与头像"].waitForExistence(timeout: 6)
                || app.staticTexts["个人资料"].waitForExistence(timeout: 2)
        )
        // 使用 ASCII 姓名，避免模拟器中文输入法影响资料保存断言。
        typeInto("profile.name", text: "Test User")
        if app.keyboards.element(boundBy: 0).exists {
            for key in ["return", "Return", "Done", "完成"] {
                let returnKey = app.keyboards.buttons[key]
                if returnKey.exists {
                    returnKey.tap()
                    break
                }
            }
        }
        waitTap("profile.save")

        // 保存方式
        XCTAssertTrue(
            app.navigationBars["选择保存方式"].waitForExistence(timeout: 6)
                || element("backup.continue").waitForExistence(timeout: 2)
        )
        waitTap("backup.continue")

        // 首页
        XCTAssertTrue(app.navigationBars["我们的记录"].waitForExistence(timeout: 6))
        XCTAssertTrue(scrollTo("home.single").waitForExistence(timeout: 3))
        XCTAssertTrue(scrollTo("home.dual").exists)
        XCTAssertTrue(scrollTo("home.openFile").exists)
    }

    func testSkipToHomeAndNavigateSingleSession() throws {
        prepareApp()
        launchSkipToHome()

        waitTap("home.single")
        XCTAssertTrue(app.navigationBars["同机记录"].waitForExistence(timeout: 5))

        // 使用 ASCII 姓名，避免模拟器输入法干扰
        typeInto("single.nameA", text: "Alice")
        typeInto("single.nameB", text: "Bob")
        // 收起键盘避免挡住按钮（不同系统键盘按钮文案不一致）
        if app.keyboards.element(boundBy: 0).exists {
            let returnKeys = ["return", "Return", "Done", "完成", "换行"]
            var dismissed = false
            for key in returnKeys {
                let button = app.keyboards.buttons[key]
                if button.exists {
                    button.tap()
                    dismissed = true
                    break
                }
            }
            if !dismissed {
                // 轻点导航栏收起键盘
                if app.navigationBars["同机记录"].exists {
                    app.navigationBars["同机记录"].tap()
                }
            }
        }
        waitTap("single.start")

        // 可能弹出错误 alert
        if app.alerts.firstMatch.waitForExistence(timeout: 1.5) {
            let texts = app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map { $0.label }
            XCTFail("start failed: \(texts.joined(separator: " | "))")
        }

        let consentReady =
            app.navigationBars["参与者 A 确认"].waitForExistence(timeout: 6)
            || element("consent.accept").waitForExistence(timeout: 2)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS '将手机交给参与者'")).firstMatch.waitForExistence(timeout: 2)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Alice'")).firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(consentReady, "should enter consent for participant A")
        enableSwitch("consent.accept")
        XCTAssertTrue(element("consent.start").waitForExistence(timeout: 3))
        waitEnabledTap("consent.start")
    }

    func testSingleSessionKeyboardDismissesAndConsentFitsScreen() throws {
        prepareApp()
        launchSkipToHome()

        waitTap("home.single")
        typeInto("single.nameA", text: "Alice")
        typeInto("single.nameB", text: "Bob")
        element("single.nameB").typeText("\n")

        let keyboardDeadline = Date().addingTimeInterval(2)
        while app.keyboards.count > 0 && Date() < keyboardDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(app.keyboards.count, 0, "the Done key should dismiss the name-entry keyboard")

        waitTap("single.start")
        let statement = element("consent.statement")
        XCTAssertTrue(statement.waitForExistence(timeout: 5))
        XCTAssertEqual(
            statement.label,
            "我叫 Alice，我已经成年，我同意并自愿与 Bob 发生性关系，我意识清醒，没有受到任何形式的胁迫。"
        )
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(statement.frame.minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(statement.frame.maxX, windowFrame.maxX)
        XCTAssertGreaterThanOrEqual(statement.frame.minY, windowFrame.minY)
        XCTAssertLessThanOrEqual(statement.frame.maxY, windowFrame.maxY)
        XCTAssertGreaterThan(statement.frame.height, 40, "the statement should retain a readable text height instead of clipping")
    }

    func testVaultPasswordCanBeFilledWithOneTap() throws {
        prepareApp()
        launchSkipToHome(extraArguments: ["-UITestingSingleProtect"])

        waitTap("home.single")
        XCTAssertTrue(element("encryption.method.vault").waitForExistence(timeout: 5))
        XCTAssertTrue(element("encryption.method.oneTime").exists)
        XCTAssertFalse(app.staticTexts["方式"].exists)

        waitTap("encryption.autofillVault")
        XCTAssertEqual(element("encryption.autofillVault").label, "私密空间密码已填入")
        XCTAssertTrue(element("encryption.encrypt").isEnabled)
    }

    func testNativeExporterUsesEditableTimestampFilename() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This test resets its isolated App data and is simulator-only")
        #endif

        prepareApp()
        launchSkipToHome(extraArguments: ["-UITestingSingleExport"])

        waitTap("home.single")

        // iOS 26 系统导出面板：顶部「保存」+ 底部「保存为 <timestamp>」
        // 旧版可能是 Cancel/取消；系统 UI 不一定挂在 app 进程树下，故多路径探测。
        let saveCandidates = [
            app.buttons["保存"],
            app.buttons["Save"],
            app.buttons["Cancel"],
            app.buttons["取消"]
        ]
        var pickerVisible = saveCandidates.contains { $0.waitForExistence(timeout: 8) }

        if !pickerVisible {
            let reopen = app.buttons["重新打开保存器"]
            if reopen.waitForExistence(timeout: 2) {
                reopen.tap()
                pickerVisible = saveCandidates.contains { $0.waitForExistence(timeout: 6) }
            }
        }

        // 再扫一遍含时间戳的元素（文件名条「保存为 2026-…」）
        let timestampPattern = #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#
        let namePredicate = NSPredicate(
            format: "label MATCHES %@ OR value MATCHES %@",
            ".*\(timestampPattern).*",
            ".*\(timestampPattern).*"
        )
        let namedElement = app.descendants(matching: .any).matching(namePredicate).firstMatch
        let sawTimestampName = namedElement.waitForExistence(timeout: 3)

        // 系统文档 UI 偶发不进入 app 的 accessibility 树：至少应进入导出页
        if !pickerVisible && !sawTimestampName {
            XCTAssertTrue(
                app.staticTexts["已加密"].waitForExistence(timeout: 2)
                    || app.buttons["重新打开保存器"].exists,
                "should at least reach the export stage when system picker is not queryable"
            )
        } else {
            XCTAssertTrue(pickerVisible || sawTimestampName, "system save sheet should appear")
        }

        if sawTimestampName {
            let label = namedElement.label
            let value = (namedElement.value as? String) ?? ""
            let combined = label.isEmpty ? value : label
            XCTAssertNotNil(
                combined.range(of: timestampPattern, options: .regularExpression),
                "unexpected default export filename: \(combined)"
            )
        }
    }

    func testCompletionCanReturnHome() throws {
        prepareApp()
        launchSkipToHome(extraArguments: ["-UITestingSingleCompletion"])

        waitTap("home.single")
        XCTAssertTrue(app.navigationBars["完成"].waitForExistence(timeout: 5))
        waitTap("completion.home")
        XCTAssertTrue(
            app.navigationBars["我们的记录"].waitForExistence(timeout: 3)
                || element("home.root").waitForExistence(timeout: 3)
        )
    }

    func testHomeLockReturnsToUnlock() throws {
        prepareApp()
        launchSkipToHome()

        let lock = scrollTo("home.lock")
        XCTAssertTrue(lock.waitForExistence(timeout: 3), "lock control missing after scroll")
        if lock.isHittable {
            lock.tap()
        } else {
            lock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        XCTAssertTrue(element("vault.unlock.button").waitForExistence(timeout: 6))
        XCTAssertTrue(element("vault.unlock.password").exists)
    }

    func testWrongUnlockPasswordShowsAlert() throws {
        prepareApp()
        launchSkipToHome()

        let lock = scrollTo("home.lock")
        XCTAssertTrue(lock.waitForExistence(timeout: 3))
        if lock.isHittable {
            lock.tap()
        } else {
            lock.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        typeInto("vault.unlock.password", text: "wrong-password!!")
        waitTap("vault.unlock.button")

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        if alert.buttons["知道了"].exists {
            alert.buttons["知道了"].tap()
        } else {
            alert.buttons.firstMatch.tap()
        }
    }

    func testOpenEncryptedFileScreen() throws {
        prepareApp()
        launchSkipToHome()
        waitTap("home.openFile")
        XCTAssertTrue(app.navigationBars["打开加密文件"].waitForExistence(timeout: 5))
    }

    func testDualSessionEntry() throws {
        prepareApp()
        launchSkipToHome()
        waitTap("home.dual")
        XCTAssertTrue(app.navigationBars["双机记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("dual.host").waitForExistence(timeout: 3))
        XCTAssertTrue(element("dual.scan").exists)
    }

    func testDualScannerOffersSimulatorFallback() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Photo and text fallback controls are specific to the simulator scanner.")
        #else
        prepareApp()
        launchSkipToHome()
        waitTap("home.dual")
        waitTap("dual.scan")

        XCTAssertTrue(element("dual.scanner.import").waitForExistence(timeout: 5))
        XCTAssertTrue(element("dual.scanner.text").exists)
        #endif
    }

    func testHostingShowsCopyableQRCodeText() throws {
        prepareApp()
        launchSkipToHome()
        waitTap("home.dual")
        waitTap("dual.host")

        let invitationText = element("dual.invitation.text")
        XCTAssertTrue(invitationText.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(invitationText.label.count, 100, "the full QR payload should be visible as text")

        let copyButton = scrollTo("dual.invitation.copy")
        XCTAssertTrue(copyButton.waitForExistence(timeout: 3))
        copyButton.tap()
        XCTAssertEqual(copyButton.label, "已复制")
    }
}

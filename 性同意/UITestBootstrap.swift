import Foundation

/// UI 测试启动参数引导。仅在测试进程注入参数时生效。
enum UITestBootstrap {
    static let testingFlag = "-UITesting"
    static let resetFlag = "-UITestingReset"
    static let skipToHomeFlag = "-UITestingSkipToHome"
    static let singleProtectFlag = "-UITestingSingleProtect"
    static let singleCompletionFlag = "-UITestingSingleCompletion"

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(testingFlag)
    }

    static var shouldReset: Bool {
        ProcessInfo.processInfo.arguments.contains(resetFlag)
    }

    static var shouldSkipToHome: Bool {
        ProcessInfo.processInfo.arguments.contains(skipToHomeFlag)
    }

    static var shouldShowSingleProtect: Bool {
        isUITesting && ProcessInfo.processInfo.arguments.contains(singleProtectFlag)
    }

    static var shouldShowSingleCompletion: Bool {
        isUITesting && ProcessInfo.processInfo.arguments.contains(singleCompletionFlag)
    }

    /// 在 App 初始化最早阶段调用：清状态或预置可进入首页的私密空间。
    @MainActor
    static func prepareIfNeeded() {
        guard isUITesting else { return }

        if shouldReset || shouldSkipToHome {
            // 清本机文件与引导标记，保证测试可重复
            try? FileManager.default.removeItem(at: AppFiles.rootURL)
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "xagree.onboarding.privacyAccepted")
            defaults.removeObject(forKey: "xagree.onboarding.adultConfirmed")
        }

        if shouldSkipToHome {
            do {
                try AppFiles.prepareDirectories()
                let store = VaultStore()
                try store.create(password: UITestCredentials.password, hint: UITestCredentials.hint)
                try store.saveProfile(
                    ParticipantProfile(name: UITestCredentials.displayName, avatarData: nil),
                    password: UITestCredentials.password
                )
                try store.savePreferredBackupMode(.dual, password: UITestCredentials.password)
                UserDefaults.standard.set(true, forKey: "xagree.onboarding.privacyAccepted")
                UserDefaults.standard.set(true, forKey: "xagree.onboarding.adultConfirmed")
            } catch {
                assertionFailure("UITest bootstrap failed: \(error)")
            }
        }
    }
}

enum UITestCredentials {
    static let password = "uiTestPassword12"
    static let hint = "uitest"
    static let displayName = "测试用户"
}

enum AccessibilityID {
    static let privacyContinue = "onboarding.privacy.continue"
    static let adultToggle = "onboarding.adult.toggle"
    static let adultContinue = "onboarding.adult.continue"
    static let vaultPassword = "vault.setup.password"
    static let vaultConfirm = "vault.setup.confirm"
    static let vaultHint = "vault.setup.hint"
    static let vaultNotice = "vault.setup.notice"
    static let vaultCreate = "vault.setup.create"
    static let unlockPassword = "vault.unlock.password"
    static let unlockButton = "vault.unlock.button"
    static let profileName = "profile.name"
    static let profileSave = "profile.save"
    static let backupContinue = "backup.continue"
    static let homeTitle = "home.root"
    static let homeNewRecord = "home.newRecord"
    static let homeSingle = "home.single"
    static let homeDual = "home.dual"
    static let homeOpenFile = "home.openFile"
    static let homeProfilePrivacy = "home.profilePrivacy"
    static let homeLock = "home.lock"
    static let singleStart = "single.start"
    static let singleNameA = "single.nameA"
    static let singleNameB = "single.nameB"
    static let consentStatement = "consent.statement"
    static let consentAccept = "consent.accept"
    static let consentStart = "consent.start"
    static let recordingWatermark = "recording.watermark"
    static let encryptionVault = "encryption.method.vault"
    static let encryptionOneTime = "encryption.method.oneTime"
    static let encryptionAutofillVault = "encryption.autofillVault"
    static let encryptionEncrypt = "encryption.encrypt"
    static let completionHome = "completion.home"
    static let dualHost = "dual.host"
    static let dualScan = "dual.scan"
}

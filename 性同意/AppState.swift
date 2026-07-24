import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case onboardingPrivacy
        case onboardingAdult
        case setupVault
        case unlock
        case setupProfile
        case setupBackupMode
        case home
    }

    private let vaultStore = VaultStore()
    private let onboardingPrivacyKey = "xagree.onboarding.privacyAccepted"
    private let onboardingAdultKey = "xagree.onboarding.adultConfirmed"

    @Published var phase: Phase
    @Published var profile: ParticipantProfile?
    @Published var activePassword = ""
    @Published var preferredBackupMode: BackupMode = .dual
    @Published var transientError: AppError?
    @Published var isPrivacyShieldVisible = false
    @Published var exportDrafts: [ExportDraft] = []

    init() {
        let startupCleanupError: AppError?
        do {
            try AppFiles.purgeTemporaryWorkFiles()
            startupCleanupError = nil
        } catch {
            startupCleanupError = AppError(
                title: "无法清理临时文件",
                detail: error.localizedDescription
            )
        }

        let privacyDone = UserDefaults.standard.bool(forKey: onboardingPrivacyKey)
        let adultDone = UserDefaults.standard.bool(forKey: onboardingAdultKey)

        // UI 测试可预置私密空间并直接进入首页（仍需输入密码解锁，或直接 skip 后视为已解锁）。
        if UITestBootstrap.shouldSkipToHome, vaultStore.hasVault {
            do {
                let profile = try vaultStore.unlock(password: UITestCredentials.password)
                activePassword = UITestCredentials.password
                self.profile = profile
                preferredBackupMode = vaultStore.preferredBackupMode
                phase = profile == nil ? .setupProfile : .home
                refreshDrafts()
                if transientError == nil {
                    transientError = startupCleanupError
                }
                return
            } catch {
                // 回落到正常启动路径
            }
        }

        if !privacyDone {
            phase = .onboardingPrivacy
        } else if !adultDone {
            phase = .onboardingAdult
        } else if vaultStore.hasVault {
            phase = .unlock
        } else {
            phase = .setupVault
        }
        refreshDrafts()
        if transientError == nil {
            transientError = startupCleanupError
        }
    }

    var passwordHint: String? {
        vaultStore.passwordHint
    }

    func acceptPrivacyNotice() {
        UserDefaults.standard.set(true, forKey: onboardingPrivacyKey)
        phase = .onboardingAdult
    }

    func confirmAdultUse() {
        UserDefaults.standard.set(true, forKey: onboardingAdultKey)
        phase = vaultStore.hasVault ? .unlock : .setupVault
    }

    func createVault(password: String, hint: String?) throws {
        try vaultStore.create(password: password, hint: hint)
        activePassword = password
        preferredBackupMode = .dual
        phase = .setupProfile
    }

    func unlock(password: String) throws {
        let unlockedProfile = try vaultStore.unlock(password: password)
        activePassword = password
        profile = unlockedProfile
        preferredBackupMode = vaultStore.preferredBackupMode
        refreshDrafts()
        if unlockedProfile == nil {
            phase = .setupProfile
        } else {
            phase = .home
        }
    }

    func saveProfile(_ profile: ParticipantProfile) throws {
        guard !profile.trimmedName.isEmpty,
              profile.trimmedName.count <= 80,
              profile.avatarData.map(AvatarImageValidator.isSafeStoredAvatar) ?? true else {
            throw VaultError.invalidProfile
        }
        try vaultStore.saveProfile(profile, password: activePassword)
        self.profile = profile
        if phase == .setupProfile {
            phase = .setupBackupMode
        }
    }

    func saveBackupMode(_ mode: BackupMode) throws {
        try vaultStore.savePreferredBackupMode(mode, password: activePassword)
        preferredBackupMode = mode
        if phase == .setupBackupMode {
            phase = .home
        }
    }

    func lock() {
        activePassword.removeAll(keepingCapacity: false)
        profile = nil
        isPrivacyShieldVisible = false
        phase = .unlock
    }

    func resetVault() throws {
        try vaultStore.resetLocalVault()
        activePassword.removeAll(keepingCapacity: false)
        profile = nil
        exportDrafts = []
        preferredBackupMode = .dual
        UserDefaults.standard.removeObject(forKey: onboardingPrivacyKey)
        UserDefaults.standard.removeObject(forKey: onboardingAdultKey)
        phase = .onboardingPrivacy
    }

    func refreshDrafts() {
        let snapshot = DraftStore.snapshot()
        exportDrafts = snapshot.drafts
        if transientError == nil, !snapshot.issues.isEmpty {
            transientError = AppError(
                title: "无法完整读取草稿",
                detail: snapshot.issues.map(\.localizedDescription).joined(separator: "\n")
            )
        }
    }

    func deleteDraft(_ draft: ExportDraft) throws {
        try DraftStore.deleteDraft(draft)
        refreshDrafts()
    }

    func deleteAllDrafts() throws {
        try DraftStore.deleteAllDrafts()
        refreshDrafts()
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        // UI 测试时禁用后台遮蔽，避免打断交互断言
        if UITestBootstrap.isUITesting { return }
        switch scenePhase {
        case .active:
            isPrivacyShieldVisible = false
        case .background:
            isPrivacyShieldVisible = true
        case .inactive:
            // App switcher 截图可能发生在 inactive，必须先遮蔽敏感内容。
            isPrivacyShieldVisible = true
        @unknown default:
            isPrivacyShieldVisible = true
        }
    }
}

struct AppError: LocalizedError, Identifiable {
    let id = UUID()
    let title: String
    let detail: String

    init(title: String, detail: String) {
        self.title = L10n.string(title)
        self.detail = L10n.string(detail)
    }

    var errorDescription: String? { detail }
}

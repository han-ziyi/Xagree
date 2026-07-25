import PhotosUI
import SwiftUI
import UIKit

enum AppTheme {
    static let canvasUIColor = UIColor.systemGroupedBackground
    static let inkUIColor = UIColor.label
    static let canvas = Color(uiColor: canvasUIColor)
    static let paper = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: inkUIColor)
    static let mutedInk = Color(uiColor: .secondaryLabel)
    static let accent = Color(uiColor: .systemRed)
    static let accentSoft = Color(uiColor: .tertiarySystemFill)
    static let sage = Color(uiColor: .systemGreen)
    static let line = Color(uiColor: .separator)
}

struct AppScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AppTheme.canvas.ignoresSafeArea())
            .tint(AppTheme.accent)
    }
}

extension View {
    func appScreenBackground() -> some View { modifier(AppScreenBackground()) }

    func appReadableWidth(_ width: CGFloat = 720) -> some View {
        frame(maxWidth: width)
            .frame(maxWidth: .infinity)
    }
}

struct PasswordValidationFeedback: View {
    let password: String
    var confirmation: String?

    var body: some View {
        if !password.isEmpty, let issue = PasswordPolicy.validationIssue(for: password) {
            Label(message(for: issue), systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("password.validation.format")
        }
        if let confirmation, !confirmation.isEmpty, password != confirmation {
            Label("两次输入的密码不一致。", systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("password.validation.confirmation")
        }
    }

    private func message(for issue: PasswordPolicy.ValidationIssue) -> String {
        switch issue {
        case .tooShort:
            L10n.string("密码至少需要 8 位。")
        case .invalidCharacters:
            L10n.string("密码只能包含数字或英文字母。")
        }
    }
}

struct AppRootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Group {
                switch appState.phase {
                case .onboardingPrivacy:
                    OnboardingPrivacyView()
                case .onboardingAdult:
                    OnboardingAdultView()
                case .setupVault:
                    VaultSetupView()
                case .unlock:
                    VaultUnlockView()
                case .setupProfile:
                    ProfileSetupView()
                case .setupBackupMode:
                    BackupModeSetupView()
                case .home:
                    HomeView()
                }
            }
            .tint(AppTheme.accent)

            if appState.isPrivacyShieldVisible {
                PrivacyShieldView()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(999)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.isPrivacyShieldVisible)
        .alert(item: $appState.transientError) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
        .onChange(of: scenePhase) { _, newPhase in
            appState.handleScenePhase(newPhase)
        }
    }
}

// MARK: - Onboarding

struct OnboardingPrivacyView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(AppTheme.accent)
                            .accessibilityHidden(true)
                        Text("把这一刻，留给彼此")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text("同意爱帮助你们当面表达、彼此确认，再把共同的记录留在自己选择的地方。")
                            .font(.title3)
                            .foregroundStyle(AppTheme.mutedInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)

                    VStack(spacing: 12) {
                        WelcomeFeatureRow(
                            icon: "person.2.fill",
                            title: "每个人都亲自参与",
                            detail: "两个人会分别确认资料，并亲自开始自己的录制。"
                        )
                        WelcomeFeatureRow(
                            icon: "lock.fill",
                            title: "内容只留在你们手里",
                            detail: "不需要账号，也不会上传到开发者服务器。"
                        )
                        WelcomeFeatureRow(
                            icon: "square.and.arrow.down.fill",
                            title: "保存位置由你们决定",
                            detail: "可以在一台机器上保存，也可以在两台附近设备上各自保存。"
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 24)
            }
            .appReadableWidth(680)
            .safeAreaInset(edge: .bottom) {
                Button {
                    appState.acceptPrivacyNotice()
                } label: {
                    Label("开始设置", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.bar)
                .accessibilityIdentifier(AccessibilityID.privacyContinue)
            }
            .navigationTitle("欢迎")
            .appScreenBackground()
        }
    }
}

private struct WelcomeFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 38, height: 38)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(title))
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text(L10n.string(detail))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.line.opacity(0.7), lineWidth: 0.5)
        }
    }
}

struct OnboardingAdultView: View {
    @EnvironmentObject private var appState: AppState
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("仅限所有参与者明确知情、自愿且已达到法定成年年龄时使用。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("我确认自己已成年，并将仅用于合法、自愿的用途", isOn: $confirmed)
                        .accessibilityIdentifier(AccessibilityID.adultToggle)
                }
                Section {
                    Button("继续设置私密空间") {
                        appState.confirmAdultUse()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!confirmed)
                    .accessibilityIdentifier(AccessibilityID.adultContinue)
                }
            }
            .appReadableWidth()
            .navigationTitle("确认使用方式")
            .appScreenBackground()
        }
    }
}

struct VaultSetupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var password = ""
    @State private var confirmation = ""
    @State private var hint = ""
    @State private var acceptedNotice = false

    private var hintCountOK: Bool {
        hint.trimmingCharacters(in: .whitespacesAndNewlines).count <= 60
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(AppTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    Text("建立你的私密空间")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                    Text("密码只由你掌握。你们的记录、姓名和头像都不会传给开发者。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Section("密码") {
                    SecureField("至少 8 位，只能包含数字或英文字母", text: $password)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier(AccessibilityID.vaultPassword)
                    SecureField("再次输入密码", text: $confirmation)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier(AccessibilityID.vaultConfirm)
                    PasswordValidationFeedback(password: password, confirmation: confirmation)
                    TextField("辅助记忆提示词（可选，最多 60 字）", text: $hint)
                        .accessibilityIdentifier(AccessibilityID.vaultHint)
                    Text("提示词不是密码，只是帮助你想起密码的线索；忘记密码后无法恢复记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !hintCountOK {
                        Text("提示词超过 60 字。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("我了解这是只留在我们手里的私密记录。", isOn: $acceptedNotice)
                        .accessibilityIdentifier(AccessibilityID.vaultNotice)
                }

                Section {
                    Button("创建私密空间") {
                        do {
                            try appState.createVault(password: password, hint: hint)
                            password.removeAll()
                            confirmation.removeAll()
                            hint.removeAll()
                        } catch {
                            appState.transientError = AppError(title: "无法创建私密空间", detail: error.localizedDescription)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(
                        password != confirmation
                            || !PasswordPolicy.isValid(password)
                            || !acceptedNotice
                            || !hintCountOK
                    )
                    .accessibilityIdentifier(AccessibilityID.vaultCreate)
                }
            }
            .appReadableWidth()
            .navigationTitle("私密空间密码")
            .appScreenBackground()
        }
    }
}

struct VaultUnlockView: View {
    @EnvironmentObject private var appState: AppState
    @State private var password = ""
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(AppTheme.accent)
                Text("打开私密空间")
                    .font(.title.bold())
                if let hint = appState.passwordHint {
                    Text("提示：\(hint)")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("未设置提示词。忘记密码将无法恢复已加密内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                SecureField("私密空间密码", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 28)
                    .submitLabel(.go)
                    .onSubmit(unlock)
                    .accessibilityIdentifier(AccessibilityID.unlockPassword)
                Button { unlock() } label: {
                    Label("打开", systemImage: "arrow.right")
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier(AccessibilityID.unlockButton)
                Button("清除本机私密空间…", role: .destructive) {
                    showResetConfirm = true
                }
                .font(.footnote)
                Text("重置只清除本机配置，不能删除已导出的 iCloud 文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .appReadableWidth(560)
            .navigationTitle("私密空间")
            .appScreenBackground()
            .confirmationDialog("清除本机私密空间？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("清除本机配置", role: .destructive) {
                    do {
                        try appState.resetVault()
                        password.removeAll()
                    } catch {
                        appState.transientError = AppError(title: "重置失败", detail: error.localizedDescription)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除本机私密空间、资料与待导出草稿。已导出的加密文件不受影响。")
            }
        }
    }

    private func unlock() {
        do {
            try appState.unlock(password: password)
            password.removeAll()
        } catch {
            appState.transientError = AppError(title: "无法解锁", detail: error.localizedDescription)
        }
    }
}

struct ProfileSetupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var name = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var avatarData: Data?

    var body: some View {
        let avatarActionTitle = avatarData == nil ? L10n.string("选择头像") : L10n.string("更换头像")
        NavigationStack {
            Form {
                Section {
                    Text("这里的名字和头像只用于彼此确认，并保存在本机。可以填写对方熟悉的称呼；应用不会核验身份。")
                        .foregroundStyle(.secondary)
                }

                Section("个人资料") {
                    HStack(spacing: 16) {
                        ProfileAvatar(data: avatarData, size: 64)
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label(avatarActionTitle, systemImage: "photo")
                        }
                    }
                    TextField("姓名", text: $name)
                        .textContentType(.name)
                        .accessibilityIdentifier(AccessibilityID.profileName)
                }

                Section {
                    Button("保存并继续") {
                        let profile = ParticipantProfile(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            avatarData: avatarData
                        )
                        guard !profile.trimmedName.isEmpty else {
                            appState.transientError = AppError(title: "需要姓名", detail: "请填写用于配对展示的姓名。")
                            return
                        }
                        do {
                            try appState.saveProfile(profile)
                        } catch {
                            appState.transientError = AppError(title: "无法保存资料", detail: error.localizedDescription)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(AccessibilityID.profileSave)
                }
            }
            .appReadableWidth()
            .navigationTitle("姓名与头像")
            .appScreenBackground()
            .task(id: pickerItem) {
                guard let pickerItem else { return }
                do {
                    avatarData = try await AvatarThumbnail.load(from: pickerItem)
                } catch is CancellationError {
                    return
                } catch {
                    appState.transientError = AppError(
                        title: "无法读取头像",
                        detail: error.localizedDescription
                    )
                }
            }
            .onAppear {
                if let existing = appState.profile {
                    name = existing.name
                    avatarData = existing.avatarData
                }
            }
        }
    }
}

struct BackupModeSetupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var mode: BackupMode = .dual

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("选一个平时更顺手的方式。每次开始记录时仍然可以重新选择。")
                        .foregroundStyle(.secondary)
                }
                Section("保存方式") {
                    ForEach(BackupMode.allCases) { item in
                        Button {
                            mode = item
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: mode == item ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(mode == item ? .indigo : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.title).foregroundStyle(.primary)
                                        if item == .dual {
                                            Text("更安心")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(AppTheme.sage)
                                        }
                                    }
                                    Text(item.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("进入首页") {
                        do {
                            try appState.saveBackupMode(mode)
                        } catch {
                            appState.transientError = AppError(title: "无法保存", detail: error.localizedDescription)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(AccessibilityID.backupContinue)
                }
            }
            .appReadableWidth()
            .navigationTitle("选择保存方式")
            .appScreenBackground()
            .onAppear { mode = appState.preferredBackupMode }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var destination: HomeDestination?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ProfileAvatar(data: appState.profile?.avatarData, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("你好，\(appState.profile?.trimmedName ?? L10n.string("你"))")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            Text("一起留下只属于你们的记录")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(AppTheme.paper)
                }

                Section {
                    Button {
                        destination = appState.preferredBackupMode == .dual ? .dual : .single
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.headline.weight(.bold))
                                .frame(width: 38, height: 38)
                                .background(.white.opacity(0.18), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text("开始一份新记录")
                                    .font(.headline)
                                Text(
                                    appState.preferredBackupMode == .dual
                                        ? L10n.string("默认使用双机模式")
                                        : L10n.string("默认使用同机模式")
                                )
                                    .font(.caption)
                                    .opacity(0.82)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(AppTheme.accent)
                    .accessibilityIdentifier(AccessibilityID.homeNewRecord)
                }

                Section("一起记录") {
                    Button {
                        destination = .single
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("同一台手机", systemImage: "iphone")
                                .font(.body.weight(.medium))
                            Text("轮流完成两段记录")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.homeSingle)
                    Button {
                        destination = .dual
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("两台手机", systemImage: "iphone.gen3.radiowaves.left.and.right")
                                .font(.body.weight(.medium))
                            HStack(spacing: 8) {
                                Text("各自录制、各自保存")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedInk)
                                Spacer(minLength: 8)
                                Text("更安心")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.sage)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier(AccessibilityID.homeDual)
                }

                Section("已保存的内容") {
                    NavigationLink {
                        EvidenceImportView()
                    } label: {
                        Label("打开一份私密记录", systemImage: "lock.doc")
                    }
                    .accessibilityIdentifier(AccessibilityID.homeOpenFile)
                    if !appState.exportDrafts.isEmpty {
                        NavigationLink {
                            PendingDraftsView()
                        } label: {
                            Label("删除待导出草稿", systemImage: "trash")
                            Spacer()
                            Text("\(appState.exportDrafts.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("我的设置") {
                    NavigationLink {
                        ProfileAndPrivacyView()
                    } label: {
                        Label("资料与隐私", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier(AccessibilityID.homeProfilePrivacy)
                    Button(role: .destructive) {
                        appState.lock()
                    } label: {
                        Label("锁定私密空间", systemImage: "lock")
                    }
                    .accessibilityIdentifier(AccessibilityID.homeLock)
                    .accessibilityLabel("锁定私密空间")
                }
            }
            .appReadableWidth(760)
            .navigationTitle("我们的记录")
            .appScreenBackground()
            .accessibilityIdentifier(AccessibilityID.homeTitle)
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .single:
                    SingleSessionView(profile: appState.profile ?? ParticipantProfile(name: "", avatarData: nil))
                case .dual:
                    DualSessionView(profile: appState.profile ?? ParticipantProfile(name: "", avatarData: nil))
                }
            }
            .onAppear { appState.refreshDrafts() }
        }
    }
}

private enum HomeDestination: String, Identifiable {
    case single
    case dual
    var id: String { rawValue }
}

struct PendingDraftsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var exportDraft: ExportDraft?
    @State private var isExporting = false

    var body: some View {
        List {
            Section {
                Text("这些是你在系统“文件”保存器中取消后保留的加密包。成功导出后会删除；也可在此手动删除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(appState.exportDrafts) { draft in
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.fileName).font(.headline)
                    Text("\(draft.mode.title) · \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("重新导出") {
                            exportDraft = draft
                            isExporting = false
                            DispatchQueue.main.async {
                                isExporting = true
                            }
                        }
                        .buttonStyle(.bordered)
                    Button("删除", role: .destructive) {
                            do {
                                try appState.deleteDraft(draft)
                            } catch {
                                appState.transientError = AppError(title: "无法删除草稿", detail: error.localizedDescription)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
            if !appState.exportDrafts.isEmpty {
                Button("全部删除", role: .destructive) {
                    do {
                        try appState.deleteAllDrafts()
                    } catch {
                        appState.transientError = AppError(title: "无法删除草稿", detail: error.localizedDescription)
                    }
                }
            }
        }
        .appReadableWidth(760)
        .navigationTitle("待导出草稿")
        .appScreenBackground()
        .evidenceDocumentExporter(
            isPresented: $isExporting,
            packageURL: exportDraft.map { DraftStore.draftURL(for: $0) },
            preferredBaseName: exportDraft.map { AppFiles.exportPackageBaseName(at: $0.createdAt) },
            onCompleted: {
                if let exportDraft {
                    do {
                        try appState.deleteDraft(exportDraft)
                    } catch {
                        appState.transientError = AppError(
                            title: "无法删除草稿",
                            detail: error.localizedDescription
                        )
                    }
                    self.exportDraft = nil
                }
            },
            onCancelled: {
                // isPresented 已由 exporter 置 false
            }
        )
        .onAppear { appState.refreshDrafts() }
    }
}

struct ProfileAndPrivacyView: View {
    @EnvironmentObject private var appState: AppState
    @State private var name = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var backupMode: BackupMode = .dual
    @State private var showReset = false

    var body: some View {
        let avatarActionTitle = avatarData == nil ? L10n.string("选择头像") : L10n.string("更换头像")
        Form {
            Section("本机资料") {
                HStack(spacing: 16) {
                    ProfileAvatar(data: avatarData, size: 64)
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(avatarActionTitle, systemImage: "photo")
                    }
                }
                TextField("姓名", text: $name)
                Button("保存资料") {
                    let profile = ParticipantProfile(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        avatarData: avatarData
                    )
                    guard !profile.trimmedName.isEmpty else {
                        appState.transientError = AppError(title: "需要姓名", detail: "请填写姓名。")
                        return
                    }
                    do {
                        try appState.saveProfile(profile)
                    } catch {
                        appState.transientError = AppError(title: "无法保存", detail: error.localizedDescription)
                    }
                }
            }
            Section("默认保存方式") {
                Picker("模式", selection: $backupMode) {
                    ForEach(BackupMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: backupMode) { _, newValue in
                    do {
                        try appState.saveBackupMode(newValue)
                    } catch {
                        appState.transientError = AppError(title: "无法保存", detail: error.localizedDescription)
                    }
                }
            }
            Section("隐私说明") {
                PrivacyNoticeView()
            }
            Section {
                Button("清除本机私密空间…", role: .destructive) { showReset = true }
            }
        }
        .appReadableWidth()
        .navigationTitle("资料与隐私")
        .appScreenBackground()
        .onAppear {
            name = appState.profile?.name ?? ""
            avatarData = appState.profile?.avatarData
            backupMode = appState.preferredBackupMode
        }
        .task(id: pickerItem) {
            guard let pickerItem else { return }
            do {
                avatarData = try await AvatarThumbnail.load(from: pickerItem)
            } catch is CancellationError {
                return
            } catch {
                appState.transientError = AppError(
                    title: "无法读取头像",
                    detail: error.localizedDescription
                )
            }
        }
        .confirmationDialog("清除本机私密空间？", isPresented: $showReset, titleVisibility: .visible) {
            Button("清除本机配置", role: .destructive) {
                do { try appState.resetVault() } catch {
                    appState.transientError = AppError(title: "重置失败", detail: error.localizedDescription)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除本机配置与草稿，不能删除已导出的 iCloud 文件。")
        }
    }
}

struct PrivacyNoticeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("只属于你们", systemImage: "heart.fill")
                .font(.headline)
                .foregroundStyle(AppTheme.accent)
            Text("不需要登录，也不会上传给开发者。双机模式只在附近设备之间直接传输；导出位置由你们自己选择。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("请在彼此都已成年、清楚并愿意的情况下使用。姓名和头像由你们自己填写，应用不会进行身份核验。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("水印中的设备时间用于整理和回看。临时文件会按流程删除，但设备系统不提供物理擦除证明。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42))
                Text("内容已遮蔽")
                    .font(.title3.bold())
                Text("回到前台后可继续操作")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
    }
}

enum AvatarThumbnailError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        L10n.string("所选图片无法读取、过大或格式不受支持。")
    }
}

enum AvatarThumbnail {
    static func load(from item: PhotosPickerItem) async throws -> Data {
        guard let data = try await item.loadTransferable(type: Data.self),
              let thumbnail = make(from: data) else {
            throw AvatarThumbnailError.invalidImage
        }
        return thumbnail
    }

    static func make(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 10 * 1_024 * 1_024 else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              image.size.width * image.size.height <= 16_777_216 else { return nil }
        let maximumSide: CGFloat = 256
        let scale = min(1, maximumSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumbnail = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return thumbnail.jpegData(compressionQuality: 0.78)
    }
}

struct ProfileAvatar: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.quaternary, lineWidth: 1))
    }
}

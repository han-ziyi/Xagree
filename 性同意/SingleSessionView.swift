import Combine
import SwiftUI

@MainActor
final class SingleSessionModel: ObservableObject {
    enum Stage: Equatable {
        case details
        case consent(ParticipantRole)
        case recording(ParticipantRole)
        case processing
        case protect
        case export
        case complete
    }

    private struct Segment {
        let url: URL
        let manifest: SegmentManifest
    }

    let sessionID = UUID()
    let owner: ParticipantProfile
    @Published var stage: Stage = .details
    @Published var participantA: String
    @Published var participantB = ""
    @Published var processingLabel = ""
    @Published var finalVideoURL: URL?
    @Published var encryptedPackageURL: URL?
    @Published var error: AppError?
    @Published var sessionPhase: SessionPhase = .draft
    private var segments: [ParticipantRole: Segment] = [:]
    private var completedSegmentManifests: [SegmentManifest] = []
    private var hasCancelled = false

    init(owner: ParticipantProfile) {
        self.owner = owner
        participantA = owner.trimmedName
        if UITestBootstrap.shouldShowSingleProtect {
            stage = .protect
            sessionPhase = .assembling
        } else if UITestBootstrap.shouldShowSingleCompletion {
            stage = .complete
            sessionPhase = .completed
        }
    }

    nonisolated deinit {}

    func start() throws {
        hasCancelled = false
        participantA = participantA.trimmingCharacters(in: .whitespacesAndNewlines)
        participantB = participantB.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantA.isEmpty, !participantB.isEmpty else { throw SessionFailure.missingParticipantName }
        guard participantA.count <= 80, participantB.count <= 80 else {
            throw SessionFailure.invalidParticipantName
        }
        // 清理上一次失败残留的片段，避免文件泄漏与脏状态
        clearWorkingMedia()
        if sessionPhase == .failed || sessionPhase == .completed {
            try transition(to: .draft)
        }
        try transition(to: .armed)
        stage = .consent(.a)
    }

    func beginRecording(_ role: ParticipantRole) throws {
        // 第一段 armed→recording；第二段 recording→recording
        try transition(to: .recording)
        stage = .recording(role)
    }

    func watermark(for role: ParticipantRole) -> RecordingWatermark {
        RecordingWatermark(sessionID: sessionID, role: role, recordedAt: Date(), status: "REC")
    }

    func recordingFinished(artifact: CaptureArtifact, role: ParticipantRole) async {
        stage = .processing
        processingLabel = L10n.format("正在校验参与者 %@ 的视频…", role.rawValue)
        do {
            try await MediaProcessor.validateSegment(
                url: artifact.url,
                expectedSHA256: artifact.sha256
            )
            let segment = Segment(
                url: artifact.url,
                manifest: SegmentManifest(
                    role: role,
                    duration: artifact.duration,
                    sha256: artifact.sha256,
                    watermark: artifact.watermark
                )
            )
            segments[role] = segment
            if let next = role.next {
                stage = .consent(next)
            } else {
                try await assemble()
                stage = .protect
            }
        } catch {
            // 仅删除尚未入库的临时文件；已入库片段统一在 clearWorkingMedia 中处理
            if segments[role]?.url != artifact.url {
                EvidenceCryptor.remove(artifact.url)
            }
            clearWorkingMedia()
            reportFailure(
                title: "视频处理失败",
                error: error,
                transitions: [.failed, .draft]
            )
            stage = .details
        }
    }

    func assemble() async throws {
        guard let a = segments[.a], let b = segments[.b] else { throw SessionFailure.missingRecording }
        try transition(to: .assembling)
        processingLabel = L10n.string("正在按 A → B 合并两段视频…")
        do {
            let finalURL = try await MediaProcessor.concatenate([a.url, b.url])
            finalVideoURL = finalURL
            completedSegmentManifests = [a.manifest, b.manifest]
            EvidenceCryptor.remove(a.url)
            EvidenceCryptor.remove(b.url)
            segments.removeAll()
        } catch {
            // 合成失败时保留分段文件，允许用户从详情页重新开始（start 会清理）
            throw error
        }
    }

    func encrypt(password: String) async {
        guard let finalVideoURL else {
            error = AppError(title: "未找到视频", detail: SessionFailure.missingRecording.localizedDescription)
            return
        }
        guard !password.isEmpty else {
            error = AppError(title: "需要密码", detail: "请输入用于加密本次记录的密码。")
            return
        }
        stage = .processing
        processingLabel = L10n.string("正在加密视频…")
        do {
            try transition(to: .encrypting)
            let finalHash = try FileHasher.sha256Hex(of: finalVideoURL)
            let avatarHash = owner.avatarData.map { FileHasher.sha256Hex(of: $0) }
            let manifest = EvidenceManifest(
                version: 1,
                sessionID: sessionID,
                createdAt: Date(),
                mode: .single,
                participantNames: ["A": participantA, "B": participantB],
                segments: completedSegmentManifests,
                finalVideoSHA256: finalHash,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                profileSnapshots: [
                    "A": ParticipantProfileSnapshot(name: participantA, avatarSHA256: avatarHash),
                    "B": ParticipantProfileSnapshot(name: participantB, avatarSHA256: nil)
                ]
            )
            let package = try await Task.detached(priority: .userInitiated) {
                try EvidenceCryptor.seal(
                    videoURL: finalVideoURL,
                    manifest: manifest,
                    password: password
                )
            }.value
            guard !hasCancelled else {
                EvidenceCryptor.remove(package)
                return
            }
            encryptedPackageURL = package
            EvidenceCryptor.remove(finalVideoURL)
            self.finalVideoURL = nil
            try transition(to: .awaitingExport)
            stage = .export
        } catch {
            // 允许回到 protect 后再次加密
            reportFailure(
                title: "加密失败",
                error: error,
                transitions: sessionPhase == .encrypting ? [.assembling] : []
            )
            stage = .protect
        }
    }

    func finishExport() {
        do {
            try transition(to: .completed)
        } catch {
            self.error = AppError(title: "无法完成导出", detail: error.localizedDescription)
            return
        }
        if let url = encryptedPackageURL {
            // 若指向草稿目录，同步删草稿索引
            if url.path.contains("/Drafts/") {
                for draft in DraftStore.listDrafts() where DraftStore.draftURL(for: draft).path == url.path {
                    do {
                        try DraftStore.deleteDraft(draft)
                    } catch {
                        self.error = AppError(title: "无法清理草稿", detail: error.localizedDescription)
                    }
                }
            }
            EvidenceCryptor.remove(url)
        }
        encryptedPackageURL = nil
        stage = .complete
    }

    func cancelExport(saveDraft: Bool) {
        guard let url = encryptedPackageURL else { return }
        if saveDraft {
            do {
                let result = try DraftStore.preserveExportDraft(from: url, mode: .single)
                let draft = result.draft
                // 删除临时包，但保留草稿路径以便“重新打开保存器”
                if url.path != DraftStore.draftURL(for: draft).path {
                    EvidenceCryptor.remove(url)
                }
                encryptedPackageURL = DraftStore.draftURL(for: draft)
                if let warning = result.warning {
                    error = AppError(title: "草稿已单独保留", detail: warning.localizedDescription)
                }
                return
            } catch {
                self.error = AppError(title: "无法保留草稿", detail: error.localizedDescription)
                return
            }
        }
        EvidenceCryptor.remove(url)
        encryptedPackageURL = nil
    }

    @discardableResult
    func cancel() -> AppError? {
        hasCancelled = true
        var cancellationError: AppError?
        var canReleasePackageReference = true
        // 导出阶段离开时保留草稿，不重复删除草稿路径中的文件
        if let encryptedPackageURL {
            let isDraft = encryptedPackageURL.path.contains("/Drafts/")
            if !isDraft {
                do {
                    let result = try DraftStore.preserveExportDraft(
                        from: encryptedPackageURL,
                        mode: .single
                    )
                    EvidenceCryptor.remove(encryptedPackageURL)
                    self.encryptedPackageURL = DraftStore.draftURL(for: result.draft)
                    if let warning = result.warning {
                        cancellationError = AppError(
                            title: "草稿已单独保留",
                            detail: warning.localizedDescription
                        )
                    }
                } catch {
                    canReleasePackageReference = false
                    cancellationError = AppError(title: "无法保留草稿", detail: error.localizedDescription)
                }
            }
        }
        clearWorkingMedia()
        if canReleasePackageReference {
            encryptedPackageURL = nil
        }
        self.error = cancellationError
        return cancellationError
    }

    private func clearWorkingMedia() {
        EvidenceCryptor.remove(finalVideoURL)
        finalVideoURL = nil
        for segment in segments.values { EvidenceCryptor.remove(segment.url) }
        segments.removeAll()
        completedSegmentManifests = []
    }

    private func reportFailure(title: String, error: Error, transitions: [SessionPhase]) {
        var details = [error.localizedDescription]
        for next in transitions {
            do {
                try transition(to: next)
            } catch {
                details.append(error.localizedDescription)
                break
            }
        }
        self.error = AppError(title: title, detail: details.joined(separator: "\n"))
    }

    private func transition(to next: SessionPhase) throws {
        guard sessionPhase.canTransition(to: next) else {
            throw SessionFailure.illegalTransition(from: sessionPhase, to: next)
        }
        sessionPhase = next
    }
}

struct SingleSessionView: View {
    let profile: ParticipantProfile
    @EnvironmentObject private var appState: AppState
    @StateObject private var model: SingleSessionModel

    init(profile: ParticipantProfile) {
        self.profile = profile
        _model = StateObject(wrappedValue: SingleSessionModel(owner: profile))
    }

    var body: some View {
        Group {
            switch model.stage {
            case .details:
                SingleDetailsView(model: model)
            case .consent(let role):
                ConsentView(model: model, role: role)
            case .recording(let role):
                RecordingView(model: model, role: role)
            case .processing:
                ProcessingView(label: model.processingLabel)
            case .protect:
                ProtectEvidenceView(model: model)
            case .export:
                ExportEvidenceView(model: model)
            case .complete:
                CompletionView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
        .onDisappear {
            if let error = model.cancel() {
                appState.transientError = error
            }
            appState.refreshDrafts()
        }
    }
}

private struct SingleDetailsView: View {
    @ObservedObject var model: SingleSessionModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case participantA
        case participantB
    }

    var body: some View {
        Form {
            Section {
                Text("先写下你们的名字，再把手机交给每个人亲自确认。整个过程只在这台设备上完成。")
                    .foregroundStyle(.secondary)
            }
            Section("你们的名字") {
                TextField("参与者 A 姓名", text: $model.participantA)
                    .textContentType(.name)
                    .focused($focusedField, equals: .participantA)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .participantB }
                    .accessibilityIdentifier(AccessibilityID.singleNameA)
                TextField("参与者 B 姓名", text: $model.participantB)
                    .textContentType(.name)
                    .focused($focusedField, equals: .participantB)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .accessibilityIdentifier(AccessibilityID.singleNameB)
            }
            Section("接下来会发生什么") {
                Label("前置摄像头和麦克风会一起开启", systemImage: "camera.fill")
                Label("每个人都有 3 秒准备时间，最长 30 秒", systemImage: "timer")
                Label("画面会留下时间、角色和短会话号", systemImage: "text.viewfinder")
                Label("结束后按 A → B 合成为一段视频", systemImage: "arrow.right.arrow.left")
            }
        }
        .appReadableWidth()
        .navigationTitle("同机记录")
        .appScreenBackground()
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button {
                focusedField = nil
                do {
                    try model.start()
                } catch {
                    model.error = AppError(title: "无法开始", detail: error.localizedDescription)
                }
            } label: {
                Label("先从参与者 A 开始", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier(AccessibilityID.singleStart)
        }
    }
}

private struct ConsentView: View {
    @ObservedObject var model: SingleSessionModel
    let role: ParticipantRole
    @State private var accepted = false

    private var participantName: String { role == .a ? model.participantA : model.participantB }
    private var otherName: String { role == .a ? model.participantB : model.participantA }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("将手机交给参与者 \(role.rawValue)")
                    .font(.title2.bold())
                Text("请把手机交给 \(participantName)，由本人读完并亲自开始。")
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    Text(ConsentStatement.text(participantName: participantName, otherParticipantName: otherName))
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .accessibilityIdentifier(AccessibilityID.consentStatement)
                    .padding(16)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 18))
                Toggle("我已阅读并理解以上说明", isOn: $accepted)
                    .accessibilityIdentifier(AccessibilityID.consentAccept)
                Button("本人开始录制") {
                    do {
                        try model.beginRecording(role)
                    } catch {
                        model.error = AppError(title: "无法开始录制", detail: error.localizedDescription)
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!accepted)
                    .accessibilityIdentifier(AccessibilityID.consentStart)
                Text("录制时将显示明显的 REC 状态和剩余时间；最长 30 秒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .appReadableWidth(680)
        .navigationTitle("参与者 \(role.rawValue) 确认")
        .background(AppTheme.canvas.ignoresSafeArea())
    }
}

private struct RecordingView: View {
    @ObservedObject var model: SingleSessionModel
    let role: ParticipantRole
    @StateObject private var capture = CaptureService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var watermark: RecordingWatermark?
    @State private var started = false
    @State private var countdown = 3
    @State private var inCountdown = false
    @State private var recordingTask: Task<Void, Never>?
    @State private var setupError: AppError?

    var body: some View {
        ZStack {
            if capture.isPrepared {
                CameraPreview(session: capture.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView("正在准备相机…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
            VStack {
                HStack {
                    if capture.isRecording {
                        Label("REC", systemImage: "record.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text(
                        capture.isRecording
                            ? L10n.format("剩余 %lld 秒", capture.remainingSeconds)
                            : L10n.string("最多 30 秒")
                    )
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .padding(14)
                .background(.black.opacity(0.56), in: Capsule())
                .padding(.top, 10)

                Spacer()

                if inCountdown {
                    Text("\(countdown)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(28)
                        .background(.black.opacity(0.55), in: Circle())
                }

                if let watermark {
                    LiveRecordingWatermarkView(watermark: watermark)
                        .padding(.horizontal)
                }

                Button {
                    if capture.isRecording {
                        capture.stop()
                    } else if !started {
                        startCountdownAndRecord()
                    }
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 76, height: 76)
                        Circle()
                            .fill(capture.isRecording ? .red : .red.opacity(0.85))
                            .frame(width: capture.isRecording ? 34 : 58, height: capture.isRecording ? 34 : 58)
                            .clipShape(RoundedRectangle(cornerRadius: capture.isRecording ? 7 : 29))
                    }
                }
                .disabled(!capture.isPrepared || (started && !capture.isRecording) || inCountdown)
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 22)
        }
        .navigationTitle("参与者 \(role.rawValue) 录制")
        .navigationBarBackButtonHidden(capture.isRecording || started || inCountdown)
        .task {
            do {
                try await capture.prepare()
            } catch {
                setupError = AppError(title: "无法使用相机", detail: error.localizedDescription)
            }
        }
        .alert(item: $setupError) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")) { dismiss() })
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard RecordingInterruptionPolicy.shouldAbort(
                scenePhase: newPhase,
                hasStarted: started,
                isCountingDown: inCountdown,
                isRecording: capture.isRecording
            ) else { return }
            recordingTask?.cancel()
            capture.cancelAndDelete()
            dismiss()
        }
        .onDisappear {
            recordingTask?.cancel()
            capture.stopSession()
        }
    }

    private func startCountdownAndRecord() {
        guard !started, capture.isPrepared else { return }
        started = true
        inCountdown = true
        recordingTask = Task {
            defer { recordingTask = nil }
            for value in stride(from: 3, through: 1, by: -1) {
                countdown = value
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    started = false
                    inCountdown = false
                    return
                }
            }
            inCountdown = false
            let nextWatermark = model.watermark(for: role)
            watermark = nextWatermark
            do {
                let artifact = try await capture.begin(CaptureRequest(watermark: nextWatermark))
                // 录制完成后的校验属于流程模型，不应被录制页面的 onDisappear 取消。
                recordingTask = nil
                await model.recordingFinished(artifact: artifact, role: role)
            } catch {
                if (error as? CaptureError) != .noRecording {
                    model.error = AppError(title: "录制失败", detail: error.localizedDescription)
                }
            }
        }
    }
}

struct ProcessingView: View {
    let label: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(label).font(.headline)
            Text("请保持应用在前台，处理中不会上传任何内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationBarBackButtonHidden()
    }
}

enum EncryptionMethod: String, CaseIterable, Identifiable {
    case vault
    case oneTime

    var id: String { rawValue }
}

struct EncryptionMethodSections: View {
    @Binding var selection: EncryptionMethod

    var body: some View {
        Section("加密方式") {
            methodButton(.vault)
        }
        Section {
            methodButton(.oneTime)
        }
    }

    private func methodButton(_ method: EncryptionMethod) -> some View {
        Button {
            selection = method
        } label: {
            HStack {
                Text(method == .vault ? "使用私密空间密码" : "设置一次性密码")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if selection == method {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AppTheme.accent)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(method == .vault ? AccessibilityID.encryptionVault : AccessibilityID.encryptionOneTime)
    }
}

private struct ProtectEvidenceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: SingleSessionModel
    @State private var method: EncryptionMethod = .vault
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        Form {
            Section {
                Text("视频已合成为一条带水印的成片。现在对它加密，明文成片将在加密成功后删除。")
                    .foregroundStyle(.secondary)
            }
            EncryptionMethodSections(selection: $method)
            Section(method == .vault ? L10n.string("私密空间密码") : L10n.string("一次性密码")) {
                if method == .vault {
                    Button {
                        password = appState.activePassword
                    } label: {
                        Label(
                            password.isEmpty ? "一键填入私密空间密码" : "私密空间密码已填入",
                            systemImage: password.isEmpty ? "key.fill" : "checkmark.circle.fill"
                        )
                    }
                    .accessibilityIdentifier(AccessibilityID.encryptionAutofillVault)
                } else {
                    SecureField(L10n.string("至少 8 位，只能包含数字或英文字母"), text: $password)
                    SecureField("再次输入一次性密码", text: $confirmation)
                    PasswordValidationFeedback(password: password, confirmation: confirmation)
                    Text("一次性密码不会保存在应用中，请自行妥善保管。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("加密并选择 iCloud Drive 保存位置") {
                    guard method != .vault || password == appState.activePassword else {
                        model.error = AppError(title: "密码不正确", detail: "请输入当前私密空间密码，或改用一次性密码。")
                        return
                    }
                    Task { await model.encrypt(password: password) }
                }
                .frame(maxWidth: .infinity)
                .disabled(password.isEmpty || (method == .oneTime && (!PasswordPolicy.isValid(password) || password != confirmation)))
                .accessibilityIdentifier(AccessibilityID.encryptionEncrypt)
            }
        }
        .appReadableWidth()
        .navigationTitle("加密记录")
        .appScreenBackground()
        .onChange(of: method) { _, _ in
            password.removeAll()
            confirmation.removeAll()
        }
    }
}

private struct ExportEvidenceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: SingleSessionModel
    @State private var isExporting = true

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 52))
                .foregroundStyle(.indigo)
            Text("已加密")
                .font(.title2.bold())
            Text("请在系统文件保存器中选择 iCloud Drive 文件夹。应用不会知道或上传你的 iCloud 内容。若取消保存，加密包将作为待导出草稿保留。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("重新打开保存器") { isExporting = true }
                .buttonStyle(.bordered)
        }
        .sheet(isPresented: $isExporting) {
            if let url = model.encryptedPackageURL {
                FileExportSheet(url: url) {
                    model.finishExport()
                    isExporting = false
                    appState.refreshDrafts()
                } onCancelled: {
                    model.cancelExport(saveDraft: true)
                    isExporting = false
                    appState.refreshDrafts()
                }
            }
        }
        .navigationBarBackButtonHidden()
    }
}

private struct CompletionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("加密文件已交给系统保存")
                    .font(.title2.bold())
                Text("请妥善保管密码。应用已删除本次工作文件中的明文视频；成功导出的加密包默认不在应用内保留副本。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Label("返回首页", systemImage: "house.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.completionHome)
            }
            .frame(maxWidth: 680)
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 420)
        }
        .appScreenBackground()
        .navigationTitle("完成")
    }
}

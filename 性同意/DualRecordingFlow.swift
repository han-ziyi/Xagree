import Combine
import SwiftUI

@MainActor
final class DualSessionModel: ObservableObject {
    enum Stage: Equatable {
        case ready
        case waitingToRecord
        case processing(String)
        case waitingForPeer
        case protect
        case export
        case complete
        case recoverStaging
    }

    private struct LocalSegment {
        let url: URL
        let manifest: SegmentManifest
    }

    let profile: ParticipantProfile
    let coordinator: PeerSessionCoordinator
    @Published var stage: Stage = .ready
    @Published var error: AppError?
    @Published var encryptedPackageURL: URL?
    @Published var sessionPhase: SessionPhase = .draft
    private var localSegment: LocalSegment?
    /// 合成后仍保留，避免 coordinator 断开后丢失对方清单
    private var retainedRemoteManifest: SegmentManifest?
    private var finalVideoURL: URL?
    private var hasStartedAssembly = false
    private var vaultPasswordForStaging: String = ""

    init(profile: ParticipantProfile, coordinator: PeerSessionCoordinator) {
        self.profile = profile
        self.coordinator = coordinator
        if DraftStore.activeStagingSessionID() != nil {
            stage = .recoverStaging
            sessionPhase = .transferring
        }
    }

    var localRole: ParticipantRole { coordinator.localRole ?? .a }
    var localName: String { profile.trimmedName }
    var remoteName: String { coordinator.remoteProfile?.name ?? L10n.string("对方") }
    /// 仍有待传输/待合并的本地明文片段（合成后不再为 true）
    var hasLocalSegment: Bool {
        guard let localSegment else { return false }
        return FileManager.default.fileExists(atPath: localSegment.url.path)
    }
    /// 中断恢复 UI：传输中/暂存恢复中
    var needsTransferRecoveryUI: Bool {
        switch stage {
        case .waitingForPeer, .recoverStaging:
            true
        default:
            hasLocalSegment && finalVideoURL == nil && encryptedPackageURL == nil
                && stage != .protect && stage != .export && stage != .complete
        }
    }

    func setVaultPassword(_ password: String) {
        vaultPasswordForStaging = password
    }

    func prepareForPairing() throws -> UUID? {
        if needsTransferRecoveryUI || stage == .recoverStaging {
            guard let sessionID = coordinator.currentSessionID ?? DraftStore.activeStagingSessionID() else {
                throw SessionFailure.stagingExpired
            }
            return sessionID
        }
        try reset()
        return nil
    }

    func reset() throws {
        // 新配对时清除内存中的旧片段引用；磁盘暂存由 clearStaging 参数控制
        if let error = cancel(clearStaging: false) {
            throw error
        }
        localSegment = nil
        retainedRemoteManifest = nil
        stage = .ready
        error = nil
        hasStartedAssembly = false
        sessionPhase = .draft
    }

    func markPairedIfNeeded() {
        if coordinator.state == .paired, sessionPhase == .draft {
            sessionPhase = .paired
        }
    }

    func markReady() {
        do {
            markPairedIfNeeded()
            guard sessionPhase.canTransition(to: .armed) else {
                throw SessionFailure.illegalTransition(from: sessionPhase, to: .armed)
            }
            try coordinator.markRecordingReady()
            sessionPhase = .armed
            stage = .waitingToRecord
        } catch {
            self.error = AppError(title: "无法准备录制", detail: error.localizedDescription)
        }
    }

    func watermark() -> RecordingWatermark {
        RecordingWatermark(
            sessionID: coordinator.currentSessionID ?? UUID(),
            role: localRole,
            recordedAt: Date(),
            status: "REC"
        )
    }

    func markRecordingStarted() throws {
        try transition(to: .recording)
    }

    func recordingFinished(artifact: CaptureArtifact) async {
        stage = .processing(L10n.string("正在校验你的视频…"))
        var stagingSucceeded = false
        do {
            // 确保状态机：armed/recording → transferring
            if sessionPhase == .armed {
                try transition(to: .recording)
            }
            if sessionPhase == .recording {
                try transition(to: .transferring)
            } else if sessionPhase != .transferring {
                try transition(to: .transferring)
            }
            try await MediaProcessor.validateSegment(url: artifact.url, expectedSHA256: artifact.sha256)
            let manifest = SegmentManifest(
                role: localRole,
                duration: artifact.duration,
                sha256: artifact.sha256,
                watermark: artifact.watermark
            )
            localSegment = LocalSegment(url: artifact.url, manifest: manifest)
            guard let sessionID = coordinator.currentSessionID, !vaultPasswordForStaging.isEmpty else {
                throw SessionFailure.missingRecording
            }
            try DraftStore.saveStaging(
                sessionID: sessionID,
                role: localRole,
                segmentURL: artifact.url,
                manifest: manifest,
                vaultPassword: vaultPasswordForStaging
            )
            stagingSucceeded = true
            try coordinator.sendRecording(artifact.url, manifest: manifest)
            stage = .waitingForPeer
            await assembleIfReady()
        } catch {
            if stagingSucceeded, localSegment != nil, FileManager.default.fileExists(atPath: artifact.url.path) {
                // 本地片段已就绪（可能已暂存），进入恢复流程而非丢弃重录
                stage = .recoverStaging
                reportFailure(
                    title: "视频处理或传输失败",
                    error: error,
                    transitions: sessionPhase == .recording ? [.transferring] : []
                )
            } else {
                EvidenceCryptor.remove(artifact.url)
                localSegment = nil
                stage = .ready
                reportFailure(
                    title: "视频处理或传输失败",
                    error: error,
                    transitions: [.failed, .draft]
                )
            }
        }
    }

    func peerDataChanged() async {
        if let remote = coordinator.remoteSegmentManifest {
            retainedRemoteManifest = remote
        }
        await assembleIfReady()
    }

    func handleDisconnectAfterRecording() {
        // 仅在仍有待传输明文片段时进入恢复（合成后 hasLocalSegment 为 false）
        guard hasLocalSegment || stage == .waitingForPeer || stage == .recoverStaging else { return }
        stage = .recoverStaging
        error = AppError(
            title: "连接中断",
            detail: "已录制片段已用私密空间密码加密暂存最多 10 分钟。请重新扫码配对后继续传输。"
        )
    }

    func resumeAfterRepair() async {
        // 明文片段若已丢失，尝试从 10 分钟暂存恢复
        if let existing = localSegment, !FileManager.default.fileExists(atPath: existing.url.path) {
            localSegment = nil
        }
        if localSegment == nil {
            let sessionID = coordinator.currentSessionID ?? DraftStore.activeStagingSessionID()
            guard let sessionID, !vaultPasswordForStaging.isEmpty else {
                error = AppError(title: "无法恢复", detail: "没有可用的暂存片段，请重新录制。")
                stage = .ready
                return
            }
            do {
                guard let restored = try DraftStore.loadStaging(
                    sessionID: sessionID,
                    vaultPassword: vaultPasswordForStaging
                ) else {
                    error = AppError(title: "无法恢复", detail: "没有可用的暂存片段，请重新录制。")
                    stage = .ready
                    return
                }
                localSegment = LocalSegment(url: restored.url, manifest: restored.manifest)
            } catch {
                self.error = AppError(title: "无法恢复", detail: error.localizedDescription)
                stage = .ready
                return
            }
        }
        guard let local = localSegment,
              FileManager.default.fileExists(atPath: local.url.path) else {
            error = AppError(title: "无法恢复", detail: "暂存片段文件已失效，请重新录制。")
            stage = .ready
            return
        }
        guard coordinator.currentSessionID == local.manifest.watermark.sessionID else {
            error = AppError(
                title: "无法恢复",
                detail: PeerPairingError.recoverySessionMismatch.localizedDescription
            )
            stage = .recoverStaging
            return
        }
        do {
            if sessionPhase == .draft || sessionPhase == .failed {
                sessionPhase = .transferring
            }
            try coordinator.sendRecording(local.url, manifest: local.manifest)
            stage = .waitingForPeer
            await assembleIfReady()
        } catch {
            self.error = AppError(title: "重新传输失败", detail: error.localizedDescription)
            stage = .recoverStaging
        }
    }

    func encrypt(password: String) async {
        guard let finalVideoURL else {
            error = AppError(title: "未找到合成视频", detail: "请重新开始双机记录。")
            return
        }
        guard !password.isEmpty else {
            error = AppError(title: "需要密码", detail: "请输入用于保护本机副本的密码。")
            return
        }
        stage = .processing(L10n.string("正在加密本机副本…"))
        do {
            try transition(to: .encrypting)
            let finalHash = try FileHasher.sha256Hex(of: finalVideoURL)
            guard let own = localSegment?.manifest,
                  let remote = retainedRemoteManifest ?? coordinator.remoteSegmentManifest else {
                throw SessionFailure.missingRecording
            }
            let orderedSegments = localRole == .a ? [own, remote] : [remote, own]
            let names: [String: String] = localRole == .a
                ? ["A": localName, "B": remoteName]
                : ["A": remoteName, "B": localName]
            let localSnap = ParticipantProfileSnapshot(
                name: localName,
                avatarSHA256: profile.avatarData.map { FileHasher.sha256Hex(of: $0) }
            )
            let remoteSnap = ParticipantProfileSnapshot(
                name: remoteName,
                avatarSHA256: coordinator.remoteProfile?.avatarHash
            )
            let snapshots: [String: ParticipantProfileSnapshot] = localRole == .a
                ? ["A": localSnap, "B": remoteSnap]
                : ["A": remoteSnap, "B": localSnap]
            let manifest = EvidenceManifest(
                version: 1,
                sessionID: coordinator.currentSessionID ?? UUID(),
                createdAt: Date(),
                mode: .dual,
                participantNames: names,
                segments: orderedSegments,
                finalVideoSHA256: finalHash,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                profileSnapshots: snapshots
            )
            encryptedPackageURL = try EvidenceCryptor.seal(
                videoURL: finalVideoURL,
                manifest: manifest,
                password: password
            )
            EvidenceCryptor.remove(finalVideoURL)
            self.finalVideoURL = nil
            if let sessionID = coordinator.currentSessionID {
                do {
                    try DraftStore.clearStaging(sessionID: sessionID)
                } catch {
                    self.error = AppError(title: "无法清理暂存", detail: error.localizedDescription)
                }
            }
            try transition(to: .awaitingExport)
            stage = .export
        } catch {
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
                let result = try DraftStore.preserveExportDraft(from: url, mode: .dual)
                let draft = result.draft
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
    func cancel(clearStaging: Bool = true) -> AppError? {
        var issueDetails: [String] = []
        var canReleasePackageReference = true
        if clearStaging {
            EvidenceCryptor.remove(localSegment?.url)
            localSegment = nil
            let stagingID = coordinator.currentSessionID ?? DraftStore.activeStagingSessionID()
            if let stagingID {
                do {
                    try DraftStore.clearStaging(sessionID: stagingID)
                } catch {
                    issueDetails.append(error.localizedDescription)
                }
            }
        }
        EvidenceCryptor.remove(finalVideoURL)
        if let encryptedPackageURL {
            let isDraft = encryptedPackageURL.path.contains("/Drafts/")
            if !isDraft {
                do {
                    let result = try DraftStore.preserveExportDraft(
                        from: encryptedPackageURL,
                        mode: .dual
                    )
                    EvidenceCryptor.remove(encryptedPackageURL)
                    self.encryptedPackageURL = DraftStore.draftURL(for: result.draft)
                    if let warning = result.warning {
                        issueDetails.append(warning.localizedDescription)
                    }
                } catch {
                    canReleasePackageReference = false
                    issueDetails.append(error.localizedDescription)
                }
            }
        }
        finalVideoURL = nil
        if canReleasePackageReference {
            encryptedPackageURL = nil
        }
        guard !issueDetails.isEmpty else { return nil }
        let cancellationError = AppError(
            title: "无法完整结束会话",
            detail: issueDetails.joined(separator: "\n")
        )
        self.error = cancellationError
        return cancellationError
    }

    private func assembleIfReady() async {
        guard !hasStartedAssembly,
              let local = localSegment,
              FileManager.default.fileExists(atPath: local.url.path),
              let remoteURL = coordinator.receivedRecordingURL,
              FileManager.default.fileExists(atPath: remoteURL.path),
              let remoteManifest = coordinator.remoteSegmentManifest ?? retainedRemoteManifest else { return }
        hasStartedAssembly = true
        retainedRemoteManifest = remoteManifest
        stage = .processing(L10n.string("正在校验并合并双方视频…"))
        do {
            if sessionPhase == .transferring || sessionPhase == .recording {
                try transition(to: .assembling)
            } else if sessionPhase != .assembling {
                try transition(to: .assembling)
            }
            try await MediaProcessor.validateSegment(url: remoteURL, expectedSHA256: remoteManifest.sha256)
            try await MediaProcessor.validateSegment(url: local.url, expectedSHA256: local.manifest.sha256)
            let orderedURLs = localRole == .a ? [local.url, remoteURL] : [remoteURL, local.url]
            let finalURL = try await MediaProcessor.concatenate(orderedURLs)
            finalVideoURL = finalURL
            // 保留 manifest 供加密清单使用；删除明文片段
            let keptManifest = local.manifest
            EvidenceCryptor.remove(local.url)
            EvidenceCryptor.remove(remoteURL)
            localSegment = LocalSegment(
                url: AppFiles.workURL.appendingPathComponent(".assembled-marker"),
                manifest: keptManifest
            )
            stage = .protect
        } catch {
            stage = .waitingForPeer
            hasStartedAssembly = false
            // 回到 transferring，允许在片段仍在时重试合成（不可落到 draft 导致永久卡死）
            let shouldReturnToTransfer = sessionPhase == .assembling || sessionPhase == .failed
            reportFailure(
                title: "无法合并视频",
                error: error,
                transitions: shouldReturnToTransfer ? [.transferring] : []
            )
        }
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

struct DualRecordingFlow: View {
    @ObservedObject var model: DualSessionModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch model.stage {
            case .ready:
                DualConsentView(model: model)
            case .waitingToRecord:
                DualCaptureView(model: model)
            case .processing(let label):
                ProcessingView(label: label)
            case .waitingForPeer:
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("正在接收对方的加密视频…")
                        .font(.headline)
                    Text("视频通过附近设备直接传输，不经过开发者服务器。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 72)
            case .recoverStaging:
                VStack(spacing: 16) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("连接中断 · 片段已暂存")
                        .font(.title3.bold())
                    Text("已用私密空间密码加密暂存最多 10 分钟。重新配对成功后将自动继续传输。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重新传输暂存片段") {
                        Task { await model.resumeAfterRepair() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.coordinator.state != .paired)
                }
                .padding(.top, 40)
            case .protect:
                DualProtectEvidenceView(model: model)
            case .export:
                DualExportEvidenceView(model: model)
            case .complete:
                DualCompletionView()
            }
        }
        .onAppear {
            model.setVaultPassword(appState.activePassword)
            model.markPairedIfNeeded()
        }
        .onChange(of: model.coordinator.receivedRecordingURL) { _, _ in
            Task { await model.peerDataChanged() }
        }
        .onChange(of: model.coordinator.remoteSegmentManifest) { _, _ in
            Task { await model.peerDataChanged() }
        }
        .onChange(of: model.coordinator.state) { _, newState in
            if case .failed = newState, model.hasLocalSegment || model.stage == .waitingForPeer {
                model.handleDisconnectAfterRecording()
            }
            if newState == .paired, model.stage == .recoverStaging {
                Task { await model.resumeAfterRepair() }
            }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
    }
}

private struct DualConsentView: View {
    @ObservedObject var model: DualSessionModel
    @State private var accepted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("双方同步录制")
                .font(.title2.bold())
            Text("请由 \(model.localName) 本人读完并准备录制。对方也准备好后，两台设备会一起开始 3 秒倒计时。")
                .foregroundStyle(.secondary)
            Text("我是 \(model.localName)。我已经成年，也愿意在此刻与 \(model.remoteName) 亲密相处。我知道自己可以在录制前停下来，或者重新确认后再继续。")
                .font(.body)
                .padding()
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            Toggle("我已阅读并理解以上说明", isOn: $accepted)
            Button("本人已准备好") { model.markReady() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!accepted)
            Text("录制和传输期间请让两台设备保持靠近、保持应用在前台。中断后片段可暂存 10 分钟。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DualCaptureView: View {
    @ObservedObject var model: DualSessionModel
    @StateObject private var capture = CaptureService()
    @State private var started = false
    @State private var countdown = 3
    @State private var watermark: RecordingWatermark?
    @State private var setupError: AppError?

    var body: some View {
        ZStack {
            if capture.isPrepared {
                CameraPreview(session: capture.session).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView("正在准备相机…").tint(.white)
            }
            VStack {
                HStack {
                    if capture.isRecording {
                        Label("REC", systemImage: "record.circle.fill")
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
                .padding(12)
                .background(.black.opacity(0.6), in: Capsule())
                Spacer()
                if !started {
                    Text(
                        model.coordinator.recordingStartSignal == 0
                            ? L10n.string("等待对方准备…")
                            : "\(countdown)"
                    )
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.55), in: Circle())
                }
                if let watermark {
                    LiveRecordingWatermarkView(watermark: watermark)
                }
                Button {
                    if capture.isRecording { capture.stop() }
                } label: {
                    Circle().fill(.white).frame(width: 72, height: 72)
                        .overlay(RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: 32, height: 32))
                }
                .opacity(capture.isRecording ? 1 : 0)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 22)
        }
        .task {
            do {
                try await capture.prepare()
                startIfSignaled()
            } catch {
                setupError = AppError(title: "无法使用相机", detail: error.localizedDescription)
            }
        }
        .onChange(of: model.coordinator.recordingStartSignal) { _, _ in startIfSignaled() }
        .onDisappear { capture.stopSession() }
        .alert(item: $setupError) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
    }

    private func startIfSignaled() {
        guard !started, capture.isPrepared, model.coordinator.recordingStartSignal > 0 else { return }
        started = true
        Task {
            for value in stride(from: 3, through: 1, by: -1) {
                countdown = value
                try? await Task.sleep(for: .seconds(1))
            }
            let nextWatermark = model.watermark()
            watermark = nextWatermark
            do {
                try model.markRecordingStarted()
                let artifact = try await capture.begin(CaptureRequest(watermark: nextWatermark))
                await model.recordingFinished(artifact: artifact)
            } catch {
                if (error as? CaptureError) != .noRecording {
                    model.error = AppError(title: "录制失败", detail: error.localizedDescription)
                }
            }
        }
    }
}

private struct DualProtectEvidenceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: DualSessionModel
    @State private var method: EncryptionMethod = .vault
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        Form {
            Section {
                Text("双方视频已合成为一条成片（A → B）。请设置此设备副本的密码；另一台设备可以使用不同密码。")
                    .foregroundStyle(.secondary)
            }
            EncryptionMethodSections(selection: $method)
            Section(method == .vault ? L10n.string("私密空间密码") : L10n.string("本机副本密码")) {
                if method == .vault {
                    Button {
                        password = appState.activePassword
                    } label: {
                        Label(password.isEmpty ? "一键填入总密码" : "总密码已填入", systemImage: password.isEmpty ? "key.fill" : "checkmark.circle.fill")
                    }
                    .accessibilityIdentifier(AccessibilityID.encryptionAutofillVault)
                } else {
                    SecureField(L10n.string("至少 8 位，只能包含数字或英文字母"), text: $password)
                    SecureField("再次输入密码", text: $confirmation)
                    PasswordValidationFeedback(password: password, confirmation: confirmation)
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
        .onChange(of: method) { _, _ in
            password.removeAll()
            confirmation.removeAll()
        }
    }
}

private struct DualExportEvidenceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: DualSessionModel
    @State private var isExporting = true

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.doc.fill").font(.system(size: 52)).foregroundStyle(.indigo)
            Text("本机副本已加密").font(.title2.bold())
            Text("请在系统文件保存器中选择本机 iCloud Drive 文件夹。取消后将保留待导出草稿。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新打开保存器") { isExporting = true }.buttonStyle(.bordered)
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
    }
}

private struct DualCompletionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("本机私密副本已导出").font(.title2.bold())
                Text("两台设备应各自完成导出。明文工作文件已删除。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
    }
}

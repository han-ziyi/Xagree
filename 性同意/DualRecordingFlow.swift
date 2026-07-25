import Combine
import SwiftUI

enum DualTransferGate {
    static func canAssemble(
        localURL: URL,
        remoteURL: URL?,
        remoteManifest: SegmentManifest?,
        peerAcknowledgedLocalRecording: Bool
    ) -> Bool {
        FileManager.default.fileExists(atPath: localURL.path)
            && remoteURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
            && remoteManifest != nil
            && peerAcknowledgedLocalRecording
    }
}

enum DualPeerConnectionPolicy {
    static func canContinueWithoutPeer(sessionPhase: SessionPhase) -> Bool {
        switch sessionPhase {
        case .assembling, .encrypting, .awaitingExport, .completed:
            true
        case .draft, .paired, .armed, .recording, .transferring, .failed:
            false
        }
    }
}

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
    /// 导出页「稍后保存」时请求退出双机会话。
    @Published var requestDismiss = false
    private var localSegment: LocalSegment?
    /// 合成后仍保留，避免 coordinator 断开后丢失对方清单
    private var retainedRemoteManifest: SegmentManifest?
    private var finalVideoURL: URL?
    private var hasStartedAssembly = false
    private var hasCancelled = false
    private var vaultPasswordForStaging: String = ""
    private var cancellables = Set<AnyCancellable>()

    init(profile: ParticipantProfile, coordinator: PeerSessionCoordinator) {
        self.profile = profile
        self.coordinator = coordinator
        if DraftStore.activeStagingSessionID() != nil {
            stage = .recoverStaging
            sessionPhase = .transferring
        } else if UITestBootstrap.shouldShowDualExport {
            // UI 测试：跳过配对/录制，直接验证双机导出保存面板
            do {
                try AppFiles.prepareDirectories()
                let url = try AppFiles.exportPackageURL()
                try Data("XAgree dual UI test export".utf8).write(to: url, options: .atomic)
                encryptedPackageURL = url
                stage = .export
                sessionPhase = .awaitingExport
            } catch {
                assertionFailure("UITest dual export bootstrap failed: \(error)")
            }
        }

        coordinator.$receivedRecordingURL
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.peerDataChanged()
                }
            }
            .store(in: &cancellables)

        coordinator.$remoteSegmentManifest
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.peerDataChanged()
                }
            }
            .store(in: &cancellables)

        coordinator.$remoteAcknowledgedLocalRecording
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.peerDataChanged()
                }
            }
            .store(in: &cancellables)
    }

    nonisolated deinit {}

    var localRole: ParticipantRole { coordinator.localRole ?? .a }
    var localName: String { profile.trimmedName }
    var remoteName: String { coordinator.remoteProfile?.name ?? L10n.string("对方") }
    /// 仍有待传输/待合并的本地明文片段（合成后不再为 true）
    var hasLocalSegment: Bool {
        guard let localSegment else { return false }
        return FileManager.default.fileExists(atPath: localSegment.url.path)
    }
    /// 双向视频均已接收并确认后，后续合成、加密和导出都只依赖本机数据。
    var canContinueWithoutPeer: Bool {
        DualPeerConnectionPolicy.canContinueWithoutPeer(sessionPhase: sessionPhase)
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
            hasCancelled = false
            markPairedIfNeeded()
            guard coordinator.state == .paired else {
                throw PeerPairingError.invalidState
            }
            guard sessionPhase.canTransition(to: .armed) else {
                throw SessionFailure.illegalTransition(from: sessionPhase, to: .armed)
            }
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
            try await DraftStore.saveStaging(
                sessionID: sessionID,
                role: localRole,
                segmentURL: artifact.url,
                manifest: manifest,
                vaultPassword: vaultPasswordForStaging
            )
            stagingSucceeded = true
            try await coordinator.sendRecording(artifact.url, manifest: manifest)
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
        // 双向传输已完成时，断开只结束后台连接，不能打断本机的保存流程。
        guard !canContinueWithoutPeer else { return }
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
                guard let restored = try await DraftStore.loadStaging(
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
            try await coordinator.sendRecording(local.url, manifest: local.manifest)
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
            let avatarData = profile.avatarData
            let hashes = try await Task.detached(priority: .userInitiated) {
                (
                    video: try FileHasher.sha256Hex(of: finalVideoURL),
                    avatar: avatarData.map { FileHasher.sha256Hex(of: $0) }
                )
            }.value
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
                avatarSHA256: hashes.avatar
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
                finalVideoSHA256: hashes.video,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                profileSnapshots: snapshots
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
        hasCancelled = true
        var issueDetails: [String] = []
        var canReleasePackageReference = true
        // 暂存区只含加密副本；无论是否保留暂存，都不能把本机明文片段留在 Work。
        EvidenceCryptor.remove(localSegment?.url)
        localSegment = nil
        if clearStaging {
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
              let remoteURL = coordinator.receivedRecordingURL,
              let remoteManifest = coordinator.remoteSegmentManifest ?? retainedRemoteManifest,
              DualTransferGate.canAssemble(
                localURL: local.url,
                remoteURL: remoteURL,
                remoteManifest: remoteManifest,
                peerAcknowledgedLocalRecording: coordinator.remoteAcknowledgedLocalRecording
              ) else { return }
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
    @ObservedObject private var coordinator: PeerSessionCoordinator
    @EnvironmentObject private var appState: AppState

    init(model: DualSessionModel) {
        _model = ObservedObject(wrappedValue: model)
        _coordinator = ObservedObject(wrappedValue: model.coordinator)
    }

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
                    Text("正在同步双方视频…")
                        .font(.headline)
                    Label(
                        coordinator.receivedRecordingURL == nil ? "正在接收对方视频" : "已收到并验证对方视频",
                        systemImage: coordinator.receivedRecordingURL == nil ? "arrow.down.circle" : "checkmark.circle.fill"
                    )
                    Label(
                        coordinator.remoteAcknowledgedLocalRecording ? "对方已确认收到我的视频" : "等待对方确认收到我的视频",
                        systemImage: coordinator.remoteAcknowledgedLocalRecording ? "checkmark.circle.fill" : "arrow.up.circle"
                    )
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
                DualExportEvidenceView(model: model) {
                    model.cancelExport(saveDraft: true)
                    appState.refreshDrafts()
                    model.requestDismiss = true
                }
            case .complete:
                DualCompletionView()
            }
        }
        .onAppear {
            model.setVaultPassword(appState.activePassword)
            model.markPairedIfNeeded()
        }
        .onChange(of: coordinator.state) { _, newState in
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("将手机交给参与者 \(model.localRole.rawValue)")
                    .font(.title2.bold())
                Text("请把手机交给 \(model.localName)，由本人读完并亲自开始。")
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    Text(ConsentStatement.text(participantName: model.localName, otherParticipantName: model.remoteName))
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .accessibilityIdentifier(AccessibilityID.consentStatement)
                    .padding(16)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 18))
                Toggle("我已阅读并理解以上说明", isOn: $accepted)
                    .accessibilityIdentifier(AccessibilityID.consentAccept)
                Button("本人开始录制") { model.markReady() }
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
        .navigationTitle("参与者 \(model.localRole.rawValue) 确认")
        .background(AppTheme.canvas.ignoresSafeArea())
    }
}

private struct DualCaptureView: View {
    @ObservedObject var model: DualSessionModel
    @StateObject private var capture = CaptureService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false
    @State private var isCountingDown = false
    @State private var recordingTask: Task<Void, Never>?
    @State private var countdown = 3
    @State private var watermark: RecordingWatermark?
    @State private var setupError: AppError?

    var body: some View {
        ZStack {
            if capture.isPrepared {
                CameraPreview(session: capture.session).ignoresSafeArea()
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

                if isCountingDown {
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
                .disabled(!capture.isPrepared || (started && !capture.isRecording) || isCountingDown)
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 22)
        }
        .navigationTitle("参与者 \(model.localRole.rawValue) 录制")
        .navigationBarBackButtonHidden(capture.isRecording || started || isCountingDown)
        .task {
            do {
                try await capture.prepare()
            } catch {
                setupError = AppError(title: "无法使用相机", detail: error.localizedDescription)
            }
        }
        .onDisappear {
            recordingTask?.cancel()
            capture.stopSession()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard RecordingInterruptionPolicy.shouldAbort(
                scenePhase: newPhase,
                hasStarted: started,
                isCountingDown: isCountingDown,
                isRecording: capture.isRecording
            ) else { return }
            recordingTask?.cancel()
            capture.cancelAndDelete()
            dismiss()
        }
        .alert(item: $setupError) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
    }

    private func startCountdownAndRecord() {
        guard !started, capture.isPrepared else { return }
        started = true
        isCountingDown = true
        recordingTask = Task {
            defer { recordingTask = nil }
            for value in stride(from: 3, through: 1, by: -1) {
                countdown = value
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    started = false
                    isCountingDown = false
                    return
                }
            }
            isCountingDown = false
            let nextWatermark = model.watermark()
            watermark = nextWatermark
            do {
                try model.markRecordingStarted()
                let artifact = try await capture.begin(CaptureRequest(watermark: nextWatermark))
                // 录制完成后的校验/暂存属于流程模型，不应被录制页面的 onDisappear 取消。
                recordingTask = nil
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
                        Label(
                            password.isEmpty ? "一键填入私密空间密码" : "私密空间密码已填入",
                            systemImage: password.isEmpty ? "key.fill" : "checkmark.circle.fill"
                        )
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
    var onSaveLater: () -> Void
    @State private var isExporting = false
    @State private var defaultFilename = AppFiles.exportPackageBaseName()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.doc.fill").font(.system(size: 52)).foregroundStyle(.indigo)
            Text("本机副本已加密").font(.title2.bold())
            Text("请在系统文件保存器中选择本机 iCloud Drive 文件夹。取消后将保留待导出草稿。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新打开保存器") { reopenExporter() }.buttonStyle(.bordered)
            Button("稍后保存（保留草稿）") {
                isExporting = false
                onSaveLater()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("export.saveLater")
        }
        .evidenceDocumentExporter(
            isPresented: $isExporting,
            packageURL: model.encryptedPackageURL,
            preferredBaseName: preferredExportBaseName(for: model.encryptedPackageURL),
            onCompleted: {
                model.finishExport()
                appState.refreshDrafts()
            },
            onCancelled: {
                model.cancelExport(saveDraft: true)
                appState.refreshDrafts()
            }
        )
        .onAppear { reopenExporter() }
    }

    private func preferredExportBaseName(for url: URL?) -> String {
        guard let url else { return defaultFilename }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? defaultFilename : stem
    }

    private func reopenExporter() {
        isExporting = false
        DispatchQueue.main.async {
            isExporting = true
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

import SwiftUI
import UIKit
import VisionKit

enum DualSessionPresentationPolicy {
    static func usesStandaloneFlowLayout(
        stage: DualSessionModel.Stage,
        isPeerPaired: Bool,
        canContinueWithoutPeer: Bool
    ) -> Bool {
        guard isPeerPaired || canContinueWithoutPeer else { return false }
        return switch stage {
        case .ready, .waitingToRecord, .processing, .waitingForPeer, .protect, .export, .complete:
            true
        case .recoverStaging:
            false
        }
    }
}

struct DualSessionView: View {
    let profile: ParticipantProfile
    var onRequestClose: (() -> Void)?
    @EnvironmentObject private var appState: AppState
    @StateObject private var coordinator: PeerSessionCoordinator
    @StateObject private var workflow: DualSessionModel
    @State private var joinCode = ""
    @State private var showScanner = false
    @State private var copiedInvitationCode: String?
    @State private var error: AppError?

    init(profile: ParticipantProfile, onRequestClose: (() -> Void)? = nil) {
        self.profile = profile
        self.onRequestClose = onRequestClose
        let coordinator = PeerSessionCoordinator(profile: profile)
        _coordinator = StateObject(wrappedValue: coordinator)
        _workflow = StateObject(wrappedValue: DualSessionModel(profile: profile, coordinator: coordinator))
    }

    var body: some View {
        Group {
            if usesStandaloneFlowLayout {
                // 相机、处理中状态和 Form 必须直接占用导航内容，不能被外层 ScrollView 重新布局。
                DualRecordingFlow(model: workflow)
            } else {
                ScrollView {
                    VStack(spacing: 22) {
                        if workflow.needsTransferRecoveryUI || workflow.stage == .recoverStaging {
                            // 传输/暂存阶段保留流程，支持 10 分钟内重新配对
                            DualRecordingFlow(model: workflow)
                            if coordinator.state != .paired {
                                Divider()
                                connectionView
                            }
                        } else {
                            connectionView
                        }
                    }
                    .padding(24)
                }
                .appReadableWidth(680)
                .background(AppTheme.canvas.ignoresSafeArea())
            }
        }
        .background(AppTheme.canvas.ignoresSafeArea())
        .navigationTitle("双机记录")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            let keepStaging = workflow.needsTransferRecoveryUI || workflow.stage == .recoverStaging
            if let error = workflow.cancel(clearStaging: !keepStaging) {
                appState.transientError = error
            }
            coordinator.stop()
            appState.refreshDrafts()
        }
        .sheet(isPresented: $showScanner) {
            QRCodeScannerSheet { code in
                showScanner = false
                join(code: code)
            } onFailure: { message in
                showScanner = false
                error = AppError(title: "无法扫码", detail: message)
            }
        }
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
        .onChange(of: workflow.requestDismiss) { _, shouldDismiss in
            guard shouldDismiss else { return }
            appState.refreshDrafts()
            onRequestClose?()
        }
    }

    private var usesStandaloneFlowLayout: Bool {
        DualSessionPresentationPolicy.usesStandaloneFlowLayout(
            stage: workflow.stage,
            isPeerPaired: coordinator.state == .paired,
            canContinueWithoutPeer: workflow.canContinueWithoutPeer
        )
    }

    @ViewBuilder
    private var connectionView: some View {
        switch coordinator.state {
        case .idle, .failed:
            startView
        case .hosting:
            hostView
        case .searching, .connecting:
            ProgressView(coordinator.state.title)
                .controlSize(.large)
                .padding(.top, 80)
        case .awaitingConfirmation:
            confirmationView
        case .paired:
            pairedView
        }
    }

    private var startView: some View {
        VStack(spacing: 18) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(AppTheme.accent)
            Text("让两台手机靠近一点")
                .font(.title2.bold())
            Text("你们的手机会直接建立加密连接。二维码里没有视频、密码或头像。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                do {
                    let recoverySessionID = try workflow.prepareForPairing()
                    try coordinator.host(sessionID: recoverySessionID)
                } catch {
                    self.error = AppError(title: "无法开始配对", detail: error.localizedDescription)
                }
            } label: {
                Label("展示我的二维码", systemImage: "qrcode")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.dualHost)
            Divider().padding(.vertical, 6)
            Button { showScanner = true } label: {
                Label("扫描对方二维码", systemImage: "qrcode.viewfinder")
            }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.dualScan)
            TextField("或粘贴二维码文本", text: $joinCode, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("使用粘贴文本连接") { join(code: joinCode) }
                .disabled(joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var hostView: some View {
        VStack(spacing: 18) {
            Text("请让对方用本应用扫描此二维码")
                .font(.headline)
            if let code = coordinator.invitationCode {
                QRCodeView(code: code)
                    .frame(width: 250, height: 250)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.line, lineWidth: 1))

                VStack(alignment: .leading, spacing: 8) {
                    Text("二维码文字信息")
                        .font(.subheadline.weight(.semibold))
                    Text(code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.line, lineWidth: 1))
                        .accessibilityIdentifier(AccessibilityID.dualInvitationText)
                    Button {
                        UIPasteboard.general.string = code
                        copiedInvitationCode = code
                    } label: {
                        if copiedInvitationCode == code {
                            Label("已复制", systemImage: "checkmark")
                        } else {
                            Label("复制文字信息", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.dualInvitationCopy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ProgressView("等待附近设备扫码…")
            Button("取消") { coordinator.stop() }
                .buttonStyle(.bordered)
        }
    }

    private var confirmationView: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 50))
                .foregroundStyle(AppTheme.sage)
            Text("确认连接对象")
                .font(.title2.bold())
            if let remote = coordinator.remoteProfile {
                VStack(spacing: 6) {
                    Text("对方显示姓名")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(remote.name)
                        .font(.title3.bold())
                    ProfileAvatar(data: remote.avatarData, size: 70)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("请当面核对双方屏幕上的六码是否一致")
                .foregroundStyle(.secondary)
            Text(coordinator.verificationCode ?? "------")
                .font(.system(size: 38, design: .monospaced).weight(.bold))
            Toggle("我确认资料正确且六码一致", isOn: Binding(
                get: { coordinator.localConfirmed },
                set: { value in
                    guard value else { return }
                    do {
                        try coordinator.confirm()
                    } catch {
                        self.error = AppError(title: "无法确认配对", detail: error.localizedDescription)
                    }
                }
            ))
            .disabled(coordinator.localConfirmed)
            if coordinator.localConfirmed && !coordinator.remoteConfirmed {
                ProgressView("等待对方确认…")
            }
            Button("取消配对", role: .destructive) { coordinator.stop() }
                .buttonStyle(.bordered)
        }
    }

    private var pairedView: some View {
        DualRecordingFlow(model: workflow)
    }

    private func join(code: String) {
        do {
            let recoverySessionID = try workflow.prepareForPairing()
            try coordinator.join(
                invitationCode: code,
                expectedSessionID: recoverySessionID
            )
            joinCode.removeAll()
        } catch {
            self.error = AppError(title: "无法连接", detail: error.localizedDescription)
        }
    }
}

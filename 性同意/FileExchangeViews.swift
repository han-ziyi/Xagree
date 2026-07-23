import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct FileExportSheet: UIViewControllerRepresentable {
    let url: URL
    let onCompleted: () -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompleted: onCompleted, onCancelled: onCancelled) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompleted: () -> Void
        let onCancelled: () -> Void

        init(onCompleted: @escaping () -> Void, onCancelled: @escaping () -> Void) {
            self.onCompleted = onCompleted
            self.onCancelled = onCancelled
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompleted()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancelled()
        }
    }
}

struct EvidenceImportView: View {
    @State private var showingImporter = false
    @State private var selectedURL: URL?
    @State private var password = ""
    @State private var evidence: DecryptedEvidence?
    @State private var error: AppError?
    @State private var isDecrypting = false

    var body: some View {
        Group {
            if let evidence {
                EvidencePlayerView(evidence: evidence) {
                    self.evidence = nil
                }
            } else {
                Form {
                    Section {
                        Text("选择此前导出的 `.xagree` 加密文件。仅在输入正确密码后，视频才会临时在本机解密播放。")
                            .foregroundStyle(.secondary)
                    }
                    Section("加密文件") {
                        Button(selectedURL.map(\.lastPathComponent) ?? L10n.string("选择文件")) {
                            showingImporter = true
                        }
                    }
                    Section("密码") {
                        SecureField("文件密码", text: $password)
                        Button(isDecrypting ? L10n.string("正在解密…") : L10n.string("解锁并播放")) {
                            decrypt()
                        }
                        .disabled(selectedURL == nil || password.isEmpty || isDecrypting)
                    }
                }
                .appReadableWidth()
                .navigationTitle("打开加密文件")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "xagree") ?? .data]
        ) { result in
            switch result {
            case .success(let url): selectedURL = url
            case .failure(let error): self.error = AppError(title: "无法打开文件", detail: error.localizedDescription)
            }
        }
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
    }

    private func decrypt() {
        guard let selectedURL else { return }
        isDecrypting = true
        Task {
            let hasAccess = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { selectedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let decrypted = try EvidenceCryptor.open(packageURL: selectedURL, password: password)
                await MainActor.run {
                    evidence = decrypted
                    password.removeAll()
                    isDecrypting = false
                }
            } catch {
                await MainActor.run {
                    self.error = AppError(title: "无法解锁文件", detail: error.localizedDescription)
                    isDecrypting = false
                }
            }
        }
    }
}

private struct EvidencePlayerView: View {
    let evidence: DecryptedEvidence
    let onClosed: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var idleTimer: Timer?
    @State private var isObscured = false
    @State private var isFullScreenPresented = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let player {
                    ZStack(alignment: .topTrailing) {
                        VideoPlayer(player: player)
                            .onTapGesture { resetIdleTimer() }
                        Button {
                            resetIdleTimer()
                            isFullScreenPresented = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.68), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("全屏播放")
                        .accessibilityIdentifier(AccessibilityID.playerFullScreen)
                        .help("全屏播放")
                        .padding(12)
                    }
                    .aspectRatio(9 / 16, contentMode: .fit)
                }
                List {
                    Section("记录信息") {
                        LabeledContent("会话号", value: String(evidence.manifest.sessionID.uuidString.prefix(8)) + "…")
                        LabeledContent("模式", value: evidence.manifest.mode.title)
                        LabeledContent("参与者 A", value: evidence.manifest.participantNames["A"] ?? "—")
                        LabeledContent("参与者 B", value: evidence.manifest.participantNames["B"] ?? "—")
                    }
                    Section {
                        Text("视频仅临时解密播放。停止播放、锁屏、切后台或 60 秒无操作即删除临时明文。设备时间与水印不是司法时间戳。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isObscured {
                PrivacyShieldView()
            }
        }
        .navigationTitle("加密记录")
        .fullScreenCover(isPresented: $isFullScreenPresented, onDismiss: resetIdleTimer) {
            if let player {
                FullScreenEvidencePlayer(player: player, onInteraction: resetIdleTimer)
            }
        }
        .onAppear {
            guard player == nil else {
                resetIdleTimer()
                return
            }
            let avPlayer = AVPlayer(url: evidence.videoURL)
            player = avPlayer
            avPlayer.play()
            resetIdleTimer()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                isObscured = true
                removeTemporaryVideo()
                onClosed()
            }
        }
        .onDisappear {
            guard !isFullScreenPresented else { return }
            idleTimer?.invalidate()
            removeTemporaryVideo()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            isObscured = true
            removeTemporaryVideo()
            onClosed()
        }
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        guard player != nil else {
            idleTimer = nil
            return
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            Task { @MainActor in
                removeTemporaryVideo()
                onClosed()
            }
        }
    }

    private func removeTemporaryVideo() {
        idleTimer?.invalidate()
        idleTimer = nil
        isFullScreenPresented = false
        player?.pause()
        player = nil
        EvidenceCryptor.remove(evidence.videoURL)
    }
}

private struct FullScreenEvidencePlayer: View {
    let player: AVPlayer
    let onInteraction: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .onTapGesture { onInteraction() }
            Button {
                onInteraction()
                dismiss()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.68), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出全屏")
            .accessibilityIdentifier(AccessibilityID.playerExitFullScreen)
            .help("退出全屏")
            .padding(16)
        }
        .onAppear {
            player.play()
            onInteraction()
        }
        .onDisappear { onInteraction() }
    }
}

import AVKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let xagreeEvidence = UTType(
        exportedAs: "com.hanziyi.xagree.evidence",
        conformingTo: .data
    )
}

/// 系统文件导出面板。
///
/// 重要：不要把 `UIDocumentPickerViewController` 直接当作 SwiftUI `.sheet` 的根控制器——
/// 在较新的 iOS 上该写法经常导致保存页不出现、或“静默结束”。
/// 正确做法是用透明宿主 VC，再 `present` 文档选择器。
///
/// 自定义默认文件名：导出前把包复制为 `preferredBaseName.xagree`，
/// 系统保存面板会沿用该文件名（用户仍可在 Files UI 中改名）。
struct FileExportSheet: UIViewControllerRepresentable {
    let url: URL
    /// 不含扩展名的默认文件名；为空则使用源文件名。
    var preferredBaseName: String?
    let onCompleted: () -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompleted: onCompleted, onCancelled: onCancelled)
    }

    func makeUIViewController(context: Context) -> HostController {
        HostController()
    }

    func updateUIViewController(_ host: HostController, context: Context) {
        context.coordinator.parent = self
        host.onReadyToPresent = { [weak host] in
            guard let host, host.presentedViewController == nil else { return }
            context.coordinator.presentPicker(from: host)
        }
        // 视图进入窗口后尝试弹出
        DispatchQueue.main.async {
            host.tryPresent()
        }
    }

    /// 将源包复制到临时目录，使用可读的时间戳文件名供系统保存面板展示。
    nonisolated static func preparedExportURL(from source: URL, preferredBaseName: String?) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("XAgreeExport", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let base: String = {
            if let preferredBaseName, !preferredBaseName.isEmpty {
                return preferredBaseName
            }
            let stem = source.deletingPathExtension().lastPathComponent
            return stem.isEmpty ? AppFiles.exportPackageBaseName() : stem
        }()
        let destination = directory.appendingPathComponent(base).appendingPathExtension("xagree")
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
        return destination
    }

    final class HostController: UIViewController {
        var onReadyToPresent: (() -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            tryPresent()
        }

        func tryPresent() {
            guard viewIfLoaded?.window != nil else { return }
            onReadyToPresent?()
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FileExportSheet?
        let onCompleted: () -> Void
        let onCancelled: () -> Void
        private var didPresent = false
        private var didFinish = false
        private var temporaryExportURL: URL?

        init(onCompleted: @escaping () -> Void, onCancelled: @escaping () -> Void) {
            self.onCompleted = onCompleted
            self.onCancelled = onCancelled
        }

        func presentPicker(from host: UIViewController) {
            guard !didPresent, let parent else { return }
            didPresent = true

            let exportURL: URL
            do {
                exportURL = try FileExportSheet.preparedExportURL(
                    from: parent.url,
                    preferredBaseName: parent.preferredBaseName
                )
                temporaryExportURL = exportURL == parent.url ? nil : exportURL
            } catch {
                // 复制失败时退回源文件，至少保证保存面板可用
                exportURL = parent.url
                temporaryExportURL = nil
            }

            let picker = UIDocumentPickerViewController(forExporting: [exportURL], asCopy: true)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            picker.modalPresentationStyle = .formSheet

            // 0 尺寸 background 宿主可能不适合直接 present；优先用当前 key window 顶层 VC。
            let presenter = Self.topViewController(from: host) ?? host
            if presenter.presentedViewController == nil {
                presenter.present(picker, animated: true)
            } else {
                // 已有模态时挂到最上层，避免被挡
                var top = presenter
                while let next = top.presentedViewController {
                    top = next
                }
                top.present(picker, animated: true)
            }
        }

        private static func topViewController(from start: UIViewController) -> UIViewController? {
            if let window = start.view.window {
                var top = window.rootViewController
                while let presented = top?.presentedViewController {
                    top = presented
                }
                return top
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                ?? scenes.flatMap(\.windows).first
            var top = window?.rootViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !didFinish else { return }
            didFinish = true
            cleanupTemporary()
            onCompleted()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !didFinish else { return }
            didFinish = true
            cleanupTemporary()
            onCancelled()
        }

        private func cleanupTemporary() {
            if let temporaryExportURL {
                try? FileManager.default.removeItem(at: temporaryExportURL)
            }
            temporaryExportURL = nil
        }
    }
}

/// 控制导出面板的开关：确保每次打开都走 false→true，避免 SwiftUI 不重建 present。
struct EvidenceExportTrigger: ViewModifier {
    @Binding var isPresented: Bool
    let packageURL: URL?
    var preferredBaseName: String?
    let onCompleted: () -> Void
    let onCancelled: () -> Void

    func body(content: Content) -> some View {
        content.background {
            if isPresented, let packageURL {
                FileExportSheet(
                    url: packageURL,
                    preferredBaseName: preferredBaseName ?? packageURL.deletingPathExtension().lastPathComponent,
                    onCompleted: {
                        isPresented = false
                        onCompleted()
                    },
                    onCancelled: {
                        isPresented = false
                        onCancelled()
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func evidenceDocumentExporter(
        isPresented: Binding<Bool>,
        packageURL: URL?,
        preferredBaseName: String? = nil,
        onCompleted: @escaping () -> Void,
        onCancelled: @escaping () -> Void
    ) -> some View {
        modifier(
            EvidenceExportTrigger(
                isPresented: isPresented,
                packageURL: packageURL,
                preferredBaseName: preferredBaseName,
                onCompleted: onCompleted,
                onCancelled: onCancelled
            )
        )
    }
}

struct EvidenceImportView: View {
    @State private var showingImporter = false
    @State private var selectedURL: URL?
    @State private var password = ""
    @State private var evidence: DecryptedEvidence?
    @State private var error: AppError?
    @State private var isDecrypting = false
    @State private var decryptionTask: Task<Void, Never>?

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
            allowedContentTypes: [UTType(filenameExtension: "xagree") ?? .data, .xagreeEvidence]
        ) { result in
            switch result {
            case .success(let url): selectedURL = url
            case .failure(let error): self.error = AppError(title: "无法打开文件", detail: error.localizedDescription)
            }
        }
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: Text(error.detail), dismissButton: .default(Text("知道了")))
        }
        .onDisappear {
            decryptionTask?.cancel()
        }
    }

    private func decrypt() {
        guard let selectedURL else { return }
        let submittedPassword = password
        isDecrypting = true
        decryptionTask = Task {
            defer { decryptionTask = nil }
            let hasAccess = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { selectedURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let decrypted = try await Task.detached(priority: .userInitiated) {
                    try EvidenceCryptor.open(packageURL: selectedURL, password: submittedPassword)
                }.value
                guard !Task.isCancelled else {
                    EvidenceCryptor.remove(decrypted.videoURL)
                    isDecrypting = false
                    return
                }
                evidence = decrypted
                password.removeAll()
                isDecrypting = false
            } catch {
                if !Task.isCancelled {
                    self.error = AppError(title: "无法解锁文件", detail: error.localizedDescription)
                }
                isDecrypting = false
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

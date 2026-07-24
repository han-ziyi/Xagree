@preconcurrency import AVFoundation
import Combine
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import Vision
import VisionKit

struct QRCodeView: View {
    let code: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = makeImage() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private func makeImage() -> UIImage? {
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct QRCodeScannerSheet: View {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    var body: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            LiveQRScannerSheet(onCode: onCode, onFailure: onFailure)
        } else {
            UniversalQRScannerSheet(onCode: onCode)
        }
    }
}

private struct LiveQRScannerSheet: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.onFailure(error.localizedDescription)
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onFailure: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                    delivered = true
                    dataScanner.stopScanning()
                    onCode(payload)
                    return
                }
            }
        }
    }
}

private struct UniversalQRScannerSheet: View {
    let onCode: (String) -> Void
    @StateObject private var scanner = QRCodeCaptureService()
    @State private var imageItem: PhotosPickerItem?
    @State private var pastedCode = ""
    @State private var isDecodingImage = false
    @State private var errorMessage: String?
    @State private var delivered = false

    var body: some View {
        NavigationStack {
            ZStack {
                if scanner.isReady {
                    CameraPreview(session: scanner.session)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        scanner.statusTitle,
                        systemImage: scanner.statusSymbol,
                        description: Text(scanner.statusDetail)
                    )
                }
            }
            .navigationTitle("扫描二维码")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if isDecodingImage {
                        ProgressView("正在识别二维码…")
                    }
                    PhotosPicker(selection: $imageItem, matching: .images) {
                        Label("从相册导入二维码", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.dualScannerImport)
                    TextField("或粘贴二维码文本", text: $pastedCode, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .accessibilityIdentifier(AccessibilityID.dualScannerText)
                    HStack {
                        Button {
                            pastedCode = UIPasteboard.general.string ?? ""
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        Button("使用此文本") { deliver(pastedCode) }
                            .buttonStyle(.bordered)
                            .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .task { await scanner.prepare() }
            .task(id: imageItem) { await decodeSelectedImage() }
            .onChange(of: scanner.scannedCode) { _, code in
                if let code { deliver(code) }
            }
            .alert("无法识别二维码", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onDisappear { scanner.stop() }
    }

    private func decodeSelectedImage() async {
        guard let imageItem else { return }
        isDecodingImage = true
        defer {
            isDecodingImage = false
            self.imageItem = nil
        }
        do {
            guard let data = try await imageItem.loadTransferable(type: Data.self) else {
                throw QRCodeScanError.invalidImage
            }
            deliver(try QRCodeImageDecoder.decode(data: data))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deliver(_ code: String) {
        guard !delivered else { return }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        delivered = true
        scanner.stop()
        onCode(normalized)
    }
}

private enum QRCodeScanError: LocalizedError {
    case invalidImage
    case noCode

    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取所选图片。"
        case .noCode: "所选图片中没有可识别的二维码。"
        }
    }
}

enum QRCodeImageDecoder {
    static func decode(data: Data) throws -> String {
        guard let image = CIImage(data: data),
              let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(options: [.useSoftwareRenderer: true]),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ) else {
            throw QRCodeScanError.invalidImage
        }
        guard let code = detector.features(in: image)
            .compactMap({ $0 as? CIQRCodeFeature })
            .compactMap(\.messageString)
            .first else {
            throw QRCodeScanError.noCode
        }
        return code
    }
}

@MainActor
private final class QRCodeCaptureService: NSObject, ObservableObject {
    enum Availability: Equatable {
        case loading
        case ready
        case cameraUnavailable
        case cameraDenied
    }

    let session = AVCaptureSession()
    @Published private(set) var availability: Availability = .loading
    @Published private(set) var scannedCode: String?

    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "xagree.qr-scanner.session")
    private let metadataQueue = DispatchQueue(label: "xagree.qr-scanner.metadata")
    private var isConfigured = false

    var isReady: Bool { availability == .ready }
    var statusTitle: String {
        switch availability {
        case .loading: "正在准备扫码"
        case .ready: ""
        case .cameraUnavailable: "相机不可用"
        case .cameraDenied: "未获得相机权限"
        }
    }
    var statusSymbol: String {
        switch availability {
        case .loading: "qrcode.viewfinder"
        case .ready: "qrcode.viewfinder"
        case .cameraUnavailable: "photo.on.rectangle"
        case .cameraDenied: "camera.fill"
        }
    }
    var statusDetail: String {
        switch availability {
        case .loading: ""
        case .ready: ""
        case .cameraUnavailable: "可从相册导入二维码图片，或粘贴二维码文本。"
        case .cameraDenied: "允许相机权限后可实时扫码；也可从相册导入二维码图片。"
        }
    }

    func prepare() async {
        #if targetEnvironment(simulator)
        availability = .cameraUnavailable
        return
        #else
        guard await requestCameraAccess() else {
            availability = .cameraDenied
            return
        }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            availability = .cameraUnavailable
            return
        }
        do {
            if !isConfigured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input), session.canAddOutput(metadataOutput) else {
                    availability = .cameraUnavailable
                    return
                }
                session.addInput(input)
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
                metadataOutput.metadataObjectTypes = [.qr]
                isConfigured = true
            }
            availability = .ready
            sessionQueue.async { [session] in session.startRunning() }
        } catch {
            availability = .cameraUnavailable
        }
        #endif
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
}

extension QRCodeCaptureService: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?.stringValue else { return }
        Task { @MainActor [weak self] in
            self?.scannedCode = code
        }
    }
}

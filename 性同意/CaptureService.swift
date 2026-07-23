@preconcurrency import AVFoundation
import Combine
import CoreImage
import CoreVideo
import Foundation
import SwiftUI
import UIKit

enum CaptureError: LocalizedError, Equatable {
    case cameraDenied
    case microphoneDenied
    case cameraUnavailable
    case microphoneUnavailable
    case alreadyRecording
    case noRecording
    case recordingFailed
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .cameraDenied: L10n.string("需要相机权限才能录制视频。请在系统设置中允许访问相机。")
        case .microphoneDenied: L10n.string("需要麦克风权限才能录制口述声明。请在系统设置中允许访问麦克风。")
        case .cameraUnavailable: L10n.string("当前设备无法使用前置摄像头。")
        case .microphoneUnavailable: L10n.string("当前设备无法使用麦克风。")
        case .alreadyRecording: L10n.string("录制正在进行。")
        case .noRecording: L10n.string("当前没有进行中的录制。")
        case .recordingFailed: L10n.string("视频录制失败。")
        case .writerFailed: L10n.string("无法创建录制写入器。")
        }
    }
}

struct CaptureRequest: Sendable {
    let watermark: RecordingWatermark
    let maxDuration: TimeInterval

    init(watermark: RecordingWatermark, maxDuration: TimeInterval = 30) {
        self.watermark = watermark
        self.maxDuration = maxDuration
    }
}

/// 使用 Video/Audio DataOutput + AVAssetWriter，在 writer 队列上实时烧录水印。
@MainActor
final class CaptureService: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var isPrepared = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var remainingSeconds = 30

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "xagree.capture.session")
    private let writerQueue = DispatchQueue(label: "xagree.capture.writer")

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingContinuation: CheckedContinuation<CaptureArtifact, Error>?
    private var outputURL: URL?
    private var request: CaptureRequest?
    private var timer: Timer?
    private var startedAt: Date?
    private var isWriting = false
    private let runtimeID = UUID()

    func prepare() async throws {
        guard await requestAccess(for: .video) else { throw CaptureError.cameraDenied }
        guard await requestAccess(for: .audio) else { throw CaptureError.microphoneDenied }
        guard !isPrepared else {
            if !session.isRunning {
                sessionQueue.async { [session] in session.startRunning() }
            }
            return
        }

        session.beginConfiguration()
        do {
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                throw CaptureError.cameraUnavailable
            }
            try configureCamera(camera)

            let videoDeviceInput = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(videoDeviceInput) else {
                throw CaptureError.cameraUnavailable
            }
            session.addInput(videoDeviceInput)

            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                throw CaptureError.microphoneUnavailable
            }
            let audioDeviceInput = try AVCaptureDeviceInput(device: microphone)
            guard session.canAddInput(audioDeviceInput) else {
                throw CaptureError.microphoneUnavailable
            }
            session.addInput(audioDeviceInput)

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: writerQueue)
            guard session.canAddOutput(videoOutput) else {
                throw CaptureError.cameraUnavailable
            }
            session.addOutput(videoOutput)

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }

            audioOutput.setSampleBufferDelegate(self, queue: writerQueue)
            guard session.canAddOutput(audioOutput) else {
                throw CaptureError.microphoneUnavailable
            }
            session.addOutput(audioOutput)
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            throw error
        }
        isPrepared = true
        sessionQueue.async { [session] in session.startRunning() }
    }

    func begin(_ request: CaptureRequest) async throws -> CaptureArtifact {
        guard isPrepared else { throw CaptureError.cameraUnavailable }
        guard !isRecording else { throw CaptureError.alreadyRecording }

        let url = try AppFiles.temporaryURL(extension: "mp4")
        try setupWriter(to: url)
        self.request = request
        self.outputURL = url
        self.isWriting = true
        self.isRecording = true
        self.elapsedSeconds = 0
        self.remainingSeconds = Int(request.maxDuration)
        self.startedAt = Date()

        CaptureWriterRuntime.bind(
            id: runtimeID,
            isWriting: true,
            assetWriter: assetWriter,
            videoInput: videoInput,
            audioInput: audioInput,
            pixelAdaptor: pixelAdaptor,
            request: request,
            videoOutput: videoOutput,
            audioOutput: audioOutput
        )
        startTimer(maxDuration: request.maxDuration)

        return try await withCheckedThrowingContinuation { continuation in
            recordingContinuation = continuation
        }
    }

    func stop() {
        guard isWriting else { return }
        finishWriting(cancel: false)
    }

    func cancelAndDelete() {
        finishWriting(cancel: true)
    }

    func stopSession() {
        timer?.invalidate()
        timer = nil
        if isWriting { finishWriting(cancel: true) }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureCamera(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        let desired = CMTime(value: 1, timescale: 30)
        camera.activeVideoMinFrameDuration = desired
        camera.activeVideoMaxFrameDuration = desired
    }

    private func setupWriter(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let width = 1080
        let height = 1920
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ]
        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioWriterInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoWriterInput), writer.canAdd(audioWriterInput) else {
            throw CaptureError.writerFailed
        }
        writer.add(videoWriterInput)
        writer.add(audioWriterInput)

        assetWriter = writer
        videoInput = videoWriterInput
        audioInput = audioWriterInput
        pixelAdaptor = adaptor
    }

    private func startTimer(maxDuration: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.elapsedSeconds = min(Int(maxDuration), Int(elapsed))
                self.remainingSeconds = max(0, Int(ceil(maxDuration - elapsed)))
                if elapsed >= maxDuration {
                    self.stop()
                }
            }
        }
    }

    private func finishWriting(cancel: Bool) {
        guard isWriting else { return }
        isWriting = false
        CaptureWriterRuntime.setWriting(false, id: runtimeID)
        timer?.invalidate()
        timer = nil
        startedAt = nil
        isRecording = false
        elapsedSeconds = 0
        remainingSeconds = 30

        let writer = assetWriter
        let video = videoInput
        let audio = audioInput
        let url = outputURL
        let watermark = request?.watermark
        let continuation = recordingContinuation
        let runtimeID = self.runtimeID
        recordingContinuation = nil
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelAdaptor = nil
        request = nil
        outputURL = nil

        let finishContext = WriterFinishContext(
            writer: writer,
            video: video,
            audio: audio,
            url: url,
            watermark: watermark,
            continuation: continuation,
            runtimeID: runtimeID,
            cancel: cancel
        )

        writerQueue.async {
            finishContext.video?.markAsFinished()
            finishContext.audio?.markAsFinished()
            finishContext.writer?.finishWriting {
                let status = finishContext.writer?.status
                let writerError = finishContext.writer?.error
                CaptureWriterRuntime.unbind(id: finishContext.runtimeID)
                Task { @MainActor in
                    guard let continuation = finishContext.continuation else { return }
                    if finishContext.cancel {
                        if let url = finishContext.url { try? FileManager.default.removeItem(at: url) }
                        continuation.resume(throwing: CaptureError.noRecording)
                        return
                    }
                    guard status == .completed,
                          let url = finishContext.url,
                          let watermark = finishContext.watermark else {
                        if let url = finishContext.url { try? FileManager.default.removeItem(at: url) }
                        continuation.resume(throwing: writerError ?? CaptureError.recordingFailed)
                        return
                    }
                    do {
                        try AppFiles.protect(url: url)
                        let duration = await MediaProcessor.duration(of: url)
                        let hash = try FileHasher.sha256Hex(of: url)
                        continuation.resume(returning: CaptureArtifact(
                            url: url,
                            duration: duration,
                            sha256: hash,
                            watermark: watermark
                        ))
                    } catch {
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: mediaType)
        default: false
        }
    }
}

private nonisolated final class WriterFinishContext: @unchecked Sendable {
    let writer: AVAssetWriter?
    let video: AVAssetWriterInput?
    let audio: AVAssetWriterInput?
    let url: URL?
    let watermark: RecordingWatermark?
    let continuation: CheckedContinuation<CaptureArtifact, Error>?
    let runtimeID: UUID
    let cancel: Bool

    init(
        writer: AVAssetWriter?,
        video: AVAssetWriterInput?,
        audio: AVAssetWriterInput?,
        url: URL?,
        watermark: RecordingWatermark?,
        continuation: CheckedContinuation<CaptureArtifact, Error>?,
        runtimeID: UUID,
        cancel: Bool
    ) {
        self.writer = writer
        self.video = video
        self.audio = audio
        self.url = url
        self.watermark = watermark
        self.continuation = continuation
        self.runtimeID = runtimeID
        self.cancel = cancel
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        CaptureWriterRuntime.handle(output: output, sampleBuffer: sampleBuffer)
    }
}

// MARK: - Writer runtime (writerQueue 串行访问)

private nonisolated enum CaptureWriterRuntime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var states: [UUID: State] = [:]
    private nonisolated(unsafe) static var activeID: UUID?

    private struct State {
        var isWriting: Bool
        var sessionStarted: Bool
        var assetWriter: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var request: CaptureRequest?
        var watermarkSecond: Int64?
        var watermarkText: String?
        weak var videoOutput: AVCaptureVideoDataOutput?
        weak var audioOutput: AVCaptureAudioDataOutput?
    }

    static func bind(
        id: UUID,
        isWriting: Bool,
        assetWriter: AVAssetWriter?,
        videoInput: AVAssetWriterInput?,
        audioInput: AVAssetWriterInput?,
        pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?,
        request: CaptureRequest?,
        videoOutput: AVCaptureVideoDataOutput,
        audioOutput: AVCaptureAudioDataOutput
    ) {
        lock.lock()
        defer { lock.unlock() }
        states[id] = State(
            isWriting: isWriting,
            sessionStarted: false,
            assetWriter: assetWriter,
            videoInput: videoInput,
            audioInput: audioInput,
            pixelAdaptor: pixelAdaptor,
            request: request,
            watermarkSecond: nil,
            watermarkText: nil,
            videoOutput: videoOutput,
            audioOutput: audioOutput
        )
        activeID = id
    }

    static func unbind(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        states[id] = nil
        if activeID == id { activeID = nil }
    }

    static func setWriting(_ value: Bool, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        states[id]?.isWriting = value
        if !value {
            states[id]?.sessionStarted = false
        }
    }

    static func handle(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard let id = activeID, var state = states[id], state.isWriting else {
            lock.unlock()
            return
        }
        lock.unlock()

        if output === state.videoOutput {
            guard let writer = state.assetWriter,
                  let videoInput = state.videoInput,
                  let pixelAdaptor = state.pixelAdaptor,
                  let request = state.request,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !state.sessionStarted {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: timestamp)
                lock.lock()
                states[id]?.sessionStarted = true
                lock.unlock()
                state.sessionStarted = true
            }
            guard videoInput.isReadyForMoreMediaData else { return }

            // 统一缩放到 writer 设定的 1080×1920，避免分辨率不匹配导致丢帧/黑屏
            let watermarkText = liveWatermarkText(for: request, id: id)
            guard let watermarked = WatermarkRenderer.shared.render(
                pixelBuffer: imageBuffer,
                text: watermarkText,
                targetSize: CGSize(width: 1080, height: 1920)
            ) else { return }
            pixelAdaptor.append(watermarked, withPresentationTime: timestamp)
        } else if output === state.audioOutput {
            lock.lock()
            let started = states[id]?.sessionStarted ?? false
            lock.unlock()
            guard started,
                  let audioInput = state.audioInput,
                  audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }

    private static func liveWatermarkText(for request: CaptureRequest, id: UUID) -> String {
        let now = Date()
        let second = Int64(now.timeIntervalSince1970)
        lock.lock()
        defer { lock.unlock() }
        if states[id]?.watermarkSecond != second {
            states[id]?.watermarkSecond = second
            states[id]?.watermarkText = request.watermark.displayText(at: now)
        }
        return states[id]?.watermarkText ?? request.watermark.displayText(at: now)
    }
}

/// 将水印绘制到每一帧像素缓冲（成片来源，不仅是预览层）。
final class WatermarkRenderer: @unchecked Sendable {
    nonisolated static let shared = WatermarkRenderer()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()

    /// 将输入帧缩放/裁剪到 targetSize，并烧录水印。
    nonisolated func render(
        pixelBuffer: CVPixelBuffer,
        text: String,
        targetSize: CGSize = CGSize(width: 1080, height: 1920)
    ) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        let targetW = Int(targetSize.width)
        let targetH = Int(targetSize.height)
        guard targetW > 0, targetH > 0 else { return nil }

        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetW,
            targetH,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else { return nil }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let srcW = inputImage.extent.width
        let srcH = inputImage.extent.height
        guard srcW > 1, srcH > 1 else { return nil }

        // aspect-fill 到目标尺寸
        let scale = max(CGFloat(targetW) / srcW, CGFloat(targetH) / srcH)
        let scaled = inputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledW = scaled.extent.width
        let scaledH = scaled.extent.height
        let offsetX = (scaledW - CGFloat(targetW)) / 2
        let offsetY = (scaledH - CGFloat(targetH)) / 2
        let cropped = scaled
            .transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x - offsetX, y: -scaled.extent.origin.y - offsetY))
            .cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        context.render(cropped, to: output)

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let base = CVPixelBufferGetBaseAddress(output) else { return output }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)
        guard let cgContext = CGContext(
            data: base,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return output }

        cgContext.translateBy(x: 0, y: CGFloat(targetH))
        cgContext.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(cgContext)
        defer { UIGraphicsPopContext() }

        let fontSize = max(14, CGFloat(targetW) * 0.026)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: UIColor.white
        ]
        let nsText = text as NSString
        let maximumTextWidth = CGFloat(targetW) - 64
        let textBounds = nsText.boundingRect(
            with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).integral
        let padding: CGFloat = 10
        let boxRect = CGRect(
            x: 16,
            y: 16,
            width: min(maximumTextWidth + padding * 2, textBounds.width + padding * 2),
            height: textBounds.height + padding * 2
        )
        cgContext.setFillColor(UIColor.black.withAlphaComponent(0.62).cgColor)
        let path = UIBezierPath(roundedRect: boxRect, cornerRadius: 5)
        cgContext.addPath(path.cgPath)
        cgContext.fillPath()
        nsText.draw(
            with: CGRect(
                x: boxRect.minX + padding,
                y: boxRect.minY + padding,
                width: boxRect.width - padding * 2,
                height: boxRect.height - padding * 2
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return output
    }
}

struct LiveRecordingWatermarkView: View {
    let watermark: RecordingWatermark

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(watermark.displayText(at: context.date))
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityIdentifier(AccessibilityID.recordingWatermark)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let preview = PreviewView()
        preview.previewLayer.session = session
        preview.previewLayer.videoGravity = .resizeAspectFill
        if let connection = preview.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return preview
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

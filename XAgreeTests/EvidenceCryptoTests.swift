import XCTest
import CoreImage.CIFilterBuiltins
import CoreVideo
import CryptoKit
import UIKit
@testable import XAgree

@MainActor
final class EvidenceCryptoTests: XCTestCase {
    func testExportPackageFileNameUsesLocalDateAndTime() throws {
        let date = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-24T15:30:45Z")
        )

        XCTAssertEqual(
            AppFiles.exportPackageFileName(
                at: date,
                timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            ),
            "2026-07-24_15-30-45.xagree"
        )
    }

    func testPreserveExportDraftCopiesPackageIntoDraftsIndex() throws {
        try AppFiles.prepareDirectories()
        try AppFiles.clearDirectory(AppFiles.draftsURL)
        try DraftStore.deleteAllDrafts()

        let source = try AppFiles.exportPackageURL()
        try Data("draft-fixture".utf8).write(to: source, options: .atomic)

        let preserved = try DraftStore.preserveExportDraft(from: source, mode: .single)
        let draftURL = DraftStore.draftURL(for: preserved.draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertTrue(DraftStore.listDrafts().contains(where: { $0.id == preserved.draft.id }))
        XCTAssertEqual(preserved.draft.mode, .single)

        try DraftStore.deleteDraft(preserved.draft)
        try? FileManager.default.removeItem(at: source)
    }

    func testSafeJSONRejectsInvalidUTF8BeforeFoundationDecode() {
        XCTAssertThrowsError(
            try SafeJSONDecoder.decode([String: String].self, from: Data([0xFF]))
        )
    }

    func testUITestBootstrapCannotRunInReleaseConfiguration() {
        let arguments = [
            UITestBootstrap.testingFlag,
            UITestBootstrap.resetFlag,
            UITestBootstrap.skipToHomeFlag
        ]
        XCTAssertFalse(UITestBootstrap.permitsTesting(arguments: arguments, debugBuild: false))
        XCTAssertTrue(UITestBootstrap.permitsTesting(arguments: arguments, debugBuild: true))
        XCTAssertFalse(
            UITestBootstrap.permitsTesting(
                arguments: [UITestBootstrap.resetFlag, UITestBootstrap.skipToHomeFlag],
                debugBuild: true
            )
        )
    }

    func testAppUsesSingleSceneToProtectSharedVaultState() {
        let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
        XCTAssertEqual(manifest?["UIApplicationSupportsMultipleScenes"] as? Bool, false)
    }

    func testIPadDeclaresEveryWindowOrientation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let infoData = try Data(
            contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist")
        )
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, format: nil)
                as? [String: Any]
        )
        let orientations = info["UISupportedInterfaceOrientations~ipad"] as? [String]
        XCTAssertEqual(
            Set(orientations ?? []),
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        )
    }

    func testStartupPurgesOnlyPlaintextWorkFiles() throws {
        try AppFiles.prepareDirectories()
        let workFile = AppFiles.workURL.appendingPathComponent("startup-cleanup-\(UUID().uuidString).mp4")
        let draftFile = AppFiles.draftsURL.appendingPathComponent("startup-cleanup-\(UUID().uuidString).xagr")
        let stagingFile = AppFiles.stagingURL.appendingPathComponent("startup-cleanup-\(UUID().uuidString).stage")
        defer {
            EvidenceCryptor.remove(workFile)
            EvidenceCryptor.remove(draftFile)
            EvidenceCryptor.remove(stagingFile)
        }
        try Data("plaintext".utf8).write(to: workFile)
        try Data("encrypted-draft".utf8).write(to: draftFile)
        try Data("encrypted-staging".utf8).write(to: stagingFile)

        try AppFiles.purgeTemporaryWorkFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: workFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingFile.path))
    }

    func testRecordingAbortsOnlyAfterCaptureStartsAndAppLeavesForeground() {
        XCTAssertFalse(RecordingInterruptionPolicy.shouldAbort(
            scenePhase: .active,
            hasStarted: true,
            isCountingDown: false,
            isRecording: true
        ))
        XCTAssertFalse(RecordingInterruptionPolicy.shouldAbort(
            scenePhase: .inactive,
            hasStarted: false,
            isCountingDown: false,
            isRecording: false
        ))
        XCTAssertTrue(RecordingInterruptionPolicy.shouldAbort(
            scenePhase: .inactive,
            hasStarted: true,
            isCountingDown: true,
            isRecording: false
        ))
        XCTAssertTrue(RecordingInterruptionPolicy.shouldAbort(
            scenePhase: .background,
            hasStarted: true,
            isCountingDown: false,
            isRecording: true
        ))
    }

    func testConsentStatementWordingIsFixed() {
        XCTAssertEqual(
            ConsentStatement.format,
            "我叫 %@，我已经成年，我同意并自愿与 %@ 发生性关系，我意识清醒，没有受到任何形式的胁迫。"
        )
    }

    func testRecordingWatermarkUsesCurrentTimeAndStableTwoLineLayout() {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let watermark = RecordingWatermark(
            sessionID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            role: .a,
            recordedAt: recordedAt,
            status: "REC"
        )

        let first = watermark.displayText(at: recordedAt)
        let next = watermark.displayText(at: recordedAt.addingTimeInterval(1))

        XCTAssertNotEqual(first, next)
        XCTAssertEqual(first.split(separator: "\n").count, 2)
        XCTAssertTrue(first.contains("12345678"))
        XCTAssertTrue(first.contains("REC"))
    }

    func testQRCodeImageDecoderReadsGeneratedQRCode() throws {
        let payload = "xagree-pairing-test-payload"
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return XCTFail("Failed to generate QR code")
        }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let cgImage = try XCTUnwrap(context.createCGImage(output, from: output.extent))
        let imageData = try XCTUnwrap(UIImage(cgImage: cgImage).pngData())

        XCTAssertEqual(try QRCodeImageDecoder.decode(data: imageData), payload)
    }

    func testQRCodeImageDecoderRejectsOversizedInputBeforeImageDecode() {
        let oversized = Data(repeating: 0, count: QRCodeImageDecoder.maximumInputSize + 1)
        XCTAssertThrowsError(try QRCodeImageDecoder.decode(data: oversized))
    }

    func testWatermarkRendererBurnsVisibleTextIntoFrame() throws {
        let width = 320
        let height = 568
        var source: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes,
                &source
            ),
            kCVReturnSuccess
        )
        let sourceBuffer = try XCTUnwrap(source)
        fill(pixelBuffer: sourceBuffer, red: 128, green: 128, blue: 128)

        let rendered = try XCTUnwrap(
            WatermarkRenderer.shared.render(
                pixelBuffer: sourceBuffer,
                text: "2026-07-23 21:53:00\nREC · A · ABCD1234",
                targetSize: CGSize(width: width, height: height)
            )
        )

        XCTAssertGreaterThan(
            countNearWhitePixels(in: rendered),
            40,
            "the burned-in watermark must contain visible white glyph pixels, not only its dark background"
        )
    }

    func testSealOpenRoundTrip() throws {
        let video = try makeSampleVideoData()
        let manifest = sampleManifest(hash: try FileHasher.sha256Hex(of: video))
        let package = try EvidenceCryptor.seal(videoURL: video, manifest: manifest, password: "correct-password-12")
        defer {
            EvidenceCryptor.remove(package)
            EvidenceCryptor.remove(video)
        }

        let opened = try EvidenceCryptor.open(packageURL: package, password: "correct-password-12")
        defer { EvidenceCryptor.remove(opened.videoURL) }

        XCTAssertEqual(opened.manifest.sessionID, manifest.sessionID)
        XCTAssertEqual(opened.manifest.finalVideoSHA256, manifest.finalVideoSHA256)
        let restored = try Data(contentsOf: opened.videoURL)
        let original = try Data(contentsOf: video)
        XCTAssertEqual(restored, original)
    }

    func testWrongPassword() throws {
        let video = try makeSampleVideoData()
        defer { EvidenceCryptor.remove(video) }
        let manifest = sampleManifest(hash: try FileHasher.sha256Hex(of: video))
        let package = try EvidenceCryptor.seal(videoURL: video, manifest: manifest, password: "correct-password-12")
        defer { EvidenceCryptor.remove(package) }

        XCTAssertThrowsError(
            try EvidenceCryptor.open(packageURL: package, password: "wrong-password-xxx")
        ) { error in
            XCTAssertEqual(error as? EvidenceCryptoError, .incorrectPassword)
        }
    }

    func testTamperedHeaderRejected() throws {
        let video = try makeSampleVideoData()
        defer { EvidenceCryptor.remove(video) }
        let manifest = sampleManifest(hash: try FileHasher.sha256Hex(of: video))
        let package = try EvidenceCryptor.seal(videoURL: video, manifest: manifest, password: "correct-password-12")
        defer { EvidenceCryptor.remove(package) }

        var data = try Data(contentsOf: package)
        // Flip a byte inside the header payload region.
        if data.count > 40 {
            data[36] ^= 0xFF
        }
        try data.write(to: package, options: .atomic)

        XCTAssertThrowsError(
            try EvidenceCryptor.open(packageURL: package, password: "correct-password-12")
        )
    }

    func testTamperedChunkRejected() throws {
        let video = try makeSampleVideoData(size: 2_000_000)
        defer { EvidenceCryptor.remove(video) }
        let manifest = sampleManifest(hash: try FileHasher.sha256Hex(of: video))
        let package = try EvidenceCryptor.seal(videoURL: video, manifest: manifest, password: "correct-password-12")
        defer { EvidenceCryptor.remove(package) }

        var data = try Data(contentsOf: package)
        // Flip near end of file (ciphertext region).
        if data.count > 20 {
            data[data.count - 20] ^= 0x5A
        }
        try data.write(to: package, options: .atomic)

        XCTAssertThrowsError(
            try EvidenceCryptor.open(packageURL: package, password: "correct-password-12")
        ) { error in
            let cryptoError = error as? EvidenceCryptoError
            XCTAssertTrue(cryptoError == .tamperedPackage || cryptoError == .incorrectPassword || cryptoError == .invalidPackage)
        }
    }

    func testTrailingDataRejected() throws {
        let video = try makeSampleVideoData()
        defer { EvidenceCryptor.remove(video) }
        let manifest = sampleManifest(hash: try FileHasher.sha256Hex(of: video))
        let package = try EvidenceCryptor.seal(videoURL: video, manifest: manifest, password: "correct-password-12")
        defer { EvidenceCryptor.remove(package) }

        let handle = try FileHandle(forWritingTo: package)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x58]))
        try handle.close()

        XCTAssertThrowsError(
            try EvidenceCryptor.open(packageURL: package, password: "correct-password-12")
        ) { error in
            XCTAssertEqual(error as? EvidenceCryptoError, .tamperedPackage)
        }
    }

    func testSealRejectsManifestVideoHashMismatch() throws {
        let video = try makeSampleVideoData()
        defer { EvidenceCryptor.remove(video) }
        XCTAssertThrowsError(try EvidenceCryptor.seal(
            videoURL: video,
            manifest: sampleManifest(hash: String(repeating: "0", count: 64)),
            password: "correct-password-12"
        )) { error in
            XCTAssertEqual(error as? EvidenceCryptoError, .tamperedPackage)
        }
    }

    func testStagingRejectsTamperedMetadata() async throws {
        let video = try makeSampleVideoData()
        let sessionID = UUID()
        let password = "staging-password-12"
        let hash = try FileHasher.sha256Hex(of: video)
        let manifest = SegmentManifest(
            role: .a,
            duration: 5,
            sha256: hash,
            watermark: RecordingWatermark(sessionID: sessionID, role: .a)
        )
        defer {
            EvidenceCryptor.remove(video)
            try? DraftStore.clearStaging(sessionID: sessionID)
        }

        try await DraftStore.saveStaging(
            sessionID: sessionID,
            role: .a,
            segmentURL: video,
            manifest: manifest,
            vaultPassword: password
        )
        let metadataURL = AppFiles.stagingURL.appendingPathComponent("\(sessionID.uuidString).json")
        let record = try JSONDecoder().decode(
            DraftStore.StagingRecord.self,
            from: Data(contentsOf: metadataURL)
        )
        let tamperedManifest = SegmentManifest(
            role: record.manifest.role,
            duration: record.manifest.duration + 1,
            sha256: record.manifest.sha256,
            watermark: record.manifest.watermark
        )
        let tamperedRecord = DraftStore.StagingRecord(
            sessionID: record.sessionID,
            role: record.role,
            expiresAt: record.expiresAt,
            manifest: tamperedManifest,
            fileName: record.fileName
        )
        try JSONEncoder().encode(tamperedRecord).write(to: metadataURL, options: .atomic)

        do {
            _ = try await DraftStore.loadStaging(sessionID: sessionID, vaultPassword: password)
            XCTFail("Tampered staging metadata must be rejected")
        } catch {
            XCTAssertEqual(error as? EvidenceCryptoError, .tamperedPackage)
        }
    }

    func testDualWorkflowRestoresStagedSessionIdentity() async throws {
        let video = try makeSampleVideoData()
        let sessionID = UUID()
        let password = "staging-password-12"
        let manifest = SegmentManifest(
            role: .a,
            duration: 5,
            sha256: try FileHasher.sha256Hex(of: video),
            watermark: RecordingWatermark(sessionID: sessionID, role: .a)
        )
        defer {
            EvidenceCryptor.remove(video)
            try? DraftStore.clearStaging(sessionID: sessionID)
        }

        try await DraftStore.saveStaging(
            sessionID: sessionID,
            role: .a,
            segmentURL: video,
            manifest: manifest,
            vaultPassword: password
        )
        let coordinator = PeerSessionCoordinator(
            profile: ParticipantProfile(name: "Alice", avatarData: nil)
        )
        let model = DualSessionModel(
            profile: ParticipantProfile(name: "Alice", avatarData: nil),
            coordinator: coordinator
        )

        XCTAssertEqual(model.stage, .recoverStaging)
        XCTAssertEqual(model.sessionPhase, .transferring)
        XCTAssertEqual(try model.prepareForPairing(), sessionID)
    }

    func testStagingReplacementCommitsNewPackageBeforeRemovingOldOne() async throws {
        let firstVideo = try makeSampleVideoData(size: 8_192)
        let secondVideo = try makeSampleVideoData(size: 12_288)
        let sessionID = UUID()
        let password = "staging-password-12"
        let metadataURL = AppFiles.stagingURL.appendingPathComponent("\(sessionID.uuidString).json")
        defer {
            EvidenceCryptor.remove(firstVideo)
            EvidenceCryptor.remove(secondVideo)
            try? DraftStore.clearStaging(sessionID: sessionID)
        }

        let firstManifest = SegmentManifest(
            role: .a,
            duration: 5,
            sha256: try FileHasher.sha256Hex(of: firstVideo),
            watermark: RecordingWatermark(sessionID: sessionID, role: .a)
        )
        try await DraftStore.saveStaging(
            sessionID: sessionID,
            role: .a,
            segmentURL: firstVideo,
            manifest: firstManifest,
            vaultPassword: password
        )
        let firstRecord = try JSONDecoder().decode(
            DraftStore.StagingRecord.self,
            from: Data(contentsOf: metadataURL)
        )
        let firstPackageURL = AppFiles.stagingURL.appendingPathComponent(firstRecord.fileName)

        let secondManifest = SegmentManifest(
            role: .a,
            duration: 6,
            sha256: try FileHasher.sha256Hex(of: secondVideo),
            watermark: RecordingWatermark(sessionID: sessionID, role: .a)
        )
        try await DraftStore.saveStaging(
            sessionID: sessionID,
            role: .a,
            segmentURL: secondVideo,
            manifest: secondManifest,
            vaultPassword: password
        )
        let secondRecord = try JSONDecoder().decode(
            DraftStore.StagingRecord.self,
            from: Data(contentsOf: metadataURL)
        )

        XCTAssertNotEqual(firstRecord.fileName, secondRecord.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPackageURL.path))
        let loaded = try await DraftStore.loadStaging(
            sessionID: sessionID,
            vaultPassword: password
        )
        let restored = try XCTUnwrap(loaded)
        defer { EvidenceCryptor.remove(restored.url) }
        XCTAssertEqual(try Data(contentsOf: restored.url), try Data(contentsOf: secondVideo))
        XCTAssertEqual(restored.manifest, secondManifest)
    }

    func testCorruptDraftIndexDoesNotDeleteSourcePackage() throws {
        let source = try makeSampleVideoData()
        defer {
            EvidenceCryptor.remove(source)
            try? AppFiles.removeItemIfExists(AppFiles.draftsIndexURL)
            try? AppFiles.clearDirectory(AppFiles.draftsURL)
        }
        try Data("not-json".utf8).write(to: AppFiles.draftsIndexURL, options: .atomic)

        XCTAssertThrowsError(
            try DraftStore.saveExportDraft(from: source, mode: .single)
        ) { error in
            XCTAssertEqual(error as? DraftStoreError, .corruptIndex)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(DraftStore.listDrafts().isEmpty)
    }

    func testCorruptDraftIndexUsesIndependentRecoveryRecord() throws {
        let source = try makeSampleVideoData()
        defer {
            EvidenceCryptor.remove(source)
            try? AppFiles.removeItemIfExists(AppFiles.draftsIndexURL)
            try? AppFiles.clearDirectory(AppFiles.draftsURL)
        }
        let corruptIndex = Data("not-json".utf8)
        try corruptIndex.write(to: AppFiles.draftsIndexURL, options: .atomic)

        let result = try DraftStore.preserveExportDraft(from: source, mode: .dual)
        let recoveredURL = DraftStore.draftURL(for: result.draft)

        XCTAssertEqual(result.warning, .corruptIndex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
        XCTAssertEqual(try Data(contentsOf: AppFiles.draftsIndexURL), corruptIndex)

        let snapshot = DraftStore.snapshot()
        XCTAssertEqual(snapshot.issues, [.corruptIndex])
        XCTAssertEqual(snapshot.drafts, [result.draft])

        try DraftStore.deleteDraft(result.draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredURL.path))
        XCTAssertTrue(DraftStore.snapshot().drafts.isEmpty)
    }

    func testUnsupportedVersionRejectedViaCorruptMagic() throws {
        let video = try makeSampleVideoData()
        defer { EvidenceCryptor.remove(video) }
        let package = try EvidenceCryptor.seal(
            videoURL: video,
            manifest: sampleManifest(hash: try FileHasher.sha256Hex(of: video)),
            password: "correct-password-12"
        )
        defer { EvidenceCryptor.remove(package) }

        // Truncate to invalid package.
        try Data([0, 0, 0, 1, 0xFF]).write(to: package, options: .atomic)
        XCTAssertThrowsError(try EvidenceCryptor.open(packageURL: package, password: "correct-password-12"))
    }

    // MARK: - Helpers

    private func makeSampleVideoData(size: Int = 4096) throws -> URL {
        try AppFiles.prepareDirectories()
        let url = try AppFiles.temporaryURL(extension: "mp4")
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8(i % 251) }
        try Data(bytes).write(to: url)
        try AppFiles.protect(url: url)
        return url
    }

    private func sampleManifest(hash: String) -> EvidenceManifest {
        EvidenceManifest(
            version: 1,
            sessionID: UUID(),
            createdAt: Date(),
            mode: .single,
            participantNames: ["A": "Alice", "B": "Bob"],
            segments: [
                SegmentManifest(
                    role: .a,
                    duration: 5,
                    sha256: hash,
                    watermark: RecordingWatermark(sessionID: UUID(), role: .a)
                )
            ],
            finalVideoSHA256: hash,
            appVersion: "1.0",
            profileSnapshots: nil
        )
    }
}

@MainActor
final class SessionPhaseTests: XCTestCase {
    func testSingleSessionRejectsOverlongParticipantNames() {
        let model = SingleSessionModel(owner: ParticipantProfile(name: "Alice", avatarData: nil))
        model.participantB = String(repeating: "B", count: 81)

        XCTAssertThrowsError(try model.start()) { error in
            guard case .invalidParticipantName = error as? SessionFailure else {
                return XCTFail("Expected invalidParticipantName, got \(error)")
            }
        }
    }

    func testLegalTransitions() {
        XCTAssertTrue(SessionPhase.draft.canTransition(to: .armed))
        XCTAssertTrue(SessionPhase.armed.canTransition(to: .recording))
        XCTAssertTrue(SessionPhase.recording.canTransition(to: .assembling))
        XCTAssertTrue(SessionPhase.encrypting.canTransition(to: .awaitingExport))
        XCTAssertTrue(SessionPhase.awaitingExport.canTransition(to: .completed))
    }

    func testDualRecordingAndEncryptRetryPath() {
        // 双备份：录制后进入传输，再组装
        XCTAssertTrue(SessionPhase.armed.canTransition(to: .recording))
        XCTAssertTrue(SessionPhase.recording.canTransition(to: .transferring))
        XCTAssertTrue(SessionPhase.transferring.canTransition(to: .assembling))
        // 合成失败后回到 transferring 重试；加密失败回到 assembling
        XCTAssertTrue(SessionPhase.assembling.canTransition(to: .transferring))
        XCTAssertTrue(SessionPhase.assembling.canTransition(to: .encrypting))
        XCTAssertTrue(SessionPhase.encrypting.canTransition(to: .assembling))
        XCTAssertTrue(SessionPhase.failed.canTransition(to: .transferring))
        // 单备份第二段
        XCTAssertTrue(SessionPhase.recording.canTransition(to: .recording))
    }

    func testIllegalTransitions() {
        XCTAssertFalse(SessionPhase.draft.canTransition(to: .completed))
        XCTAssertFalse(SessionPhase.recording.canTransition(to: .draft))
        XCTAssertFalse(SessionPhase.completed.canTransition(to: .recording))
        XCTAssertTrue(SessionPhase.recording.canTransition(to: .failed))
        XCTAssertTrue(SessionPhase.failed.canTransition(to: .draft))
    }
}

private func fill(pixelBuffer: CVPixelBuffer, red: UInt8, green: UInt8, blue: UInt8) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0..<height {
        let bytes = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let offset = column * 4
            bytes[offset] = blue
            bytes[offset + 1] = green
            bytes[offset + 2] = red
            bytes[offset + 3] = 255
        }
    }
}

private func countNearWhitePixels(in pixelBuffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    var count = 0
    for row in 0..<height {
        let bytes = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let offset = column * 4
            if bytes[offset] > 220, bytes[offset + 1] > 220, bytes[offset + 2] > 220 {
                count += 1
            }
        }
    }
    return count
}

@MainActor
final class PeerPairingTests: XCTestCase {
    func testIncomingResourceSizeIsCheckedBeforeStaging() throws {
        let source = try AppFiles.temporaryURL(extension: "peer-oversized")
        defer { EvidenceCryptor.remove(source) }
        try Data(repeating: 0xA5, count: 65).write(to: source)

        XCTAssertThrowsError(try PeerResourceStager.stage(source, maximumSize: 64)) { error in
            XCTAssertEqual(error as? PeerPairingError, .invalidPeerMessage)
        }
    }

    func testPairedProfileRequiresMatchingAvatarHash() {
        let avatar = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let hash = SHA256.hash(data: avatar).map { String(format: "%02x", $0) }.joined()

        XCTAssertTrue(PeerProtocolLimits.isValidProfile(
            PairedProfile(name: "Alice", avatarData: avatar, avatarHash: hash.uppercased())
        ))
        XCTAssertFalse(PeerProtocolLimits.isValidProfile(
            PairedProfile(name: "Alice", avatarData: avatar, avatarHash: String(repeating: "0", count: 64))
        ))
        XCTAssertFalse(PeerProtocolLimits.isValidProfile(
            PairedProfile(name: "Alice", avatarData: nil, avatarHash: hash)
        ))
        XCTAssertFalse(PeerProtocolLimits.isValidProfile(
            PairedProfile(
                name: "Alice",
                avatarData: Data("not-an-image".utf8),
                avatarHash: FileHasher.sha256Hex(of: Data("not-an-image".utf8))
            )
        ))
    }

    func testOversizedPairingInvitationIsRejectedBeforeDecoding() {
        XCTAssertThrowsError(try PairingInvitation.decode(String(repeating: "A", count: 4097))) { error in
            XCTAssertEqual(error as? PeerPairingError, .invalidInvitation)
        }
    }

    func testBidirectionalRecordingPayloadRoundTripSurvivesCallbackCleanup() throws {
        let sessionID = UUID()
        let key = SymmetricKey(size: .bits256)
        let authenticatedData = Data(sessionID.uuidString.utf8)
        let sourceA = try AppFiles.temporaryURL(extension: "mp4")
        let sourceB = try AppFiles.temporaryURL(extension: "mp4")
        let payloadA = Data((0..<1_100_000).map { UInt8($0 % 241) })
        let payloadB = Data((0..<1_250_000).map { UInt8(($0 * 3) % 239) })
        try payloadA.write(to: sourceA)
        try payloadB.write(to: sourceB)
        var cleanupURLs = [sourceA, sourceB]
        defer { cleanupURLs.forEach { EvidenceCryptor.remove($0) } }

        let transferA = try PeerFileCryptor.seal(
            inputURL: sourceA,
            key: key,
            authenticatedData: authenticatedData
        )
        let transferB = try PeerFileCryptor.seal(
            inputURL: sourceB,
            key: key,
            authenticatedData: authenticatedData
        )
        cleanupURLs += [transferA, transferB]

        let stagedAtB = try PeerResourceStager.stage(transferA)
        let stagedAtA = try PeerResourceStager.stage(transferB)
        cleanupURLs += [stagedAtA, stagedAtB]
        EvidenceCryptor.remove(transferA)
        EvidenceCryptor.remove(transferB)

        let receivedAtB = try PeerFileCryptor.open(
            inputURL: stagedAtB,
            key: key,
            authenticatedData: authenticatedData
        )
        let receivedAtA = try PeerFileCryptor.open(
            inputURL: stagedAtA,
            key: key,
            authenticatedData: authenticatedData
        )
        cleanupURLs += [receivedAtA, receivedAtB]

        XCTAssertEqual(try Data(contentsOf: receivedAtA), payloadB)
        XCTAssertEqual(try Data(contentsOf: receivedAtB), payloadA)
    }

    func testReceivedResourceIsStagedBeforeSystemTemporaryFileDisappears() throws {
        let source = try AppFiles.temporaryURL(extension: "peer-callback")
        let payload = Data((0..<65_537).map { UInt8($0 % 251) })
        try payload.write(to: source, options: .atomic)

        let staged = try PeerResourceStager.stage(source)
        defer {
            EvidenceCryptor.remove(source)
            EvidenceCryptor.remove(staged)
        }
        EvidenceCryptor.remove(source)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: staged), payload)
    }

    func testRecordingReceiptMustMatchSessionRoleAndVideoHash() {
        let sessionID = UUID()
        let manifest = SegmentManifest(
            role: .a,
            duration: 5,
            sha256: String(repeating: "a", count: 64),
            watermark: RecordingWatermark(sessionID: sessionID, role: .a)
        )
        let receipt = RecordingReceipt(
            sessionID: sessionID,
            role: .a,
            sha256: manifest.sha256.uppercased()
        )

        XCTAssertTrue(receipt.matches(sessionID: sessionID, localRole: .a, localManifest: manifest))
        XCTAssertFalse(receipt.matches(sessionID: UUID(), localRole: .a, localManifest: manifest))
        XCTAssertFalse(receipt.matches(sessionID: sessionID, localRole: .b, localManifest: manifest))
        XCTAssertFalse(receipt.matches(sessionID: sessionID, localRole: .a, localManifest: nil))
    }

    func testDualTransferGateRequiresPeerReceiptBeforeAssembly() throws {
        let local = try AppFiles.temporaryURL(extension: "mp4")
        let remote = try AppFiles.temporaryURL(extension: "mp4")
        try Data("local".utf8).write(to: local)
        try Data("remote".utf8).write(to: remote)
        defer {
            EvidenceCryptor.remove(local)
            EvidenceCryptor.remove(remote)
        }
        let manifest = SegmentManifest(
            role: .b,
            duration: 5,
            sha256: String(repeating: "b", count: 64),
            watermark: RecordingWatermark(sessionID: UUID(), role: .b)
        )

        XCTAssertFalse(DualTransferGate.canAssemble(
            localURL: local,
            remoteURL: remote,
            remoteManifest: manifest,
            peerAcknowledgedLocalRecording: false
        ))
        XCTAssertTrue(DualTransferGate.canAssemble(
            localURL: local,
            remoteURL: remote,
            remoteManifest: manifest,
            peerAcknowledgedLocalRecording: true
        ))
    }

    func testDualSaveFlowRemainsVisibleAfterPeerDisconnectOnceTransferCompleted() {
        for phase in [
            SessionPhase.assembling,
            .encrypting,
            .awaitingExport,
            .completed
        ] {
            XCTAssertTrue(
                DualPeerConnectionPolicy.canContinueWithoutPeer(sessionPhase: phase),
                "\(phase) should no longer depend on the peer connection"
            )
        }
        XCTAssertFalse(
            DualPeerConnectionPolicy.canContinueWithoutPeer(sessionPhase: .transferring)
        )

        XCTAssertTrue(
            DualSessionPresentationPolicy.usesStandaloneFlowLayout(
                stage: .export,
                isPeerPaired: false,
                canContinueWithoutPeer: true
            )
        )
        XCTAssertFalse(
            DualSessionPresentationPolicy.usesStandaloneFlowLayout(
                stage: .waitingForPeer,
                isPeerPaired: false,
                canContinueWithoutPeer: false
            )
        )
    }

    func testDualRecordingRequiresActivePairing() {
        let coordinator = PeerSessionCoordinator(
            profile: ParticipantProfile(name: "Alice", avatarData: nil)
        )
        let model = DualSessionModel(
            profile: ParticipantProfile(name: "Alice", avatarData: nil),
            coordinator: coordinator
        )

        model.markReady()

        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(model.sessionPhase, .draft)
        XCTAssertNotNil(model.error)
    }

    func testRecoveryPairingRejectsDifferentSession() throws {
        let invitation = PairingInvitation(
            version: 1,
            sessionID: UUID(),
            hostPeerID: "test-host",
            hostPublicKey: Data(repeating: 0, count: 32)
        )
        let coordinator = PeerSessionCoordinator(
            profile: ParticipantProfile(name: "Bob", avatarData: nil)
        )

        XCTAssertThrowsError(
            try coordinator.join(
                invitationCode: invitation.encodedString(),
                expectedSessionID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? PeerPairingError, .recoverySessionMismatch)
        }
    }
}

@MainActor
final class PasswordPolicyTests: XCTestCase {
    func testAcceptsEightOrMoreASCIIAlphanumericCharacters() {
        XCTAssertTrue(PasswordPolicy.isValid("12345678"))
        XCTAssertTrue(PasswordPolicy.isValid("abcdefgh"))
        XCTAssertTrue(PasswordPolicy.isValid("abc12345"))
    }

    func testRejectsShortPasswordsAndUnsupportedCharacters() {
        XCTAssertEqual(PasswordPolicy.validationIssue(for: "abc1234"), .tooShort)
        XCTAssertEqual(PasswordPolicy.validationIssue(for: "abc1234!"), .invalidCharacters)
        XCTAssertEqual(PasswordPolicy.validationIssue(for: "密码abc12345"), .invalidCharacters)
    }
}

@MainActor
final class PasswordKeyTests: XCTestCase {
    func testDeriveIsDeterministic() throws {
        let salt = Data((0..<32).map { UInt8($0) })
        let a = try PasswordKeyDeriver.derive(password: "same-password-12", salt: salt, rounds: 10_000)
        let b = try PasswordKeyDeriver.derive(password: "same-password-12", salt: salt, rounds: 10_000)
        let aBytes = a.withUnsafeBytes { Data($0) }
        let bBytes = b.withUnsafeBytes { Data($0) }
        XCTAssertEqual(aBytes, bBytes)
    }

    func testDifferentPasswordDifferentKey() throws {
        let salt = Data((0..<32).map { UInt8($0) })
        let a = try PasswordKeyDeriver.derive(password: "password-aaaa-12", salt: salt, rounds: 10_000)
        let b = try PasswordKeyDeriver.derive(password: "password-bbbb-12", salt: salt, rounds: 10_000)
        let aBytes = a.withUnsafeBytes { Data($0) }
        let bBytes = b.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(aBytes, bBytes)
    }
}

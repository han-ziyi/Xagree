import XCTest
@testable import XAgree

@MainActor
final class EvidenceCryptoTests: XCTestCase {
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

    func testStagingRejectsTamperedMetadata() throws {
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

        try DraftStore.saveStaging(
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

        XCTAssertThrowsError(
            try DraftStore.loadStaging(sessionID: sessionID, vaultPassword: password)
        ) { error in
            XCTAssertEqual(error as? EvidenceCryptoError, .tamperedPackage)
        }
    }

    func testDualWorkflowRestoresStagedSessionIdentity() throws {
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

        try DraftStore.saveStaging(
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

@MainActor
final class PeerPairingTests: XCTestCase {
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

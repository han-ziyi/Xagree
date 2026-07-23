import Foundation

enum DraftStoreError: LocalizedError, Equatable {
    case corruptIndex
    case corruptRecoveryRecord
    case unreadableDraftDirectory

    var errorDescription: String? {
        switch self {
        case .corruptIndex:
            L10n.string("待导出草稿索引损坏，无法安全更新。")
        case .corruptRecoveryRecord:
            L10n.string("部分草稿恢复记录已损坏，无法显示。")
        case .unreadableDraftDirectory:
            L10n.string("无法读取待导出草稿目录。")
        }
    }
}

/// 导出取消后保留的加密待导出包，以及双备份中断时的加密暂存。
@MainActor
enum DraftStore {
    private static let stagingTTL: TimeInterval = 10 * 60

    struct Snapshot {
        let drafts: [ExportDraft]
        let issues: [DraftStoreError]
    }

    struct PreserveResult {
        let draft: ExportDraft
        let warning: DraftStoreError?
    }

    static func listDrafts() -> [ExportDraft] {
        snapshot().drafts
    }

    static func snapshot() -> Snapshot {
        var issues: [DraftStoreError] = []
        var drafts: [ExportDraft] = []

        do {
            drafts = try readIndex().filter(isUsableDraft)
        } catch {
            issues.append(.corruptIndex)
        }

        if FileManager.default.fileExists(atPath: AppFiles.draftsURL.path) {
            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: AppFiles.draftsURL,
                    includingPropertiesForKeys: nil
                )
                for file in files where file.lastPathComponent.hasSuffix(".draft.json") {
                    do {
                        let draft = try JSONDecoder().decode(
                            ExportDraft.self,
                            from: Data(contentsOf: file)
                        )
                        if isUsableDraft(draft) {
                            drafts.append(draft)
                        } else {
                            issues.append(.corruptRecoveryRecord)
                        }
                    } catch {
                        issues.append(.corruptRecoveryRecord)
                    }
                }
            } catch {
                issues.append(.unreadableDraftDirectory)
            }
        }

        var seenIDs = Set<UUID>()
        var seenPaths = Set<String>()
        let uniqueDrafts = drafts.filter { draft in
            seenIDs.insert(draft.id).inserted
                && seenPaths.insert(draftURL(for: draft).standardizedFileURL.path).inserted
        }
        return Snapshot(
            drafts: uniqueDrafts.sorted { $0.createdAt > $1.createdAt },
            issues: issues.reduce(into: []) { uniqueIssues, issue in
                if !uniqueIssues.contains(issue) {
                    uniqueIssues.append(issue)
                }
            }
        )
    }

    static func preserveExportDraft(from packageURL: URL, mode: BackupMode) throws -> PreserveResult {
        do {
            return PreserveResult(
                draft: try saveExportDraft(from: packageURL, mode: mode),
                warning: nil
            )
        } catch DraftStoreError.corruptIndex {
            return PreserveResult(
                draft: try saveRecoveryDraft(from: packageURL, mode: mode),
                warning: .corruptIndex
            )
        }
    }

    static func saveExportDraft(from packageURL: URL, mode: BackupMode) throws -> ExportDraft {
        try AppFiles.prepareDirectories()
        let id = UUID()
        let fileName = "pending-\(id.uuidString).xagree"
        let destination = AppFiles.draftsURL.appendingPathComponent(fileName)
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try FileManager.default.copyItem(at: packageURL, to: destination)
        try AppFiles.protect(url: destination)
        let draft = ExportDraft(
            id: id,
            fileName: fileName,
            createdAt: Date(),
            mode: mode,
            relativePath: fileName
        )
        var drafts = try readIndex().filter(isUsableDraft)
        drafts.insert(draft, at: 0)
        try writeIndex(drafts)
        committed = true
        return draft
    }

    static func deleteDraft(_ draft: ExportDraft) throws {
        let recoveryURL = recoveryMetadataURL(for: draft)
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            try AppFiles.removeItemIfExists(draftURL(for: draft))
            try AppFiles.removeItemIfExists(recoveryURL)
            return
        }
        let remainingDrafts = try readIndex().filter { $0.id != draft.id }
        try writeIndex(remainingDrafts)
        try AppFiles.removeItemIfExists(draftURL(for: draft))
    }

    static func deleteAllDrafts() throws {
        try AppFiles.clearDirectory(AppFiles.draftsURL)
        try writeIndex([])
    }

    static func draftURL(for draft: ExportDraft) -> URL {
        AppFiles.draftsURL.appendingPathComponent(URL(fileURLWithPath: draft.relativePath).lastPathComponent)
    }

    // MARK: - Dual staging (10 minutes)

    struct StagingRecord: Codable {
        let sessionID: UUID
        let role: ParticipantRole
        let expiresAt: Date
        let manifest: SegmentManifest
        let fileName: String
    }

    static func saveStaging(
        sessionID: UUID,
        role: ParticipantRole,
        segmentURL: URL,
        manifest: SegmentManifest,
        vaultPassword: String
    ) throws {
        try AppFiles.prepareDirectories()
        purgeExpiredStaging()
        let fileName = "\(sessionID.uuidString)-\(role.rawValue).xagree"
        let package = try EvidenceCryptor.seal(
            videoURL: segmentURL,
            manifest: EvidenceManifest(
                version: 1,
                sessionID: sessionID,
                createdAt: Date(),
                mode: .dual,
                participantNames: [role.rawValue: "staging"],
                segments: [manifest],
                finalVideoSHA256: manifest.sha256,
                appVersion: "1.0",
                profileSnapshots: nil
            ),
            password: vaultPassword
        )
        let destination = AppFiles.stagingURL.appendingPathComponent(fileName)
        let metadataURL = AppFiles.stagingURL.appendingPathComponent("\(sessionID.uuidString).json")
        var committed = false
        var replacementStarted = false
        defer {
            if !committed {
                EvidenceCryptor.remove(package)
                if replacementStarted {
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.removeItem(at: metadataURL)
                }
            }
        }
        try AppFiles.removeItemIfExists(destination)
        replacementStarted = true
        try FileManager.default.moveItem(at: package, to: destination)
        try AppFiles.protect(url: destination)
        let record = StagingRecord(
            sessionID: sessionID,
            role: role,
            expiresAt: Date().addingTimeInterval(stagingTTL),
            manifest: manifest,
            fileName: fileName
        )
        try JSONEncoder().encode(record).write(to: metadataURL, options: .atomic)
        try AppFiles.protect(url: metadataURL)
        committed = true
    }

    static func loadStaging(
        sessionID: UUID,
        vaultPassword: String
    ) throws -> (url: URL, manifest: SegmentManifest)? {
        purgeExpiredStaging()
        let metaURL = AppFiles.stagingURL.appendingPathComponent("\(sessionID.uuidString).json")
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return nil }
        let record = try JSONDecoder().decode(StagingRecord.self, from: Data(contentsOf: metaURL))
        guard record.sessionID == sessionID,
              record.fileName == "\(sessionID.uuidString)-\(record.role.rawValue).xagree" else {
            try clearStaging(sessionID: sessionID)
            return nil
        }
        guard record.expiresAt > Date() else {
            try clearStaging(sessionID: sessionID)
            throw SessionFailure.stagingExpired
        }
        let packageURL = AppFiles.stagingURL.appendingPathComponent(record.fileName)
        let decrypted = try EvidenceCryptor.open(packageURL: packageURL, password: vaultPassword)
        guard decrypted.manifest.sessionID == sessionID,
              decrypted.manifest.mode == .dual,
              decrypted.manifest.segments == [record.manifest],
              decrypted.manifest.finalVideoSHA256 == record.manifest.sha256 else {
            EvidenceCryptor.remove(decrypted.videoURL)
            throw EvidenceCryptoError.tamperedPackage
        }
        return (decrypted.videoURL, decrypted.manifest.segments[0])
    }

    static func clearStaging(sessionID: UUID) throws {
        let metaURL = AppFiles.stagingURL.appendingPathComponent("\(sessionID.uuidString).json")
        var packageNames = [
            "\(sessionID.uuidString)-\(ParticipantRole.a.rawValue).xagree",
            "\(sessionID.uuidString)-\(ParticipantRole.b.rawValue).xagree"
        ]
        if let data = try? Data(contentsOf: metaURL),
           let record = try? JSONDecoder().decode(StagingRecord.self, from: data) {
            let fileName = URL(fileURLWithPath: record.fileName).lastPathComponent
            if fileName == record.fileName {
                packageNames.append(fileName)
            }
        }
        for fileName in Set(packageNames) {
            try AppFiles.removeItemIfExists(AppFiles.stagingURL.appendingPathComponent(fileName))
        }
        try AppFiles.removeItemIfExists(metaURL)
    }

    static func activeStagingSessionID() -> UUID? {
        purgeExpiredStaging()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppFiles.stagingURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "json" {
            if let record = try? JSONDecoder().decode(StagingRecord.self, from: Data(contentsOf: file)),
               record.expiresAt > Date() {
                return record.sessionID
            }
        }
        return nil
    }

    private static func purgeExpiredStaging() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppFiles.stagingURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "json" {
            guard let record = try? JSONDecoder().decode(StagingRecord.self, from: Data(contentsOf: file)) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if record.expiresAt <= Date() {
                try? clearStaging(sessionID: record.sessionID)
            }
        }
    }

    private static func writeIndex(_ drafts: [ExportDraft]) throws {
        try AppFiles.prepareDirectories()
        let data = try JSONEncoder().encode(drafts)
        try data.write(to: AppFiles.draftsIndexURL, options: .atomic)
        try AppFiles.protect(url: AppFiles.draftsIndexURL)
    }

    private static func readIndex() throws -> [ExportDraft] {
        guard FileManager.default.fileExists(atPath: AppFiles.draftsIndexURL.path) else { return [] }
        do {
            return try JSONDecoder().decode(
                [ExportDraft].self,
                from: Data(contentsOf: AppFiles.draftsIndexURL)
            )
        } catch {
            throw DraftStoreError.corruptIndex
        }
    }

    private static func saveRecoveryDraft(from packageURL: URL, mode: BackupMode) throws -> ExportDraft {
        try AppFiles.prepareDirectories()
        let id = UUID()
        let fileName = "recovered-\(id.uuidString).xagree"
        let draft = ExportDraft(
            id: id,
            fileName: fileName,
            createdAt: Date(),
            mode: mode,
            relativePath: fileName
        )
        let destination = draftURL(for: draft)
        let metadataURL = recoveryMetadataURL(for: draft)
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: metadataURL)
            }
        }
        try FileManager.default.copyItem(at: packageURL, to: destination)
        try AppFiles.protect(url: destination)
        try JSONEncoder().encode(draft).write(to: metadataURL, options: .atomic)
        try AppFiles.protect(url: metadataURL)
        committed = true
        return draft
    }

    private static func recoveryMetadataURL(for draft: ExportDraft) -> URL {
        draftURL(for: draft)
            .deletingPathExtension()
            .appendingPathExtension("draft.json")
    }

    private static func isUsableDraft(_ draft: ExportDraft) -> Bool {
        let fileName = URL(fileURLWithPath: draft.relativePath).lastPathComponent
        return fileName == draft.relativePath
            && URL(fileURLWithPath: fileName).pathExtension == "xagree"
            && FileManager.default.fileExists(atPath: draftURL(for: draft).path)
    }
}

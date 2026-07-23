import Foundation

/// 导出取消后保留的加密待导出包，以及双备份中断时的加密暂存。
@MainActor
enum DraftStore {
    private static let stagingTTL: TimeInterval = 10 * 60

    static func listDrafts() -> [ExportDraft] {
        guard let data = try? Data(contentsOf: AppFiles.draftsIndexURL),
              let drafts = try? JSONDecoder().decode([ExportDraft].self, from: data) else {
            return []
        }
        return drafts.filter {
            let fileName = URL(fileURLWithPath: $0.relativePath).lastPathComponent
            return fileName == $0.relativePath
                && URL(fileURLWithPath: fileName).pathExtension == "xagree"
                && FileManager.default.fileExists(atPath: draftURL(for: $0).path)
        }
    }

    static func saveExportDraft(from packageURL: URL, mode: BackupMode) throws -> ExportDraft {
        try AppFiles.prepareDirectories()
        let id = UUID()
        let fileName = "pending-\(id.uuidString.prefix(8)).xagree"
        let destination = AppFiles.draftsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
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
        var drafts = listDrafts()
        drafts.insert(draft, at: 0)
        try writeIndex(drafts)
        return draft
    }

    static func deleteDraft(_ draft: ExportDraft) throws {
        try AppFiles.removeItemIfExists(draftURL(for: draft))
        try writeIndex(listDrafts().filter { $0.id != draft.id })
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
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: package, to: destination)
        try AppFiles.protect(url: destination)
        let record = StagingRecord(
            sessionID: sessionID,
            role: role,
            expiresAt: Date().addingTimeInterval(stagingTTL),
            manifest: manifest,
            fileName: fileName
        )
        let metadataURL = AppFiles.stagingURL.appendingPathComponent("\(sessionID.uuidString).json")
        try JSONEncoder().encode(record).write(to: metadataURL, options: .atomic)
        try AppFiles.protect(url: metadataURL)
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
        return (decrypted.videoURL, record.manifest)
    }

    static func clearStaging(sessionID: UUID) throws {
        let metaURL = AppFiles.stagingURL.appendingPathComponent("\(sessionID.uuidString).json")
        if let data = try? Data(contentsOf: metaURL),
           let record = try? JSONDecoder().decode(StagingRecord.self, from: data) {
            let fileName = URL(fileURLWithPath: record.fileName).lastPathComponent
            if fileName == record.fileName {
                try AppFiles.removeItemIfExists(AppFiles.stagingURL.appendingPathComponent(fileName))
            }
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
}

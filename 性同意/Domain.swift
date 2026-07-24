import Foundation
import ImageIO

nonisolated enum SafeJSONDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard String(data: data, encoding: .utf8) != nil else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON is not valid UTF-8.")
            )
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

nonisolated enum ConsentStatement {
    // Product-approved fixed wording. Only the two participant names may be substituted.
    static let format = "我叫 %@，我已经成年，我同意并自愿与 %@ 发生性关系，我意识清醒，没有受到任何形式的胁迫。"

    static func text(participantName: String, otherParticipantName: String) -> String {
        L10n.format(format, participantName, otherParticipantName)
    }
}

nonisolated enum PasswordPolicy {
    enum ValidationIssue: Equatable {
        case tooShort
        case invalidCharacters
    }

    static let minimumLength = 8

    static func validationIssue(for password: String) -> ValidationIssue? {
        guard password.count >= minimumLength else { return .tooShort }
        guard password.unicodeScalars.allSatisfy({ $0.isASCIIAlphanumeric }) else {
            return .invalidCharacters
        }
        return nil
    }

    static func isValid(_ password: String) -> Bool {
        validationIssue(for: password) == nil
    }
}

private nonisolated extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool {
        switch value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}

nonisolated struct ParticipantProfile: Codable, Equatable, Sendable {
    var name: String
    var avatarData: Data?

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum AvatarImageValidator {
    static func isSafeStoredAvatar(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= 1_048_576,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }
        let pixelWidth = width.intValue
        let pixelHeight = height.intValue
        return pixelWidth > 0
            && pixelHeight > 0
            && pixelWidth <= 512
            && pixelHeight <= 512
            && pixelWidth * pixelHeight <= 262_144
    }
}

nonisolated enum BackupMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case single
    case dual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: L10n.string("同机保存")
        case .dual: L10n.string("双机保存（推荐）")
        }
    }

    var summary: String {
        switch self {
        case .single: L10n.string("在一台手机上轮流完成两段记录。")
        case .dual: L10n.string("两台手机直接连接，各自录制、各自保存。")
        }
    }
}

nonisolated enum ParticipantRole: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"

    var next: ParticipantRole? {
        self == .a ? .b : nil
    }

    var label: String { L10n.format("参与者 %@", rawValue) }
}

/// 会话阶段仅允许合法迁移；非法迁移由协调器拒绝。
nonisolated enum SessionPhase: String, Codable, Sendable, Equatable {
    case draft
    case paired
    case armed
    case recording
    case transferring
    case assembling
    case encrypting
    case awaitingExport
    case completed
    case failed

    func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        case (.draft, .paired), (.draft, .armed), (.draft, .failed):
            true
        case (.paired, .armed), (.paired, .failed):
            true
        case (.armed, .recording), (.armed, .failed):
            true
        // 单备份第二段仍在 recording；双备份录完后进入传输
        case (.recording, .recording), (.recording, .transferring), (.recording, .assembling), (.recording, .failed):
            true
        case (.transferring, .assembling), (.transferring, .failed):
            true
        case (.assembling, .encrypting), (.assembling, .failed):
            true
        // 合成失败后回到 transferring 以便重试；加密失败回到 assembling
        case (.assembling, .transferring):
            true
        case (.encrypting, .awaitingExport), (.encrypting, .assembling), (.encrypting, .failed):
            true
        case (.awaitingExport, .completed), (.awaitingExport, .failed), (.awaitingExport, .encrypting):
            true
        case (_, .failed), (.failed, .draft), (.failed, .transferring), (.completed, .draft):
            true
        default:
            false
        }
    }
}

nonisolated struct RecordingWatermark: Codable, Sendable, Equatable {
    let sessionID: UUID
    let role: ParticipantRole
    let recordedAt: Date
    let status: String

    init(sessionID: UUID, role: ParticipantRole, recordedAt: Date = Date(), status: String = "REC") {
        self.sessionID = sessionID
        self.role = role
        self.recordedAt = recordedAt
        self.status = status
    }

    nonisolated var displayText: String {
        displayText(at: recordedAt)
    }

    nonisolated func displayText(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let shortID = String(sessionID.uuidString.prefix(8))
        return "\(formatter.string(from: date))  ·  \(role.rawValue)\n\(shortID)  ·  \(status)"
    }
}

nonisolated struct SegmentManifest: Codable, Sendable, Equatable {
    let role: ParticipantRole
    let duration: TimeInterval
    let sha256: String
    let watermark: RecordingWatermark
}

nonisolated struct EvidenceManifest: Codable, Sendable {
    let version: Int
    let sessionID: UUID
    let createdAt: Date
    let mode: BackupMode
    let participantNames: [String: String]
    let segments: [SegmentManifest]
    let finalVideoSHA256: String
    let appVersion: String
    /// 资料快照：姓名 + 头像哈希，不验证真实身份。
    let profileSnapshots: [String: ParticipantProfileSnapshot]?
}

nonisolated struct ParticipantProfileSnapshot: Codable, Sendable, Equatable {
    let name: String
    let avatarSHA256: String?
}

nonisolated struct CaptureArtifact: Sendable {
    let url: URL
    let duration: TimeInterval
    let sha256: String
    let watermark: RecordingWatermark
}

nonisolated enum PasswordProtection: Sendable {
    case vaultPassword(String)
    case oneTimePassword(String)

    var password: String {
        switch self {
        case .vaultPassword(let value), .oneTimePassword(let value):
            value
        }
    }
}

nonisolated struct ExportDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    let mode: BackupMode
    let relativePath: String
}

nonisolated enum SessionFailure: LocalizedError {
    case missingParticipantName
    case invalidParticipantName
    case missingRecording
    case incompatibleVideo
    case illegalTransition(from: SessionPhase, to: SessionPhase)
    case hashMismatch
    case stagingExpired

    var errorDescription: String? {
        switch self {
        case .missingParticipantName: L10n.string("请填写两位参与者的姓名。")
        case .invalidParticipantName: L10n.string("姓名或头像数据无效。")
        case .missingRecording: L10n.string("未找到完成的录制文件。")
        case .incompatibleVideo: L10n.string("视频文件无法合成。")
        case .illegalTransition(let from, let to):
            L10n.format("非法会话迁移：%@ → %@。", from.rawValue, to.rawValue)
        case .hashMismatch: L10n.string("对方片段哈希校验失败，请重新录制。")
        case .stagingExpired: L10n.string("暂存已超过 10 分钟，请重新录制。")
        }
    }
}

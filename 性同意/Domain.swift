import Foundation

enum PasswordPolicy {
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

private extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool {
        switch value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}

struct ParticipantProfile: Codable, Equatable, Sendable {
    var name: String
    var avatarData: Data?

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum BackupMode: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum ParticipantRole: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"

    var next: ParticipantRole? {
        self == .a ? .b : nil
    }

    var label: String { L10n.format("参与者 %@", rawValue) }
}

/// 会话阶段仅允许合法迁移；非法迁移由协调器拒绝。
enum SessionPhase: String, Codable, Sendable, Equatable {
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

struct RecordingWatermark: Codable, Sendable, Equatable {
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

struct SegmentManifest: Codable, Sendable, Equatable {
    let role: ParticipantRole
    let duration: TimeInterval
    let sha256: String
    let watermark: RecordingWatermark
}

struct EvidenceManifest: Codable, Sendable {
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

struct ParticipantProfileSnapshot: Codable, Sendable, Equatable {
    let name: String
    let avatarSHA256: String?
}

struct CaptureArtifact: Sendable {
    let url: URL
    let duration: TimeInterval
    let sha256: String
    let watermark: RecordingWatermark
}

enum PasswordProtection: Sendable {
    case vaultPassword(String)
    case oneTimePassword(String)

    var password: String {
        switch self {
        case .vaultPassword(let value), .oneTimePassword(let value):
            value
        }
    }
}

struct ExportDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    let mode: BackupMode
    let relativePath: String
}

enum SessionFailure: LocalizedError {
    case missingParticipantName
    case missingRecording
    case incompatibleVideo
    case illegalTransition(from: SessionPhase, to: SessionPhase)
    case hashMismatch
    case stagingExpired

    var errorDescription: String? {
        switch self {
        case .missingParticipantName: L10n.string("请填写两位参与者的姓名。")
        case .missingRecording: L10n.string("未找到完成的录制文件。")
        case .incompatibleVideo: L10n.string("视频文件无法合成。")
        case .illegalTransition(let from, let to):
            L10n.format("非法会话迁移：%@ → %@。", from.rawValue, to.rawValue)
        case .hashMismatch: L10n.string("对方片段哈希校验失败，请重新录制。")
        case .stagingExpired: L10n.string("暂存已超过 10 分钟，请重新录制。")
        }
    }
}

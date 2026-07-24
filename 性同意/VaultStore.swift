import CommonCrypto
import CryptoKit
import Foundation

nonisolated enum VaultError: LocalizedError {
    case invalidPassword
    case passwordTooShort
    case passwordContainsInvalidCharacters
    case hintTooLong
    case invalidProfile
    case missingVault
    case corruptVault
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPassword: L10n.string("密码不正确。")
        case .passwordTooShort: L10n.string("密码至少需要 8 位。")
        case .passwordContainsInvalidCharacters: L10n.string("密码只能包含数字或英文字母。")
        case .hintTooLong: L10n.string("提示词最多 60 个字。")
        case .invalidProfile: L10n.string("姓名或头像数据无效。")
        case .missingVault: L10n.string("本机没有可打开的私密空间。")
        case .corruptVault: L10n.string("本机私密空间数据损坏或已被修改。")
        case .keyDerivationFailed: L10n.string("无法安全派生加密密钥。")
        }
    }
}

private struct VaultFile: Codable {
    let version: Int
    let salt: Data
    let rounds: UInt32
    let verifier: Data
    let passwordHint: String?
    var encryptedProfile: Data?
    var preferredBackupMode: BackupMode?
}

@MainActor
final class VaultStore {
    private let verifierText = Data("xagree-vault-verifier-v1".utf8)
    private let maxHintLength = 60

    var hasVault: Bool {
        FileManager.default.fileExists(atPath: AppFiles.vaultURL.path)
    }

    var passwordHint: String? {
        guard let file = try? readVault() else { return nil }
        return file.passwordHint
    }

    var preferredBackupMode: BackupMode {
        (try? readVault())?.preferredBackupMode ?? .dual
    }

    func create(password: String, hint: String?) throws {
        switch PasswordPolicy.validationIssue(for: password) {
        case .tooShort:
            throw VaultError.passwordTooShort
        case .invalidCharacters:
            throw VaultError.passwordContainsInvalidCharacters
        case nil:
            break
        }
        let normalizedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let normalizedHint, normalizedHint.count > maxHintLength {
            throw VaultError.hintTooLong
        }
        let salt = try randomData(count: 32)
        let rounds: UInt32 = 210_000
        let key = try PasswordKeyDeriver.derive(password: password, salt: salt, rounds: rounds)
        guard let verifier = try AES.GCM.seal(verifierText, using: key).combined else {
            throw VaultError.keyDerivationFailed
        }

        let file = VaultFile(
            version: 1,
            salt: salt,
            rounds: rounds,
            verifier: verifier,
            passwordHint: normalizedHint,
            encryptedProfile: nil,
            preferredBackupMode: .dual
        )
        try writeVault(file)
    }

    func unlock(password: String) throws -> ParticipantProfile? {
        let file = try readVault()
        let key = try PasswordKeyDeriver.derive(password: password, salt: file.salt, rounds: file.rounds)
        do {
            let verifier = try AES.GCM.SealedBox(combined: file.verifier)
            guard try AES.GCM.open(verifier, using: key) == verifierText else {
                throw VaultError.invalidPassword
            }
        } catch {
            throw VaultError.invalidPassword
        }

        guard let encryptedProfile = file.encryptedProfile else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: encryptedProfile)
            let data = try AES.GCM.open(box, using: key)
            let profile = try SafeJSONDecoder.decode(ParticipantProfile.self, from: data)
            guard !profile.trimmedName.isEmpty,
                  profile.trimmedName.count <= 80,
                  profile.avatarData.map(AvatarImageValidator.isSafeStoredAvatar) ?? true else {
                throw VaultError.corruptVault
            }
            return profile
        } catch {
            throw VaultError.corruptVault
        }
    }

    func saveProfile(_ profile: ParticipantProfile, password: String) throws {
        _ = try unlock(password: password)
        var file = try readVault()
        let key = try PasswordKeyDeriver.derive(password: password, salt: file.salt, rounds: file.rounds)
        let data = try JSONEncoder().encode(profile)
        guard let encryptedProfile = try AES.GCM.seal(data, using: key).combined else {
            throw VaultError.keyDerivationFailed
        }
        file.encryptedProfile = encryptedProfile
        try writeVault(file)
    }

    func savePreferredBackupMode(_ mode: BackupMode, password: String) throws {
        _ = try unlock(password: password)
        var file = try readVault()
        file.preferredBackupMode = mode
        try writeVault(file)
    }

    /// 仅清除本机配置；无法删除已导出到 iCloud 的文件。
    func resetLocalVault() throws {
        try AppFiles.removeItemIfExists(AppFiles.vaultURL)
        try AppFiles.clearDirectory(AppFiles.workURL)
        try AppFiles.clearDirectory(AppFiles.draftsURL)
        try AppFiles.clearDirectory(AppFiles.stagingURL)
        try AppFiles.removeItemIfExists(AppFiles.draftsIndexURL)
    }

    private func readVault() throws -> VaultFile {
        guard hasVault else { throw VaultError.missingVault }
        do {
            let size = try AppFiles.vaultURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 2 * 1_024 * 1_024 else {
                throw VaultError.corruptVault
            }
            let file = try SafeJSONDecoder.decode(
                VaultFile.self,
                from: Data(contentsOf: AppFiles.vaultURL)
            )
            guard file.version == 1,
                  file.salt.count == 32,
                  (10_000...2_000_000).contains(file.rounds),
                  !file.verifier.isEmpty,
                  file.verifier.count <= 128 else {
                throw VaultError.corruptVault
            }
            return file
        } catch {
            throw VaultError.corruptVault
        }
    }

    private func writeVault(_ file: VaultFile) throws {
        try AppFiles.prepareDirectories()
        let data = try JSONEncoder().encode(file)
        try data.write(to: AppFiles.vaultURL, options: .atomic)
        try AppFiles.protect(url: AppFiles.vaultURL)
    }
}

nonisolated enum PasswordKeyDeriver {
    static func derive(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordLength = password.lengthOfBytes(using: .utf8)
        let status: Int32 = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer,
                    passwordLength,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    rounds,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw VaultError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}

nonisolated enum AppFiles {
    static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("XAgree", isDirectory: true)
    }

    static var vaultURL: URL {
        rootURL.appendingPathComponent("vault.json")
    }

    static var workURL: URL {
        rootURL.appendingPathComponent("Work", isDirectory: true)
    }

    static var draftsURL: URL {
        rootURL.appendingPathComponent("Drafts", isDirectory: true)
    }

    static var stagingURL: URL {
        rootURL.appendingPathComponent("Staging", isDirectory: true)
    }

    static var draftsIndexURL: URL {
        rootURL.appendingPathComponent("drafts-index.json")
    }

    static func prepareDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: workURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: draftsURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try protect(url: rootURL)
        try protect(url: workURL)
        try protect(url: draftsURL)
        try protect(url: stagingURL)
    }

    static func temporaryURL(extension fileExtension: String) throws -> URL {
        try prepareDirectories()
        return workURL.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    static func exportPackageBaseName(
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d_%02d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    static func exportPackageFileName(
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        exportPackageBaseName(at: date, timeZone: timeZone) + ".xagree"
    }

    static func exportPackageURL(
        in directory: URL? = nil,
        at date: Date = Date()
    ) throws -> URL {
        try prepareDirectories()
        let destinationDirectory = directory ?? workURL
        let manager = FileManager.default
        let defaultName = exportPackageFileName(at: date)
        let stem = URL(fileURLWithPath: defaultName).deletingPathExtension().lastPathComponent
        let fileExtension = URL(fileURLWithPath: defaultName).pathExtension
        var candidate = destinationDirectory.appendingPathComponent(defaultName)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = destinationDirectory
                .appendingPathComponent("\(stem)-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    /// Work 只保存可重建的明文临时文件。每次冷启动都应清空，避免崩溃或强退后残留。
    static func purgeTemporaryWorkFiles() throws {
        try clearDirectory(workURL)
    }

    static func protect(url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try protectedURL.setResourceValues(values)
    }

    static func removeItemIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func clearDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
        for item in contents {
            try FileManager.default.removeItem(at: item)
        }
    }
}

nonisolated enum SecurityRandomError: LocalizedError {
    case generationFailed

    var errorDescription: String? {
        L10n.string("无法生成安全随机数据。")
    }
}

nonisolated func randomData(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw SecurityRandomError.generationFailed
    }
    return Data(bytes)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

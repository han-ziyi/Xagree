import CryptoKit
import Foundation

enum EvidenceCryptoError: LocalizedError {
    case invalidPackage
    case unsupportedVersion
    case incorrectPassword
    case tamperedPackage
    case missingVideo

    var errorDescription: String? {
        switch self {
        case .invalidPackage: L10n.string("这不是有效的私密记录文件。")
        case .unsupportedVersion: L10n.string("该加密文件版本暂不受支持。")
        case .incorrectPassword: L10n.string("密码不正确。")
        case .tamperedPackage: L10n.string("文件校验失败，可能已损坏或被修改。")
        case .missingVideo: L10n.string("找不到要加密的视频。")
        }
    }
}

struct DecryptedEvidence {
    let manifest: EvidenceManifest
    let videoURL: URL
}

/// 明文头仅含容器元数据；清单与视频密文均经认证加密。
private struct EvidencePackageHeader: Codable {
    let magic: String
    let version: Int
    let salt: Data
    let rounds: UInt32
    let chunkSize: Int
    let chunkCount: UInt64
    let sourceSize: UInt64
    let noncePrefix: Data
    let wrappedContentKey: Data
    let encryptedManifest: Data
}

enum EvidenceCryptor {
    private static let magic = "XAGR"
    private static let version = 1
    private static let chunkSize = 1_048_576
    private static let rounds: UInt32 = 210_000
    private static let minimumRounds: UInt32 = 10_000
    private static let maximumRounds: UInt32 = 2_000_000
    private static let maximumSourceSize: UInt64 = 512 * 1_024 * 1_024

    static func seal(videoURL: URL, manifest: EvidenceManifest, password: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw EvidenceCryptoError.missingVideo
        }

        let sourceSize = try fileSize(of: videoURL)
        guard sourceSize <= maximumSourceSize else { throw EvidenceCryptoError.invalidPackage }
        let sourceHash = try FileHasher.sha256Hex(of: videoURL)
        guard sourceHash.caseInsensitiveCompare(manifest.finalVideoSHA256) == .orderedSame else {
            throw EvidenceCryptoError.tamperedPackage
        }
        let salt = try randomData(count: 32)
        let noncePrefix = try randomData(count: 8)
        let passwordKey = try PasswordKeyDeriver.derive(password: password, salt: salt, rounds: rounds)
        let contentKey = SymmetricKey(data: try randomData(count: 32))
        let aad = headerAAD(salt: salt, rounds: rounds, sourceSize: sourceSize, noncePrefix: noncePrefix)
        guard let wrappedContentKey = try AES.GCM.seal(
            contentKey.withUnsafeBytes { Data($0) },
            using: passwordKey,
            authenticating: aad
        ).combined else {
            throw EvidenceCryptoError.invalidPackage
        }
        let manifestData = try JSONEncoder().encode(manifest)
        guard let encryptedManifest = try AES.GCM.seal(
            manifestData,
            using: contentKey,
            authenticating: aad
        ).combined else {
            throw EvidenceCryptoError.invalidPackage
        }

        let outputURL = try AppFiles.temporaryURL(extension: "xagree")
        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput { try? FileManager.default.removeItem(at: outputURL) }
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: videoURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? input.close()
            try? output.close()
        }

        // 文件大小已知，头部可以直接写入，避免把整段视频密文攒在内存里。
        let expectedChunkCount = sourceSize == 0 ? 0 : (sourceSize + UInt64(chunkSize) - 1) / UInt64(chunkSize)
        let header = EvidencePackageHeader(
            magic: magic,
            version: version,
            salt: salt,
            rounds: rounds,
            chunkSize: chunkSize,
            chunkCount: expectedChunkCount,
            sourceSize: sourceSize,
            noncePrefix: noncePrefix,
            wrappedContentKey: wrappedContentKey,
            encryptedManifest: encryptedManifest
        )
        let headerData = try JSONEncoder().encode(header)
        guard headerData.count <= Int(UInt32.max) else { throw EvidenceCryptoError.invalidPackage }
        try output.write(contentsOf: UInt32(headerData.count).bigEndianData)
        try output.write(contentsOf: headerData)

        var index: UInt64 = 0
        while true {
            let plaintext = try input.read(upToCount: chunkSize) ?? Data()
            guard !plaintext.isEmpty else { break }
            let chunkNonce = makeNonce(prefix: noncePrefix, index: index)
            let chunkAAD = aad + index.bigEndianData
            let sealed = try AES.GCM.seal(
                plaintext,
                using: contentKey,
                nonce: AES.GCM.Nonce(data: chunkNonce),
                authenticating: chunkAAD
            )
            guard let combined = sealed.combined else { throw EvidenceCryptoError.invalidPackage }
            guard combined.count <= Int(UInt32.max) else { throw EvidenceCryptoError.invalidPackage }
            try output.write(contentsOf: UInt32(combined.count).bigEndianData)
            try output.write(contentsOf: combined)
            index += 1
        }
        guard index == expectedChunkCount else { throw EvidenceCryptoError.invalidPackage }

        try protect(url: outputURL)
        shouldRemoveOutput = false
        return outputURL
    }

    static func open(packageURL: URL, password: String) throws -> DecryptedEvidence {
        let input = try FileHandle(forReadingFrom: packageURL)
        defer { try? input.close() }

        let headerLength = try readUInt32(from: input)
        guard headerLength > 0, headerLength < 1_000_000 else { throw EvidenceCryptoError.invalidPackage }
        let headerData = try readExactly(from: input, count: Int(headerLength))
        let header: EvidencePackageHeader
        do {
            header = try JSONDecoder().decode(EvidencePackageHeader.self, from: headerData)
        } catch {
            throw EvidenceCryptoError.invalidPackage
        }
        guard header.magic == magic else { throw EvidenceCryptoError.invalidPackage }
        guard header.version == version else { throw EvidenceCryptoError.unsupportedVersion }
        guard header.salt.count == 32,
              (minimumRounds...maximumRounds).contains(header.rounds),
              header.chunkSize == chunkSize,
              header.sourceSize <= maximumSourceSize,
              header.wrappedContentKey.count == 60,
              header.encryptedManifest.count > 28,
              header.encryptedManifest.count <= 1_000_000,
              header.chunkCount == (header.sourceSize == 0 ? 0 : (header.sourceSize + UInt64(chunkSize) - 1) / UInt64(chunkSize)) else {
            throw EvidenceCryptoError.invalidPackage
        }
        guard header.noncePrefix.count == 8 else { throw EvidenceCryptoError.invalidPackage }

        let passwordKey = try PasswordKeyDeriver.derive(password: password, salt: header.salt, rounds: header.rounds)
        let aad = headerAAD(
            salt: header.salt,
            rounds: header.rounds,
            sourceSize: header.sourceSize,
            noncePrefix: header.noncePrefix
        )
        let contentKey: SymmetricKey
        do {
            let wrapped = try AES.GCM.SealedBox(combined: header.wrappedContentKey)
            contentKey = SymmetricKey(data: try AES.GCM.open(wrapped, using: passwordKey, authenticating: aad))
        } catch {
            throw EvidenceCryptoError.incorrectPassword
        }

        let manifest: EvidenceManifest
        do {
            let encryptedManifest = try AES.GCM.SealedBox(combined: header.encryptedManifest)
            manifest = try JSONDecoder().decode(
                EvidenceManifest.self,
                from: AES.GCM.open(encryptedManifest, using: contentKey, authenticating: aad)
            )
        } catch {
            throw EvidenceCryptoError.tamperedPackage
        }
        guard manifest.version == version,
              manifest.finalVideoSHA256.count == 64,
              manifest.finalVideoSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw EvidenceCryptoError.tamperedPackage
        }

        let outputURL = try AppFiles.temporaryURL(extension: "mp4")
        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput { try? FileManager.default.removeItem(at: outputURL) }
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var index: UInt64 = 0
        var written: UInt64 = 0
        var usedNonces = Set<Data>()
        do {
            while written < header.sourceSize {
                if header.chunkCount > 0, index >= header.chunkCount {
                    throw EvidenceCryptoError.tamperedPackage
                }
                let encryptedLength = try readUInt32(from: input)
                guard encryptedLength > 16, encryptedLength <= UInt32(header.chunkSize + 64) else {
                    throw EvidenceCryptoError.tamperedPackage
                }
                let encrypted = try readExactly(from: input, count: Int(encryptedLength))
                let box = try AES.GCM.SealedBox(combined: encrypted)
                let nonceData = Data(box.nonce)
                guard usedNonces.insert(nonceData).inserted else {
                    throw EvidenceCryptoError.tamperedPackage
                }
                let plaintext = try AES.GCM.open(
                    box,
                    using: contentKey,
                    authenticating: aad + index.bigEndianData
                )
                written += UInt64(plaintext.count)
                guard written <= header.sourceSize else { throw EvidenceCryptoError.tamperedPackage }
                try output.write(contentsOf: plaintext)
                index += 1
            }
            if header.chunkCount > 0, index != header.chunkCount {
                throw EvidenceCryptoError.tamperedPackage
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
                throw EvidenceCryptoError.tamperedPackage
            }
        } catch let error as EvidenceCryptoError {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw EvidenceCryptoError.tamperedPackage
        }

        try output.close()
        guard try FileHasher.sha256Hex(of: outputURL) == manifest.finalVideoSHA256 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw EvidenceCryptoError.tamperedPackage
        }
        try protect(url: outputURL)
        shouldRemoveOutput = false
        return DecryptedEvidence(manifest: manifest, videoURL: outputURL)
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func makeNonce(prefix: Data, index: UInt64) -> Data {
        // AES-GCM nonce 固定 12 字节：8 字节随机前缀 + 4 字节块序号
        var nonce = Data(prefix.prefix(8))
        while nonce.count < 8 { nonce.append(0) }
        var idx = UInt32(truncatingIfNeeded: index).bigEndian
        nonce.append(Data(bytes: &idx, count: 4))
        return nonce
    }

    private static func headerAAD(salt: Data, rounds: UInt32, sourceSize: UInt64, noncePrefix: Data) -> Data {
        Data("\(magic)|\(version)|\(salt.base64EncodedString())|\(rounds)|\(sourceSize)|\(noncePrefix.base64EncodedString())".utf8)
    }

    private static func readUInt32(from handle: FileHandle) throws -> UInt32 {
        let data = try readExactly(from: handle, count: 4)
        return data.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }

    private static func readExactly(from handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
                throw EvidenceCryptoError.tamperedPackage
            }
            result.append(part)
        }
        return result
    }

    private static func fileSize(of url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw EvidenceCryptoError.missingVideo }
        return UInt64(size)
    }

    private static func protect(url: URL) throws {
        try AppFiles.protect(url: url)
    }
}

private extension FixedWidthInteger {
    var bigEndianData: Data {
        var value = bigEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}

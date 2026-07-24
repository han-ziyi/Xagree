@preconcurrency import MultipeerConnectivity
import Combine
import CryptoKit
import Foundation

nonisolated enum PeerPairingError: LocalizedError, Equatable {
    case invalidInvitation
    case invalidPeerMessage
    case keyAgreementFailed
    case localNetworkUnavailable
    case invalidState
    case recoverySessionMismatch

    var errorDescription: String? {
        switch self {
        case .invalidInvitation: L10n.string("二维码无效或不属于此版本的应用。")
        case .invalidPeerMessage: L10n.string("附近设备发送了无效的配对信息。")
        case .keyAgreementFailed: L10n.string("无法建立安全的双机密钥。")
        case .localNetworkUnavailable: L10n.string("无法使用本地网络。请允许本地网络权限并保持两台设备靠近。")
        case .invalidState: L10n.string("当前配对状态不允许此操作。")
        case .recoverySessionMismatch: L10n.string("该二维码不属于当前暂存会话。请使用原配对中的另一台设备。")
        }
    }
}

struct PairingInvitation: Codable, Sendable {
    let version: Int
    let sessionID: UUID
    let hostPeerID: String
    let hostPublicKey: Data

    func encodedString() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    static func decode(_ code: String) throws -> PairingInvitation {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 4096,
              let data = Data(base64Encoded: normalized) else {
            throw PeerPairingError.invalidInvitation
        }
        let invitation = try SafeJSONDecoder.decode(PairingInvitation.self, from: data)
        guard invitation.version == 1,
              invitation.hostPeerID.count <= 128,
              !invitation.hostPeerID.isEmpty,
              invitation.hostPublicKey.count == 32 else {
            throw PeerPairingError.invalidInvitation
        }
        return invitation
    }
}

struct PairedProfile: Codable, Equatable {
    let name: String
    let avatarData: Data?
    let avatarHash: String?
}

enum PeerProtocolLimits {
    static let maximumWireMessageSize = 3 * 1_024 * 1_024
    static let maximumWirePayloadSize = 2 * 1_024 * 1_024
    static let maximumPlaintextPayloadSize = 1_500_000

    static func isValidProfile(_ profile: PairedProfile) -> Bool {
        let normalizedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName == profile.name,
              normalizedName.count <= 80,
              profile.avatarData?.count ?? 0 <= 1_048_576 else {
            return false
        }
        switch (profile.avatarData, profile.avatarHash) {
        case (nil, nil):
            return true
        case let (data?, hash?):
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return AvatarImageValidator.isSafeStoredAvatar(data)
                && hash.count == 64
                && hash.caseInsensitiveCompare(actual) == .orderedSame
        default:
            return false
        }
    }
}

private struct PeerWireMessage: Codable {
    let kind: String
    let payload: Data
}

private struct PairHello: Codable {
    let sessionID: UUID
    let publicKey: Data
}

private struct PairConfirmation: Codable {
    let sessionID: UUID
}

struct RecordingReceipt: Codable, Equatable {
    let sessionID: UUID
    let role: ParticipantRole
    let sha256: String

    func matches(sessionID: UUID, localRole: ParticipantRole, localManifest: SegmentManifest?) -> Bool {
        guard let localManifest else { return false }
        return self.sessionID == sessionID
            && role == localRole
            && sha256.caseInsensitiveCompare(localManifest.sha256) == .orderedSame
    }
}

@MainActor
final class PeerSessionCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case hosting
        case searching
        case connecting
        case awaitingConfirmation
        case paired
        case failed(String)

        var title: String {
            switch self {
            case .idle: L10n.string("尚未开始")
            case .hosting: L10n.string("正在等待对方扫码")
            case .searching: L10n.string("正在寻找附近设备")
            case .connecting: L10n.string("正在建立加密连接")
            case .awaitingConfirmation: L10n.string("请双方确认资料与验证码")
            case .paired: L10n.string("安全配对已建立")
            case .failed: L10n.string("配对失败")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var invitationCode: String?
    @Published private(set) var remoteProfile: PairedProfile?
    @Published private(set) var verificationCode: String?
    @Published private(set) var localConfirmed = false
    @Published private(set) var remoteConfirmed = false
    @Published private(set) var localRole: ParticipantRole?
    @Published private(set) var receivedRecordingURL: URL?
    @Published private(set) var remoteSegmentManifest: SegmentManifest?
    @Published private(set) var remoteAcknowledgedLocalRecording = false

    private let profile: ParticipantProfile
    private let serviceType = "xagree-v1"
    private var localPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var sessionID: UUID?
    private var joinedInvitation: PairingInvitation?
    private var expectedRemotePeerID: MCPeerID?
    private var sentSegmentManifest: SegmentManifest?
    private var acknowledgedRemoteSegmentSHA256: String?

    init(profile: ParticipantProfile) {
        self.profile = profile
        super.init()
    }

    var currentSessionID: UUID? { sessionID }

    func host(sessionID recoverySessionID: UUID? = nil) throws {
        stop()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let id = recoverySessionID ?? UUID()
        let peer = makePeerID()
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let invitation = PairingInvitation(
            version: 1,
            sessionID: id,
            hostPeerID: peer.displayName,
            hostPublicKey: key.publicKey.rawRepresentation
        )
        let advertiser = MCNearbyServiceAdvertiser(
            peer: peer,
            discoveryInfo: ["session": id.uuidString],
            serviceType: serviceType
        )
        advertiser.delegate = self
        self.privateKey = key
        self.sessionID = id
        self.localRole = .a
        self.localPeerID = peer
        self.session = session
        self.advertiser = advertiser
        invitationCode = try invitation.encodedString()
        state = .hosting
        advertiser.startAdvertisingPeer()
    }

    func join(invitationCode: String, expectedSessionID: UUID? = nil) throws {
        let invitation = try PairingInvitation.decode(invitationCode)
        if let expectedSessionID, invitation.sessionID != expectedSessionID {
            throw PeerPairingError.recoverySessionMismatch
        }
        stop()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let hostKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: invitation.hostPublicKey)
        let sharedSecret = try key.sharedSecretFromKeyAgreement(with: hostKey)
        let derivedKey = deriveSessionKey(sharedSecret: sharedSecret, sessionID: invitation.sessionID)
        let peer = makePeerID()
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: serviceType)
        browser.delegate = self
        self.privateKey = key
        self.sessionKey = derivedKey
        self.sessionID = invitation.sessionID
        self.localRole = .b
        self.localPeerID = peer
        self.session = session
        self.browser = browser
        self.joinedInvitation = invitation
        state = .searching
        browser.startBrowsingForPeers()
    }

    func confirm() throws {
        guard state == .awaitingConfirmation, let sessionID else { throw PeerPairingError.invalidState }
        localConfirmed = true
        try sendEncrypted(PairConfirmation(sessionID: sessionID), kind: "confirm")
        updateConfirmedState()
    }

    func sendRecording(_ recordingURL: URL, manifest: SegmentManifest) async throws {
        guard state == .paired,
              manifest.role == localRole,
              manifest.duration > 0,
              manifest.duration <= 30.5,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy(\.isHexDigit) else {
            throw PeerPairingError.invalidState
        }
        guard let sessionKey, let session, let sessionID else {
            throw PeerPairingError.keyAgreementFailed
        }
        guard let peer = expectedRemotePeerID,
              session.connectedPeers.contains(peer) else {
            throw PeerPairingError.localNetworkUnavailable
        }
        guard FileManager.default.fileExists(atPath: recordingURL.path) else {
            throw PeerPairingError.invalidPeerMessage
        }
        sentSegmentManifest = manifest
        remoteAcknowledgedLocalRecording = false
        try sendEncrypted(manifest, kind: "segment")
        let authenticatedData = Data(sessionID.uuidString.utf8)
        let transferURL = try await Task.detached(priority: .userInitiated) {
            try PeerFileCryptor.seal(
                inputURL: recordingURL,
                key: sessionKey,
                authenticatedData: authenticatedData
            )
        }.value
        guard state == .paired,
              self.session === session,
              self.sessionID == sessionID,
              expectedRemotePeerID == peer,
              session.connectedPeers.contains(peer) else {
            EvidenceCryptor.remove(transferURL)
            throw PeerPairingError.invalidState
        }
        let completionHandler: @Sendable (Error?) -> Void = { [weak self] error in
            try? FileManager.default.removeItem(at: transferURL)
            if let error {
                Task { @MainActor [weak self] in
                    self?.state = .failed(L10n.format("视频传输失败：%@", error.localizedDescription))
                }
            }
        }
        let progress = session.sendResource(
            at: transferURL,
            withName: "xagree-recording",
            toPeer: peer,
            withCompletionHandler: completionHandler
        )
        guard progress != nil else {
            try? FileManager.default.removeItem(at: transferURL)
            throw PeerPairingError.localNetworkUnavailable
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        localPeerID = nil
        privateKey = nil
        sessionKey = nil
        sessionID = nil
        joinedInvitation = nil
        expectedRemotePeerID = nil
        invitationCode = nil
        remoteProfile = nil
        verificationCode = nil
        localConfirmed = false
        remoteConfirmed = false
        localRole = nil
        EvidenceCryptor.remove(receivedRecordingURL)
        receivedRecordingURL = nil
        remoteSegmentManifest = nil
        remoteAcknowledgedLocalRecording = false
        sentSegmentManifest = nil
        acknowledgedRemoteSegmentSHA256 = nil
        state = .idle
    }

    private func establishHostKey(from hello: PairHello) throws {
        guard let expectedSessionID = sessionID,
              hello.sessionID == expectedSessionID,
              let privateKey else {
            throw PeerPairingError.invalidPeerMessage
        }
        let clientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.publicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: clientKey)
        sessionKey = deriveSessionKey(sharedSecret: secret, sessionID: expectedSessionID)
    }

    private func deriveSessionKey(sharedSecret: SharedSecret, sessionID: UUID) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sessionID.uuidString.utf8),
            sharedInfo: Data("xagree-pairing-v1".utf8),
            outputByteCount: 32
        )
    }

    private func sendHello() throws {
        guard let privateKey, let sessionID, let session,
              let peer = expectedRemotePeerID,
              session.connectedPeers.contains(peer) else {
            throw PeerPairingError.invalidPeerMessage
        }
        let hello = PairHello(sessionID: sessionID, publicKey: privateKey.publicKey.rawRepresentation)
        let wire = PeerWireMessage(kind: "hello", payload: try JSONEncoder().encode(hello))
        try session.send(JSONEncoder().encode(wire), toPeers: [peer], with: .reliable)
    }

    private func sendProfile() throws {
        let snapshot = PairedProfile(name: profile.trimmedName, avatarData: profile.avatarData, avatarHash: avatarHash(profile.avatarData))
        try sendEncrypted(snapshot, kind: "profile")
    }

    private func sendEncrypted<T: Encodable>(_ value: T, kind: String) throws {
        guard let sessionKey, let session, let sessionID,
              let peer = expectedRemotePeerID,
              session.connectedPeers.contains(peer) else {
            throw PeerPairingError.keyAgreementFailed
        }
        let plaintext = try JSONEncoder().encode(value)
        guard plaintext.count <= PeerProtocolLimits.maximumPlaintextPayloadSize else {
            throw PeerPairingError.invalidPeerMessage
        }
        guard let encrypted = try AES.GCM.seal(plaintext, using: sessionKey, authenticating: Data(sessionID.uuidString.utf8)).combined else {
            throw PeerPairingError.keyAgreementFailed
        }
        let wire = PeerWireMessage(kind: "sealed:\(kind)", payload: encrypted)
        let encoded = try JSONEncoder().encode(wire)
        guard encoded.count <= PeerProtocolLimits.maximumWireMessageSize else {
            throw PeerPairingError.invalidPeerMessage
        }
        try session.send(encoded, toPeers: [peer], with: .reliable)
    }

    private func receive(_ data: Data) async {
        do {
            guard data.count <= PeerProtocolLimits.maximumWireMessageSize else {
                throw PeerPairingError.invalidPeerMessage
            }
            let wire = try SafeJSONDecoder.decode(PeerWireMessage.self, from: data)
            guard wire.kind.count <= 64,
                  wire.payload.count <= PeerProtocolLimits.maximumWirePayloadSize else {
                throw PeerPairingError.invalidPeerMessage
            }
            if wire.kind == "hello" {
                guard joinedInvitation == nil,
                      state == .hosting || state == .connecting else {
                    throw PeerPairingError.invalidPeerMessage
                }
                let hello = try SafeJSONDecoder.decode(PairHello.self, from: wire.payload)
                try establishHostKey(from: hello)
                try sendProfile()
                state = .connecting
                return
            }
            guard wire.kind.hasPrefix("sealed:"), let sessionKey, let sessionID else {
                throw PeerPairingError.invalidPeerMessage
            }
            let box = try AES.GCM.SealedBox(combined: wire.payload)
            let plaintext = try AES.GCM.open(box, using: sessionKey, authenticating: Data(sessionID.uuidString.utf8))
            guard plaintext.count <= PeerProtocolLimits.maximumPlaintextPayloadSize else {
                throw PeerPairingError.invalidPeerMessage
            }
            switch String(wire.kind.dropFirst("sealed:".count)) {
            case "profile":
                guard state == .connecting else { throw PeerPairingError.invalidPeerMessage }
                let profile = try SafeJSONDecoder.decode(PairedProfile.self, from: plaintext)
                guard PeerProtocolLimits.isValidProfile(profile) else {
                    throw PeerPairingError.invalidPeerMessage
                }
                remoteProfile = profile
                if joinedInvitation != nil { try sendProfile() }
                verificationCode = shortCode(using: sessionKey, sessionID: sessionID)
                state = .awaitingConfirmation
            case "confirm":
                guard state == .awaitingConfirmation || state == .paired else {
                    throw PeerPairingError.invalidPeerMessage
                }
                let confirmation = try SafeJSONDecoder.decode(PairConfirmation.self, from: plaintext)
                guard confirmation.sessionID == sessionID else { throw PeerPairingError.invalidPeerMessage }
                remoteConfirmed = true
                updateConfirmedState()
            case "segment":
                guard state == .paired else { throw PeerPairingError.invalidPeerMessage }
                let manifest = try SafeJSONDecoder.decode(SegmentManifest.self, from: plaintext)
                guard let localRole = self.localRole,
                      manifest.role != localRole,
                      manifest.duration > 0,
                      manifest.duration <= 30.5,
                      manifest.sha256.count == 64,
                      manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
                    throw PeerPairingError.invalidPeerMessage
                }
                remoteSegmentManifest = manifest
                try await validateReceivedRecordingIfReady()
            case "recording-receipt":
                guard state == .paired else { throw PeerPairingError.invalidPeerMessage }
                let receipt = try SafeJSONDecoder.decode(RecordingReceipt.self, from: plaintext)
                guard let localRole,
                      receipt.matches(
                        sessionID: sessionID,
                        localRole: localRole,
                        localManifest: sentSegmentManifest
                      ) else {
                    throw PeerPairingError.invalidPeerMessage
                }
                remoteAcknowledgedLocalRecording = true
            default:
                throw PeerPairingError.invalidPeerMessage
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func validateReceivedRecordingIfReady() async throws {
        guard let receivedRecordingURL,
              let manifest = remoteSegmentManifest else { return }
        let actual = try await Task.detached(priority: .userInitiated) {
            try FileHasher.sha256Hex(of: receivedRecordingURL)
        }.value
        guard self.receivedRecordingURL == receivedRecordingURL,
              remoteSegmentManifest == manifest,
              state == .paired else {
            return
        }
        guard actual.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            EvidenceCryptor.remove(receivedRecordingURL)
            self.receivedRecordingURL = nil
            throw PeerPairingError.invalidPeerMessage
        }
        guard acknowledgedRemoteSegmentSHA256?.caseInsensitiveCompare(manifest.sha256) != .orderedSame else {
            return
        }
        guard let sessionID else { throw PeerPairingError.invalidState }
        try sendEncrypted(
            RecordingReceipt(sessionID: sessionID, role: manifest.role, sha256: manifest.sha256),
            kind: "recording-receipt"
        )
        acknowledgedRemoteSegmentSHA256 = manifest.sha256
    }

    private func updateConfirmedState() {
        if localConfirmed && remoteConfirmed {
            state = .paired
            advertiser?.stopAdvertisingPeer()
            browser?.stopBrowsingForPeers()
        }
    }

    private func shortCode(using key: SymmetricKey, sessionID: UUID) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(sessionID.uuidString.utf8), using: key)
        let bytes = Array(digest)
        let number = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) } % 1_000_000
        return String(format: "%06d", number)
    }

    private func avatarHash(_ data: Data?) -> String? {
        guard let data else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makePeerID() -> MCPeerID {
        MCPeerID(displayName: "xg-\(UUID().uuidString.prefix(12))")
    }

    private func isExpected(_ peerID: MCPeerID, session: MCSession) -> Bool {
        self.session === session && expectedRemotePeerID == peerID
    }
}

extension PeerSessionCoordinator: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isExpected(peerID, session: session) else {
                session.cancelConnectPeer(peerID)
                return
            }
            switch state {
            case .connected:
                self.state = .connecting
                if self.joinedInvitation != nil {
                    do { try self.sendHello() } catch { self.state = .failed(error.localizedDescription) }
                }
            case .notConnected where self.state != .idle && self.state != .hosting && self.state != .searching:
                self.state = .failed(L10n.string("与附近设备的连接已断开。"))
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self, self.isExpected(peerID, session: session) else { return }
            await self.receive(data)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {
        guard resourceName == "xagree-recording", error == nil, let localURL else {
            Task { @MainActor [weak self] in
                guard let self, self.isExpected(peerID, session: session) else { return }
                self.state = .failed(L10n.string("未能接收对方的视频。"))
            }
            return
        }

        // MCSession owns localURL only for the duration of this callback. Stage it before returning.
        do {
            let stagedURL = try PeerResourceStager.stage(localURL)
            Task { @MainActor [weak self] in
                guard let self else {
                    EvidenceCryptor.remove(stagedURL)
                    return
                }
                guard self.isExpected(peerID, session: session) else {
                    EvidenceCryptor.remove(stagedURL)
                    return
                }
                await self.finishReceivingRecording(at: stagedURL)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.state = .failed(L10n.string("未能接收对方的视频。"))
            }
        }
    }
}

private extension PeerSessionCoordinator {
    func finishReceivingRecording(at stagedURL: URL) async {
        defer { EvidenceCryptor.remove(stagedURL) }
        guard let key = sessionKey, let sessionID else {
            state = .failed(L10n.string("未能接收对方的视频。"))
            return
        }
        do {
            let authenticatedData = Data(sessionID.uuidString.utf8)
            let decrypted = try await Task.detached(priority: .userInitiated) {
                try PeerFileCryptor.open(
                    inputURL: stagedURL,
                    key: key,
                    authenticatedData: authenticatedData
                )
            }.value
            guard self.sessionID == sessionID, state == .paired else {
                EvidenceCryptor.remove(decrypted)
                return
            }
            EvidenceCryptor.remove(receivedRecordingURL)
            receivedRecordingURL = decrypted
            try await validateReceivedRecordingIfReady()
        } catch {
            state = .failed(L10n.string("收到的视频无法通过加密校验。"))
        }
    }
}

extension PeerSessionCoordinator: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping @Sendable (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  let context,
                  let expectedID = self.sessionID,
                  String(data: context, encoding: .utf8) == expectedID.uuidString,
                  self.expectedRemotePeerID == nil || self.expectedRemotePeerID == peerID else {
                invitationHandler(false, nil)
                return
            }
            self.expectedRemotePeerID = peerID
            self.state = .connecting
            invitationHandler(true, self.session)
        }
    }
}

extension PeerSessionCoordinator: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self,
                  let invitation = self.joinedInvitation,
                  peerID.displayName == invitation.hostPeerID,
                  info?["session"] == invitation.sessionID.uuidString,
                  self.expectedRemotePeerID == nil,
                  let session = self.session else { return }
            self.expectedRemotePeerID = peerID
            browser.invitePeer(peerID, to: session, withContext: Data(invitation.sessionID.uuidString.utf8), timeout: 20)
            self.state = .connecting
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

private nonisolated extension FixedWidthInteger {
    var bigEndianData: Data {
        var value = bigEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}

enum PeerResourceStager {
    nonisolated static func stage(
        _ sourceURL: URL,
        maximumSize: Int64 = 514 * 1_024 * 1_024
    ) throws -> URL {
        let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceSize > 0, Int64(sourceSize) <= maximumSize else {
            throw PeerPairingError.invalidPeerMessage
        }
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("peer-incoming")
        var shouldRemoveDestination = true
        defer {
            if shouldRemoveDestination { try? FileManager.default.removeItem(at: destinationURL) }
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destinationURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = destinationURL
        try protectedURL.setResourceValues(values)
        shouldRemoveDestination = false
        return destinationURL
    }
}

nonisolated enum PeerFileCryptor {
    private static let chunkSize = 1_048_576
    private static let maximumPlaintextSize: UInt64 = 512 * 1_024 * 1_024
    static let maximumEncryptedSize: Int64 = 514 * 1_024 * 1_024

    static func seal(inputURL: URL, key: SymmetricKey, authenticatedData: Data) throws -> URL {
        let sourceSize = try inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceSize > 0, UInt64(sourceSize) <= maximumPlaintextSize else {
            throw PeerPairingError.invalidPeerMessage
        }
        let outputURL = try AppFiles.temporaryURL(extension: "peer")
        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput { try? FileManager.default.removeItem(at: outputURL) }
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? input.close()
            try? output.close()
        }
        var index: UInt64 = 0
        while true {
            let plaintext = try input.read(upToCount: chunkSize) ?? Data()
            guard !plaintext.isEmpty else { break }
            guard let encrypted = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedData + index.bigEndianData).combined else {
                throw PeerPairingError.keyAgreementFailed
            }
            try output.write(contentsOf: UInt32(encrypted.count).bigEndianData)
            try output.write(contentsOf: encrypted)
            index += 1
        }
        try AppFiles.protect(url: outputURL)
        shouldRemoveOutput = false
        return outputURL
    }

    static func open(inputURL: URL, key: SymmetricKey, authenticatedData: Data) throws -> URL {
        let encryptedSize = try inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard encryptedSize > 0, Int64(encryptedSize) <= maximumEncryptedSize else {
            throw PeerPairingError.invalidPeerMessage
        }
        let outputURL = try AppFiles.temporaryURL(extension: "mp4")
        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput { try? FileManager.default.removeItem(at: outputURL) }
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? input.close()
            try? output.close()
        }
        var index: UInt64 = 0
        var written: UInt64 = 0
        while true {
            let firstByte = try input.read(upToCount: 1) ?? Data()
            guard !firstByte.isEmpty else { break }
            let lengthData = firstByte + (try readExactly(from: input, count: 3))
            let length = lengthData.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
            guard length > 16, length < UInt32(chunkSize + 64) else { throw PeerPairingError.invalidPeerMessage }
            let encrypted = try readExactly(from: input, count: Int(length))
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: authenticatedData + index.bigEndianData)
            written += UInt64(plaintext.count)
            guard written <= maximumPlaintextSize else { throw PeerPairingError.invalidPeerMessage }
            try output.write(contentsOf: plaintext)
            index += 1
        }
        guard written > 0 else { throw PeerPairingError.invalidPeerMessage }
        try AppFiles.protect(url: outputURL)
        shouldRemoveOutput = false
        return outputURL
    }

    private static func readExactly(from handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
                throw PeerPairingError.invalidPeerMessage
            }
            result.append(part)
        }
        return result
    }
}

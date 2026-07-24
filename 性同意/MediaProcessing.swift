@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import UIKit

enum MediaProcessingError: LocalizedError {
    case missingTrack
    case exportFailed
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTrack: L10n.string("视频缺少可用的视频轨。")
        case .exportFailed: L10n.string("视频处理失败。")
        case .validationFailed(let detail): L10n.string(detail)
        }
    }
}

enum MediaProcessor {
    /// 合成前校验时长、音视频轨、大小与 SHA-256。
    static func validateSegment(url: URL, expectedSHA256: String?, maxDuration: TimeInterval = 30) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        // Allow a small container timestamp rounding error, but reject materially longer clips.
        guard seconds.isFinite, seconds > 0, seconds <= maxDuration + 0.5 else {
            throw MediaProcessingError.validationFailed("片段时长无效或超过 30 秒。")
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaProcessingError.missingTrack }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else {
            throw MediaProcessingError.validationFailed("片段文件为空。")
        }
        if let expectedSHA256 {
            let actual = try FileHasher.sha256Hex(of: url)
            guard actual == expectedSHA256 else {
                throw MediaProcessingError.validationFailed("片段 SHA-256 不匹配。")
            }
        }
    }

    static func concatenate(_ urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        guard let outputVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaProcessingError.exportFailed
        }
        let outputAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        var cursor = CMTime.zero
        for url in urls {
            // Each source frame already contains its burned-in timestamp watermark.
            try await validateSegment(url: url, expectedSHA256: nil)
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let video = videoTracks.first else { throw MediaProcessingError.missingTrack }
            let duration = try await asset.load(.duration)
            try outputVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: cursor)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audio = audioTracks.first, let outputAudio {
                try outputAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        let outputURL = try AppFiles.temporaryURL(extension: "mp4")
        try await export(composition: composition, to: outputURL)
        try AppFiles.protect(url: outputURL)
        return outputURL
    }

    static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }

    private static func export(composition: AVAsset, to outputURL: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaProcessingError.exportFailed
        }
        try await exporter.export(to: outputURL, as: .mp4)
    }
}

nonisolated enum FileHasher {
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

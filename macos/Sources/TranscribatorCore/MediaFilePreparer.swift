@preconcurrency import AVFoundation
import Foundation

public enum MediaFileKind: Equatable, Sendable {
    case audio
    case video
}

public struct MediaFileInfo: Sendable {
    public let sourceURL: URL
    public let kind: MediaFileKind
    public let durationSeconds: TimeInterval
    public let fileSize: Int64

    public init(
        sourceURL: URL,
        kind: MediaFileKind,
        durationSeconds: TimeInterval,
        fileSize: Int64
    ) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.fileSize = fileSize
    }
}

public final class MediaFilePreparer: @unchecked Sendable {
    private let exporter: AudioExporter

    public init(exporter: AudioExporter = AudioExporter()) {
        self.exporter = exporter
    }

    public func inspect(_ sourceURL: URL) async throws -> MediaFileInfo {
        try Task.checkCancellation()
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isReadableKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isReadable != false else {
            throw MediaPreparationError.unreadableSource(sourceURL.path)
        }

        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let firstAudioTrack = audioTracks.first else {
            throw MediaPreparationError.noAudioTrack
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTimeRange = try await firstAudioTrack.load(.timeRange)
        let durationSeconds = CMTimeGetSeconds(audioTimeRange.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw MediaPreparationError.invalidDuration
        }
        try Task.checkCancellation()

        return MediaFileInfo(
            sourceURL: sourceURL,
            kind: videoTracks.isEmpty ? .audio : .video,
            durationSeconds: durationSeconds,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    public func prepare(
        sourceURL: URL,
        destinationURL: URL,
        quality: AudioQuality = .standard
    ) async throws {
        _ = try await inspect(sourceURL)
        try Task.checkCancellation()
        try await exporter.mixToM4A(
            sources: [sourceURL],
            destination: destinationURL,
            quality: quality
        )
        try Task.checkCancellation()
    }
}

public enum MediaPreparationError: LocalizedError {
    case unreadableSource(String)
    case noAudioTrack
    case invalidDuration

    public var errorDescription: String? {
        switch self {
        case .unreadableSource(let path):
            "Не удалось прочитать выбранный файл: \(path)"
        case .noAudioTrack:
            "В выбранном файле нет аудиодорожки"
        case .invalidDuration:
            "Не удалось определить длительность аудиодорожки"
        }
    }
}

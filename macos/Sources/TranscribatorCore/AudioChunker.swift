import AVFoundation
import Foundation

public struct AudioChunkingPolicy: Sendable {
    public let maxUploadBytes: Int64
    public let targetChunkBytes: Int64
    public let maxChunkDurationSeconds: TimeInterval

    public init(
        maxUploadBytes: Int64 = 24_000_000,
        targetChunkBytes: Int64 = 20 * 1024 * 1024,
        maxChunkDurationSeconds: TimeInterval = 30 * 60
    ) {
        precondition(targetChunkBytes > 0 && targetChunkBytes <= maxUploadBytes)
        precondition(maxChunkDurationSeconds.isFinite && maxChunkDurationSeconds > 0)
        self.maxUploadBytes = maxUploadBytes
        self.targetChunkBytes = targetChunkBytes
        self.maxChunkDurationSeconds = maxChunkDurationSeconds
    }

    public func chunkCount(forFileSize size: Int64) -> Int {
        guard size > maxUploadBytes else { return 1 }
        return max(2, Int(ceil(Double(size) / Double(targetChunkBytes))))
    }

    public func chunkCount(forFileSize size: Int64, duration: CMTime) -> Int {
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return chunkCount(forFileSize: size) }

        let rawDurationCount = ceil(seconds / maxChunkDurationSeconds)
        let durationCount = rawDurationCount >= Double(Int.max)
            ? Int.max
            : max(1, Int(rawDurationCount))
        return max(chunkCount(forFileSize: size), durationCount)
    }

    public func timeRanges(duration: CMTime, fileSize: Int64) -> [CMTimeRange] {
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else { return [] }
        let count = chunkCount(forFileSize: fileSize, duration: duration)
        guard count > 1 else { return [CMTimeRange(start: .zero, duration: duration)] }

        let secondsPerChunk = totalSeconds / Double(count)
        return (0..<count).map { index in
            let startSeconds = Double(index) * secondsPerChunk
            let endSeconds = index == count - 1 ? totalSeconds : Double(index + 1) * secondsPerChunk
            return CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: endSeconds - startSeconds, preferredTimescale: 600)
            )
        }
    }
}

public final class AudioChunker {
    private let policy: AudioChunkingPolicy
    private let exporter: AudioExporter

    public init(
        policy: AudioChunkingPolicy = AudioChunkingPolicy(),
        exporter: AudioExporter = AudioExporter()
    ) {
        self.policy = policy
        self.exporter = exporter
    }

    public func uploadFiles(
        for recordingURL: URL,
        quality: AudioQuality = .standard
    ) async throws -> [URL] {
        let values = try recordingURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        let duration = try await exporter.duration(of: recordingURL)
        let ranges = policy.timeRanges(duration: duration, fileSize: size)
        guard !ranges.isEmpty else { throw AudioChunkingError.invalidDuration }
        guard ranges.count > 1 else { return [recordingURL] }

        let directory = recordingURL.deletingLastPathComponent()
        let uploadStem = "upload-\(UUID().uuidString)"
        var chunks: [URL] = []

        do {
            for (index, range) in ranges.enumerated() {
                let url = directory.appendingPathComponent(
                    String(format: "\(uploadStem)-%02d.m4a", index + 1)
                )
                chunks.append(url)
                try await exporter.mixToM4A(
                    sources: [recordingURL],
                    destination: url,
                    timeRange: range,
                    quality: quality
                )
                let chunkSize = Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                guard chunkSize <= policy.maxUploadBytes else {
                    throw AudioChunkingError.chunkStillTooLarge(size: chunkSize)
                }
            }
            return chunks
        } catch {
            for url in chunks { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}

public enum AudioChunkingError: LocalizedError {
    case invalidDuration
    case chunkStillTooLarge(size: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "Не удалось определить длительность записанного аудио"
        case .chunkStillTooLarge(let size):
            "После разбиения часть всё ещё больше лимита API: \(size / 1024 / 1024) MB"
        }
    }
}

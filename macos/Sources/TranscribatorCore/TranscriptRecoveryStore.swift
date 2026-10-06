import Darwin
import Foundation

/// Durable local progress. Recovery files never contain session credentials or server responses.
@MainActor
public final class TranscriptRecoveryStore {
    public let recoveryDirectoryURL: URL
    public let partialTranscriptURL: URL
    public let checkpointURL: URL
    public let outputURL: URL
    public private(set) var lastCheckpoint: AudioTranscriptionCheckpoint?

    public var hasPartialTranscript: Bool {
        // URL resource values can be cached across atomic replacement/removal.
        guard let values = try? FileManager.default.attributesOfItem(atPath: partialTranscriptURL.path) else {
            return false
        }
        return values[.type] as? FileAttributeType == .typeRegular
            && ((values[.size] as? NSNumber)?.intValue ?? 0) > 0
    }

    private var sourceAudioURL: URL
    private var completed = false

    public init(outputURL: URL, sourceAudioURL: URL, recoveryRootURL: URL? = nil) throws {
        guard outputURL.isFileURL, sourceAudioURL.isFileURL,
              recoveryRootURL?.isFileURL != false else { throw RecoveryError.invalidURL }
        self.outputURL = outputURL.standardizedFileURL
        self.sourceAudioURL = sourceAudioURL.standardizedFileURL
        let root: URL
        if let recoveryRootURL {
            root = recoveryRootURL.standardizedFileURL
        } else {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Transcribator Mac", isDirectory: true)
                .appendingPathComponent("Recovery", isDirectory: true)
        }
        var stem = outputURL.deletingPathExtension().lastPathComponent
        while stem.utf8.count > 120 { stem.removeLast() }
        if stem.isEmpty { stem = "transcript" }
        recoveryDirectoryURL = root.appendingPathComponent("\(stem)-\(UUID().uuidString)", isDirectory: true)
        partialTranscriptURL = recoveryDirectoryURL.appendingPathComponent("partial.txt")
        checkpointURL = recoveryDirectoryURL.appendingPathComponent("checkpoint.json")
        try FileManager.default.createDirectory(
            at: recoveryDirectoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryDirectoryURL.path)
    }

    public func save(_ checkpoint: AudioTranscriptionCheckpoint) throws {
        guard !completed else { throw RecoveryError.alreadyCompleted }
        // JSON is the authoritative snapshot and includes the text. Publish it first so
        // a later partial.txt write failure cannot lose the new response.
        let data = try metadata(status: "partial", checkpoint: checkpoint)
        try Self.writePrivately(data, to: checkpointURL, replaceExisting: true)
        lastCheckpoint = checkpoint
        let text = checkpoint.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if FileManager.default.fileExists(atPath: partialTranscriptURL.path) {
                try FileManager.default.removeItem(at: partialTranscriptURL)
            }
        } else {
            try Self.writePrivately(Data(checkpoint.transcript.utf8), to: partialTranscriptURL, replaceExisting: true)
        }
    }

    /// Update the recovery pointer after the caller has preserved the audio.
    /// This method never moves, copies, or removes either audio file.
    public func relocateSourceAudio(to url: URL) throws {
        guard url.isFileURL else { throw RecoveryError.invalidURL }
        let source = url.standardizedFileURL
        let data = try metadata(
            status: completed ? "completed" : "partial", checkpoint: lastCheckpoint, sourceURL: source
        )
        try Self.writePrivately(data, to: checkpointURL, replaceExisting: true)
        sourceAudioURL = source
    }

    public func finish(_ transcript: String) throws {
        guard !completed else { throw RecoveryError.alreadyCompleted }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecoveryError.emptyTranscript
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.writePrivately(Data(transcript.utf8), to: outputURL, replaceExisting: false)
        completed = true
        // The final file now exists. Cleanup/metadata failure must not turn this success
        // into a failed transcription or remove the successfully written final file.
        try? FileManager.default.removeItem(at: partialTranscriptURL)
        if let data = try? metadata(status: "completed", checkpoint: lastCheckpoint) {
            try? Self.writePrivately(data, to: checkpointURL, replaceExisting: true)
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let status: String
        let sourceAudioPath: String
        let outputPath: String
        let checkpoint: AudioTranscriptionCheckpoint?
    }

    private func metadata(
        status: String, checkpoint: AudioTranscriptionCheckpoint?, sourceURL: URL? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(
            schemaVersion: 1, status: status, sourceAudioPath: (sourceURL ?? sourceAudioURL).path,
            outputPath: outputURL.path, checkpoint: checkpoint
        ))
    }

    private static func writePrivately(_ data: Data, to destination: URL, replaceExisting: Bool) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".transcript-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        // RENAME_EXCL atomically rejects an existing final file, including a file
        // created after the caller's existence check. Both paths are on one volume.
        let flags = replaceExisting ? UInt32(0) : UInt32(RENAME_EXCL)
        guard renamex_np(temporary.path, destination.path, flags) == 0 else { throw posixError() }
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private enum RecoveryError: LocalizedError {
        case invalidURL, emptyTranscript, alreadyCompleted

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Для сохранения транскрипции нужен локальный путь"
            case .emptyTranscript: "Нельзя сохранить пустую транскрипцию"
            case .alreadyCompleted: "Транскрипция уже сохранена"
            }
        }
    }
}

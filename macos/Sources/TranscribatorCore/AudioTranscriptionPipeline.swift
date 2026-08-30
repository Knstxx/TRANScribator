import Foundation

public protocol AudioTranscriptionRequesting: AnyObject {
    func transcribe(
        fileURL: URL,
        model: TranscriptionModel,
        prompt: String?
    ) async throws -> String
}

extension OpenAITranscriptionClient: AudioTranscriptionRequesting {}

public enum AudioTranscriptionProgress: Equatable, Sendable {
    case preparingUploads
    case transcribing(current: Int, total: Int)
}

public final class AudioTranscriptionPipeline: @unchecked Sendable {
    private let chunker: AudioChunker

    public init(chunker: AudioChunker = AudioChunker()) {
        self.chunker = chunker
    }

    public func transcribe(
        audioURL: URL,
        quality: AudioQuality = .standard,
        model: TranscriptionModel,
        initialPrompt: String? = nil,
        client: AudioTranscriptionRequesting,
        progress: (@MainActor @Sendable (AudioTranscriptionProgress) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        await progress?(.preparingUploads)
        let uploadFiles = try await chunker.uploadFiles(for: audioURL, quality: quality)

        var results: [String] = []
        for (index, fileURL) in uploadFiles.enumerated() {
            try Task.checkCancellation()
            await progress?(.transcribing(current: index + 1, total: uploadFiles.count))
            let prompt = Self.prompt(
                model: model,
                initialPrompt: initialPrompt,
                previousTranscript: results.last
            )
            let text = try await client.transcribe(
                fileURL: fileURL,
                model: model,
                prompt: prompt
            )
            try Task.checkCancellation()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { results.append(trimmed) }
        }

        let transcript = results.joined(separator: "\n\n")
        guard !transcript.isEmpty else { throw AudioTranscriptionPipelineError.emptyTranscript }
        return transcript
    }

    private static func prompt(
        model: TranscriptionModel,
        initialPrompt: String?,
        previousTranscript: String?
    ) -> String? {
        guard model.supportsPrompt else { return nil }
        let continuity = previousTranscript.map { String($0.suffix(1_000)) }
        let context = initialPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(450)
        let parts = [continuity, context.map(String.init)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

public enum AudioTranscriptionPipelineError: LocalizedError {
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "OpenAI вернул пустую транскрипцию"
        }
    }
}

import AVFoundation
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
    private let chatGPTChunker = AudioChunker(policy: .gptApp)
    private let emptyResponseChunker = AudioChunker(policy: AudioChunkingPolicy(maxChunkDurationSeconds: 60))

    public init(chunker: AudioChunker = AudioChunker()) {
        self.chunker = chunker
    }

    public func transcribe(
        audioURL: URL,
        quality: AudioQuality = .standard,
        model: TranscriptionModel,
        initialPrompt: String? = nil,
        client: AudioTranscriptionRequesting,
        checkpoint: (@MainActor @Sendable (AudioTranscriptionCheckpoint) throws -> Void)? = nil,
        progress: (@MainActor @Sendable (AudioTranscriptionProgress) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        await progress?(.preparingUploads)
        let selectedChunker = model == .gptApp ? chatGPTChunker : chunker
        let uploadFiles = try await selectedChunker.uploadFiles(for: audioURL, quality: quality)
        let totalSeconds = CMTimeGetSeconds(try await AudioExporter().duration(of: audioURL))
        guard totalSeconds.isFinite, totalSeconds > 0 else { throw AudioChunkingError.invalidDuration }

        var state = CheckpointState(totalSeconds: totalSeconds)
        for (index, fileURL) in uploadFiles.enumerated() {
            try Task.checkCancellation()
            await progress?(.transcribing(current: index + 1, total: uploadFiles.count))
            let prompt = Self.prompt(
                model: model,
                initialPrompt: initialPrompt,
                previousTranscript: state.results.last
            )
            let text = try await client.transcribe(
                fileURL: fileURL,
                model: model,
                prompt: prompt
            )
            try Task.checkCancellation()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = Self.range(index: index, count: uploadFiles.count, within: AudioTranscriptionRange(
                startSeconds: 0, endSeconds: totalSeconds
            ))
            if model == .gptApp && trimmed.isEmpty {
                // Save the empty primary response before starting recovery. It is not yet
                // classified as a no-text interval because shorter uploads may recover speech.
                state.pendingRecoveryRanges = [range]
                try await checkpoint?(state.snapshot)
                try Task.checkCancellation()
                let shortFiles = try await emptyResponseChunker.uploadFiles(for: fileURL, quality: quality)
                var recoveredText = false
                for (shortIndex, shortFile) in shortFiles.enumerated() {
                    try Task.checkCancellation()
                    // Exactly one extra pass: a <=60s primary chunk is retried once as-is.
                    // Auth, HTTP, malformed-response, and cancellation errors propagate immediately.
                    let shortText = try await client.transcribe(fileURL: shortFile, model: model, prompt: nil)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    let shortRange = Self.range(index: shortIndex, count: shortFiles.count, within: range)
                    recoveredText = recoveredText || !shortText.isEmpty
                    state.accept(shortText, in: shortRange)
                    let isLast = shortIndex == shortFiles.count - 1
                    state.pendingRecoveryRanges = isLast ? [] : [AudioTranscriptionRange(
                        startSeconds: shortRange.endSeconds, endSeconds: range.endSeconds
                    )]
                    if isLast && recoveredText { state.recoveredEmptyChunkCount += 1 }
                    try await checkpoint?(state.snapshot)
                }
            } else {
                state.accept(trimmed, in: range)
                try await checkpoint?(state.snapshot)
            }
        }

        try Task.checkCancellation()
        let transcript = state.snapshot.transcript
        guard !transcript.isEmpty else {
            // The last (all-empty) checkpoint has already been durably offered to the caller.
            throw model == .gptApp
                ? AudioTranscriptionPipelineError.noSpeechDetected
                : AudioTranscriptionPipelineError.emptyTranscript
        }
        return transcript
    }

    private static func range(index: Int, count: Int, within parent: AudioTranscriptionRange) -> AudioTranscriptionRange {
        let duration = parent.endSeconds - parent.startSeconds
        return AudioTranscriptionRange(
            startSeconds: parent.startSeconds + duration * Double(index) / Double(count),
            endSeconds: index == count - 1
                ? parent.endSeconds
                : parent.startSeconds + duration * Double(index + 1) / Double(count)
        )
    }

    private struct CheckpointState {
        let totalSeconds: Double
        var results: [String] = []
        var processedSeconds: Double = 0
        var noSpeechRanges: [AudioTranscriptionRange] = []
        var pendingRecoveryRanges: [AudioTranscriptionRange] = []
        var recoveredEmptyChunkCount = 0

        mutating func accept(_ text: String, in range: AudioTranscriptionRange) {
            if text.isEmpty { noSpeechRanges.append(range) } else { results.append(text) }
            processedSeconds = range.endSeconds
        }

        var snapshot: AudioTranscriptionCheckpoint {
            AudioTranscriptionCheckpoint(
                transcript: results.joined(separator: "\n\n"), processedSeconds: processedSeconds,
                totalSeconds: totalSeconds, noSpeechRanges: noSpeechRanges,
                pendingRecoveryRanges: pendingRecoveryRanges, recoveredEmptyChunkCount: recoveredEmptyChunkCount
            )
        }
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
    case noSpeechDetected

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "OpenAI вернул пустую транскрипцию"
        case .noSpeechDetected:
            "Речь не обнаружена"
        }
    }
}

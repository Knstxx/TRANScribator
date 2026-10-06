import Foundation

public struct AudioTranscriptionRange: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// A snapshot emitted after every accepted server response, before the next upload.
/// No-text ranges mean only that ASR returned no text; they do not prove acoustic silence.
public struct AudioTranscriptionCheckpoint: Codable, Equatable, Sendable {
    public let transcript: String
    public let processedSeconds: Double
    public let totalSeconds: Double
    public let noSpeechRanges: [AudioTranscriptionRange]
    public let pendingRecoveryRanges: [AudioTranscriptionRange]
    public let recoveredEmptyChunkCount: Int

    public init(
        transcript: String,
        processedSeconds: Double,
        totalSeconds: Double,
        noSpeechRanges: [AudioTranscriptionRange] = [],
        pendingRecoveryRanges: [AudioTranscriptionRange] = [],
        recoveredEmptyChunkCount: Int = 0
    ) {
        self.transcript = transcript
        self.processedSeconds = processedSeconds
        self.totalSeconds = totalSeconds
        self.noSpeechRanges = noSpeechRanges
        self.pendingRecoveryRanges = pendingRecoveryRanges
        self.recoveredEmptyChunkCount = recoveredEmptyChunkCount
    }
}

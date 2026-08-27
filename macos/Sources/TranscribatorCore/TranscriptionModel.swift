import Foundation

public enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case transcribe = "gpt-transcribe"
    case diarize = "gpt-4o-transcribe-diarize"
    case whisper = "whisper-1"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .transcribe: "GPT Transcribe"
        case .diarize: "GPT-4o · говорящие"
        case .whisper: "Whisper"
        }
    }

    public var shortTitle: String {
        switch self {
        case .transcribe: "Transcribe"
        case .diarize: "Diarize"
        case .whisper: "Whisper"
        }
    }

    var supportsPrompt: Bool { self != .diarize }

    public var usesAutomaticChunking: Bool { self != .whisper }
}

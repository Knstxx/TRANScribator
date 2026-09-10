import Foundation

public enum TranscriptionPhase: Equatable {
    case idle
    case recording
    case processing(String)
    case done(copied: Bool)
    case cancelled(String)
    case failed(String)
}

public enum AppStatusTone: Equatable {
    case neutral
    case recording
    case working
    case success
    case warning
    case failure
}

/// Describes which sources will be audible in the resulting recording.
/// These values describe the controls, not measured microphone or system activity.
public struct RecordingAudioStatus: Equatable {
    private let includesMicrophone: Bool
    private let microphoneVolume: Double
    private let systemAudioVolume: Double

    public init(
        includesMicrophone: Bool,
        microphoneVolume: Double,
        systemAudioVolume: Double
    ) {
        self.includesMicrophone = includesMicrophone
        self.microphoneVolume = Self.normalizedVolume(microphoneVolume)
        self.systemAudioVolume = Self.normalizedVolume(systemAudioVolume)
    }

    public var isMicrophoneMuted: Bool { !includesMicrophone || microphoneVolume == 0 }
    public var isSystemAudioMuted: Bool { systemAudioVolume == 0 }
    public var hasAudibleSource: Bool { !isMicrophoneMuted || !isSystemAudioMuted }

    public var microphoneDetail: String {
        if !includesMicrophone { return "Выключен" }
        return Self.volumeDetail(microphoneVolume)
    }

    public var systemAudioDetail: String { Self.volumeDetail(systemAudioVolume) }

    public var recordingText: String {
        switch (isMicrophoneMuted, isSystemAudioMuted) {
        case (false, false): "Запись системного звука и микрофона"
        case (true, false): "Запись только системного звука"
        case (false, true): "Запись только микрофона"
        case (true, true): "Запись идёт без звука"
        }
    }

    public var summary: String {
        "Микрофон: \(microphoneDetail) · Системный звук: \(systemAudioDetail)"
    }

    public var warningText: String? {
        hasAudibleSource
            ? nil
            : "Оба источника выключены или имеют громкость 0%. В итоговой записи будет тишина, пока вы не включите звук."
    }

    private static func volumeDetail(_ volume: Double) -> String {
        guard volume > 0 else { return "Громкость 0%" }
        return "\(max(1, Int((volume * 100).rounded())))%"
    }

    private static func normalizedVolume(_ volume: Double) -> Double {
        // Match the exporter's handling of invalid volume automation values.
        volume.isFinite ? min(1, max(0, volume)) : 1
    }
}

/// Keeps operation state independent from the recording source controls.
public struct AppStatus: Equatable {
    private let phase: TranscriptionPhase
    private let audio: RecordingAudioStatus
    private let hasAPIKey: Bool
    private let authorizationRequiredMessage: String

    public init(phase: TranscriptionPhase, audio: RecordingAudioStatus, hasAPIKey: Bool) {
        self.phase = phase
        self.audio = audio
        self.hasAPIKey = hasAPIKey
        self.authorizationRequiredMessage = "Добавьте OpenAI API key"
    }

    public init(phase: TranscriptionPhase, audio: RecordingAudioStatus, authorizationRequiredMessage: String?) {
        self.phase = phase
        self.audio = audio
        self.hasAPIKey = authorizationRequiredMessage == nil
        self.authorizationRequiredMessage = authorizationRequiredMessage ?? ""
    }

    public var statusText: String {
        switch phase {
        case .idle:
            if !hasAPIKey { return authorizationRequiredMessage }
            return audio.hasAudibleSource ? "Готов к записи" : "Нет звука для записи"
        case .recording:
            return audio.recordingText
        case .processing(let text), .cancelled(let text), .failed(let text):
            return text
        case .done(let copied):
            return copied ? "Транскрипция готова и скопирована" : "Транскрипция готова"
        }
    }

    public var symbolName: String {
        switch phase {
        case .idle:
            if !hasAPIKey { return "key.fill" }
            return audio.hasAudibleSource ? "waveform" : "exclamationmark.triangle.fill"
        case .recording: return "record.circle.fill"
        case .processing: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    public var tone: AppStatusTone {
        switch phase {
        case .idle: hasAPIKey && audio.hasAudibleSource ? .neutral : .warning
        case .recording: .recording
        case .processing: .working
        case .done: .success
        case .cancelled: .neutral
        case .failed: .failure
        }
    }

    public var menuBarActivitySymbolName: String? {
        if phase == .idle, hasAPIKey, audio.hasAudibleSource { return nil }
        return symbolName
    }

    public var menuBarAudioSymbolName: String? {
        guard phase == .idle || phase == .recording else { return nil }
        if !audio.hasAudibleSource {
            if phase == .recording { return "exclamationmark.triangle.fill" }
            return hasAPIKey ? nil : "speaker.slash.fill"
        }
        if audio.isSystemAudioMuted { return "speaker.slash.fill" }
        return audio.isMicrophoneMuted ? "mic.slash.fill" : nil
    }

    public var menuBarHelp: String {
        var text = "Transcribator — \(statusText)"
        if phase == .idle || phase == .recording {
            text += "\n\(audio.summary)"
        }
        return text
    }
}

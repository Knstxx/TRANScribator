import Foundation
import SwiftUI
import TranscribatorCore

// This preview-only type deliberately replaces the production AppState at
// compile time. It never reads preferences, files, Keychain, auth, or capture.
enum ChatGPTAppStatus { case notInstalled, signInRequired, ready, unavailable }
enum MediaFileKind { case audio, video }
struct MediaFileInfo {
    let sourceURL: URL
    let kind: MediaFileKind
    let durationSeconds: TimeInterval
    let fileSize: Int64
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: TranscriptionPhase = .recording
    @Published var startedAt: Date? = Date().addingTimeInterval(-19)
    @Published var apiKeyStatus: APIKeyStatus = .available
    @Published var isCheckingAPIKey = false
    @Published var chatGPTStatus: ChatGPTAppStatus = .ready
    @Published var isCheckingChatGPT = false
    @Published var lastTranscriptURL: URL?
    @Published var lastRecordingURL: URL?
    @Published var selectedMediaFile: MediaFileInfo?
    @Published var isFileTranscribing = false
    @Published var isInspectingMediaFile = false
    @Published var filePrompt = ""
    @Published var audioDirectoryURL = URL(fileURLWithPath: "/Preview/Transcribator/Audio", isDirectory: true)
    @Published var transcriptsDirectoryURL = URL(fileURLWithPath: "/Preview/Transcribator/Transcripts", isDirectory: true)
    @Published var savesAudioRecording = true
    @Published var copiesTranscriptToClipboard = false
    @Published var selectedAudioQuality: AudioQuality = .standard
    @Published var selectedModel: TranscriptionModel = .gptApp
    @Published var includesMicrophone = false
    @Published var microphoneVolume = 1.0
    @Published var systemAudioVolume = 0.65

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { if case .processing = phase { true } else { false } }
    var hasAPIKey: Bool { apiKeyStatus.hasSavedKey }
    var apiKeyStatusText: String {
        isCheckingAPIKey ? APIKeyStatus.checking.statusText : apiKeyStatus.statusText
    }
    var audioStatus: RecordingAudioStatus {
        RecordingAudioStatus(includesMicrophone: includesMicrophone,
                             microphoneVolume: microphoneVolume,
                             systemAudioVolume: systemAudioVolume)
    }
    var status: AppStatus {
        AppStatus(phase: phase, audio: audioStatus, authorizationRequiredMessage: authorizationRequiredMessage)
    }
    var canUseSelectedModel: Bool { selectedModel.requiresAPIKey ? hasAPIKey : canSelectGPTApp }
    var canSelectGPTApp: Bool { chatGPTStatus == .ready && !isCheckingChatGPT }
    var chatGPTStatusText: String { "Подключена текущая сессия ChatGPT" }
    var authorizationRequiredMessage: String? {
        guard !canUseSelectedModel else { return nil }
        return selectedModel.requiresAPIKey ? apiKeyStatus.authorizationRequiredMessage : "Подключите выбранную модель"
    }

    func setMicrophoneEnabled(_ enabled: Bool) { includesMicrophone = enabled }
    func setSystemAudioEnabled(_ enabled: Bool) { systemAudioVolume = enabled ? 0.65 : 0 }
    func refreshChatGPTStatus(manual _: Bool = false) {}
    func refreshAPIKeyStatus() {}
    func toggleRecording() {}
    func cancelRecording() {}
    func chooseMediaFile() {}
    func clearSelectedMediaFile() {}
    func transcribeSelectedMediaFile() {}
    func cancelFileTranscription() {}
    func cancelMediaInspection() {}
    func revealLastResult() {}
    func chooseAudioDirectory() -> Bool { false }
    func chooseTranscriptsDirectory() -> Bool { false }
    func resetAudioDirectory() {}
    func resetTranscriptsDirectory() {}
    func saveAPIKey(_: String) throws {}
    func deleteAPIKey() throws {}
}

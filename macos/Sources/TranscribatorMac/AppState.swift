import AppKit
import Foundation
import SwiftUI
import TranscribatorCore
@preconcurrency import UserNotifications

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case processing(String)
        case done(copied: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var hasAPIKey = false
    @Published private(set) var lastTranscriptURL: URL?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var audioDirectoryURL: URL
    @Published private(set) var transcriptsDirectoryURL: URL
    @Published var savesAudioRecording: Bool {
        didSet { UserDefaults.standard.set(savesAudioRecording, forKey: Self.savesAudioRecordingKey) }
    }
    @Published var copiesTranscriptToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(
                copiesTranscriptToClipboard,
                forKey: Self.copiesTranscriptToClipboardKey
            )
        }
    }
    @Published var selectedAudioQuality: AudioQuality {
        didSet {
            UserDefaults.standard.set(selectedAudioQuality.rawValue, forKey: Self.audioQualityKey)
        }
    }
    @Published var includesMicrophone: Bool {
        didSet {
            UserDefaults.standard.set(includesMicrophone, forKey: Self.includesMicrophoneKey)
            if isRecording {
                capture.setMicrophoneEnabled(includesMicrophone)
            }
        }
    }
    @Published var microphoneVolume: Double {
        didSet {
            UserDefaults.standard.set(microphoneVolume, forKey: Self.microphoneVolumeKey)
            recordVolumeChange(microphone: true)
        }
    }
    @Published var systemAudioVolume: Double {
        didSet {
            UserDefaults.standard.set(systemAudioVolume, forKey: Self.systemAudioVolumeKey)
            recordVolumeChange(microphone: false)
        }
    }
    @Published var selectedModel: TranscriptionModel {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "transcriptionModel") }
    }

    private let capture = AudioCaptureSession()
    private let exporter = AudioExporter()
    private let chunker = AudioChunker()
    private let keychain = KeychainStore()
    private var sessionDirectory: URL?
    private var sessionFileStem: String?
    private var sessionAudioQuality: AudioQuality?
    private var sessionStartedUptime: TimeInterval?
    private var microphoneVolumePoints: [AudioVolumePoint] = []
    private var systemVolumePoints: [AudioVolumePoint] = []

    private static let audioDirectoryKey = "audioDirectory"
    private static let transcriptsDirectoryKey = "transcriptsDirectory"
    private static let savesAudioRecordingKey = "savesAudioRecording"
    private static let copiesTranscriptToClipboardKey = "copiesTranscriptToClipboard"
    private static let audioQualityKey = "audioQuality"
    private static let includesMicrophoneKey = "includesMicrophone"
    private static let microphoneVolumeKey = "microphoneVolume"
    private static let systemAudioVolumeKey = "systemAudioVolume"
    private static let minimumVolumePointInterval: TimeInterval = 0.05

    init() {
        let savedModel = UserDefaults.standard.string(forKey: "transcriptionModel")
            .flatMap(TranscriptionModel.init(rawValue:))
        selectedModel = savedModel ?? .transcribe
        audioDirectoryURL = Self.savedDirectory(
            forKey: Self.audioDirectoryKey,
            defaultURL: Self.defaultAudioDirectory()
        )
        transcriptsDirectoryURL = Self.savedDirectory(
            forKey: Self.transcriptsDirectoryKey,
            defaultURL: Self.defaultTranscriptsDirectory()
        )
        savesAudioRecording = UserDefaults.standard.object(
            forKey: Self.savesAudioRecordingKey
        ) as? Bool ?? true
        copiesTranscriptToClipboard = UserDefaults.standard.object(
            forKey: Self.copiesTranscriptToClipboardKey
        ) as? Bool ?? false
        selectedAudioQuality = UserDefaults.standard.string(forKey: Self.audioQualityKey)
            .flatMap(AudioQuality.init(rawValue:)) ?? .standard
        includesMicrophone = UserDefaults.standard.object(
            forKey: Self.includesMicrophoneKey
        ) as? Bool ?? true
        microphoneVolume = Self.savedCoefficient(
            forKey: Self.microphoneVolumeKey,
            defaultValue: 1
        )
        systemAudioVolume = Self.savedCoefficient(
            forKey: Self.systemAudioVolumeKey,
            defaultValue: 0.65
        )
        if CaptureSmokeRunner.isRequested || ExistingFileTranscriptionRunner.isRequested {
            hasAPIKey = false
        } else {
            hasAPIKey = (try? keychain.containsValue()) == true
            Self.removeStaleWorkingFiles()
        }
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { if case .processing = phase { true } else { false } }
    var isMicrophoneMuted: Bool { !includesMicrophone || microphoneVolume == 0 }

    var statusText: String {
        switch phase {
        case .idle: "Готов"
        case .recording:
            !isMicrophoneMuted
                ? "Запись системного звука и микрофона"
                : "Запись только системного звука"
        case .processing(let text): text
        case .done(let copied):
            copied ? "Транскрипция готова и скопирована" : "Транскрипция готова"
        case .failed(let message): message
        }
    }

    var iconName: String {
        switch phase {
        case .recording:
            isMicrophoneMuted ? "waveform.badge.xmark" : "record.circle.fill"
        case .processing: "waveform.badge.magnifyingglass"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .idle: "waveform"
        }
    }

    func saveAPIKey(_ value: String) throws {
        try keychain.save(value)
        hasAPIKey = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasAPIKey, case .failed = phase { phase = .idle }
    }

    func deleteAPIKey() throws {
        try keychain.delete()
        hasAPIKey = false
    }

    func chooseAudioDirectory() -> Bool {
        guard let url = chooseDirectory(
            title: "Папка для аудиозаписей",
            message: "Новые M4A-записи будут сохраняться в выбранной папке.",
            currentURL: audioDirectoryURL
        ) else { return false }
        UserDefaults.standard.set(url.path, forKey: Self.audioDirectoryKey)
        audioDirectoryURL = url
        return true
    }

    func chooseTranscriptsDirectory() -> Bool {
        guard let url = chooseDirectory(
            title: "Папка для транскриптов",
            message: "Новые текстовые транскрипты будут сохраняться в выбранной папке.",
            currentURL: transcriptsDirectoryURL
        ) else { return false }
        UserDefaults.standard.set(url.path, forKey: Self.transcriptsDirectoryKey)
        transcriptsDirectoryURL = url
        return true
    }

    func resetAudioDirectory() {
        UserDefaults.standard.removeObject(forKey: Self.audioDirectoryKey)
        audioDirectoryURL = Self.defaultAudioDirectory()
    }

    func resetTranscriptsDirectory() {
        UserDefaults.standard.removeObject(forKey: Self.transcriptsDirectoryKey)
        transcriptsDirectoryURL = Self.defaultTranscriptsDirectory()
    }

    private func chooseDirectory(title: String, message: String, currentURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Выбрать"
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = currentURL

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else if !isBusy {
            phase = .processing("Подготовка записи…")
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard hasAPIKey else {
            phase = .failed("Сначала сохраните OpenAI API key")
            return
        }
        do {
            guard try keychain.read()?.isEmpty == false else {
                hasAPIKey = false
                phase = .failed(AppStateError.missingAPIKey.localizedDescription)
                return
            }
        } catch {
            phase = .failed("Не удалось прочитать API key: \(error.localizedDescription)")
            return
        }
        let shouldEnableMicrophone = includesMicrophone
        guard await AudioCaptureSession.requestMicrophoneAccess() else {
            phase = .failed("Разрешите доступ к микрофону в System Settings → Privacy & Security")
            return
        }

        var workingDirectory: URL?
        do {
            let session = try makeWorkingSession()
            workingDirectory = session.directory
            try capture.start(
                in: session.directory,
                includeMicrophone: true,
                microphoneEnabled: shouldEnableMicrophone
            )
            sessionDirectory = session.directory
            sessionFileStem = session.fileStem
            sessionAudioQuality = selectedAudioQuality
            sessionStartedUptime = ProcessInfo.processInfo.systemUptime
            microphoneVolumePoints = [
                AudioVolumePoint(time: 0, volume: Float(microphoneVolume))
            ]
            systemVolumePoints = [
                AudioVolumePoint(time: 0, volume: Float(systemAudioVolume))
            ]
            lastRecordingURL = nil
            lastTranscriptURL = nil
            startedAt = Date()
            phase = .recording
        } catch {
            if let workingDirectory {
                Self.removeWorkingSession(at: workingDirectory)
            }
            sessionAudioQuality = nil
            clearVolumeAutomation()
            phase = .failed(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let sources = capture.stop()
        startedAt = nil
        phase = .processing("Сведение аудио…")

        guard let directory = sessionDirectory,
              let fileStem = sessionFileStem,
              let audioQuality = sessionAudioQuality else {
            if let sessionDirectory { Self.removeWorkingSession(at: sessionDirectory) }
            sessionDirectory = nil
            sessionFileStem = nil
            sessionAudioQuality = nil
            clearVolumeAutomation()
            phase = .failed(AppStateError.missingSession.localizedDescription)
            return
        }
        let microphoneAutomation = microphoneVolumePoints
        let systemAutomation = systemVolumePoints
        sessionDirectory = nil
        sessionFileStem = nil
        sessionAudioQuality = nil
        clearVolumeAutomation()
        let shouldSaveAudio = savesAudioRecording
        let shouldCopyTranscript = copiesTranscriptToClipboard
        let audioOutputDirectory = audioDirectoryURL
        let transcriptOutputDirectory = transcriptsDirectoryURL

        Task {
            do {
                defer {
                    Self.removeWorkingSession(at: directory)
                }

                let workingRecordingURL = directory.appendingPathComponent("recording.m4a")
                let volumeAutomation = Dictionary(uniqueKeysWithValues: sources.map { source in
                    let points = source.lastPathComponent == AudioCaptureSession.microphoneSourceFilename
                        ? microphoneAutomation
                        : systemAutomation
                    return (source, points)
                })
                try await exporter.mixToM4A(
                    sources: sources,
                    destination: workingRecordingURL,
                    quality: audioQuality,
                    volumeAutomation: volumeAutomation
                )

                if shouldSaveAudio {
                    try FileManager.default.createDirectory(
                        at: audioOutputDirectory,
                        withIntermediateDirectories: true
                    )
                    let recordingURL = uniqueOutputURL(
                        directory: audioOutputDirectory,
                        fileStem: fileStem,
                        fileExtension: "m4a"
                    )
                    try FileManager.default.copyItem(at: workingRecordingURL, to: recordingURL)
                    lastRecordingURL = recordingURL
                } else {
                    lastRecordingURL = nil
                }

                phase = .processing("Подготовка к отправке…")
                let uploadFiles = try await chunker.uploadFiles(
                    for: workingRecordingURL,
                    quality: audioQuality
                )
                guard let key = try keychain.read(), !key.isEmpty else {
                    throw AppStateError.missingAPIKey
                }
                let client = OpenAITranscriptionClient(apiKey: key)

                var results: [String] = []
                for (index, file) in uploadFiles.enumerated() {
                    phase = .processing(
                        uploadFiles.count == 1
                            ? "Транскрибирование…"
                            : "Транскрибирование \(index + 1) из \(uploadFiles.count)…"
                    )
                    let prompt = selectedModel == .diarize ? nil : results.last
                    let text = try await client.transcribe(
                        fileURL: file,
                        model: selectedModel,
                        prompt: prompt
                    )
                    if !text.isEmpty { results.append(text) }
                }

                let transcript = results.joined(separator: "\n\n")
                try FileManager.default.createDirectory(
                    at: transcriptOutputDirectory,
                    withIntermediateDirectories: true
                )
                let transcriptURL = uniqueOutputURL(
                    directory: transcriptOutputDirectory,
                    fileStem: fileStem,
                    fileExtension: "txt"
                )
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
                lastTranscriptURL = transcriptURL
                if shouldCopyTranscript { copyToPasteboard(transcript) }
                phase = .done(copied: shouldCopyTranscript)
                notifyFinished(copied: shouldCopyTranscript)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func revealLastResult() {
        guard let url = lastTranscriptURL ?? lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func resetStatus() {
        if !isRecording && !isBusy { phase = .idle }
    }

    private func makeWorkingSession() throws -> (directory: URL, fileStem: String) {
        let root = Self.workingRootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileStem = formatter.string(from: Date())
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, fileStem)
    }

    private func uniqueOutputURL(directory: URL, fileStem: String, fileExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(fileStem).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(fileStem)-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func recordVolumeChange(microphone: Bool) {
        guard isRecording, let sessionStartedUptime else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - sessionStartedUptime)
        let volume = Float(microphone ? microphoneVolume : systemAudioVolume)
        if microphone {
            appendVolumePoint(
                AudioVolumePoint(time: elapsed, volume: volume),
                to: &microphoneVolumePoints
            )
        } else {
            appendVolumePoint(
                AudioVolumePoint(time: elapsed, volume: volume),
                to: &systemVolumePoints
            )
        }
    }

    private func appendVolumePoint(
        _ point: AudioVolumePoint,
        to points: inout [AudioVolumePoint]
    ) {
        if points.count > 1,
           let last = points.last,
           point.time - last.time < Self.minimumVolumePointInterval {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }
    }

    private func clearVolumeAutomation() {
        sessionStartedUptime = nil
        microphoneVolumePoints = []
        systemVolumePoints = []
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func notifyFinished(copied: Bool) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = "Transcribator"
            content.body = copied ? "Транскрипция готова и скопирована" : "Транскрипция готова"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func savedDirectory(forKey key: String, defaultURL: URL) -> URL {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
            return defaultURL
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func savedCoefficient(forKey key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        let value = UserDefaults.standard.double(forKey: key)
        return value.isFinite ? min(1, max(0, value)) : defaultValue
    }

    private static func defaultDocumentsRoot() -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents
            .appendingPathComponent("Transcribator", isDirectory: true)
            .standardizedFileURL
    }

    private static func defaultAudioDirectory() -> URL {
        defaultDocumentsRoot().appendingPathComponent("Audio", isDirectory: true)
    }

    private static func defaultTranscriptsDirectory() -> URL {
        defaultDocumentsRoot().appendingPathComponent("Transcripts", isDirectory: true)
    }

    private static func workingRootDirectory() -> URL {
        workingContainerDirectory().appendingPathComponent("Work", isDirectory: true)
    }

    private static func workingContainerDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Transcribator Mac", isDirectory: true)
            .standardizedFileURL
    }

    private static func removeStaleWorkingFiles() {
        try? FileManager.default.removeItem(at: workingRootDirectory())
        removeDirectoryIfEmpty(at: workingContainerDirectory())
    }

    private static func removeWorkingSession(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        removeDirectoryIfEmpty(at: workingRootDirectory())
        removeDirectoryIfEmpty(at: workingContainerDirectory())
    }

    private static func removeDirectoryIfEmpty(at directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

enum AppStateError: LocalizedError {
    case missingSession
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingSession: "Не найдена текущая запись"
        case .missingAPIKey: "OpenAI API key не найден в Keychain"
        }
    }
}

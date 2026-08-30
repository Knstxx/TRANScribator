import AppKit
import Foundation
import SwiftUI
import TranscribatorCore
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case processing(String)
        case done(copied: Bool)
        case cancelled(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var hasAPIKey = false
    @Published private(set) var lastTranscriptURL: URL?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var selectedMediaFile: MediaFileInfo?
    @Published private(set) var isFileTranscribing = false
    @Published private(set) var isInspectingMediaFile = false
    @Published var filePrompt = ""
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
    private let mediaPreparer = MediaFilePreparer()
    private let transcriptionPipeline = AudioTranscriptionPipeline()
    private let keychain = KeychainStore()
    private var sessionDirectory: URL?
    private var sessionFileStem: String?
    private var sessionAudioQuality: AudioQuality?
    private var sessionStartedUptime: TimeInterval?
    private var microphoneVolumePoints: [AudioVolumePoint] = []
    private var systemVolumePoints: [AudioVolumePoint] = []
    private var fileTranscriptionTask: Task<Void, Never>?
    private var mediaInspectionTask: Task<Void, Never>?

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
        case .cancelled(let text): text
        case .failed(let message): message
        }
    }

    var iconName: String {
        switch phase {
        case .recording:
            isMicrophoneMuted ? "waveform.badge.xmark" : "record.circle.fill"
        case .processing: "waveform.badge.magnifyingglass"
        case .done: "checkmark.circle"
        case .cancelled: "xmark.circle"
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

    func chooseMediaFile() {
        guard !isRecording, !isBusy, !isFileTranscribing, !isInspectingMediaFile else { return }

        let panel = NSOpenPanel()
        panel.title = "Транскрибировать аудио или видео"
        panel.prompt = "Выбрать"
        panel.message = "Видео останется на Mac: приложение извлечёт и отправит только аудиодорожку."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie]

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        let standardizedURL = sourceURL.standardizedFileURL
        isInspectingMediaFile = true
        phase = .processing("Проверка выбранного файла…")

        let task = Task { [weak self] in
            guard let self else { return }
            await self.inspectMediaFile(at: standardizedURL)
        }
        mediaInspectionTask = task
    }

    private func inspectMediaFile(at sourceURL: URL) async {
        defer {
            mediaInspectionTask = nil
            isInspectingMediaFile = false
        }
        do {
            selectedMediaFile = try await mediaPreparer.inspect(sourceURL)
            filePrompt = ""
            phase = .idle
        } catch is CancellationError {
            phase = .cancelled("Выбор файла отменён")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancelMediaInspection() {
        guard isInspectingMediaFile, let task = mediaInspectionTask else { return }
        phase = .processing("Отмена загрузки файла…")
        task.cancel()
    }

    func clearSelectedMediaFile() {
        guard !isFileTranscribing, !isInspectingMediaFile else { return }
        selectedMediaFile = nil
        filePrompt = ""
        resetStatus()
    }

    func transcribeSelectedMediaFile() {
        guard let media = selectedMediaFile,
              !isRecording,
              !isBusy,
              !isInspectingMediaFile else { return }
        guard hasAPIKey else {
            phase = .failed("Сначала сохраните OpenAI API key")
            return
        }

        let apiKey: String
        do {
            guard let value = try keychain.read(), !value.isEmpty else {
                hasAPIKey = false
                phase = .failed(AppStateError.missingAPIKey.localizedDescription)
                return
            }
            apiKey = value
        } catch {
            phase = .failed("Не удалось прочитать API key: \(error.localizedDescription)")
            return
        }

        let session: (directory: URL, fileStem: String)
        do {
            session = try makeWorkingSession(
                fileStem: Self.safeFileStem(for: media.sourceURL)
            )
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let model = selectedModel
        let quality = selectedAudioQuality
        let prompt = filePrompt
        let transcriptOutputDirectory = transcriptsDirectoryURL
        let shouldCopyTranscript = copiesTranscriptToClipboard

        isFileTranscribing = true
        phase = .processing(
            media.kind == .video ? "Извлечение аудиодорожки…" : "Подготовка аудио…"
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runFileTranscription(
                media: media,
                directory: session.directory,
                fileStem: session.fileStem,
                apiKey: apiKey,
                model: model,
                quality: quality,
                initialPrompt: prompt,
                transcriptOutputDirectory: transcriptOutputDirectory,
                shouldCopyTranscript: shouldCopyTranscript
            )
        }
        fileTranscriptionTask = task
    }

    func cancelFileTranscription() {
        guard isFileTranscribing, let task = fileTranscriptionTask else { return }
        phase = .processing("Отмена обработки файла…")
        task.cancel()
    }

    private func runFileTranscription(
        media: MediaFileInfo,
        directory: URL,
        fileStem: String,
        apiKey: String,
        model: TranscriptionModel,
        quality: AudioQuality,
        initialPrompt: String,
        transcriptOutputDirectory: URL,
        shouldCopyTranscript: Bool
    ) async {
        var createdTranscriptURL: URL?
        defer {
            fileTranscriptionTask = nil
            isFileTranscribing = false
        }

        do {
            let preparedAudioURL = directory.appendingPathComponent("prepared.m4a")
            try await mediaPreparer.prepare(
                sourceURL: media.sourceURL,
                destinationURL: preparedAudioURL,
                quality: quality
            )
            try Task.checkCancellation()

            let client = OpenAITranscriptionClient(apiKey: apiKey)
            let transcript = try await transcriptionPipeline.transcribe(
                audioURL: preparedAudioURL,
                quality: quality,
                model: model,
                initialPrompt: initialPrompt,
                client: client
            ) { [weak self] progress in
                guard let self else { return }
                switch progress {
                case .preparingUploads:
                    self.phase = .processing("Подготовка к отправке…")
                case .transcribing(let current, let total):
                    self.phase = .processing(
                        total == 1
                            ? "Транскрибирование файла…"
                            : "Транскрибирование файла \(current) из \(total)…"
                    )
                }
            }
            try Task.checkCancellation()

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
            createdTranscriptURL = transcriptURL
            try Task.checkCancellation()
            try Self.removeWorkingSession(at: directory)
            try Task.checkCancellation()
            lastTranscriptURL = transcriptURL
            if shouldCopyTranscript { copyToPasteboard(transcript) }
            phase = .done(copied: shouldCopyTranscript)
            notifyFinished(copied: shouldCopyTranscript)
        } catch is CancellationError {
            if let createdTranscriptURL {
                try? FileManager.default.removeItem(at: createdTranscriptURL)
                if lastTranscriptURL == createdTranscriptURL { lastTranscriptURL = nil }
            }
            do {
                try Self.removeWorkingSession(at: directory)
                phase = .cancelled("Транскрибация файла отменена")
            } catch {
                phase = .failed(
                    "Обработка отменена, но временные файлы удалить не удалось: \(error.localizedDescription)"
                )
            }
        } catch {
            let operationError = error
            do {
                try Self.removeWorkingSession(at: directory)
                phase = .failed(operationError.localizedDescription)
            } catch {
                phase = .failed(
                    "\(operationError.localizedDescription). Временные файлы удалить не удалось: \(error.localizedDescription)"
                )
            }
        }
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
                try? Self.removeWorkingSession(at: workingDirectory)
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
            if let sessionDirectory { try? Self.removeWorkingSession(at: sessionDirectory) }
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
        let model = selectedModel

        Task {
            do {
                defer {
                    try? Self.removeWorkingSession(at: directory)
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

                guard let key = try keychain.read(), !key.isEmpty else {
                    throw AppStateError.missingAPIKey
                }
                let client = OpenAITranscriptionClient(apiKey: key)
                let transcript = try await transcriptionPipeline.transcribe(
                    audioURL: workingRecordingURL,
                    quality: audioQuality,
                    model: model,
                    client: client
                ) { [weak self] progress in
                    guard let self else { return }
                    switch progress {
                    case .preparingUploads:
                        self.phase = .processing("Подготовка к отправке…")
                    case .transcribing(let current, let total):
                        self.phase = .processing(
                            total == 1
                                ? "Транскрибирование…"
                                : "Транскрибирование \(current) из \(total)…"
                        )
                    }
                }
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

    func cancelRecording() {
        guard isRecording else { return }

        _ = capture.stop()
        let directory = sessionDirectory
        startedAt = nil
        sessionDirectory = nil
        sessionFileStem = nil
        sessionAudioQuality = nil
        clearVolumeAutomation()

        guard let directory else {
            phase = .failed(AppStateError.missingSession.localizedDescription)
            return
        }
        do {
            try Self.removeWorkingSession(at: directory)
            phase = .cancelled("Запись отменена · аудио удалено")
        } catch {
            phase = .failed(
                "Запись остановлена, но временные файлы удалить не удалось: \(error.localizedDescription)"
            )
        }
    }

    func revealLastResult() {
        guard let url = lastTranscriptURL ?? lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func resetStatus() {
        if !isRecording && !isBusy { phase = .idle }
    }

    private func makeWorkingSession(
        fileStem suppliedFileStem: String? = nil
    ) throws -> (directory: URL, fileStem: String) {
        let root = Self.workingRootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fileStem: String
        if let suppliedFileStem, !suppliedFileStem.isEmpty {
            fileStem = suppliedFileStem
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            fileStem = formatter.string(from: Date())
        }
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

    private static func safeFileStem(for sourceURL: URL) -> String {
        let original = sourceURL.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_"))
        let sanitizedScalars = original.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        var sanitized = String(sanitizedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        return sanitized.isEmpty ? "Транскрипция" : sanitized
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
        try? removeDirectoryIfEmpty(at: workingContainerDirectory())
        removeStaleTemporaryDirectories()
    }

    private static func removeStaleTemporaryDirectories() {
        let prefixes = [
            "TranscribatorRecovery-",
            "TranscribatorCoreChecks-",
            "TranscribatorCaptureSmoke-",
            "TranscribatorCaptureCancelSmoke-"
        ]
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for candidate in candidates where prefixes.contains(where: candidate.lastPathComponent.hasPrefix) {
            guard let values = try? candidate.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private static func removeWorkingSession(at directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try removeDirectoryIfEmpty(at: workingRootDirectory())
        try removeDirectoryIfEmpty(at: workingContainerDirectory())
    }

    private static func removeDirectoryIfEmpty(at directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard contents.isEmpty else { return }
        try FileManager.default.removeItem(at: directory)
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

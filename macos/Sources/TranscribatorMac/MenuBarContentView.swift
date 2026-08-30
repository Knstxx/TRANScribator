import SwiftUI
import TranscribatorCore

struct MenuBarContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var settingsExpanded = false
    @State private var fileSectionExpanded = false
    @State private var confirmingRecordingCancellation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            modelPicker
            microphoneToggle
            recordButton
            if state.isRecording {
                recordingCancellationSection
            } else {
                fileTranscriptionSection
            }
            if !state.hasAPIKey {
                Label("Добавьте OpenAI API key в настройках", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if state.lastTranscriptURL != nil || state.lastRecordingURL != nil {
                Button("Показать последний результат в Finder") {
                    state.revealLastResult()
                }
            }

            if settingsExpanded {
                Divider()
                SettingsView()
                Divider()
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settingsExpanded = false
                        }
                    } label: {
                        Label("Свернуть настройки", systemImage: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Выйти") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(state.isRecording || state.isBusy)
                }
            } else {
                Divider()
                HStack {
                    Button("Настройки…") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            fileSectionExpanded = false
                            settingsExpanded = true
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.isFileTranscribing || state.isInspectingMediaFile)

                    Spacer()

                    Button("Выйти") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(state.isRecording || state.isBusy)
                }
            }
        }
        .padding(16)
        .frame(width: 390)
        .onChange(of: state.isRecording) { _, isRecording in
            if !isRecording { confirmingRecordingCancellation = false }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: state.iconName)
                .font(.title2)
                .foregroundStyle(state.isRecording ? .red : .primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribator")
                    .font(.headline)
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let startedAt = state.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(from: startedAt, to: context.date))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer()
        }
    }

    private var modelPicker: some View {
        Picker("Модель", selection: $state.selectedModel) {
            ForEach(TranscriptionModel.allCases) { model in
                Text(model.title).tag(model)
            }
        }
        .pickerStyle(.menu)
        .disabled(state.isRecording || state.isBusy)
    }

    private var microphoneToggle: some View {
        Toggle(isOn: $state.includesMicrophone) {
            Label(
                microphoneLabel,
                systemImage: state.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
            )
        }
        .toggleStyle(.switch)
        .disabled(state.isBusy)
        .help("Добавлять ваш голос с микрофона в запись")
    }

    private var microphoneLabel: String {
        if !state.includesMicrophone { return "Микрофон выключен" }
        if state.microphoneVolume == 0 { return "Микрофон включён · громкость 0" }
        return "Микрофон включён"
    }

    private var recordButton: some View {
        Button(action: state.toggleRecording) {
            Label(
                state.isRecording ? "Остановить и транскрибировать" : "Начать запись",
                systemImage: state.isRecording ? "stop.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.isRecording ? .red : .accentColor)
        .disabled(state.isBusy)
    }

    @ViewBuilder
    private var recordingCancellationSection: some View {
        if confirmingRecordingCancellation {
            VStack(alignment: .leading, spacing: 8) {
                Text("Удалить текущую запись?")
                    .font(.subheadline.weight(.semibold))
                Text("Аудио будет удалено, транскрибация и запрос к API не запустятся.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Не удалять") {
                        confirmingRecordingCancellation = false
                    }
                    Spacer()
                    Button("Удалить запись", role: .destructive) {
                        state.cancelRecording()
                    }
                }
            }
            .padding(10)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Button(role: .destructive) {
                confirmingRecordingCancellation = true
            } label: {
                Label("Отменить запись", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Остановить запись, удалить временное аудио и не обращаться к API")
        }
    }

    @ViewBuilder
    private var fileTranscriptionSection: some View {
        if fileSectionExpanded || state.isFileTranscribing || state.isInspectingMediaFile {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Транскрибировать файл", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !state.isFileTranscribing, !state.isInspectingMediaFile {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                fileSectionExpanded = false
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Свернуть раздел")
                    }
                }

                if state.isInspectingMediaFile {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Чтение аудиодорожки и метаданных…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        state.cancelMediaInspection()
                    } label: {
                        Label("Отменить загрузку файла", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if let media = state.selectedMediaFile {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.sourceURL.lastPathComponent)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(mediaDescription(media))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("На сервер отправится только временный mono M4A в выбранном качестве; исходный файл не изменится.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if state.selectedModel.supportsPrompt {
                        TextField(
                            "Контекст: имена, термины, язык (необязательно)",
                            text: $state.filePrompt
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(state.isFileTranscribing)
                    } else {
                        Text("Для модели с разделением по говорящим контекст не поддерживается.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if state.isFileTranscribing {
                        Button(role: .destructive) {
                            state.cancelFileTranscription()
                        } label: {
                            Label("Отменить обработку файла", systemImage: "xmark.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        HStack {
                            Button("Выбрать другой…") { state.chooseMediaFile() }
                            Button("Убрать") { state.clearSelectedMediaFile() }
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            state.transcribeSelectedMediaFile()
                        } label: {
                            Label("Транскрибировать выбранный файл", systemImage: "waveform.badge.magnifyingglass")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy || !state.hasAPIKey)
                    }
                } else {
                    Text("Поддерживаются аудио и видео, которые открывает macOS. Видеодорожка никуда не загружается.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        state.chooseMediaFile()
                    } label: {
                        Label("Выбрать аудио или видео…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
                }
            }
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settingsExpanded = false
                    fileSectionExpanded = true
                }
                if state.selectedMediaFile == nil {
                    state.chooseMediaFile()
                }
            } label: {
                Label("Транскрибировать файл…", systemImage: "doc.badge.plus")
            }
            .disabled(state.isBusy)
        }
    }

    private func mediaDescription(_ media: MediaFileInfo) -> String {
        let kind = media.kind == .video ? "Видео · будет извлечено аудио" : "Аудио"
        let bytes = ByteCountFormatter.string(fromByteCount: media.fileSize, countStyle: .file)
        return "\(kind) · \(duration(media.durationSeconds)) · \(bytes)"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

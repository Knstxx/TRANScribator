import AppKit
import SwiftUI
import TranscribatorCore

struct MenuBarContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var settingsExpanded = false
    @State private var fileSectionExpanded = false
    @State private var confirmingRecordingCancellation = false

    init(settingsExpanded: Bool = false) {
        _settingsExpanded = State(initialValue: settingsExpanded)
    }

    var body: some View {
        FittingMenuScrollView { panel }
            .onDisappear { settingsExpanded = false }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppStatusHeader(status: state.status, icon: AppBranding.appIcon, startedAt: state.startedAt)
            Divider()
            modelPicker
            if !state.canSelectGPTApp && !state.isCheckingChatGPT {
                Text("GPT App: \(state.chatGPTStatusText)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            RecordingAudioControls(
                audio: state.audioStatus,
                microphoneEnabled: Binding(
                    get: { !state.audioStatus.isMicrophoneMuted },
                    set: state.setMicrophoneEnabled
                ),
                systemAudioEnabled: Binding(
                    get: { !state.audioStatus.isSystemAudioMuted },
                    set: state.setSystemAudioEnabled
                ),
                microphoneVolume: $state.microphoneVolume,
                systemAudioVolume: $state.systemAudioVolume,
                isRecording: state.isRecording,
                isBusy: state.isBusy
            )
            recordButton
            if state.isRecording {
                recordingCancellationSection
            } else {
                fileTranscriptionSection
            }
            if let message = state.authorizationRequiredMessage {
                Label(message, systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if state.lastTranscriptURL != nil || state.lastRecordingURL != nil {
                Button("Показать последний результат в Finder") {
                    state.revealLastResult()
                }
            }
            if let notice = state.lastResultNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .onAppear {
            state.refreshAPIKeyStatus()
            state.refreshChatGPTStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshAPIKeyStatus()
            state.refreshChatGPTStatus()
        }
        .onChange(of: state.isRecording) { _, isRecording in
            if !isRecording { confirmingRecordingCancellation = false }
        }
    }

    private var modelPicker: some View {
        Picker("Модель", selection: $state.selectedModel) {
            ForEach(TranscriptionModel.allCases) { model in
                Text(model == .gptApp && !state.canSelectGPTApp
                     ? "GPT App · недоступно" : model.title).tag(model)
                    .disabled(model == .gptApp && !state.canSelectGPTApp)
                    .help(model == .gptApp ? state.chatGPTStatusText : model.title)
            }
        }
        .pickerStyle(.menu)
        .disabled(state.isRecording || state.isBusy)
    }

    private var recordButton: some View {
        Button(action: state.toggleRecording) {
            Label(
                state.isRecording ? "Остановить и транскрибировать" : state.isBusy ? "Обработка…" : "Начать запись",
                systemImage: state.isRecording ? "stop.fill" : state.isBusy ? "arrow.triangle.2.circlepath" : "record.circle"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.isRecording ? .red : .accentColor)
        .disabled(state.isBusy || (!state.isRecording && (!state.canUseSelectedModel || !state.audioStatus.hasAudibleSource)))
    }

    @ViewBuilder
    private var recordingCancellationSection: some View {
        if confirmingRecordingCancellation {
            VStack(alignment: .leading, spacing: 8) {
                Text("Удалить текущую запись?")
                    .font(.subheadline.weight(.semibold))
                Text("Аудио будет удалено без отправки на транскрибацию.")
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
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .help("Остановить и удалить запись без отправки на транскрибацию")
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
                        Text(state.selectedModel == .gptApp
                            ? "GPT App распознаёт речь автоматически; дополнительный контекст не поддерживается."
                            : "Для модели с разделением по говорящим контекст не поддерживается.")
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
                        .disabled(state.isBusy || !state.canUseSelectedModel)
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

}

import SwiftUI
import TranscribatorCore

struct MenuBarContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var settingsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            modelPicker
            microphoneToggle
            recordButton
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
                }
            } else {
                Divider()
                HStack {
                    Button("Настройки…") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settingsExpanded = true
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Выйти") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 390)
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

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

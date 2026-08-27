import AppKit
import SwiftUI
import TranscribatorCore

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var apiKeyDraft = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("OpenAI API")
                    .font(.headline)

                HStack {
                    Label(
                        state.hasAPIKey ? "API key сохранён в Keychain" : "API key не добавлен",
                        systemImage: state.hasAPIKey ? "checkmark.circle.fill" : "key"
                    )
                    .foregroundStyle(state.hasAPIKey ? .green : .secondary)
                    Spacer()
                    if state.hasAPIKey {
                        Button("Удалить", role: .destructive) { deleteAPIKey() }
                    }
                }

                SecureField(state.hasAPIKey ? "Новый ключ для замены" : "sk-…", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)

                Button(state.hasAPIKey ? "Заменить API key" : "Сохранить API key") {
                    saveAPIKey()
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Divider()

                Text("Обработка")
                    .font(.headline)

                Toggle("Копировать готовую транскрипцию", isOn: $state.copiesTranscriptToClipboard)

                Picker("Качество аудио", selection: $state.selectedAudioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .disabled(state.isRecording || state.isBusy)

                Text(state.selectedAudioQuality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Громкость дорожек")
                    .font(.headline)

                volumeSlider(
                    title: "Мой голос",
                    systemImage: "mic.fill",
                    value: $state.microphoneVolume
                )

                volumeSlider(
                    title: "Остальной звук",
                    systemImage: "speaker.wave.2.fill",
                    value: $state.systemAudioVolume
                )

                Text("Новое значение применяется с момента изменения. При 1.00 на обеих громких дорожках возможен перегруз.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Сохранение")
                    .font(.headline)

                Toggle("Сохранять аудиозапись после транскрибации", isOn: $state.savesAudioRecording)

                outputDirectoryRow(
                    title: "Аудиозаписи (.m4a)",
                    url: state.audioDirectoryURL,
                    choose: state.chooseAudioDirectory,
                    reset: state.resetAudioDirectory,
                    isEnabled: state.savesAudioRecording
                )

                Divider()

                outputDirectoryRow(
                    title: "Транскрипты (.txt)",
                    url: state.transcriptsDirectoryURL,
                    choose: state.chooseTranscriptsDirectory,
                    reset: state.resetTranscriptsDirectory,
                    isEnabled: true
                )

                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedbackIsError ? .red : .secondary)
                }
            }
            .padding(.trailing, 6)
        }
        .frame(height: 460)
    }

    @ViewBuilder
    private func volumeSlider(
        title: String,
        systemImage: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0 ... 1, step: 0.05)
        }
    }

    @ViewBuilder
    private func outputDirectoryRow(
        title: String,
        url: URL,
        choose: @escaping () -> Bool,
        reset: @escaping () -> Void,
        isEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "folder")
                .font(.subheadline.weight(.semibold))

            Text(url.path(percentEncoded: false))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                Button("Изменить…") {
                    if choose() { showFeedback("Папка сохранения изменена") }
                }
                Button("Сбросить") {
                    reset()
                    showFeedback("Восстановлена папка по умолчанию")
                }
                Spacer()
                Button("Finder") {
                    try? FileManager.default.createDirectory(
                        at: url,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func saveAPIKey() {
        do {
            try state.saveAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            showFeedback("API key сохранён в macOS Keychain")
        } catch {
            showFeedback(error.localizedDescription, isError: true)
        }
    }

    private func deleteAPIKey() {
        do {
            try state.deleteAPIKey()
            apiKeyDraft = ""
            showFeedback("API key удалён")
        } catch {
            showFeedback(error.localizedDescription, isError: true)
        }
    }

    private func showFeedback(_ text: String, isError: Bool = false) {
        feedback = text
        feedbackIsError = isError
    }
}

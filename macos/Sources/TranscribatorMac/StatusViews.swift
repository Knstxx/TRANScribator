import AppKit
import SwiftUI
import TranscribatorCore

struct AppStatusHeader: View {
    let status: AppStatus
    let icon: NSImage?
    let startedAt: Date?

    private var statusColor: Color {
        switch status.tone {
        case .neutral: .secondary
        case .recording, .failure: .red
        case .working: .accentColor
        case .success: .green
        case .warning: .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribator")
                    .font(.headline)
                Label {
                    Text(status.statusText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: status.symbolName)
                        .foregroundStyle(statusColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(status.statusText)
                if let startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: startedAt, to: context.date))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Длительность записи")
                            .accessibilityValue(Self.elapsed(from: startedAt, to: context.date))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

struct RecordingAudioControls: View {
    enum Source { case microphone, systemAudio }

    let audio: RecordingAudioStatus
    @Binding var microphoneEnabled: Bool
    @Binding var systemAudioEnabled: Bool
    @Binding var microphoneVolume: Double
    @Binding var systemAudioVolume: Double
    let isRecording: Bool
    let isBusy: Bool
    @State var expandedSource: Source? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            sourceRow(
                source: .microphone,
                title: "Микрофон",
                detail: audio.microphoneDetail,
                symbol: audio.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                enabled: $microphoneEnabled,
                volume: $microphoneVolume
            )
            Divider().padding(.leading, 22)
            sourceRow(
                source: .systemAudio,
                title: "Системный звук",
                detail: audio.systemAudioDetail,
                symbol: audio.isSystemAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                enabled: $systemAudioEnabled,
                volume: $systemAudioVolume
            )
            if !isBusy, let warning = audio.warningText {
                Label("Оба источника выключены", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .help(warning)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: isBusy) { _, busy in
            if busy { expandedSource = nil }
        }
    }

    private func sourceRow(
        source: Source,
        title: String,
        detail: String,
        symbol: String,
        enabled: Binding<Bool>,
        volume: Binding<Double>
    ) -> some View {
        let isExpanded = expandedSource == source
        let shortDetail = detail == "Выключен" ? "Выкл." : detail == "Громкость 0%" ? "0%" : detail
        return VStack(spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 15)
                    .foregroundStyle(enabled.wrappedValue ? .primary : .secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 4)
                if enabled.wrappedValue || isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedSource = isExpanded ? nil : source
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(shortDetail)
                                .monospacedDigit()
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40, minHeight: 22, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(isBusy
                        ? "Недоступно во время обработки"
                        : "\(detail). Нажмите, чтобы настроить громкость")
                    .accessibilityLabel("Настроить громкость: \(title.lowercased())")
                    .accessibilityValue("\(detail), \(isExpanded ? "раскрыто" : "свёрнуто")")
                } else {
                    Text(shortDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40, minHeight: 22, alignment: .trailing)
                        .help(detail)
                        .accessibilityLabel(detail)
                }

                Toggle(title, isOn: Binding(
                    get: { enabled.wrappedValue },
                    set: { value in
                        enabled.wrappedValue = value
                        if !value, expandedSource == source { expandedSource = nil }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isBusy)
                .accessibilityLabel(title)
                .help(isBusy
                    ? "Недоступно во время обработки"
                    : "Включить или выключить \(title.lowercased()) в записи")
            }
            if expandedSource == source {
                Slider(value: volume, in: 0 ... 1, step: 0.05)
                    .controlSize(.mini)
                    .disabled(isBusy)
                    .padding(.leading, 22)
                    .padding(.trailing, 32)
                    .accessibilityLabel("Громкость: \(title.lowercased())")
                    .accessibilityValue("\(Int((volume.wrappedValue * 100).rounded())) процентов")
                    .help(isRecording
                        ? "Громкость в текущей записи; изменения применяются сразу"
                        : "Громкость для следующей записи")
            }
        }
    }
}

/// The expanded settings and long error messages must remain reachable on short displays.
struct FittingMenuScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 440

    private var maximumHeight: CGFloat {
        max(280, min(760, (NSScreen.main?.visibleFrame.height ?? 850) - 48))
    }

    var body: some View {
        ScrollView {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MenuContentHeightKey.self, value: geometry.size.height)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 390, height: min(contentHeight, maximumHeight))
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            if height > 0, abs(contentHeight - height) > 0.5 { contentHeight = height }
        }
    }
}

private struct MenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

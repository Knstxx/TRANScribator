import AppKit
import SwiftUI
import TranscribatorCore

// This standalone program imports only the pure status module and the real status views.
// It never instantiates AppState, a recorder, app delegate, or a displayed window.
private struct Scenario: Identifiable {
    let id: String
    let title: String
    let phase: TranscriptionPhase
    var microphoneEnabled = true
    var microphoneVolume = 0.8
    var systemAudioVolume = 1.0
    var hasAPIKey = true

    var audio: RecordingAudioStatus {
        RecordingAudioStatus(
            includesMicrophone: microphoneEnabled,
            microphoneVolume: microphoneVolume,
            systemAudioVolume: systemAudioVolume
        )
    }

    var status: AppStatus { AppStatus(phase: phase, audio: audio, hasAPIKey: hasAPIKey) }
    var isRecording: Bool { phase == .recording }
    var isBusy: Bool {
        if case .processing = phase { return true }
        return false
    }
}

@MainActor
private struct PreviewCard: View {
    let scenario: Scenario
    let icon: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scenario.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            AppStatusHeader(
                status: scenario.status,
                icon: icon,
                startedAt: scenario.isRecording ? Date().addingTimeInterval(-3672) : nil
            )
            Divider()
            RecordingAudioControls(
                audio: scenario.audio,
                microphoneEnabled: .constant(!scenario.audio.isMicrophoneMuted),
                systemAudioEnabled: .constant(!scenario.audio.isSystemAudioMuted),
                microphoneVolume: .constant(scenario.microphoneVolume),
                systemAudioVolume: .constant(scenario.systemAudioVolume),
                isRecording: scenario.isRecording,
                isBusy: scenario.isBusy
            )
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 390, height: 356, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct ContactSheet: View {
    let scenarios: [Scenario]
    let icon: NSImage
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcribator · реальные компоненты · \(scheme == .dark ? "тёмная" : "светлая") тема")
                .font(.headline)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<(scenarios.count / 2), id: \.self) { row in
                    GridRow {
                        PreviewCard(scenario: scenarios[row * 2], icon: icon)
                        PreviewCard(scenario: scenarios[row * 2 + 1], icon: icon)
                    }
                }
            }
        }
        .padding(16)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.90))
        .environment(\.colorScheme, scheme)
    }
}

@MainActor
private struct MenuIconSheet: View {
    let scenarios: [Scenario]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Строка меню · цветной бейдж · 18 × 18 pt")
                .font(.headline)
                .padding(16)
            ForEach(scenarios) { scenario in
                HStack(spacing: 0) {
                    Text(scenario.title)
                        .font(.system(size: 12))
                        .frame(width: 230, alignment: .leading)
                    iconCell(scenario, foreground: .black, background: Color(white: 0.96))
                    iconCell(scenario, foreground: .white, background: Color(white: 0.16))
                    iconCell(scenario, foreground: .white, background: Color(red: 0.0, green: 0.35, blue: 0.90))
                    Text("\(Int(AppBranding.menuBarIcon(for: scenario.status).size.width)) × 18 pt")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 105)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            Text("Слева направо: светлая панель, тёмная панель, выбранный пункт. PNG сохранён в масштабе 2×.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .background(.white)
        .environment(\.colorScheme, .light)
    }

    private func iconCell(_ scenario: Scenario, foreground: Color, background: Color) -> some View {
        let image = AppBranding.menuBarIcon(for: scenario.status, isDarkAppearance: foreground == .white)
        return Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(foreground)
            .frame(width: 100, height: 28)
            .background(background)
    }
}

private enum PreviewError: Error {
    case missingIcon, missingSymbol(String), invalidTemplate(String), renderingFailed(String), invalidScrollSize(CGSize)
}

@main
@MainActor
private enum StatusPreview {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let icon = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
            throw PreviewError.missingIcon
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scenarios: [Scenario] = [
            Scenario(id: "idle", title: "01 · Готов к записи", phase: .idle),
            Scenario(id: "recording-both", title: "02 · Запись обоих источников", phase: .recording),
            Scenario(id: "recording-system", title: "03 · Микрофон выключен", phase: .recording, microphoneEnabled: false),
            Scenario(id: "recording-mic", title: "04 · Системный звук выключен", phase: .recording, systemAudioVolume: 0),
            Scenario(id: "recording-muted", title: "05 · Оба источника без звука", phase: .recording, microphoneVolume: 0, systemAudioVolume: 0),
            Scenario(id: "processing", title: "06 · Обработка", phase: .processing("Транскрибирование записи: фрагмент 2 из 3…")),
            Scenario(id: "failed", title: "07 · Длинная ошибка", phase: .failed("Не удалось подключиться к сервису транскрибации. Проверьте интернет-соединение и повторите попытку. Запись сохранена локально.")),
            Scenario(id: "done", title: "08 · Готово и скопировано", phase: .done(copied: true))
        ]
        let extraScenarios = [
            Scenario(id: "no-key", title: "API key отсутствует", phase: .idle, hasAPIKey: false),
            Scenario(id: "idle-muted", title: "До записи · оба выключены", phase: .idle, microphoneEnabled: false, systemAudioVolume: 0),
            Scenario(id: "cancelled", title: "Операция отменена", phase: .cancelled("Транскрипция отменена"))
        ]
        let allScenarios = scenarios + extraScenarios
        var symbols: Set<String> = ["mic.fill", "mic.slash.fill", "speaker.wave.2.fill", "speaker.slash.fill", "exclamationmark.triangle.fill", "checkmark", "xmark", "exclamationmark"]
        for scenario in allScenarios {
            symbols.insert(scenario.status.symbolName)
            if let name = scenario.status.menuBarActivitySymbolName { symbols.insert(name) }
            if let name = scenario.status.menuBarAudioSymbolName { symbols.insert(name) }
            let image = AppBranding.menuBarIcon(for: scenario.status)
            let hasBadge = scenario.status.menuBarActivitySymbolName != nil || scenario.status.menuBarAudioSymbolName != nil
            guard image.isTemplate == !hasBadge, image.size == NSSize(width: 18, height: 18),
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
                throw PreviewError.invalidTemplate(scenario.id)
            }
            var visiblePixels = 0
            var coloredPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { visiblePixels += 1 }
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 {
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        if channels.max()! - channels.min()! > 0.2 { coloredPixels += 1 }
                    }
                }
            }
            guard visiblePixels > 30 else { throw PreviewError.invalidTemplate(scenario.id) }
            if hasBadge, scenario.id != "cancelled" {
                guard coloredPixels > 5 else { throw PreviewError.invalidTemplate("Missing badge color: \(scenario.id)") }
            }
            if hasBadge {
                guard image.tiffRepresentation != AppBranding.menuBarIcon(for: scenario.status, isDarkAppearance: true).tiffRepresentation else {
                    throw PreviewError.invalidTemplate("Appearance did not change: \(scenario.id)")
                }
            }
        }
        // A muted source must never make an active recording look idle or failed.
        let recordingSystem = scenarios[2]
        let idleSystem = Scenario(id: "idle-system", title: "", phase: .idle, microphoneEnabled: false)
        let recordingSilent = scenarios[4]
        let idleSilent = extraScenarios[1]
        for (active, inactive) in [(recordingSystem, idleSystem), (recordingSilent, idleSilent)] {
            guard AppBranding.menuBarIcon(for: active.status).tiffRepresentation
                != AppBranding.menuBarIcon(for: inactive.status).tiffRepresentation else {
                throw PreviewError.invalidTemplate("Recording indicator lost: \(active.id)")
            }
        }
        // The corner overlays must preserve the recognizable waveform on the left.
        let baseline = NSBitmapImageRep(data: AppBranding.menuBarIcon(for: scenarios[0].status).tiffRepresentation!)!
        for scenario in allScenarios {
            let bitmap = NSBitmapImageRep(data: AppBranding.menuBarIcon(for: scenario.status).tiffRepresentation!)!
            for y in 0..<baseline.pixelsHigh {
                for x in 0..<min(7, baseline.pixelsWide) {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    let expected = baseline.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    guard abs(alpha - expected) < 0.01 else {
                        throw PreviewError.invalidTemplate("Waveform obscured: \(scenario.id)")
                    }
                }
            }
        }
        for symbol in symbols.sorted() {
            guard NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
                throw PreviewError.missingSymbol(symbol)
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            try render(ContactSheet(scenarios: scenarios, icon: icon, scheme: scheme), to: output.appendingPathComponent("status-\(scheme == .light ? "light" : "dark").png"), scale: 1)
            for scenario in scenarios {
                try render(PreviewCard(scenario: scenario, icon: icon).environment(\.colorScheme, scheme), to: output.appendingPathComponent("\(scenario.id)-\(scheme == .light ? "light" : "dark").png"), scale: 2)
            }
            let suffix = scheme == .light ? "light" : "dark"
            for expanded in [false, true] {
                let compact = RecordingAudioControls(
                    audio: .init(includesMicrophone: false, microphoneVolume: 1, systemAudioVolume: 0.65),
                    microphoneEnabled: .constant(false),
                    systemAudioEnabled: .constant(true),
                    microphoneVolume: .constant(1),
                    systemAudioVolume: .constant(0.65),
                    isRecording: false,
                    isBusy: false,
                    expandedSource: expanded ? .systemAudio : nil
                )
                .frame(width: 358)
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                try render(compact, to: output.appendingPathComponent("audio-\(expanded ? "expanded" : "compact")-\(suffix).png"), scale: 2)
                if scheme == .light {
                    print("Audio block \(expanded ? "expanded" : "compact"): \(preparedHostingView(compact).frame.height - 24) pt high")
                }
            }
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        try renderMenuIcons(MenuIconSheet(scenarios: allScenarios), to: output.appendingPathComponent("menu-icons.png"))
        let shortMenu = FittingMenuScrollView { PreviewCard(scenario: scenarios[0], icon: icon) }
        let tallMenu = FittingMenuScrollView {
            VStack(spacing: 12) {
                PreviewCard(scenario: scenarios[4], icon: icon)
                PreviewCard(scenario: scenarios[6], icon: icon)
                PreviewCard(scenario: scenarios[7], icon: icon)
            }
        }
        let shortSize = preparedHostingView(shortMenu).frame.size
        let tallSize = preparedHostingView(tallMenu).frame.size
        guard shortSize.width == 390, abs(shortSize.height - 356) < 1,
              tallSize.width == 390, tallSize.height >= 280, tallSize.height <= 760,
              tallSize.height < 1092 else {
            throw PreviewError.invalidScrollSize(shortSize.height == 356 ? tallSize : shortSize)
        }
        try render(shortMenu, to: output.appendingPathComponent("scroll-short.png"), scale: 2)
        try render(tallMenu, to: output.appendingPathComponent("scroll-tall.png"), scale: 2)
        print("PASS: \(symbols.count) SF Symbols available; \(allScenarios.count) icon variants valid, including colored badges.")
        print("PASS: real scroll wrapper fits short content at \(shortSize) and bounds tall content at \(tallSize).")
        print("Rendered 8 real status/audio control cards in both themes and native menu bar icon variants into \(output.path)")
    }

    static func preparedHostingView<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: content)
        // Allow GeometryReader preference updates to settle in this isolated process.
        for _ in 0..<4 {
            hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return hostingView
    }

    static func renderMenuIcons<Content: View>(_ content: Content, to url: URL) throws {
        // Menu images have no native controls and can be rasterized sharply at 2×.
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PreviewError.renderingFailed(url.lastPathComponent)
        }
        try data.write(to: url)
    }

    static func render<Content: View>(_ content: Content, to url: URL, scale: CGFloat) throws {
        // ImageRenderer does not render AppKit-backed Slider and Toggle controls.
        // An unattached hosting view keeps these real controls, without showing a window.
        let hostingView = preparedHostingView(content)
        let size = hostingView.frame.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded(.up)),
            pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw PreviewError.renderingFailed(url.lastPathComponent) }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.renderingFailed(url.lastPathComponent)
        }
        try data.write(to: url)
    }
}

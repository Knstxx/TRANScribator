import AppKit
import SwiftUI

// Renders the real menu/settings views against MenuPreviewState.swift only.
// No production AppState, app delegate, shown window, or live app is involved.
@main
@MainActor
private enum MenuPreview {
    enum Failure: Error {
        case usage, invalidScrollCount(String, Int), invalidHeight(String, CGFloat)
        case rendering(String), translucentBackground(String)
        case missingIcon
    }

    static func main() {
        do { try run() }
        catch {
            fputs("Menu preview check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.usage }
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard AppBranding.appIcon != nil else { throw Failure.missingIcon }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            for expanded in [false, true] {
                let scenario = "recording-\(expanded ? "settings" : "collapsed")-\(suffix)"
                let state = AppState()
                let content = MenuBarContentView(settingsExpanded: expanded)
                    .environmentObject(state)
                    .environment(\.colorScheme, scheme)
                let hosting = prepare(content)
                let scrolls = descendants(of: hosting).compactMap { $0 as? NSScrollView }
                guard scrolls.count == 1 else { throw Failure.invalidScrollCount(scenario, scrolls.count) }
                guard hosting.frame.width == 390, hosting.frame.height > 250, hosting.frame.height <= 760 else {
                    throw Failure.invalidHeight(scenario, hosting.frame.height)
                }
                try render(hosting, to: output.appendingPathComponent("\(scenario).png"), scenario: scenario)
                print("PASS: \(scenario), size=\(hosting.frame.size), NSScrollView=\(scrolls.count), opaque panel.")

                if expanded {
                    // SwiftUI's unattached native scroll document is a zero-size
                    // adapter, so it cannot prove a wheel gesture reaches the
                    // bottom. Render the actual complete settings separately to
                    // inspect all rows, and verify they own no nested scroll.
                    let settingsContent = SettingsView()
                        .environmentObject(state)
                        .environment(\.colorScheme, scheme)
                        .frame(width: 358)
                        .padding(16)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let settingsHosting = prepare(settingsContent)
                    let nestedScrolls = descendants(of: settingsHosting).compactMap { $0 as? NSScrollView }
                    guard nestedScrolls.isEmpty else { throw Failure.invalidScrollCount(scenario, nestedScrolls.count) }
                    try render(settingsHosting, to: output.appendingPathComponent("settings-content-\(suffix).png"), scenario: scenario)
                    print("PASS: settings-content-\(suffix), NSScrollView=0, all settings rendered without a fixed viewport.")
                }
            }
        }
        print("Rendered real recording menus with collapsed/expanded settings in both themes into \(output.path).")
    }

    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    static func prepare<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: content)
        for _ in 0..<6 {
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            settle(hosting)
        }
        return hosting
    }

    static func settle(_ hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }

    static func render(_ hosting: NSView, to url: URL, scenario: String) throws {
        let size = hosting.frame.size
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded(.up)),
            pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw Failure.rendering(scenario) }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // Interior side padding belongs to the actual panel, not a fixture card.
        for y in [bitmap.pixelsHigh / 4, bitmap.pixelsHigh / 2, bitmap.pixelsHigh * 3 / 4] {
            guard (bitmap.colorAt(x: 16, y: y)?.alphaComponent ?? 0) >= 0.99 else {
                throw Failure.translucentBackground(scenario)
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.rendering(scenario)
        }
        try data.write(to: url)
    }
}

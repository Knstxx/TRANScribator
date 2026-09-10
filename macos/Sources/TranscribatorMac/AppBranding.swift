import AppKit
import TranscribatorCore

@MainActor
enum AppBranding {
    static let appIcon: NSImage? = Bundle.main
        .url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    private static var menuBarImages: [String: NSImage] = [:]

    static func menuBarIcon(for status: AppStatus, isDarkAppearance: Bool = false) -> NSImage {
        let isRecording = status.menuBarActivitySymbolName == "record.circle.fill"
        let overlaySymbol = isRecording
            ? status.menuBarAudioSymbolName ?? status.menuBarActivitySymbolName
            : status.menuBarActivitySymbolName ?? status.menuBarAudioSymbolName
        let showsRecordingDot = isRecording && status.menuBarAudioSymbolName != nil
        let hasAudioWarning = status.menuBarAudioSymbolName != nil
            && (isRecording || status.menuBarActivitySymbolName == nil)
        let badgeTone: AppStatusTone = hasAudioWarning ? .warning : status.tone
        let colorName: String
        let badgeColor: NSColor
        switch badgeTone {
        case .recording, .failure:
            colorName = "red"
            badgeColor = NSColor(srgbRed: 0.87, green: 0.17, blue: 0.21, alpha: 1)
        case .warning:
            colorName = "orange"
            badgeColor = NSColor(srgbRed: 0.79, green: 0.38, blue: 0.02, alpha: 1)
        case .working:
            colorName = "blue"
            badgeColor = NSColor(srgbRed: 0.00, green: 0.39, blue: 0.87, alpha: 1)
        case .success:
            colorName = "green"
            badgeColor = NSColor(srgbRed: 0.13, green: 0.56, blue: 0.29, alpha: 1)
        case .neutral:
            colorName = "gray"
            badgeColor = NSColor(srgbRed: 0.40, green: 0.43, blue: 0.46, alpha: 1)
        }
        let key = "\(overlaySymbol ?? "none"):\(showsRecordingDot):\(colorName):\(isDarkAppearance)"
        if let cached = menuBarImages[key] { return cached }

        // Remove decorative rings that are too fine to read in a corner badge.
        let compactSymbol: String?
        switch overlaySymbol {
        case "checkmark.circle.fill": compactSymbol = "checkmark"
        case "xmark.circle": compactSymbol = "xmark"
        case "exclamationmark.triangle.fill": compactSymbol = "exclamationmark"
        default: compactSymbol = overlaySymbol
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let badge = compactSymbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            (isDarkAppearance ? NSColor.white : NSColor.black).setFill()
            // A small, pixel-aligned version of the waveform-and-transcript emblem.
            // Colored states use an explicit mark tint for the menu bar's appearance.
            // The unbadged idle mark remains a native, automatically tinted template.
            let strokes: [NSRect] = [
                NSRect(x: 0, y: 6, width: 2, height: 6),
                NSRect(x: 3, y: 2, width: 2, height: 14),
                NSRect(x: 6, y: 5, width: 2, height: 8),
                NSRect(x: 10, y: 12, width: 8, height: 2),
                NSRect(x: 10, y: 8, width: 7, height: 2),
                NSRect(x: 10, y: 4, width: 5, height: 2)
            ]
            for rect in strokes {
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            func clearHalo(around rect: NSRect) {
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.saveGState()
                context.setBlendMode(.clear)
                context.fillEllipse(in: rect.insetBy(dx: -0.75, dy: -0.75))
                context.restoreGState()
            }

            // All states share the same footprint; status overlaps the transcript strokes.
            if overlaySymbol != nil {
                let badgeRect = NSRect(x: 9, y: 0, width: 9, height: 9)
                clearHalo(around: badgeRect)
                badgeColor.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
                if overlaySymbol == "record.circle.fill" {
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: badgeRect.insetBy(dx: 2.75, dy: 2.75)).fill()
                } else if let badge {
                    let glyphRect = badgeRect.insetBy(dx: 1.25, dy: 1.25)
                    let scale = min(glyphRect.width / badge.size.width, glyphRect.height / badge.size.height)
                    let size = NSSize(width: badge.size.width * scale, height: badge.size.height * scale)
                    badge.draw(in: NSRect(
                        x: glyphRect.midX - size.width / 2,
                        y: glyphRect.midY - size.height / 2,
                        width: size.width,
                        height: size.height
                    ))
                }
            }
            if showsRecordingDot {
                let dot = NSRect(x: 14, y: 14, width: 3, height: 3)
                clearHalo(around: dot)
                NSColor(srgbRed: 0.87, green: 0.17, blue: 0.21, alpha: 1).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = overlaySymbol == nil
        menuBarImages[key] = image
        return image
    }
}

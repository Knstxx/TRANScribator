import SwiftUI
import TranscribatorCore

@main
struct TranscribatorMacApp: App {
    @StateObject private var state = AppState()

    init() {
        if ExistingFileTranscriptionRunner.isRequested {
            Task { await ExistingFileTranscriptionRunner.runAndExit() }
        } else if CaptureSmokeRunner.isRequested {
            Task { await CaptureSmokeRunner.runAndExit() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(state)
        } label: {
            MenuBarStatusLabel(status: state.status)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: AppStatus

    var body: some View {
        let icon = AppBranding.menuBarIcon(for: status, isDarkAppearance: colorScheme == .dark)
        Image(nsImage: icon)
            .renderingMode(icon.isTemplate ? .template : .original)
            .accessibilityLabel(status.menuBarHelp)
            .accessibilityIdentifier("TranscribatorMenuBarStatus")
            .help(status.menuBarHelp)
    }
}

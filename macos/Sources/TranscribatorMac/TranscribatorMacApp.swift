import SwiftUI

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
            if state.isMicrophoneMuted {
                Image(systemName: "waveform.badge.xmark")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.red)
            } else {
                Image(systemName: state.iconName)
                    .symbolRenderingMode(state.isRecording ? .multicolor : .monochrome)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

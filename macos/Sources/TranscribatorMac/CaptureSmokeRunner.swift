import AppKit
import AVFoundation
import Darwin
import Foundation
import TranscribatorCore

enum CaptureSmokeRunner {
    private static let systemOnlyArgument = "--capture-smoke-system-only"
    private static let cancellationArgument = "--capture-cancel-smoke"

    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--capture-smoke")
            || arguments.contains(systemOnlyArgument)
            || arguments.contains(cancellationArgument)
    }

    @MainActor
    static func runAndExit() async {
        var testDirectory: URL?
        do {
            if ProcessInfo.processInfo.arguments.contains(cancellationArgument) {
                try await runCancellationSmoke()
                print("CAPTURE_CANCEL_SMOKE_OK cleaned=true apiRequested=false")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            }

            let includesMicrophone = !ProcessInfo.processInfo.arguments.contains(systemOnlyArgument)
            if includesMicrophone {
                guard await AudioCaptureSession.requestMicrophoneAccess() else {
                    throw CaptureSmokeError.microphoneDenied
                }
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscribatorCaptureSmoke-\(UUID().uuidString)", isDirectory: true)
            testDirectory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let capture = AudioCaptureSession()
            try capture.start(
                in: directory,
                includeMicrophone: includesMicrophone,
                microphoneEnabled: !includesMicrophone
            )

            let speaker = AVSpeechSynthesizer()
            if includesMicrophone {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                capture.setMicrophoneEnabled(true)
                speaker.speak(AVSpeechUtterance(string: "Transcribator microphone enabled test"))
                try await Task.sleep(nanoseconds: 2_000_000_000)
                capture.setMicrophoneEnabled(false)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                capture.setMicrophoneEnabled(true)
                speaker.speak(AVSpeechUtterance(string: "Transcribator microphone restored test"))
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                speaker.speak(AVSpeechUtterance(string: "Transcribator system audio capture test"))
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }

            let sources = capture.stop()
            guard !sources.isEmpty else { throw CaptureSmokeError.systemSourceMissing }

            var microphoneMetrics = "microphone=disabled"
            if includesMicrophone {
                guard let microphoneURL = sources.last else {
                    throw CaptureSmokeError.microphoneSourceMissing
                }
                let microphoneSize = (try microphoneURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                let microphoneRMS = try rms(of: microphoneURL)
                let restoredRMS = try trailingRMS(of: microphoneURL, seconds: 1)
                let mutedSeconds = try longestZeroRunSeconds(of: microphoneURL)
                guard microphoneSize > 4_096, microphoneRMS > 0.000_001 else {
                    throw CaptureSmokeError.microphoneSourceEmpty(bytes: microphoneSize, rms: microphoneRMS)
                }
                guard mutedSeconds >= 1 else {
                    throw CaptureSmokeError.liveMuteMissing(silentSeconds: mutedSeconds)
                }
                guard restoredRMS > 0.000_001 else {
                    throw CaptureSmokeError.liveUnmuteMissing(restoredRMS: restoredRMS)
                }
                microphoneMetrics = "microphoneBytes=\(microphoneSize) microphoneRMS=\(microphoneRMS) mutedSeconds=\(mutedSeconds) restoredRMS=\(restoredRMS)"
            } else if sources.contains(where: { $0.lastPathComponent == "source-microphone.caf" }) {
                throw CaptureSmokeError.microphoneSourceUnexpected
            }

            let output = directory.appendingPathComponent("capture-smoke.m4a")
            let exporter = AudioExporter()
            try await exporter.mixToM4A(sources: sources, destination: output)
            let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let outputRMS = try rms(of: output)
            let duration = CMTimeGetSeconds(try await exporter.duration(of: output))
            guard size > 4_096, outputRMS > 0.000_001 else {
                throw CaptureSmokeError.systemSourceEmpty(bytes: size, rms: outputRMS)
            }
            try FileManager.default.removeItem(at: directory)
            testDirectory = nil
            print("CAPTURE_SMOKE_OK sources=\(sources.count) \(microphoneMetrics) bytes=\(size) rms=\(outputRMS) duration=\(duration) cleaned=true")
            fflush(stdout)
            exit(EXIT_SUCCESS)
        } catch {
            if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) }
            fputs("CAPTURE_SMOKE_FAILED \(error.localizedDescription)\n", stderr)
            fflush(stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func runCancellationSmoke() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribatorCaptureCancelSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var needsCleanup = true
        defer {
            if needsCleanup { try? FileManager.default.removeItem(at: directory) }
        }

        let capture = AudioCaptureSession()
        try capture.start(in: directory, includeMicrophone: false)
        try await Task.sleep(nanoseconds: 500_000_000)
        let sources = capture.stop()
        guard !sources.isEmpty else { throw CaptureSmokeError.systemSourceMissing }
        try FileManager.default.removeItem(at: directory)
        needsCleanup = false
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CaptureSmokeError.cancellationCleanupFailed
        }
    }

    private static func rms(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            return 0
        }

        var sum = 0.0
        var sampleCount = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard let channels = buffer.floatChannelData else { continue }
            for channel in 0 ..< Int(format.channelCount) {
                for frame in 0 ..< Int(buffer.frameLength) {
                    let sample = Double(channels[channel][frame])
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        }
        return sampleCount == 0 ? 0 : sqrt(sum / Double(sampleCount))
    }

    private static func longestZeroRunSeconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            return 0
        }

        var longestRun = 0
        var currentRun = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard let channels = buffer.floatChannelData else { continue }
            for frame in 0 ..< Int(buffer.frameLength) {
                var isZero = true
                for channel in 0 ..< Int(format.channelCount) where channels[channel][frame] != 0 {
                    isZero = false
                    break
                }
                if isZero {
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 0
                }
            }
        }
        return Double(longestRun) / format.sampleRate
    }

    private static func trailingRMS(of url: URL, seconds: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let requestedFrames = AVAudioFramePosition(seconds * format.sampleRate)
        file.framePosition = max(0, file.length - requestedFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            return 0
        }

        var sum = 0.0
        var sampleCount = 0
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            try file.read(into: buffer, frameCount: min(buffer.frameCapacity, remaining))
            guard let channels = buffer.floatChannelData else { continue }
            for channel in 0 ..< Int(format.channelCount) {
                for frame in 0 ..< Int(buffer.frameLength) {
                    let sample = Double(channels[channel][frame])
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        }
        return sampleCount == 0 ? 0 : sqrt(sum / Double(sampleCount))
    }
}

enum CaptureSmokeError: LocalizedError {
    case systemSourceMissing
    case systemSourceEmpty(bytes: Int, rms: Double)
    case microphoneDenied
    case microphoneSourceMissing
    case microphoneSourceEmpty(bytes: Int, rms: Double)
    case microphoneSourceUnexpected
    case liveMuteMissing(silentSeconds: Double)
    case liveUnmuteMissing(restoredRMS: Double)
    case cancellationCleanupFailed

    var errorDescription: String? {
        switch self {
        case .systemSourceMissing:
            "System audio source was not created"
        case .systemSourceEmpty(let bytes, let rms):
            "System audio source is empty (bytes=\(bytes), rms=\(rms))"
        case .microphoneDenied:
            "Microphone permission was not granted"
        case .microphoneSourceMissing:
            "Microphone source was not created"
        case .microphoneSourceEmpty(let bytes, let rms):
            "Microphone source is empty (bytes=\(bytes), rms=\(rms))"
        case .microphoneSourceUnexpected:
            "Microphone source was created in system-only mode"
        case .liveMuteMissing(let silentSeconds):
            "Live microphone mute did not produce silence (longest run=\(silentSeconds)s)"
        case .liveUnmuteMissing(let restoredRMS):
            "Microphone signal did not return after live unmute (rms=\(restoredRMS))"
        case .cancellationCleanupFailed:
            "Cancelled recording working files were not removed"
        }
    }
}

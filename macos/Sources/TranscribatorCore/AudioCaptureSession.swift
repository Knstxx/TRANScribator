import AVFoundation
import CAudioCapture
import CoreAudio
import Foundation

public final class AudioCaptureSession {
    public static let microphoneSourceFilename = "source-microphone.caf"

    private let recorder = AudioCaptureRecorder()
    private let microphoneRecorder = MicrophoneRecorder()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

    public init() {}

    deinit { cleanup() }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public func start(
        in directory: URL,
        includeMicrophone: Bool = true,
        microphoneEnabled: Bool = true
    ) throws {
        cleanup()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "Transcribator system audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), operation: "Создание системного audio tap")
        tapID = newTapID

        do {
            let tapUID = try stringProperty(objectID: tapID, selector: kAudioTapPropertyUID)
            let aggregateUID = "app.transcribator.aggregate.\(UUID().uuidString)"
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Transcribator Capture",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try check(
                AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
                operation: "Создание временного Aggregate Device"
            )
            aggregateDeviceID = newAggregateID

            try recorder.start(withDeviceID: aggregateDeviceID, directoryURL: directory)
            if includeMicrophone {
                try microphoneRecorder.start(in: directory, enabled: microphoneEnabled)
            }
        } catch {
            cleanup()
            throw error
        }
    }

    public func stop() -> [URL] {
        let microphoneURL = microphoneRecorder.stop()
        let urls = recorder.stop()
        destroyAudioObjects()
        return urls + [microphoneURL].compactMap { $0 }
    }

    public var isRecording: Bool { recorder.isRecording }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneRecorder.setEnabled(enabled)
    }

    private func cleanup() {
        _ = microphoneRecorder.stop()
        _ = recorder.stop()
        destroyAudioObjects()
    }

    private func destroyAudioObjects() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(
                AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
                operation: "Получение идентификатора аудиоустройства"
            )
        }
        return value as String
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == kAudioHardwareNoError else {
            throw CaptureError.coreAudio(operation: operation, status: status)
        }
    }
}

public enum CaptureError: LocalizedError {
    case message(String)
    case coreAudio(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .message(let message):
            message
        case .coreAudio(let operation, let status):
            "\(operation) не удалось (Core Audio: \(status))"
        }
    }
}

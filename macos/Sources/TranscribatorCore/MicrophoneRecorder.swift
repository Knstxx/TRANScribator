import AVFoundation
import CAudioCapture
import Foundation

final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private let muteState = AudioCaptureMuteState()
    private var file: AVAudioFile?
    private var recordingURL: URL?
    private var isRunning = false

    func start(in directory: URL, enabled: Bool = true) throws {
        _ = stop()
        engine.reset()
        muteState.isMuted = !enabled

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.message("Микрофон не предоставляет доступный аудиоформат")
        }

        let url = directory.appendingPathComponent(AudioCaptureSession.microphoneSourceFilename)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let bufferCapacity: AVAudioFrameCount = 4_096
        let silenceCapacity = max(
            bufferCapacity,
            AVAudioFrameCount(format.sampleRate.rounded(.up))
        )
        guard let silenceBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: silenceCapacity
        ) else {
            throw CaptureError.message("Не удалось подготовить тишину для выключения микрофона")
        }
        silenceBuffer.frameLength = silenceCapacity
        for audioBuffer in UnsafeMutableAudioBufferListPointer(silenceBuffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
        silenceBuffer.frameLength = 0
        self.file = file
        recordingURL = url

        let muteState = muteState
        input.installTap(onBus: 0, bufferSize: bufferCapacity, format: format) { [weak self] buffer, _ in
            guard let file = self?.file else { return }
            do {
                if muteState.isMuted {
                    var framesRemaining = buffer.frameLength
                    while framesRemaining > 0 {
                        silenceBuffer.frameLength = min(
                            framesRemaining,
                            silenceBuffer.frameCapacity
                        )
                        try file.write(from: silenceBuffer)
                        framesRemaining -= silenceBuffer.frameLength
                    }
                } else {
                    try file.write(from: buffer)
                }
            } catch {
                NSLog("Transcribator: не удалось записать буфер микрофона: %@", error.localizedDescription)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            self.file = nil
            recordingURL = nil
            throw CaptureError.message("Не удалось запустить запись микрофона: \(error.localizedDescription)")
        }
    }

    func setEnabled(_ enabled: Bool) {
        muteState.isMuted = !enabled
    }

    @discardableResult
    func stop() -> URL? {
        guard isRunning || file != nil else { return nil }

        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRunning = false
        file = nil

        defer { recordingURL = nil }
        return recordingURL
    }
}

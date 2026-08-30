@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

public struct AudioVolumePoint: Equatable, Sendable {
    public let time: TimeInterval
    public let volume: Float

    public init(time: TimeInterval, volume: Float) {
        self.time = time.isFinite ? max(0, time) : 0
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1
    }
}

public final class AudioExporter: @unchecked Sendable {
    public init() {}

    public func mixToM4A(
        sources: [URL],
        destination: URL,
        timeRange: CMTimeRange? = nil,
        quality: AudioQuality = .standard,
        volumeAutomation: [URL: [AudioVolumePoint]] = [:]
    ) async throws {
        try Task.checkCancellation()
        guard !sources.isEmpty else { throw AudioExportError.noAudioTracks }

        let composition = AVMutableComposition()
        var mixParameters: [AVMutableAudioMixInputParameters] = []

        for source in sources {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: source)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                continue
            }
            let sourceTimeRange = try await sourceTrack.load(.timeRange)
            guard sourceTimeRange.duration.isValid,
                  sourceTimeRange.duration.isNumeric,
                  CMTimeGetSeconds(sourceTimeRange.duration) > 0 else {
                continue
            }
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try track.insertTimeRange(
                sourceTimeRange,
                of: sourceTrack,
                at: .zero
            )
            let parameters = AVMutableAudioMixInputParameters(track: track)
            if let points = volumeAutomation[source], !points.isEmpty {
                apply(points, to: parameters, sourceDuration: sourceTimeRange.duration)
            } else {
                parameters.setVolume(sources.count > 1 ? 0.65 : 1.0, at: .zero)
            }
            mixParameters.append(parameters)
        }

        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioExportError.noAudioTracks }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters

        let reader = try AVAssetReader(asset: composition)
        if let timeRange { reader.timeRange = timeRange }

        let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: quality.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        readerOutput.audioMix = audioMix
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw AudioExportError.readerConfiguration }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: quality.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: quality.bitRate
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw AudioExportError.writerConfiguration }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw writer.error ?? AudioExportError.writerStart
        }
        let sourceStart = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: sourceStart)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? AudioExportError.readerStart
        }

        let pump = AudioExportPump(
            reader: reader,
            output: readerOutput,
            writer: writer,
            input: writerInput
        )
        try await pump.run()
    }

    public func duration(of url: URL) async throws -> CMTime {
        try await AVURLAsset(url: url).load(.duration)
    }

    private func apply(
        _ points: [AudioVolumePoint],
        to parameters: AVMutableAudioMixInputParameters,
        sourceDuration: CMTime
    ) {
        let durationSeconds = CMTimeGetSeconds(sourceDuration)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return }

        let ordered = points.enumerated().sorted { left, right in
            if left.element.time == right.element.time { return left.offset < right.offset }
            return left.element.time < right.element.time
        }
        var normalized: [AudioVolumePoint] = []
        for (_, point) in ordered where point.time < durationSeconds {
            if let last = normalized.last,
               Int64((last.time * 1_000).rounded()) == Int64((point.time * 1_000).rounded()) {
                normalized[normalized.count - 1] = point
            } else {
                normalized.append(point)
            }
        }
        guard let first = normalized.first else { return }

        let transitionDuration = 0.02
        var currentVolume = first.volume
        var cursor = 0.0

        for point in normalized.dropFirst() {
            let eventTime = max(cursor, min(durationSeconds, point.time))
            addVolumeRamp(
                from: currentVolume,
                to: currentVolume,
                start: cursor,
                end: eventTime,
                to: parameters
            )
            let transitionEnd = min(durationSeconds, eventTime + transitionDuration)
            addVolumeRamp(
                from: currentVolume,
                to: point.volume,
                start: eventTime,
                end: transitionEnd,
                to: parameters
            )
            currentVolume = point.volume
            cursor = transitionEnd
        }

        addVolumeRamp(
            from: currentVolume,
            to: currentVolume,
            start: cursor,
            end: durationSeconds,
            to: parameters
        )
    }

    private func addVolumeRamp(
        from startVolume: Float,
        to endVolume: Float,
        start: TimeInterval,
        end: TimeInterval,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        guard end > start else { return }
        parameters.setVolumeRamp(
            fromStartVolume: startVolume,
            toEndVolume: endVolume,
            timeRange: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1_000),
                duration: CMTime(seconds: end - start, preferredTimescale: 1_000)
            )
        )
    }
}

private final class AudioExportPump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "app.transcribator.audio-export")
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var terminalResult: Result<Void, Error>?
    private var cancellationRequested = false

    init(
        reader: AVAssetReader,
        output: AVAssetReaderAudioMixOutput,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if install(continuation) {
                    input.requestMediaDataWhenReady(on: queue) { [self] in pump() }
                }
            }
        } onCancel: {
            requestCancellation()
        }
    }

    private func pump() {
        while input.isReadyForMoreMediaData {
            if isCancellationRequested {
                cancelOnQueue()
                return
            }
            if let buffer = output.copyNextSampleBuffer() {
                if !input.append(buffer) {
                    reader.cancelReading()
                    input.markAsFinished()
                    writer.cancelWriting()
                    complete(.failure(writer.error ?? AudioExportError.append))
                    return
                }
            } else {
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if isCancellationRequested {
                        complete(.failure(CancellationError()))
                    } else if reader.status == .failed {
                        complete(.failure(reader.error ?? AudioExportError.readerFailed))
                    } else if writer.status == .completed {
                        complete(.success(()))
                    } else {
                        complete(.failure(writer.error ?? AudioExportError.writerFailed))
                    }
                }
                return
            }
        }
    }

    private var isCancellationRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancellationRequested
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        stateLock.lock()
        if let terminalResult {
            stateLock.unlock()
            continuation.resume(with: terminalResult)
            return false
        }
        self.continuation = continuation
        stateLock.unlock()
        return true
    }

    private func requestCancellation() {
        stateLock.lock()
        cancellationRequested = true
        stateLock.unlock()
        queue.async { [self] in cancelOnQueue() }
    }

    private func cancelOnQueue() {
        reader.cancelReading()
        writer.cancelWriting()
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<Void, Error>) {
        stateLock.lock()
        guard terminalResult == nil else {
            stateLock.unlock()
            return
        }
        terminalResult = result
        let continuation = continuation
        self.continuation = nil
        stateLock.unlock()
        continuation?.resume(with: result)
    }
}

public enum AudioExportError: LocalizedError {
    case noAudioTracks
    case readerConfiguration
    case writerConfiguration
    case readerStart
    case writerStart
    case append
    case readerFailed
    case writerFailed

    public var errorDescription: String? {
        switch self {
        case .noAudioTracks: "В записи не найдено аудио"
        case .readerConfiguration: "Не удалось подготовить сведение аудио"
        case .writerConfiguration: "Не удалось подготовить кодирование M4A"
        case .readerStart: "Не удалось прочитать записанное аудио"
        case .writerStart: "Не удалось начать создание M4A"
        case .append: "Ошибка при сведении аудиодорожек"
        case .readerFailed: "Ошибка чтения аудио"
        case .writerFailed: "Ошибка сохранения M4A"
        }
    }
}

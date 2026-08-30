import AVFoundation
import Foundation
import TranscribatorCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

@main
struct TranscribatorCoreChecks {
    static func main() async {
        do {
            try await runChecks()
            print("All TranscribatorCore checks passed")
        } catch {
            fputs("Check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func runChecks() async throws {
        try checkChunkingPolicy()
        try checkAudioQualityPolicy()
        try checkMultipartAndResponseParsing()
        try await checkCancelledRequestIsNotRetried()
        try await checkNativeAudioPipeline()
    }

    private static func checkAudioQualityPolicy() throws {
        try require(AudioQuality.compact.bitRate == 32_000, "Compact bitrate is incorrect")
        try require(AudioQuality.standard.bitRate == 64_000, "Standard bitrate is incorrect")
        try require(AudioQuality.high.bitRate == 128_000, "High bitrate is incorrect")
        try require(
            AudioQuality.compact.sampleRate < AudioQuality.standard.sampleRate,
            "Compact sample rate must be lower than standard"
        )
        let sanitizedPoint = AudioVolumePoint(time: .nan, volume: .infinity)
        try require(sanitizedPoint.time == 0, "Invalid volume automation time was not sanitized")
        try require(sanitizedPoint.volume == 1, "Invalid volume coefficient was not sanitized")
        try require(TranscriptionModel.transcribe.usesAutomaticChunking, "GPT Transcribe must use server chunking")
        try require(TranscriptionModel.diarize.usesAutomaticChunking, "Diarization must use server chunking")
        try require(!TranscriptionModel.whisper.usesAutomaticChunking, "Whisper must not use server chunking")
    }

    private static func checkChunkingPolicy() throws {
        let policy = AudioChunkingPolicy()
        try require(policy.chunkCount(forFileSize: 24_000_000) == 1, "24 MB must remain whole")
        try require(policy.chunkCount(forFileSize: 24_000_001) == 2, "A file over 24 MB must split")
        try require(policy.chunkCount(forFileSize: 40 * 1024 * 1024) == 2, "40 MiB must split into two")
        try require(policy.chunkCount(forFileSize: 41 * 1024 * 1024) == 3, "41 MiB must split into three")

        let limitDuration = CMTime(seconds: 30 * 60, preferredTimescale: 600)
        try require(
            policy.chunkCount(forFileSize: 19 * 1024 * 1024, duration: limitDuration) == 1,
            "A 30-minute file under the size limit must remain whole"
        )
        let overLimitDuration = CMTime(seconds: 30 * 60 + 0.01, preferredTimescale: 600)
        try require(
            policy.chunkCount(forFileSize: 19 * 1024 * 1024, duration: overLimitDuration) == 2,
            "A file over 30 minutes must split"
        )

        let failedMeetingDuration = CMTime(seconds: 3_679.274667, preferredTimescale: 600)
        try require(
            policy.chunkCount(forFileSize: 14_639_605, duration: failedMeetingDuration) == 3,
            "The 61-minute regression recording must split into three parts"
        )

        let twoHourDuration = CMTime(seconds: 2 * 60 * 60, preferredTimescale: 600)
        try require(
            policy.chunkCount(forFileSize: 19 * 1024 * 1024, duration: twoHourDuration) == 4,
            "Duration must force four chunks for a two-hour file"
        )
        try require(
            policy.chunkCount(forFileSize: 50 * 1024 * 1024, duration: twoHourDuration) == 4,
            "The stricter duration limit must win over the size limit"
        )
        let twentyMinuteDuration = CMTime(seconds: 20 * 60, preferredTimescale: 600)
        try require(
            policy.chunkCount(forFileSize: 50 * 1024 * 1024, duration: twentyMinuteDuration) == 3,
            "The stricter size limit must win over the duration limit"
        )
        try require(
            policy.timeRanges(duration: .invalid, fileSize: 1).isEmpty,
            "Invalid duration must not produce upload ranges"
        )

        let duration = CMTime(seconds: 7_200, preferredTimescale: 600)
        let ranges = policy.timeRanges(duration: duration, fileSize: 50 * 1024 * 1024)
        try require(ranges.count == 4, "Two hours must produce four ranges")
        try require(ranges.first?.start == .zero, "First range must start at zero")
        for index in 1..<ranges.count {
            try require(ranges[index - 1].end == ranges[index].start, "Ranges must not contain gaps")
        }
        try require(
            ranges.allSatisfy { CMTimeGetSeconds($0.duration) <= 30 * 60 + 0.01 },
            "No range may exceed the duration limit"
        )
        let coveredSeconds = CMTimeGetSeconds(ranges.map(\.duration).reduce(.zero, +))
        try require(abs(coveredSeconds - 7_200) < 0.01, "Ranges must cover the whole duration")
    }

    private static func checkMultipartAndResponseParsing() throws {
        let form = MultipartFormData()
        form.addField(name: "model", value: "gpt-transcribe")
        form.addField(name: "chunking_strategy", value: "auto")
        form.addFile(name: "file", filename: "sample.m4a", mimeType: "audio/mp4", data: Data([1, 2, 3]))
        let multipartText = String(decoding: form.body, as: UTF8.self)
        try require(multipartText.contains("name=\"model\""), "Multipart model field missing")
        try require(multipartText.contains("gpt-transcribe"), "Multipart model value missing")
        try require(multipartText.contains("chunking_strategy"), "Multipart chunking strategy missing")
        try require(multipartText.contains("filename=\"sample.m4a\""), "Multipart filename missing")
        try require(multipartText.contains("--\(form.boundary)--"), "Multipart closing boundary missing")

        let standardData = Data(#"{"text":"Привет, мир"}"#.utf8)
        try require(
            TranscriptionResponseParser.parse(data: standardData, model: .transcribe) == "Привет, мир",
            "Standard response parser failed"
        )

        let diarizedData = Data(#"{"text":"","segments":[{"speaker":"A","text":"Привет","start":0},{"speaker":"B","text":"Слушаю","start":1.2}]}"#.utf8)
        try require(
            TranscriptionResponseParser.parse(data: diarizedData, model: .diarize)
                == "[A] — Привет\n[B] — Слушаю",
            "Diarized response parser failed"
        )
    }

    private static func checkCancelledRequestIsNotRetried() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribatorCancellationCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("sample.m4a")
        try Data([0, 1, 2, 3]).write(to: input)

        CancelledRequestURLProtocol.reset()
        let client = OpenAITranscriptionClient(
            apiKey: "test-key",
            endpoint: URL(string: "https://example.invalid/transcriptions")!,
            session: session
        )
        do {
            _ = try await client.transcribe(fileURL: input, model: .transcribe)
            throw CheckFailure(description: "A cancelled URL request unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation must not enter the retry loop.
        }
        try require(
            CancelledRequestURLProtocol.requestCount == 1,
            "A cancelled URL request was retried"
        )
    }

    private static func checkNativeAudioPipeline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribatorCoreChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.caf")
        let second = root.appendingPathComponent("second.caf")
        try writeTone(to: first, frequency: 440)
        try writeTone(to: second, frequency: 660, amplitude: 0.06)

        let output = root.appendingPathComponent("mixed.m4a")
        let exporter = AudioExporter()
        try await exporter.mixToM4A(sources: [first, second], destination: output)

        let originalSourceData = try Data(contentsOf: first)
        let importedOutput = root.appendingPathComponent("imported.m4a")
        let mediaPreparer = MediaFilePreparer()
        let mediaInfo = try await mediaPreparer.inspect(first)
        try require(mediaInfo.kind == .audio, "A CAF source must be detected as audio")
        try require(abs(mediaInfo.durationSeconds - 2) < 0.1, "Imported media duration is incorrect")
        try await mediaPreparer.prepare(
            sourceURL: first,
            destinationURL: importedOutput,
            quality: .standard
        )
        try require(
            try Data(contentsOf: first) == originalSourceData,
            "Preparing imported media modified the source file"
        )
        let importedFile = try AVAudioFile(forReading: importedOutput)
        try require(
            importedFile.processingFormat.channelCount == 1,
            "Imported media was not converted to mono"
        )

        let videoSource = root.appendingPathComponent("video-with-audio.mov")
        try await writeMovieWithAudio(audioURL: first, destinationURL: videoSource)
        let videoInfo = try await mediaPreparer.inspect(videoSource)
        try require(
            videoInfo.kind == .video,
            "A MOV with a video track must be detected as video"
        )
        let extractedAudio = root.appendingPathComponent("video-audio.m4a")
        try await mediaPreparer.prepare(
            sourceURL: videoSource,
            destinationURL: extractedAudio,
            quality: .standard
        )
        let extractedFile = try AVAudioFile(forReading: extractedAudio)
        try require(
            extractedFile.processingFormat.channelCount == 1,
            "Video audio was not extracted as mono"
        )
        let extractedDuration = CMTimeGetSeconds(try await exporter.duration(of: extractedAudio))
        try require(
            abs(extractedDuration - 2) < 0.1,
            "Extracted video audio has incorrect duration"
        )

        let cancellableSource = root.appendingPathComponent("cancellable-source.wav")
        let cancelledOutput = root.appendingPathComponent("cancelled-export.m4a")
        try writeSparsePCMWave(to: cancellableSource, durationSeconds: 600)
        let exportTask = Task {
            try await exporter.mixToM4A(
                sources: [cancellableSource],
                destination: cancelledOutput
            )
        }
        var exportStarted = false
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: cancelledOutput.path) {
                exportStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try require(exportStarted, "The cancellable AVFoundation export did not start")
        exportTask.cancel()
        do {
            try await exportTask.value
            throw CheckFailure(description: "An active AVFoundation export ignored cancellation")
        } catch is CancellationError {
            // Expected: cancellation handler must stop the reader and writer.
        }
        try? FileManager.default.removeItem(at: cancelledOutput)

        let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        try require(size > 1_000, "Native M4A export produced an empty file")
        try require(size < 100_000, "Two-second 64 kbps M4A is unexpectedly large")

        let duration = CMTimeGetSeconds(try await exporter.duration(of: output))
        try require(abs(duration - 2.0) < 0.1, "Native M4A duration is incorrect: \(duration)")
        let uploadFiles = try await AudioChunker().uploadFiles(for: output)
        try require(uploadFiles == [output], "Small native M4A must not be split")

        let durationLimitedChunker = AudioChunker(
            policy: AudioChunkingPolicy(maxChunkDurationSeconds: 1.5)
        )
        let durationChunks = try await durationLimitedChunker.uploadFiles(for: output)
        try require(durationChunks.count == 2, "Duration limit must split a small M4A")
        let durationChunkSeconds = try await durationChunks.asyncMap {
            CMTimeGetSeconds(try await exporter.duration(of: $0))
        }
        try require(
            durationChunkSeconds.allSatisfy { $0 > 0 && $0 <= 1.1 },
            "Duration-limited chunks must be valid and evenly bounded"
        )
        try require(
            abs(durationChunkSeconds.reduce(0, +) - duration) < 0.1,
            "Duration-limited chunks must cover the original M4A"
        )

        let fakeClient = StubTranscriptionClient(responses: ["Первая часть", "Вторая часть"])
        let transcript = try await AudioTranscriptionPipeline(
            chunker: durationLimitedChunker
        ).transcribe(
            audioURL: output,
            model: .transcribe,
            initialPrompt: "Имена: Анна",
            client: fakeClient
        )
        try require(
            transcript == "Первая часть\n\nВторая часть",
            "The transcription pipeline joined chunk results incorrectly"
        )
        try require(fakeClient.prompts.count == 2, "The fake client did not receive both chunks")
        try require(
            fakeClient.prompts[0]?.contains("Имена: Анна") == true,
            "Initial file context was not sent with the first chunk"
        )
        try require(
            fakeClient.prompts[1]?.contains("Первая часть") == true
                && fakeClient.prompts[1]?.contains("Имена: Анна") == true,
            "Prompt continuity or initial context was lost on the second chunk"
        )

        let cancellationClient = StubTranscriptionClient(
            responses: ["Не должно вернуться"],
            delayNanoseconds: 5_000_000_000
        )
        let cancellationTask = Task {
            try await AudioTranscriptionPipeline().transcribe(
                audioURL: output,
                model: .transcribe,
                client: cancellationClient
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            throw CheckFailure(description: "A cancelled transcription pipeline unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }

        let compactOutput = root.appendingPathComponent("compact.m4a")
        let highOutput = root.appendingPathComponent("high.m4a")
        try await exporter.mixToM4A(sources: [first, second], destination: compactOutput, quality: .compact)
        try await exporter.mixToM4A(sources: [first, second], destination: highOutput, quality: .high)
        let compactSize = (try compactOutput.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        let highSize = (try highOutput.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        try require(compactSize < highSize, "Audio quality selection does not change encoded size")

        let automatedOutput = root.appendingPathComponent("volume-automation.m4a")
        try await exporter.mixToM4A(
            sources: [first],
            destination: automatedOutput,
            volumeAutomation: [
                first: [
                    AudioVolumePoint(time: 1, volume: 0),
                    AudioVolumePoint(time: 0, volume: 0),
                    AudioVolumePoint(time: 1, volume: 1)
                ]
            ]
        )
        let mutedRMS = try rms(of: automatedOutput, start: 0.15, duration: 0.65)
        let audibleRMS = try rms(of: automatedOutput, start: 1.2, duration: 0.6)
        try require(audibleRMS > 0.01, "Volume automation did not restore the audio signal")
        try require(
            mutedRMS < audibleRMS * 0.05,
            "Volume automation did not mute the requested interval (muted=\(mutedRMS), audible=\(audibleRMS))"
        )

        let quarterOutput = root.appendingPathComponent("quarter-volume.m4a")
        try await exporter.mixToM4A(
            sources: [first],
            destination: quarterOutput,
            volumeAutomation: [
                first: [AudioVolumePoint(time: 0, volume: 0.25)]
            ]
        )
        let quarterRMS = try rms(of: quarterOutput, start: 0.2, duration: 1.5)
        try require(
            quarterRMS / audibleRMS > 0.20 && quarterRMS / audibleRMS < 0.30,
            "A 0.25 volume coefficient produced the wrong level ratio: \(quarterRMS / audibleRMS)"
        )

        let firstOnlyOutput = root.appendingPathComponent("first-only.m4a")
        try await exporter.mixToM4A(
            sources: [first, second],
            destination: firstOnlyOutput,
            volumeAutomation: [
                first: [AudioVolumePoint(time: 0, volume: 1)],
                second: [AudioVolumePoint(time: 0, volume: 0)]
            ]
        )
        let secondHalfOutput = root.appendingPathComponent("second-half.m4a")
        try await exporter.mixToM4A(
            sources: [first, second],
            destination: secondHalfOutput,
            volumeAutomation: [
                first: [AudioVolumePoint(time: 0, volume: 0)],
                second: [AudioVolumePoint(time: 0, volume: 0.5)]
            ]
        )
        let firstOnlyRMS = try rms(of: firstOnlyOutput, start: 0.2, duration: 1.5)
        let secondHalfRMS = try rms(of: secondHalfOutput, start: 0.2, duration: 1.5)
        let independentTrackRatio = secondHalfRMS / firstOnlyRMS
        try require(
            independentTrackRatio > 0.15 && independentTrackRatio < 0.25,
            "Independent source volume automation produced the wrong ratio: \(independentTrackRatio)"
        )
    }

    private static func writeMovieWithAudio(
        audioURL: URL,
        destinationURL: URL
    ) async throws {
        let videoOnlyURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("video-only-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: videoOnlyURL) }

        try await writeSolidVideo(to: videoOnlyURL, durationSeconds: 2)

        let videoAsset = AVURLAsset(url: videoOnlyURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw CheckFailure(description: "Unable to load fixture tracks")
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        let composition = AVMutableComposition()
        guard let composedVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let composedAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CheckFailure(description: "Unable to create fixture tracks")
        }
        try composedVideo.insertTimeRange(
            CMTimeRange(start: videoRange.start, duration: duration),
            of: videoTrack,
            at: .zero
        )
        try composedAudio.insertTimeRange(
            CMTimeRange(start: audioRange.start, duration: duration),
            of: audioTrack,
            at: .zero
        )

        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw CheckFailure(description: "Unable to create fixture exporter")
        }
        try await exporter.export(to: destinationURL, as: .mov)
    }

    private static func writeSolidVideo(
        to url: URL,
        durationSeconds: Double
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 64
        let height = 64
        let framesPerSecond: Int32 = 10
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw CheckFailure(description: "Unable to add fixture video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CheckFailure(description: "Unable to start fixture writer")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw CheckFailure(description: "No fixture pixel buffer pool")
        }

        let frameCount = Int(ceil(durationSeconds * Double(framesPerSecond)))
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                await Task.yield()
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else {
                throw CheckFailure(description: "Unable to allocate fixture pixel buffer")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(baseAddress, 0x66, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: Int64(frame), timescale: framesPerSecond)
            ) else {
                throw writer.error ?? CheckFailure(description: "Unable to append fixture frame")
            }
        }
        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CheckFailure(description: "Fixture writer did not finish")
        }
    }

    private static func writeSparsePCMWave(
        to url: URL,
        durationSeconds: Int
    ) throws {
        let sampleRate: UInt32 = 48_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = UInt32(durationSeconds) * sampleRate * UInt32(channelCount) * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * bytesPerSample
        let blockAlign = channelCount * (bitsPerSample / 8)

        var header = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36) + dataSize, to: &header)
        header.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(channelCount, to: &header)
        appendLittleEndian(sampleRate, to: &header)
        appendLittleEndian(byteRate, to: &header)
        appendLittleEndian(blockAlign, to: &header)
        appendLittleEndian(bitsPerSample, to: &header)
        header.append(Data("data".utf8))
        appendLittleEndian(dataSize, to: &header)
        try header.write(to: url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(header.count) + UInt64(dataSize))
        try handle.close()
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func writeTone(
        to url: URL,
        frequency: Double,
        amplitude: Double = 0.15
    ) throws {
        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount(sampleRate * 2)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            throw CheckFailure(description: "Unable to allocate a tone buffer")
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(
                sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * amplitude
            )
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func rms(
        of url: URL,
        start: TimeInterval,
        duration: TimeInterval
    ) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let startFrame = min(
            file.length,
            AVAudioFramePosition(max(0, start) * format.sampleRate)
        )
        let endFrame = min(
            file.length,
            startFrame + AVAudioFramePosition(max(0, duration) * format.sampleRate)
        )
        file.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw CheckFailure(description: "Unable to allocate an RMS buffer")
        }

        var sum = 0.0
        var sampleCount = 0
        while file.framePosition < endFrame {
            let frames = AVAudioFrameCount(min(
                AVAudioFramePosition(buffer.frameCapacity),
                endFrame - file.framePosition
            ))
            try file.read(into: buffer, frameCount: frames)
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

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}

private final class StubTranscriptionClient: AudioTranscriptionRequesting {
    private var responses: [String]
    private let delayNanoseconds: UInt64
    private(set) var prompts: [String?] = []

    init(responses: [String], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribe(
        fileURL _: URL,
        model _: TranscriptionModel,
        prompt: String?
    ) async throws -> String {
        prompts.append(prompt)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !responses.isEmpty else { return "" }
        return responses.removeFirst()
    }
}

private final class CancelledRequestURLProtocol: URLProtocol {
    private static let counter = LockedCounter()

    static var requestCount: Int { counter.value }

    static func reset() { counter.reset() }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counter.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

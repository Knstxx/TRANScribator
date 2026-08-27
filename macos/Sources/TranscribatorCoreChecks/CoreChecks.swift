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

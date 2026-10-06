import AVFoundation
import Foundation
import TranscribatorCore

/// Exercises the complete local chunk/export/request path without network or authentication.
enum GPTAppPipelineChecks {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTAppPipelineChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let wave = directory.appendingPathComponent("synthetic-silence.wav")
        try writeSilentWave(to: wave, seconds: 601)
        let recording = directory.appendingPathComponent("prepared.m4a")
        let exporter = AudioExporter()
        try await exporter.mixToM4A(sources: [wave], destination: recording)
        let original = try Data(contentsOf: recording)
        let duration = CMTimeGetSeconds(try await exporter.duration(of: recording))

        // 10m01s needs three GPT App chunks at 5m, versus two API chunks at 10m.
        // An explicitly injected API policy must not override GPT App's policy.
        let pipeline = AudioTranscriptionPipeline(
            chunker: AudioChunker(policy: AudioChunkingPolicy(maxChunkDurationSeconds: 600))
        )
        let chatGPT = Requests()
        let transcript = try await pipeline.transcribe(
            audioURL: recording,
            model: .gptApp,
            initialPrompt: "This context must not reach dictation",
            client: chatGPT
        )
        try require(chatGPT.calls.count == 3, "GPT App pipeline did not use its five-minute chunk policy")
        try require(transcript == "Part 1\n\nPart 2\n\nPart 3", "GPT App chunk text order changed")
        try require(chatGPT.calls.allSatisfy { $0.model == .gptApp && $0.prompt == nil },
                    "GPT App received an API model or unsupported continuity prompt")
        try require(chatGPT.calls.allSatisfy {
            $0.duration > 0 && $0.duration <= 300.1 && $0.bytes <= AudioChunkingPolicy.gptApp.maxUploadBytes
        }, "GPT App exported chunks exceed the local duration or byte policy")
        try require(abs(chatGPT.calls.reduce(0) { $0 + $1.duration } - duration) < 0.15,
                    "GPT App chunks do not cover the original recording")

        let api = Requests()
        _ = try await pipeline.transcribe(audioURL: recording, model: .transcribe, client: api)
        try require(api.calls.count == 2, "Adding GPT App changed the injected API chunk policy")

        let cancelled = Requests(cancelAt: 2)
        do {
            _ = try await pipeline.transcribe(audioURL: recording, model: .gptApp, client: cancelled)
            throw CheckFailure(description: "Cancellation between GPT App chunks was ignored")
        } catch is CancellationError {
            try require(cancelled.calls.count == 2, "GPT App uploaded later chunks after cancellation")
        }
        try await checkEmptyResponses(pipeline: pipeline, recording: recording, duration: duration)
        let shortWave = directory.appendingPathComponent("short-silence.wav")
        try writeSilentWave(to: shortWave, seconds: 1)
        let shortRecording = directory.appendingPathComponent("short-prepared.m4a")
        try await exporter.mixToM4A(sources: [shortWave], destination: shortRecording)
        let short = Requests(responses: [.success(""), .success("Recovered short speech")])
        let shortText = try await pipeline.transcribe(audioURL: shortRecording, model: .gptApp, client: short)
        try require(shortText == "Recovered short speech" && short.calls.count == 2,
                    "An empty <=60s response must be retried exactly once without recursive splitting")
        try require(try Data(contentsOf: recording) == original, "GPT App processing changed the source recording")
    }

    @MainActor
    private static func checkEmptyResponses(
        pipeline: AudioTranscriptionPipeline, recording: URL, duration: Double
    ) async throws {
        let empty: Result<String, Error> = .success("")
        let first: Result<String, Error> = .success("First speech")
        let middle: Result<String, Error> = .success("Middle speech")
        let last: Result<String, Error> = .success("Last speech")
        // Each primary chunk is ~200s, so one empty response yields exactly four <=60s attempts.
        let cases: [([Result<String, Error>], String, Int, Int)] = [
            ([first, empty, empty, empty, empty, empty, last], "First speech\n\nLast speech", 4, 0),
            ([empty, empty, empty, empty, empty, middle, empty, empty, empty, empty, empty], "Middle speech", 8, 0),
            ([empty, first, empty, middle, empty, middle, last], "First speech\n\nMiddle speech\n\nMiddle speech\n\nLast speech", 2, 1)
        ]
        for (responses, expected, emptyCount, recoveredCount) in cases {
            let client = Requests(responses: responses)
            var checkpoints: [AudioTranscriptionCheckpoint] = []
            let transcript = try await pipeline.transcribe(
                audioURL: recording, model: .gptApp, client: client,
                checkpoint: { checkpoints.append($0) }
            )
            try require(transcript == expected, "Empty ASR response lost speech before or after recovery")
            try require(client.calls.count == responses.count && checkpoints.count == responses.count,
                        "Each valid response needs one checkpoint and bounded empty-only recovery")
            let final = checkpoints.last!
            try require(final.transcript == transcript && final.noSpeechRanges.count == emptyCount
                        && final.recoveredEmptyChunkCount == recoveredCount && final.pendingRecoveryRanges.isEmpty,
                        "Final checkpoint lost no-text or recovered-chunk metadata")
            try require(abs(final.processedSeconds - duration) < 0.01 && final.totalSeconds == duration,
                        "Final checkpoint does not cover the whole recording")
            try require(final.noSpeechRanges.allSatisfy {
                $0.endSeconds > $0.startSeconds && $0.endSeconds - $0.startSeconds <= 60.001
                    && $0.startSeconds >= 0 && $0.endSeconds <= duration
            }, "No-text intervals must be bounded recovery ranges within the source")
            try require(zip(checkpoints, checkpoints.dropFirst()).allSatisfy {
                $0.processedSeconds <= $1.processedSeconds
            }, "Checkpoint progress must never move backwards")
            try require(checkpoints.contains { !$0.pendingRecoveryRanges.isEmpty },
                        "Initial empty responses must be checkpointed before retrying")
            try require(client.calls.filter { $0.duration < 100 }.allSatisfy { $0.duration <= 60.1 },
                        "Recovery uploads exceeded sixty seconds")
            let encoded = try JSONEncoder().encode(final)
            try require(try JSONDecoder().decode(AudioTranscriptionCheckpoint.self, from: encoded) == final,
                        "Recovery checkpoints must round-trip without losing ranges")
        }

        let silent = Requests(responses: Array(repeating: empty, count: 15))
        var silentCheckpoints: [AudioTranscriptionCheckpoint] = []
        do {
            _ = try await pipeline.transcribe(
                audioURL: recording, model: .gptApp, client: silent,
                checkpoint: { silentCheckpoints.append($0) }
            )
            throw CheckFailure(description: "All-empty ASR must not report successful transcription")
        } catch AudioTranscriptionPipelineError.noSpeechDetected {
            try require(silent.calls.count == 15 && silentCheckpoints.count == 15,
                        "All-empty recovery was not bounded or did not save the final checkpoint")
            let final = silentCheckpoints.last!
            try require(final.transcript.isEmpty && final.noSpeechRanges.count == 12
                        && final.pendingRecoveryRanges.isEmpty && final.processedSeconds == final.totalSeconds,
                        "All-empty checkpoint must retain every resolved no-text range before the error")
            try require(abs(final.noSpeechRanges.reduce(0) { $0 + $1.endSeconds - $1.startSeconds } - duration) < 0.01,
                        "All-empty intervals must cover the recording without dropping audio")
        }

        let unauthorized = Requests(responses: [first, .failure(ChatGPTTranscriptionError.authorizationRequired)])
        var saved: [AudioTranscriptionCheckpoint] = []
        do {
            _ = try await pipeline.transcribe(audioURL: recording, model: .gptApp, client: unauthorized,
                                             checkpoint: { saved.append($0) })
            throw CheckFailure(description: "Authentication failure must terminate uploads")
        } catch ChatGPTTranscriptionError.authorizationRequired {
            try require(unauthorized.calls.count == 2 && saved.count == 1 && saved[0].transcript == "First speech",
                        "Authentication failure retried or lost the prior successful checkpoint")
        }

        let failedRecovery = Requests(responses: [first, empty, .failure(ChatGPTTranscriptionError.network)])
        saved = []
        do {
            _ = try await pipeline.transcribe(audioURL: recording, model: .gptApp, client: failedRecovery,
                                             checkpoint: { saved.append($0) })
            throw CheckFailure(description: "Failed recovery must preserve the unresolved range")
        } catch ChatGPTTranscriptionError.network {
            try require(failedRecovery.calls.count == 3 && saved.count == 2 && saved.last?.transcript == "First speech"
                        && saved.last?.pendingRecoveryRanges.count == 1 && saved.last?.noSpeechRanges.isEmpty == true,
                        "Failed recovery was silently accepted as silence or lost prior speech")
        }

        let cannotSave = Requests(responses: [first, middle, last])
        do {
            _ = try await pipeline.transcribe(audioURL: recording, model: .gptApp, client: cannotSave,
                                             checkpoint: { _ in throw SaveError.unavailable })
            throw CheckFailure(description: "Checkpoint persistence failure must stop uploads")
        } catch SaveError.unavailable {
            try require(cannotSave.calls.count == 1, "Pipeline continued uploading without a durable checkpoint")
        }
    }

    private enum SaveError: Error { case unavailable }

    private struct Call {
        let model: TranscriptionModel
        let prompt: String?
        let duration: Double
        let bytes: Int64
    }

    private final class Requests: AudioTranscriptionRequesting {
        var calls: [Call] = []
        let cancelAt: Int?
        let responses: [Result<String, Error>]?

        init(cancelAt: Int? = nil, responses: [Result<String, Error>]? = nil) {
            self.cancelAt = cancelAt
            self.responses = responses
        }

        func transcribe(fileURL: URL, model: TranscriptionModel, prompt: String?) async throws -> String {
            let duration = CMTimeGetSeconds(try await AudioExporter().duration(of: fileURL))
            let bytes = Int64((try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            calls.append(Call(model: model, prompt: prompt, duration: duration, bytes: bytes))
            if calls.count == cancelAt { throw CancellationError() }
            if let responses {
                guard responses.indices.contains(calls.count - 1) else {
                    throw CheckFailure(description: "Pipeline exceeded the bounded fixture request count")
                }
                return try responses[calls.count - 1].get()
            }
            return "Part \(calls.count)"
        }
    }

    private static func writeSilentWave(to url: URL, seconds: UInt32) throws {
        let rate: UInt32 = 16_000
        let bytes = rate * seconds * 2
        var data = Data("RIFF".utf8)
        append(UInt32(36) + bytes, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(rate, to: &data)
        append(rate * 2, to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(bytes, to: &data)
        try data.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(data.count) + UInt64(bytes))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

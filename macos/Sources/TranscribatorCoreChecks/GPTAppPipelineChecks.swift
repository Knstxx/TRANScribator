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
        try require(try Data(contentsOf: recording) == original, "GPT App processing changed the source recording")
    }

    private struct Call {
        let model: TranscriptionModel
        let prompt: String?
        let duration: Double
        let bytes: Int64
    }

    private final class Requests: AudioTranscriptionRequesting {
        var calls: [Call] = []
        let cancelAt: Int?

        init(cancelAt: Int? = nil) { self.cancelAt = cancelAt }

        func transcribe(fileURL: URL, model: TranscriptionModel, prompt: String?) async throws -> String {
            let duration = CMTimeGetSeconds(try await AudioExporter().duration(of: fileURL))
            let bytes = Int64((try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            calls.append(Call(model: model, prompt: prompt, duration: duration, bytes: bytes))
            if calls.count == cancelAt { throw CancellationError() }
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

import Foundation
import TranscribatorCore

@MainActor
enum TranscriptRecoveryStoreChecks {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRecoveryStoreChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let original = Data("source must stay unchanged".utf8)
        try original.write(to: source)
        let recovery = directory.appendingPathComponent("Recovery", isDirectory: true)
        let output = directory.appendingPathComponent("result.txt")
        let store = try TranscriptRecoveryStore(outputURL: output, sourceAudioURL: source, recoveryRootURL: recovery)
        let empty = AudioTranscriptionCheckpoint(
            transcript: " \n ", processedSeconds: 20, totalSeconds: 100,
            noSpeechRanges: [AudioTranscriptionRange(startSeconds: 0, endSeconds: 20)]
        )
        try store.save(empty)
        try require(!store.hasPartialTranscript, "An empty checkpoint created a misleading partial TXT")
        try require(!FileManager.default.fileExists(atPath: store.partialTranscriptURL.path), "Empty partial TXT exists")
        try require(store.lastCheckpoint == empty, "Empty checkpoint metadata was discarded")
        do {
            try store.finish(" \n ")
            throw CheckFailure(description: "An empty final transcript was created")
        } catch let error as CheckFailure { throw error }
        catch {}
        try require(!FileManager.default.fileExists(atPath: output.path), "Empty finish created a final file")

        let progress = AudioTranscriptionCheckpoint(
            transcript: "First response", processedSeconds: 50, totalSeconds: 100,
            noSpeechRanges: empty.noSpeechRanges,
            pendingRecoveryRanges: [AudioTranscriptionRange(startSeconds: 50, endSeconds: 100)],
            recoveredEmptyChunkCount: 1
        )
        try store.save(progress)
        try require(store.hasPartialTranscript, "Partial text was not saved")
        try require(try String(contentsOf: store.partialTranscriptURL, encoding: .utf8) == progress.transcript,
                    "Partial text differs from completed responses")
        let metadata = try Data(contentsOf: store.checkpointURL)
        let json = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
        try require(json["status"] as? String == "partial", "Checkpoint lost partial status")
        try require(json["sourceAudioPath"] as? String == source.path, "Checkpoint source path is wrong")
        try require(json["outputPath"] as? String == output.path, "Checkpoint output path is wrong")
        let decoded = try JSONDecoder().decode(
            AudioTranscriptionCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: json["checkpoint"]!)
        )
        try require(decoded == progress, "Checkpoint lost progress or recovery ranges")
        try require(try permissions(recovery) == 0o700, "New recovery root is not private")
        try require(try permissions(store.recoveryDirectoryURL) == 0o700, "Recovery directory is not private")
        try require(try permissions(store.partialTranscriptURL) == 0o600, "Partial text is not private")
        try require(try permissions(store.checkpointURL) == 0o600, "Checkpoint is not private")

        // Failed updates must leave the previous durable checkpoint recoverable.
        do {
            try store.save(AudioTranscriptionCheckpoint(transcript: "bad", processedSeconds: .nan, totalSeconds: 100))
            throw CheckFailure(description: "Non-JSON checkpoint unexpectedly succeeded")
        } catch is EncodingError {}
        try require(try Data(contentsOf: store.checkpointURL) == metadata, "Failed save destroyed previous checkpoint")
        try require(store.lastCheckpoint == progress, "Failed save replaced in-memory checkpoint")
        try require(try String(contentsOf: store.partialTranscriptURL, encoding: .utf8) == progress.transcript,
                    "Failed save destroyed partial text")

        let preservedAudio = store.recoveryDirectoryURL.appendingPathComponent("recording.m4a")
        try FileManager.default.copyItem(at: source, to: preservedAudio)
        try store.relocateSourceAudio(to: preservedAudio)
        let relocated = try JSONSerialization.jsonObject(with: Data(contentsOf: store.checkpointURL)) as! [String: Any]
        try require(relocated["sourceAudioPath"] as? String == preservedAudio.path,
                    "Audio relocation left a stale recovery path")
        let relocatedCheckpoint = try JSONDecoder().decode(
            AudioTranscriptionCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: relocated["checkpoint"]!)
        )
        try require(relocatedCheckpoint == progress, "Audio relocation lost the last checkpoint")

        // Model completion and a concurrently-created destination must not overwrite user data.
        try Data("existing final".utf8).write(to: output)
        do {
            try store.finish("new final")
            throw CheckFailure(description: "finish overwrote an existing final TXT")
        } catch is POSIXError {}
        try require(try String(contentsOf: output, encoding: .utf8) == "existing final", "Existing final changed")
        try require(store.hasPartialTranscript, "Final collision discarded partial text")
        try FileManager.default.removeItem(at: output)
        try store.finish("First response\n\nSecond response")
        try require(!store.hasPartialTranscript, "Successful final did not remove partial text")
        try require(try permissions(output) == 0o600, "Final transcript is not private")
        let completed = try JSONSerialization.jsonObject(with: Data(contentsOf: store.checkpointURL)) as! [String: Any]
        try require(completed["status"] as? String == "completed", "Final metadata did not record completion")

        let second = try TranscriptRecoveryStore(outputURL: output, sourceAudioURL: source, recoveryRootURL: recovery)
        try require(second.recoveryDirectoryURL != store.recoveryDirectoryURL, "Recovery directories collide")
        try FileManager.default.createDirectory(at: second.partialTranscriptURL, withIntermediateDirectories: false)
        do {
            try second.save(progress)
            throw CheckFailure(description: "Partial write unexpectedly replaced a directory")
        } catch is POSIXError {}
        let fallbackJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: second.checkpointURL)) as! [String: Any]
        let fallbackCheckpoint = try JSONDecoder().decode(
            AudioTranscriptionCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: fallbackJSON["checkpoint"]!)
        )
        try require(fallbackCheckpoint == progress && second.lastCheckpoint == progress,
                    "A failed partial TXT write lost the already received response from JSON")
        try require(!second.hasPartialTranscript, "A directory was mistaken for a partial transcript")
        let secondOutput = directory.appendingPathComponent("second.txt")
        let failingMetadata = try TranscriptRecoveryStore(outputURL: secondOutput, sourceAudioURL: source, recoveryRootURL: recovery)
        try failingMetadata.save(progress)
        try FileManager.default.removeItem(at: failingMetadata.checkpointURL)
        try FileManager.default.createDirectory(at: failingMetadata.checkpointURL, withIntermediateDirectories: false)
        do {
            try failingMetadata.relocateSourceAudio(to: preservedAudio)
            throw CheckFailure(description: "Relocation unexpectedly replaced a directory with metadata")
        } catch is POSIXError {}
        try require(try Data(contentsOf: preservedAudio) == original,
                    "Failed metadata relocation damaged preserved audio")
        try failingMetadata.finish("Final survives metadata failure")
        try require(try String(contentsOf: secondOutput, encoding: .utf8) == "Final survives metadata failure",
                    "Metadata failure discarded a successful final transcript")
        try require(!failingMetadata.hasPartialTranscript, "Metadata failure kept obsolete partial text")
        try require(try Data(contentsOf: source) == original, "Recovery store modified the source audio")
    }

    private static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}

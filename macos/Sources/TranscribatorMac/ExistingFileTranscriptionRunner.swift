import Darwin
import Foundation
import TranscribatorCore

enum ExistingFileTranscriptionRunner {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--transcribe-existing")
    }

    static func runAndExit() async {
        do {
            let request = try parseRequest()
            try await transcribe(request)
            print("Транскрипт сохранён: \(request.outputURL.path)")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Ошибка: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func parseRequest() throws -> Request {
        let arguments = CommandLine.arguments
        guard let inputIndex = arguments.firstIndex(of: "--transcribe-existing"),
              arguments.indices.contains(inputIndex + 1),
              let outputPath = value(after: "--output", in: arguments) else {
            throw RecoveryError.usage
        }

        let inputURL = URL(fileURLWithPath: arguments[inputIndex + 1]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let modelName = value(after: "--model", in: arguments) ?? TranscriptionModel.transcribe.rawValue
        guard let model = TranscriptionModel(rawValue: modelName) else {
            throw RecoveryError.unknownModel(modelName)
        }
        return Request(inputURL: inputURL, outputURL: outputURL, model: model)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func transcribe(_ request: Request) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: request.inputURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw RecoveryError.inputMissing(request.inputURL.path)
        }
        guard !FileManager.default.fileExists(atPath: request.outputURL.path) else {
            throw RecoveryError.outputExists(request.outputURL.path)
        }

        guard let apiKey = try KeychainStore().read(), !apiKey.isEmpty else {
            throw RecoveryError.missingAPIKey
        }

        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribatorRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let workingRecordingURL = sessionDirectory.appendingPathComponent("prepared.m4a")
        try await MediaFilePreparer().prepare(
            sourceURL: request.inputURL,
            destinationURL: workingRecordingURL,
            quality: .standard
        )
        let client = OpenAITranscriptionClient(apiKey: apiKey)
        let transcript = try await AudioTranscriptionPipeline().transcribe(
            audioURL: workingRecordingURL,
            model: request.model,
            client: client
        ) { progress in
            guard case .transcribing(let index, let count) = progress else { return }
            FileHandle.standardError.write(
                Data("Транскрибирование \(index) из \(count)…\n".utf8)
            )
        }
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTranscriptAtomicallyWithoutOverwriting(
            transcript,
            to: request.outputURL
        )
    }

    private static func writeTranscriptAtomicallyWithoutOverwriting(
        _ transcript: String,
        to outputURL: URL
    ) throws {
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try Data(transcript.utf8).write(to: temporaryURL, options: .atomic)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RecoveryError.outputExists(outputURL.path)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    }

    private struct Request {
        let inputURL: URL
        let outputURL: URL
        let model: TranscriptionModel
    }
}

private enum RecoveryError: LocalizedError {
    case usage
    case inputMissing(String)
    case outputExists(String)
    case unknownModel(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .usage:
            "Использование: --transcribe-existing <audio-or-video> --output <output.txt> [--model <id>]"
        case .inputMissing(let path):
            "Аудиофайл не найден: \(path)"
        case .outputExists(let path):
            "Файл транскрипта уже существует: \(path)"
        case .unknownModel(let model):
            "Неизвестная модель: \(model)"
        case .missingAPIKey:
            "OpenAI API key не найден в Keychain"
        }
    }
}

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
        guard request.inputURL.pathExtension.lowercased() == "m4a" else {
            throw RecoveryError.unsupportedInput
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

        let workingRecordingURL = sessionDirectory.appendingPathComponent("recording.m4a")
        try FileManager.default.copyItem(at: request.inputURL, to: workingRecordingURL)
        let uploadFiles = try await AudioChunker().uploadFiles(for: workingRecordingURL)
        let client = OpenAITranscriptionClient(apiKey: apiKey)

        var results: [String] = []
        for (index, fileURL) in uploadFiles.enumerated() {
            FileHandle.standardError.write(
                Data("Транскрибирование \(index + 1) из \(uploadFiles.count)…\n".utf8)
            )
            let prompt = request.model == .diarize ? nil : results.last
            let text = try await client.transcribe(
                fileURL: fileURL,
                model: request.model,
                prompt: prompt
            )
            if !text.isEmpty { results.append(text) }
        }

        let transcript = results.joined(separator: "\n\n")
        guard !transcript.isEmpty else { throw RecoveryError.emptyTranscript }
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(transcript.utf8).write(
            to: request.outputURL,
            options: [.atomic, .withoutOverwriting]
        )
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
    case unsupportedInput
    case unknownModel(String)
    case missingAPIKey
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .usage:
            "Использование: --transcribe-existing <input.m4a> --output <output.txt> [--model <id>]"
        case .inputMissing(let path):
            "Аудиофайл не найден: \(path)"
        case .outputExists(let path):
            "Файл транскрипта уже существует: \(path)"
        case .unsupportedInput:
            "Повторная транскрибация сейчас поддерживает только M4A"
        case .unknownModel(let model):
            "Неизвестная модель: \(model)"
        case .missingAPIKey:
            "OpenAI API key не найден в Keychain"
        case .emptyTranscript:
            "OpenAI вернул пустую транскрипцию"
        }
    }
}

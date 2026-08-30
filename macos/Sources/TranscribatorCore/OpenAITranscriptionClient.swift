import Foundation

public final class OpenAITranscriptionClient: @unchecked Sendable {
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration)
        }
    }

    public func transcribe(
        fileURL: URL,
        model: TranscriptionModel,
        prompt: String? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        let multipart = MultipartFormData()
        multipart.addField(name: "model", value: model.rawValue)
        if model.usesAutomaticChunking {
            multipart.addField(name: "chunking_strategy", value: "auto")
        }
        if model == .diarize {
            multipart.addField(name: "response_format", value: "diarized_json")
        } else {
            multipart.addField(name: "response_format", value: "json")
            if model.supportsPrompt,
               let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                multipart.addField(name: "prompt", value: String(prompt.suffix(1_500)))
            }
        }
        multipart.addFile(
            name: "file",
            filename: fileURL.lastPathComponent,
            mimeType: "audio/mp4",
            data: fileData
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.body

        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw OpenAIError.invalidResponse
                }
                if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    throw OpenAIError.retryable(status: http.statusCode)
                }
                guard (200...299).contains(http.statusCode) else {
                    throw OpenAIError.api(
                        status: http.statusCode,
                        message: Self.errorMessage(from: data)
                    )
                }
                return try TranscriptionResponseParser.parse(data: data, model: model)
            } catch {
                if error is CancellationError
                    || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                lastError = error
                guard attempt < 2, Self.isRetryable(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        throw lastError ?? OpenAIError.invalidResponse
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case OpenAIError.retryable = error { return true }
        return error is URLError
    }

    private static func errorMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable { let message: String }
            let error: APIError
        }
        return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.message)
            ?? String(data: data, encoding: .utf8)
            ?? "Неизвестная ошибка OpenAI"
    }
}

public final class MultipartFormData {
    public let boundary = "Boundary-\(UUID().uuidString)"
    public private(set) var body = Data()
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public init() {}

    public func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public func addFile(name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
    }

    private func append(_ string: String) { body.append(Data(string.utf8)) }
}

public enum TranscriptionResponseParser {
    private struct Response: Decodable {
        struct Segment: Decodable {
            let speaker: String?
            let text: String
            let start: Double?
        }
        let text: String?
        let segments: [Segment]?
    }

    public static func parse(data: Data, model: TranscriptionModel) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if model == .diarize, let segments = response.segments, !segments.isEmpty {
            return segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let speaker = segment.speaker ?? "?"
                return "[\(speaker)] — \(text)"
            }.joined(separator: "\n")
        }
        return response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public enum OpenAIError: LocalizedError {
    case invalidResponse
    case retryable(status: Int)
    case api(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenAI вернул неизвестный ответ"
        case .retryable(let status):
            "OpenAI временно недоступен (HTTP \(status))"
        case .api(let status, let message):
            "OpenAI API: \(message) (HTTP \(status))"
        }
    }
}

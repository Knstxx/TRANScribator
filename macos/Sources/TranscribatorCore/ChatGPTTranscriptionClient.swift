import Foundation

/// Uses the installed ChatGPT app's session without copying it into persistent storage.
public final class ChatGPTTranscriptionClient: AudioTranscriptionRequesting, @unchecked Sendable {
    public typealias TokenProvider = @Sendable (_ refresh: Bool) async throws -> String

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    private let tokenProvider: TokenProvider
    private let session: URLSession

    public init(
        tokenProvider: @escaping TokenProvider,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.tokenProvider = tokenProvider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func transcribe(
        fileURL: URL,
        model: TranscriptionModel,
        prompt _: String? = nil
    ) async throws -> String {
        do {
            try Task.checkCancellation()
            guard model == .gptApp else { throw ChatGPTTranscriptionError.unsupportedModel }
            guard fileURL.isFileURL,
                  let audio = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                  !audio.isEmpty else {
                throw ChatGPTTranscriptionError.fileUnreadable
            }
            try Task.checkCancellation()

            let multipart = MultipartFormData()
            // Neither the source filename nor API model/prompt fields belong in this request.
            multipart.addFile(name: "file", filename: "audio.m4a", mimeType: "audio/mp4", data: audio)
            try Task.checkCancellation()
            let token: String
            do {
                token = try await tokenProvider(false)
            } catch let error as ChatGPTAppSessionError {
                switch error {
                case .notInstalled:
                    throw ChatGPTTranscriptionError.applicationMissing
                case .unavailable, .timedOut:
                    throw ChatGPTTranscriptionError.sessionUnavailable
                case .signInRequired:
                    throw ChatGPTTranscriptionError.authorizationRequired
                }
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                throw ChatGPTTranscriptionError.authorizationRequired
            }
            try Task.checkCancellation()
            guard Self.isValidBearerToken(token) else {
                throw ChatGPTTranscriptionError.authorizationRequired
            }

            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("CodexDesktop", forHTTPHeaderField: "originator")
            if let accountID = Self.routingAccountID(in: token) {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
            request.httpBody = multipart.body

            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  http.url == Self.endpoint else {
                throw ChatGPTTranscriptionError.invalidResponse
            }
            switch http.statusCode {
            case 200...299:
                return try Self.transcript(from: data)
            case 300...399:
                throw ChatGPTTranscriptionError.redirectBlocked
            case 401, 403:
                throw ChatGPTTranscriptionError.authorizationRequired
            case 429:
                throw ChatGPTTranscriptionError.rateLimited
            case 500...599:
                throw ChatGPTTranscriptionError.unavailable
            default:
                throw ChatGPTTranscriptionError.requestRejected
            }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            try Task.checkCancellation()
            if let safeError = error as? ChatGPTTranscriptionError { throw safeError }
            // Never expose server bodies, request details, bearer tokens, or URLSession diagnostics.
            throw ChatGPTTranscriptionError.network
        }
    }

    private static func transcript(from data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        guard data.count <= 256 * 1_024,
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ChatGPTTranscriptionError.invalidResponse
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ChatGPTTranscriptionError.emptyTranscript }
        return text
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func isValidBearerToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 32_768
            && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func routingAccountID(in token: String) -> String? {
        // This unverified JWT claim is only a routing hint, never an authorization decision.
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty, accountID.utf8.count <= 128,
              accountID.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || byte == 45 || byte == 95
              }) else { return nil }
        return accountID
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Refuse same-origin redirects too: the bearer token has one fixed destination.
            completionHandler(nil)
        }
    }
}

public enum ChatGPTTranscriptionError: LocalizedError {
    case unsupportedModel
    case fileUnreadable
    case applicationMissing
    case sessionUnavailable
    case authorizationRequired
    case redirectBlocked
    case rateLimited
    case unavailable
    case requestRejected
    case invalidResponse
    case emptyTranscript
    case network

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel:
            "Для сессии ChatGPT выберите модель GPT App"
        case .fileUnreadable:
            "Не удалось прочитать аудиофайл для GPT App"
        case .applicationMissing:
            "Установите актуальное приложение ChatGPT, чтобы использовать GPT App"
        case .sessionUnavailable:
            "Не удалось подключиться к ChatGPT. Проверьте версию приложения и повторите подключение GPT App"
        case .authorizationRequired:
            "Войдите в приложение ChatGPT и проверьте подключение GPT App"
        case .redirectBlocked:
            "ChatGPT перенаправил запрос. Откройте ChatGPT и подключите GPT App снова"
        case .rateLimited:
            "Достигнут лимит ChatGPT. Попробуйте позже"
        case .unavailable:
            "ChatGPT временно недоступен. Попробуйте позже"
        case .requestRejected:
            "ChatGPT не принял аудиозапись. Проверьте доступ к диктовке в приложении ChatGPT"
        case .invalidResponse:
            "ChatGPT вернул неизвестный ответ"
        case .emptyTranscript:
            "ChatGPT вернул пустую транскрипцию"
        case .network:
            "Не удалось связаться с ChatGPT. Проверьте подключение к интернету"
        }
    }
}

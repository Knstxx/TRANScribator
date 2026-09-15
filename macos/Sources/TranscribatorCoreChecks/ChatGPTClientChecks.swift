import Foundation
import TranscribatorCore

extension TranscribatorCoreChecks {
    static func checkChatGPTClient() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTClientChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("private-recording-name.m4a")
        try Data("offline-audio-fixture".utf8).write(to: audioURL)

        let payload = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "fixture-account-123"]
        ]).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let fixtureToken = "fixture.\(payload).signature"
        let tokens = ChatGPTTokenFixture(tokens: [fixtureToken])
        ChatGPTFixtureURLProtocol.fixture.reset([.response(200, try JSONEncoder().encode(["text": "  Привет  "]))])
        let client = ChatGPTTranscriptionClient(
            tokenProvider: { try await tokens.token(refresh: $0) },
            protocolClasses: [ChatGPTFixtureURLProtocol.self]
        )
        let transcript = try await client.transcribe(fileURL: audioURL, model: .gptApp, prompt: "private prompt")
        try require(transcript == "Привет", "GPT App must parse and trim dictation text")
        let requests = ChatGPTFixtureURLProtocol.fixture.requests
        try require(requests.count == 1, "GPT App must send one successful request")
        let request = requests[0]
        try require(request.url == URL(string: "https://chatgpt.com/backend-api/transcribe"), "GPT App must use the fixed official endpoint")
        try require(request.method == "POST", "GPT App must POST audio")
        try require(request.authorization == "Bearer \(fixtureToken)", "GPT App did not use the session token")
        try require(request.accountID == "fixture-account-123", "GPT App account routing is missing")
        try require(request.originator == "CodexDesktop", "GPT App must match the desktop dictation contract")
        try require(request.cookie == nil, "GPT App must not use browser cookies")
        let body = String(decoding: request.body, as: UTF8.self)
        try require(body.contains("name=\"file\"; filename=\"audio.m4a\""), "GPT App must use a fixed safe upload filename")
        try require(body.contains("Content-Type: audio/mp4"), "GPT App upload must declare the audio type")
        try require(body.contains("offline-audio-fixture"), "GPT App did not upload the audio")
        for forbidden in ["name=\"model\"", "name=\"prompt\"", "response_format", "chunking_strategy", "private-recording-name", "private prompt", fixtureToken] {
            try require(!body.contains(forbidden), "GPT App multipart contains an unrelated or private field")
        }

        let rejectedTokens = ChatGPTTokenFixture(tokens: ["expired-fixture"])
        ChatGPTFixtureURLProtocol.fixture.reset([
            .response(401, Data()),
            .response(200, try JSONEncoder().encode(["text": "Unexpected"]))
        ])
        let rejectedClient = ChatGPTTranscriptionClient(
            tokenProvider: { try await rejectedTokens.token(refresh: $0) },
            protocolClasses: [ChatGPTFixtureURLProtocol.self]
        )
        try await expectChatGPTFailure(.authorizationRequired) {
            try await rejectedClient.transcribe(fileURL: audioURL, model: .gptApp)
        }
        try require(ChatGPTFixtureURLProtocol.fixture.requests.count == 1, "GPT App must stop when the app session expires")
        let refreshFlags = await rejectedTokens.refreshFlags
        try require(refreshFlags == [false], "GPT App must never initiate a login or refresh the app session")

        for target in ["https://attacker.invalid/collect", "https://chatgpt.com/other-path"] {
            ChatGPTFixtureURLProtocol.fixture.reset([.redirect(URL(string: target)!)])
            try await expectChatGPTFailure(.redirectBlocked) {
                try await client.transcribe(fileURL: audioURL, model: .gptApp)
            }
            try require(ChatGPTFixtureURLProtocol.fixture.requests.count == 1, "GPT App followed a redirect with the user's session")
            try require(ChatGPTFixtureURLProtocol.fixture.requests.allSatisfy { $0.url?.absoluteString == "https://chatgpt.com/backend-api/transcribe" }, "GPT App sent credentials outside its fixed endpoint")
        }

        let untrustedSecret = "fixture-secret-must-never-appear-in-errors"
        let failureFixtures: [(ChatGPTFixtureURLProtocol.Action, ChatGPTTranscriptionError)] = [
            (.response(403, Data(untrustedSecret.utf8)), .authorizationRequired),
            (.response(429, Data(untrustedSecret.utf8)), .rateLimited),
            (.response(503, Data(untrustedSecret.utf8)), .unavailable),
            (.response(400, Data(untrustedSecret.utf8)), .requestRejected),
            (.response(200, Data(untrustedSecret.utf8)), .invalidResponse),
            (.response(200, Data("{}".utf8)), .invalidResponse),
            (.response(200, Data("{\"text\":null}".utf8)), .invalidResponse),
            (.response(200, try JSONEncoder().encode(["text": String(repeating: "x", count: 256 * 1_024)])), .invalidResponse),
            (.response(200, try JSONEncoder().encode(["text": "  \n "])), .emptyTranscript),
            (.failure(NSError(domain: "fixture-network", code: 1, userInfo: [NSLocalizedDescriptionKey: untrustedSecret])), .network)
        ]
        for (action, expected) in failureFixtures {
            ChatGPTFixtureURLProtocol.fixture.reset([action])
            try await expectChatGPTFailure(expected, forbidden: [untrustedSecret, fixtureToken]) {
                try await client.transcribe(fileURL: audioURL, model: .gptApp)
            }
            let failedRequests = ChatGPTFixtureURLProtocol.fixture.requests
            try require(failedRequests.count == 1, "GPT App errors must not trigger API fallback or unbounded retries")
            try require(failedRequests.allSatisfy { $0.url?.host == "chatgpt.com" }, "GPT App must never fall back to the paid API")
        }

        ChatGPTFixtureURLProtocol.fixture.reset([])
        let failingProvider = ChatGPTTranscriptionClient(
            tokenProvider: { _ in throw NSError(domain: "fixture-provider", code: 1, userInfo: [NSLocalizedDescriptionKey: untrustedSecret]) },
            protocolClasses: [ChatGPTFixtureURLProtocol.self]
        )
        try await expectChatGPTFailure(.authorizationRequired, forbidden: [untrustedSecret]) {
            try await failingProvider.transcribe(fileURL: audioURL, model: .gptApp)
        }
        let sessionFailures: [(ChatGPTAppSessionError, ChatGPTTranscriptionError)] = [
            (.notInstalled, .applicationMissing),
            (.unavailable, .sessionUnavailable),
            (.timedOut, .sessionUnavailable),
            (.signInRequired, .authorizationRequired)
        ]
        for (sessionError, expected) in sessionFailures {
            let unavailableClient = ChatGPTTranscriptionClient(
                tokenProvider: { _ in throw sessionError },
                protocolClasses: [ChatGPTFixtureURLProtocol.self]
            )
            try await expectChatGPTFailure(expected) {
                try await unavailableClient.transcribe(fileURL: audioURL, model: .gptApp)
            }
        }
        try require(ChatGPTFixtureURLProtocol.fixture.requests.isEmpty, "GPT App must preserve actionable session errors without sending audio")
        let invalidTokenClient = ChatGPTTranscriptionClient(
            tokenProvider: { _ in "fixture\r\nInjected: value" },
            protocolClasses: [ChatGPTFixtureURLProtocol.self]
        )
        try await expectChatGPTFailure(.authorizationRequired) {
            try await invalidTokenClient.transcribe(fileURL: audioURL, model: .gptApp)
        }
        try await expectChatGPTFailure(.unsupportedModel) {
            try await client.transcribe(fileURL: audioURL, model: .whisper)
        }
        try require(ChatGPTFixtureURLProtocol.fixture.requests.isEmpty, "GPT App must not send a request without a valid session and provider")

        ChatGPTFixtureURLProtocol.fixture.reset([.failure(URLError(.cancelled))])
        do {
            _ = try await client.transcribe(fileURL: audioURL, model: .gptApp)
            throw CheckFailure(description: "GPT App ignored URLSession cancellation")
        } catch is CancellationError { }
        try require(ChatGPTFixtureURLProtocol.fixture.requests.count == 1, "GPT App retried a cancelled request")

        ChatGPTFixtureURLProtocol.fixture.reset([])
        let cancelledProvider = ChatGPTTranscriptionClient(
            tokenProvider: { _ in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return "unused-token"
            },
            protocolClasses: [ChatGPTFixtureURLProtocol.self]
        )
        let task = Task { try await cancelledProvider.transcribe(fileURL: audioURL, model: .gptApp) }
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure(description: "GPT App ignored task cancellation")
        } catch is CancellationError { }
        try require(ChatGPTFixtureURLProtocol.fixture.requests.isEmpty, "A cancelled GPT App task sent audio")
        try await checkChatGPTDiagnostics(fileURL: audioURL)
    }

    private static func checkChatGPTDiagnostics(fileURL: URL) async throws {
        let observed = ChatGPTDiagnosticsFixture()
        let client = ChatGPTTranscriptionClient(
            tokenProvider: { _ in "diagnostic-fixture-token" },
            diagnostics: { observed.append($0) },
            protocolClasses: [ChatGPTFixtureURLProtocol.self]
        )
        let secret = "private-fixture-value-must-not-appear"
        let longText = String(repeating: "Полная строка 🙂 с концом.\n", count: 2_000) + "Последняя фраза."
        let wireText = "  \n" + longText + "  \n"
        let response = try JSONSerialization.data(withJSONObject: [
            "text": wireText,
            "asset_pointer": secret,
            "unknown_field": secret,
            "private_customer_Alice": "Another private key must remain hidden",
            "finish_reason": "stop",
            "truncated": false,
            "incomplete": false,
            secret: "This key is not a diagnostic identifier"
        ])
        try require(response.count < 256 * 1_024, "Long-text fixture must fit the response limit")
        ChatGPTFixtureURLProtocol.fixture.reset([.response(200, response)])
        let returned = try await client.transcribe(fileURL: fileURL, model: .gptApp)
        try require(returned == longText, "GPT App truncated or changed a long successful transcript")
        try require(observed.events.count == 1, "GPT App must emit one diagnostic per received response")
        let event = observed.events[0]
        try require(event.httpStatus == 200 && event.responseBytes == response.count,
                    "GPT App diagnostics lost response status or size")
        try require(event.textCharacters == wireText.count && event.textBytes == wireText.utf8.count,
                    "GPT App diagnostics must measure untrimmed Unicode text correctly")
        try require(event.jsonFieldNames == ["asset_pointer", "finish_reason", "incomplete", "text", "truncated"]
                    && event.unknownFieldCount == 3,
                    "GPT App diagnostics must retain only known field names and count unknown fields")
        try require(event.finishReason == "stop" && event.truncated == false && event.incomplete == false,
                    "GPT App diagnostics lost known literal completion indicators")
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        for forbidden in [secret, "private_customer_Alice", "unknown_field", "diagnostic-fixture-token", "Последняя фраза", "Полная строка"] {
            try require(!encoded.contains(forbidden), "GPT App diagnostics exposed transcript or secret data")
        }

        // These fields are diagnostic observations only until the internal endpoint's semantics
        // are established; they must not silently change or discard the returned transcript.
        ChatGPTFixtureURLProtocol.fixture.reset([.response(200, try JSONSerialization.data(withJSONObject: [
            "text": "Ответ сохранён без изменений",
            "finish_reason": "length", "truncated": true, "incomplete": true
        ]))])
        let flagged = try await client.transcribe(fileURL: fileURL, model: .gptApp)
        try require(flagged == "Ответ сохранён без изменений", "Diagnostic flags changed the transcript")
        let flaggedEvent = observed.events[1]
        try require(flaggedEvent.finishReason == "length" && flaggedEvent.truncated == true && flaggedEvent.incomplete == true,
                    "GPT App must report explicit completion indicators when present")
        try require(flaggedEvent.unknownFieldCount == 0, "Known diagnostic fields were counted as unknown")

        ChatGPTFixtureURLProtocol.fixture.reset([.response(200, try JSONSerialization.data(withJSONObject: [
            "text": "Готово", "finish_reason": secret, "truncated": 1, "incomplete": "true"
        ]))])
        _ = try await client.transcribe(fileURL: fileURL, model: .gptApp)
        let unknown = observed.events[2]
        try require(unknown.finishReason == nil && unknown.truncated == nil && unknown.incomplete == nil,
                    "GPT App diagnostics must reject arbitrary strings and non-boolean flags")
        try require(!String(decoding: try JSONEncoder().encode(unknown), as: UTF8.self).contains(secret),
                    "GPT App diagnostics leaked an unrecognized finish_reason")

        let malformed = Data("not-json".utf8)
        ChatGPTFixtureURLProtocol.fixture.reset([.response(200, malformed)])
        try await expectChatGPTFailure(.invalidResponse) {
            try await client.transcribe(fileURL: fileURL, model: .gptApp)
        }
        let invalid = observed.events[3]
        try require(invalid.responseBytes == malformed.count && invalid.textCharacters == nil
                    && invalid.textBytes == nil && invalid.jsonFieldNames.isEmpty && invalid.unknownFieldCount == 0,
                    "GPT App malformed-response diagnostics must remain available and safe")

        ChatGPTFixtureURLProtocol.fixture.reset([.response(403, try JSONEncoder().encode(["message": secret]))])
        try await expectChatGPTFailure(.authorizationRequired, forbidden: [secret]) {
            try await client.transcribe(fileURL: fileURL, model: .gptApp)
        }
        let rejected = observed.events[4]
        try require(rejected.httpStatus == 403 && rejected.jsonFieldNames == ["message"]
                    && rejected.textCharacters == nil, "GPT App must diagnose rejected HTTP responses")
        try require(!String(decoding: try JSONEncoder().encode(rejected), as: UTF8.self).contains(secret),
                    "GPT App rejected-response diagnostics exposed server text")
    }

    private static func expectChatGPTFailure(
        _ expected: ChatGPTTranscriptionError,
        forbidden: [String] = [],
        operation: () async throws -> String
    ) async throws {
        do {
            _ = try await operation()
            throw CheckFailure(description: "Expected a safe GPT App failure")
        } catch let error as ChatGPTTranscriptionError {
            try require(error.localizedDescription == expected.localizedDescription, "GPT App returned the wrong safe error")
            for secret in forbidden {
                try require(!error.localizedDescription.contains(secret), "GPT App exposed sensitive response details in an error")
                try require(!String(reflecting: error).contains(secret), "GPT App retained sensitive response details in an error")
            }
        }
    }
}

private final class ChatGPTDiagnosticsFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ChatGPTTranscriptionDiagnostics] = []

    var events: [ChatGPTTranscriptionDiagnostics] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func append(_ event: ChatGPTTranscriptionDiagnostics) {
        lock.lock()
        defer { lock.unlock() }
        captured.append(event)
    }
}

private actor ChatGPTTokenFixture {
    private let tokens: [String]
    private(set) var refreshFlags: [Bool] = []

    init(tokens: [String]) { self.tokens = tokens }

    func token(refresh: Bool) throws -> String {
        refreshFlags.append(refresh)
        return tokens[min(refreshFlags.count - 1, tokens.count - 1)]
    }
}

private final class ChatGPTFixtureURLProtocol: URLProtocol {
    enum Action {
        case response(Int, Data)
        case redirect(URL)
        case failure(Error)
    }

    struct CapturedRequest {
        let url: URL?
        let method: String?
        let authorization: String?
        let accountID: String?
        let originator: String?
        let cookie: String?
        let body: Data
    }

    final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [Action] = []
        private var captured: [CapturedRequest] = []

        var requests: [CapturedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }

        func reset(_ actions: [Action]) {
            lock.lock()
            defer { lock.unlock() }
            self.actions = actions
            captured = []
        }

        func record(_ request: URLRequest) -> Action {
            lock.lock()
            defer { lock.unlock() }
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            captured.append(CapturedRequest(
                url: request.url,
                method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                accountID: request.value(forHTTPHeaderField: "ChatGPT-Account-ID"),
                originator: request.value(forHTTPHeaderField: "originator"),
                cookie: request.value(forHTTPHeaderField: "Cookie"),
                body: body
            ))
            guard !actions.isEmpty else {
                return .failure(CheckFailure(description: "Unexpected offline GPT App request"))
            }
            return actions.removeFirst()
        }
    }

    static let fixture = Fixture()

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let action = Self.fixture.record(request)
        switch action {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let url):
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
            var redirected = request
            redirected.url = url
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

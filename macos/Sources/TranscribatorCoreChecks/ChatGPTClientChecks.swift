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

import AppKit
import Darwin
import Foundation
import Security

public enum ChatGPTAppStatus: Equatable, Sendable {
    case notInstalled
    case signInRequired
    case ready
    case unavailable
}

public enum ChatGPTAppSessionError: LocalizedError, Sendable {
    case notInstalled
    case signInRequired
    case unavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Установите актуальное приложение ChatGPT, чтобы использовать GPT App."
        case .signInRequired:
            return "Откройте приложение ChatGPT и войдите в свой аккаунт, затем повторите проверку GPT App."
        case .unavailable:
            return "Не удалось подключиться к ChatGPT. Проверьте, что установлена актуальная версия приложения."
        case .timedOut:
            return "ChatGPT не ответил вовремя. Повторите подключение."
        }
    }
}

/// Uses the installed, signed desktop helper's managed ChatGPT login. The app
/// never opens auth.json, browser storage, or ChatGPT's Keychain entries.
/// Access tokens travel only over private pipes and are returned in memory for
/// one first-party transcription request. This actor does not cache them.
public actor ChatGPTAppSession {
    public init() {}

    public func checkStatus() async -> ChatGPTAppStatus {
        do {
            let connection = try await makeConnection()
            defer { connection.stop() }
            try await connection.initialize()
            guard try await accountStatus(connection) == .ready else { return .signInRequired }
            _ = try await existingToken(connection)
            return .ready
        } catch ChatGPTAppSessionError.signInRequired {
            return .signInRequired
        } catch ChatGPTAppSessionError.notInstalled {
            return .notInstalled
        } catch {
            return .unavailable
        }
    }

    /// Each call re-reads the existing desktop session. `refresh` requests that
    /// same re-read for a caller retry; it never starts or forces an OAuth refresh.
    public func accessToken(refresh _: Bool = false) async throws -> String {
        let connection = try await makeConnection()
        defer { connection.stop() }
        try await connection.initialize()
        guard try await accountStatus(connection) == .ready else {
            throw ChatGPTAppSessionError.signInRequired
        }
        return try await existingToken(connection)
    }

    private func existingToken(_ connection: ChatGPTAppRPCProcess) async throws -> String {
        // This declared legacy RPC is also used by the installed desktop.
        // The helper owns normal session maintenance; TRANScribator never
        // requests login, logout, or a forced token refresh.
        let response = try await connection.request("getAuthStatus", params: [
            "includeToken": true, "refreshToken": false
        ])
        guard let method = response["authMethod"] as? String,
              ["chatgpt", "chatgptAuthTokens"].contains(method),
              let token = response["authToken"] as? String,
              !token.isEmpty, token.utf8.count <= 64 * 1024,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ChatGPTAppSessionError.signInRequired
        }
        // The claim is used only to identify an expired session locally; the
        // first-party server remains responsible for validating the token.
        if let expiry = Self.expiration(of: token), expiry <= Date().timeIntervalSince1970 + 30 {
            throw ChatGPTAppSessionError.signInRequired
        }
        return token
    }

    static func expiration(of token: String) -> TimeInterval? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["exp"] as? TimeInterval
    }

    private func makeConnection() async throws -> ChatGPTAppRPCProcess {
        try Task.checkCancellation()
        let executable = try await ChatGPTAppInstallation.executable()
        try Task.checkCancellation()
        return try ChatGPTAppRPCProcess(executableURL: executable)
    }

    private func accountStatus(_ connection: ChatGPTAppRPCProcess) async throws -> ChatGPTAppStatus {
        let response = try await connection.request("account/read", params: ["refreshToken": false])
        guard let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            return .signInRequired
        }
        return .ready
    }
}

private enum ChatGPTAppInstallation {
    static func executable() async throws -> URL {
        let registered = await MainActor.run {
            ["com.openai.codex", "com.openai.chat"].compactMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }
        }
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let candidates = registered + roots.flatMap { root in
            ["ChatGPT.app", "Codex.app"].map { root.appendingPathComponent($0, isDirectory: true) }
        }
        var sawApplication = false
        for candidate in candidates {
            let app = candidate.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: app.path) else { continue }
            sawApplication = true
            guard let identifier = Bundle(url: app)?.bundleIdentifier,
                  ["com.openai.codex", "com.openai.chat"].contains(identifier) else { continue }
            let helper = app.appendingPathComponent("Contents/Resources/codex").resolvingSymlinksInPath()
            guard helper.path.hasPrefix(app.path + "/"),
                  FileManager.default.isExecutableFile(atPath: helper.path),
                  isOfficialCode(app, identifier: identifier), isOfficialCode(helper, identifier: "codex") else { continue }
            return helper
        }
        throw sawApplication ? ChatGPTAppSessionError.unavailable : ChatGPTAppSessionError.notInstalled
    }

    private static func isOfficialCode(_ url: URL, identifier: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"\(identifier)\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}

/// Internal transport seam permits offline protocol checks without exposing an
/// arbitrary executable override to application callers. All mutable transport
/// state is confined to `queue`; no subprocess output is ever logged.
final class ChatGPTAppRPCProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TRANScribator.ChatGPT.auth")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let directory: URL
    private var buffer = Data()
    private var nextID = 0
    private var stopped = false
    private var stoppedError: Error = ChatGPTAppSessionError.unavailable
    private var requests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestTimers: [Int: DispatchWorkItem] = [:]

    init(executableURL: URL) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcribator-chatgpt-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            process.executableURL = executableURL
            process.currentDirectoryURL = directory
            process.arguments = ["-c", "model_provider=\"openai\"", "-c", "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"",
                                 "-c", "analytics.enabled=false", "app-server", "--listen", "stdio://"]
            process.environment = Self.environment()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { [weak self] in self?.receive(data) }
            }
            process.terminationHandler = { [weak self] _ in self?.stop() }
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            try? FileManager.default.removeItem(at: directory)
            throw ChatGPTAppSessionError.unavailable
        }
    }

    static func environment(source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // No inherited API keys, proxies, custom endpoints, dynamic-loader
        // variables, or logging settings reach the helper.
        var result = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "RUST_LOG": "off"]
        for key in ["USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = source[key] { result[key] = value }
        }
        // Preserve an explicitly configured desktop profile, without opening
        // any of its credential files ourselves.
        if let value = source["CODEX_HOME"], value.hasPrefix("/") { result["CODEX_HOME"] = value }
        return result
    }

    func initialize() async throws {
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "transcribator_gpt_app", "title": "TRANScribator", "version": "1.0"],
            "capabilities": ["experimentalApi": false]
        ])
        try await notify("initialized")
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped else {
                        continuation.resume(throwing: self.stoppedError)
                        return
                    }
                    self.nextID += 1
                    let id = self.nextID
                    self.requests[id] = continuation
                    let timer = DispatchWorkItem { [weak self] in self?.stopOnQueue(error: ChatGPTAppSessionError.timedOut) }
                    self.requestTimers[id] = timer
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                    self.write(["id": id, "method": method, "params": params])
                }
            }
        } onCancel: {
            self.stop(error: CancellationError())
        }
    }

    private func notify(_ method: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.stopped else {
                    continuation.resume(throwing: self.stoppedError)
                    return
                }
                self.write(["method": method])
                if self.stopped { continuation.resume(throwing: self.stoppedError) }
                else { continuation.resume() }
            }
        }
    }

    func stop(error: Error = ChatGPTAppSessionError.unavailable) {
        queue.async { self.stopOnQueue(error: error) }
    }

    private func write(_ value: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            stopOnQueue(error: ChatGPTAppSessionError.unavailable)
        }
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        guard !data.isEmpty, buffer.count + data.count <= 1024 * 1024 else {
            stopOnQueue(error: ChatGPTAppSessionError.unavailable)
            return
        }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard line.count <= 256 * 1024,
                  let payload = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                stopOnQueue(error: ChatGPTAppSessionError.unavailable)
                return
            }
            if let id = payload["id"] as? Int, let continuation = requests.removeValue(forKey: id) {
                requestTimers.removeValue(forKey: id)?.cancel()
                if payload["error"] != nil {
                    // Never propagate server messages: they can include URLs,
                    // request details, or credential material.
                    continuation.resume(throwing: ChatGPTAppSessionError.unavailable)
                } else if let result = payload["result"] as? [String: Any] {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: ChatGPTAppSessionError.unavailable)
                }
            }
        }
    }

    private func stopOnQueue(error: Error) {
        guard !stopped else { return }
        stopped = true
        stoppedError = error
        buffer.removeAll(keepingCapacity: false)
        requestTimers.values.forEach { $0.cancel() }
        requestTimers.removeAll()
        let pending = requests.values
        requests.removeAll()
        pending.forEach { $0.resume(throwing: error) }
        // Unblock callers and stop the writer before closing the read handle.
        // FileHandle teardown may synchronize with a pending read callback.
        // The hard-kill fallback runs independently of this cleanup queue.
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

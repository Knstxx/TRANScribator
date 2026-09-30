import Darwin
import Foundation

// Compile together with ChatGPTAppSession.swift to exercise its internal
// transport seam. No installed helper, real credentials, or network are used.
@main
struct ChatGPTAppSessionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError.failed(message) }
    }

    enum CheckError: Error { case failed(String) }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gpt-session-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try checkHelperDiscovery(in: directory)
        let server = directory.appendingPathComponent("mock-helper")
        let script = #"""
        #!/bin/sh
        echo $$ > "$0.pid"
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":1,"result":{}}\n' ;;
            *account*read*)
              printf '{"id":2,"result":{"acc'
              /bin/sleep 0.01
              printf 'ount":{"type":"chatgpt"}}}\n'
              ;;
            *'"method":"getAuthStatus"'*)
              case "$line" in
                *'"refreshToken":false'*) printf '{"id":3,"result":{"authMethod":"chatgpt","authToken":"offline-fixture"}}\n' ;;
                *) printf '{"id":3,"error":{"message":"wrong refresh contract"}}\n' ;;
              esac
              ;;
            *test*error*) printf '{"id":2,"error":{"message":"sensitive-should-not-escape"}}\n' ;;
            *test*oversized*)
              /usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\000' a
              printf '\n'
              ;;
          esac
        done
        """#
        try script.write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)

        let env = ChatGPTAppRPCProcess.environment(source: [
            "OPENAI_API_KEY": "fixture", "CODEX_API_KEY": "fixture", "CODEX_ACCESS_TOKEN": "fixture",
            "HTTPS_PROXY": "https://example.invalid", "OPENAI_BASE_URL": "https://example.invalid",
            "RUST_LOG": "trace", "DYLD_INSERT_LIBRARIES": "fixture", "CODEX_HOME": "/fixture/profile"
        ])
        try require(env["OPENAI_API_KEY"] == nil && env["CODEX_API_KEY"] == nil && env["CODEX_ACCESS_TOKEN"] == nil, "API credentials escaped environment filter")
        try require(env["HTTPS_PROXY"] == nil && env["OPENAI_BASE_URL"] == nil && env["DYLD_INSERT_LIBRARIES"] == nil, "Unsafe environment variable retained")
        try require(env["RUST_LOG"] == "off" && env["CODEX_HOME"] == "/fixture/profile", "Managed profile or logging setup incorrect")
        let claims = Data(#"{"exp":1234}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        try require(ChatGPTAppSession.expiration(of: "header.\(claims).signature") == 1234, "JWT expiry parsing failed")
        try require(ChatGPTAppSession.expiration(of: "malformed") == nil, "Malformed token unexpectedly decoded")

        let connection = try ChatGPTAppRPCProcess(executableURL: server)
        try await connection.initialize()
        let account = try await connection.request("account/read", params: ["refreshToken": false])
        try require((account["account"] as? [String: Any])?["type"] as? String == "chatgpt", "Fragmented JSONL response was lost")
        let auth = try await connection.request("getAuthStatus", params: ["includeToken": true, "refreshToken": false])
        try require(auth["authMethod"] as? String == "chatgpt", "Existing-session RPC contract failed")
        connection.stop()

        let errors = try ChatGPTAppRPCProcess(executableURL: server)
        try await errors.initialize()
        do {
            _ = try await errors.request("test/error", params: [:])
            throw CheckError.failed("Server error was accepted")
        } catch let error as ChatGPTAppSessionError {
            try require(!error.localizedDescription.contains("sensitive-should-not-escape"), "Raw server error leaked")
        }
        errors.stop()

        let oversized = try ChatGPTAppRPCProcess(executableURL: server)
        try await oversized.initialize()
        do {
            _ = try await oversized.request("test/oversized", params: [:])
            throw CheckError.failed("Oversized response was accepted")
        } catch ChatGPTAppSessionError.unavailable { }
        oversized.stop()

        let timed = try ChatGPTAppRPCProcess(executableURL: server)
        try await timed.initialize()
        let timeoutPID = try Int32(String(contentsOf: server.appendingPathExtension("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)).unwrap()
        do {
            _ = try await timed.request("test/hang", params: [:], timeout: 0.05)
            throw CheckError.failed("Unresponsive helper did not time out")
        } catch ChatGPTAppSessionError.timedOut { }
        try await Task.sleep(for: .milliseconds(650))
        try require(Darwin.kill(timeoutPID, 0) != 0, "Timed-out child was left alive")

        let cancelled = try ChatGPTAppRPCProcess(executableURL: server)
        try await cancelled.initialize()
        let cancellationPID = try Int32(String(contentsOf: server.appendingPathExtension("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)).unwrap()
        let task = Task { try await cancelled.request("test/hang", params: [:]) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            throw CheckError.failed("Cancellation was ignored")
        } catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(650))
        try require(Darwin.kill(cancellationPID, 0) != 0, "Cancelled child was left alive")

        let exitedServer = directory.appendingPathComponent("immediate-exit")
        try "#!/bin/sh\nexit 0\n".write(to: exitedServer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exitedServer.path)
        let exited = try ChatGPTAppRPCProcess(executableURL: exitedServer)
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await exited.request("initialize", params: [:], timeout: 1)
            throw CheckError.failed("Exited child was accepted")
        } catch ChatGPTAppSessionError.unavailable { }
        exited.stop()

        let resistantServer = directory.appendingPathComponent("resistant-helper")
        let resistantScript = #"""
        #!/bin/sh
        trap '' TERM
        echo $$ > "$0.pid"
        IFS= read -r line
        printf '{"id":1,"result":{}}\n'
        while :; do :; done
        """#
        try resistantScript.write(to: resistantServer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resistantServer.path)
        let resistant = try ChatGPTAppRPCProcess(executableURL: resistantServer)
        try await resistant.initialize()
        let resistantPID = try Int32(String(contentsOf: resistantServer.appendingPathExtension("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)).unwrap()
        do {
            _ = try await resistant.request("test/hang", params: [:], timeout: 0.05)
            throw CheckError.failed("TERM-resistant helper did not time out")
        } catch ChatGPTAppSessionError.timedOut { }
        try await Task.sleep(for: .milliseconds(850))
        try require(Darwin.kill(resistantPID, 0) != 0, "TERM-resistant child escaped fallback kill")

        let beforeInitialize = try ChatGPTAppRPCProcess(executableURL: server)
        let gate = Gate()
        let early = Task {
            defer { beforeInitialize.stop() }
            await gate.wait()
            try await beforeInitialize.initialize()
        }
        early.cancel()
        await gate.release()
        do {
            try await early.value
            throw CheckError.failed("Cancellation before initialization was ignored")
        } catch is CancellationError { }
        print("GPT App auth checks passed: signed helper layouts, containment, private protocol, session reuse, environment, expiry, redaction, bounds, timeout, cancellation, early cancellation, immediate exit, forced child termination.")
    }

    static func checkHelperDiscovery(in directory: URL) throws {
        let manager = FileManager.default
        let app = directory.appendingPathComponent("Fixture.app").resolvingSymlinksInPath()
        let legacy = app.appendingPathComponent("Contents/Resources/codex")
        let packaged = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let wrapper = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let identifier = "com.openai.codex"
        // These files are never executed. The fake verifier approves only the
        // expected app and helper identities, while real signature validation
        // must reject this unsigned fixture.
        func createExecutable(_ url: URL) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("offline fixture".utf8).write(to: url)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let approved: (URL, String) -> Bool = { url, expectedIdentifier in
            (url.path == app.path && expectedIdentifier == identifier)
                || ([legacy.path, packaged.path].contains(url.path) && expectedIdentifier == "codex")
        }
        try createExecutable(legacy)
        try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier, verifyCode: approved)?.path == legacy.path,
                    "Legacy desktop helper layout was lost")
        try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier) == nil,
                    "Unsigned fixture app passed real signature validation")
        try manager.removeItem(at: legacy)
        try createExecutable(packaged)
        try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier, verifyCode: approved)?.path == packaged.path,
                    "Packaged desktop helper layout was not discovered")
        try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier, verifyCode: { _, _ in false }) == nil,
                    "Untrusted application was accepted")
        try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier, verifyCode: { url, _ in url.path == app.path }) == nil,
                    "Untrusted helper was accepted")
        try createExecutable(legacy)
        try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier, verifyCode: approved)?.path == legacy.path,
                    "Legacy layout precedence changed")
        try manager.removeItem(at: legacy)
        try manager.removeItem(at: packaged)
        try createExecutable(wrapper)
        try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier, verifyCode: { _, _ in true }) == nil,
                    "Shell wrapper was accepted as a helper")
        let outside = directory.appendingPathComponent("outside-helper")
        try createExecutable(outside)
        for path in [legacy, packaged] {
            try manager.createSymbolicLink(at: path, withDestinationURL: outside)
            try require(ChatGPTAppInstallation.verifiedHelper(in: app, identifier: identifier, verifyCode: { _, _ in true }) == nil,
                        "Helper symlink escaped the application bundle")
            try manager.removeItem(at: path)
        }
    }

    actor Gate {
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw ChatGPTAppSessionChecks.CheckError.failed("Missing mock child identifier") }
        return self
    }
}

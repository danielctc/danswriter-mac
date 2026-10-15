import Foundation
import Darwin
import Security
@testable import WriteOnAI

@main
struct WriteOnAIChecks {
    static func main() async {
        do {
            try checkKeychainPresenceQueries()
            try checkRequestDefaultsAndLifecycle()
            try checkParserBoundaries()
            try await checkOversizeRequest()
            try await checkAPIAdapter()
            try await checkCLIAndTimeout()
            if ProcessInfo.processInfo.environment["WRITE_ON_AI_SUBSCRIPTION_SMOKE"] == "1" {
                try await checkSubscriptionSmoke()
            }
            print("WRITE_ON_AI_CHECKS_PASSED")
        } catch {
            fputs("WriteOnAI checks failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

func checkKeychainPresenceQueries() throws {
        let service = "org.danswriter.credentials"
        for provider in AIProvider.allCases {
            let query = KeychainStore.keyPresenceQuery(for: provider)
            precondition(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            precondition(query[kSecAttrService as String] as? String == service)
            precondition(query[kSecAttrAccount as String] as? String == provider.rawValue)
            precondition(query[kSecReturnAttributes as String] as? Bool == true)
            precondition(query[kSecReturnData as String] == nil, "AI status query must never request credential data")
            precondition(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            let aiFound = try KeychainStore.keyPresenceResult(for: errSecSuccess)
            let aiMissing = try KeychainStore.keyPresenceResult(for: errSecItemNotFound)
            precondition(aiFound)
            precondition(!aiMissing)
            do {
                _ = try KeychainStore.keyPresenceResult(for: errSecInteractionNotAllowed)
                preconditionFailure("AI Keychain status must be unavailable when authentication UI would be required")
            } catch let error as AIError {
                precondition(error == .keychain("Status unavailable (\(errSecInteractionNotAllowed))."))
            }
        }

        let valyuQuery = ValyuKeychainStore.keyPresenceQuery()
        precondition(valyuQuery[kSecClass as String] as? String == kSecClassGenericPassword as String)
        precondition(valyuQuery[kSecAttrService as String] as? String == "org.danswriter.valyu")
        precondition(valyuQuery[kSecAttrAccount as String] as? String == "valyu")
        precondition(valyuQuery[kSecReturnAttributes as String] as? Bool == true)
        precondition(valyuQuery[kSecReturnData as String] == nil, "Valyu status query must never request credential data")
        precondition(valyuQuery[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        let valyuFound = try ValyuKeychainStore.keyPresenceResult(for: errSecSuccess)
        let valyuMissing = try ValyuKeychainStore.keyPresenceResult(for: errSecItemNotFound)
        precondition(valyuFound)
        precondition(!valyuMissing)
        do {
            _ = try ValyuKeychainStore.keyPresenceResult(for: errSecInteractionNotAllowed)
            preconditionFailure("Valyu Keychain status must be unavailable when authentication UI would be required")
        } catch let error as ValyuResearchError {
            precondition(error == .keychain)
        }
}

func checkRequestDefaultsAndLifecycle() throws {
        let blank = AIConfiguration()
        precondition(blank.modelForRequest == "gpt-6-luna", "Blank Codex subscription model did not resolve to the lightweight default")
        precondition(blank.codexRequestOverrides == ["model_reasoning_effort=\"low\"", "service_tier=\"default\""])
        precondition(blank.model.isEmpty, "Request defaults must not overwrite the saved preference")
        let custom = AIConfiguration(provider: .codex, connection: .subscription, model: "account-model")
        precondition(custom.modelForRequest == "account-model" && custom.codexRequestOverrides.isEmpty)
        let api = AIConfiguration(provider: .codex, connection: .api)
        precondition(api.modelForRequest.isEmpty && api.codexRequestOverrides.isEmpty)
        let cli = CLIProcessRunner()
        let args = cli.arguments(provider: .codex, model: blank.modelForRequest, schemaPath: "/tmp/schema.json", codexRequestOverrides: blank.codexRequestOverrides)
        precondition(args.contains("--model") && args[args.firstIndex(of: "--model")! + 1] == "gpt-6-luna")
        precondition(args.contains("model_reasoning_effort=\"low\"") && args.contains("service_tier=\"default\""))
        let customArgs = cli.arguments(provider: .codex, model: custom.modelForRequest, schemaPath: "/tmp/schema.json", codexRequestOverrides: custom.codexRequestOverrides)
        precondition(!customArgs.contains(where: { $0.hasPrefix("service_tier=") || $0.hasPrefix("model_reasoning_effort=") }))

        var requests = AIRequestLifecycle()
        guard let first = requests.begin() else { preconditionFailure("First alternatives request was rejected") }
        precondition(requests.begin() == nil, "Repeated click restarted an in-flight request")
        requests.cancel(first)
        precondition(!requests.isCurrent(first), "Cancelled request remained current")
        guard let second = requests.begin() else { preconditionFailure("Request could not restart after cancellation") }
        precondition(!requests.finish(first), "Late completion from cancelled request cleared newer request state")
        precondition(requests.isCurrent(second))
        precondition(requests.finish(second) && !requests.isBusy)
}

func checkSubscriptionSmoke() async throws {
        let service = AIService()
        let requestedProvider = ProcessInfo.processInfo.environment["WRITE_ON_AI_SUBSCRIPTION_PROVIDER"]
        let providers = requestedProvider.flatMap(AIProvider.init(rawValue:)).map { [$0] } ?? AIProvider.allCases
        for provider in providers {
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            let configURL = URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml")
            let originalCodexConfig = provider == .codex ? try Data(contentsOf: configURL) : nil
            let configuration = AIConfiguration(provider: provider, connection: .subscription)
            let request = AIRequest(action: .alternatives, document: "The small team shipped the first draft on Friday.")
            let result: AIResult
            let started = Date()
            do { result = try await service.generate(request, configuration: configuration) }
            catch { print("\(provider.rawValue) subscription synthetic request failed: \(error)"); throw error }
            precondition(!result.alternatives.isEmpty)
            if let originalCodexConfig {
                let currentCodexConfig = try Data(contentsOf: configURL)
                precondition(currentCodexConfig == originalCodexConfig, "Codex user config changed during isolated request")
            }
            print(String(format: "%@ subscription synthetic generation passed in %.2f seconds", provider.rawValue, Date().timeIntervalSince(started)))
        }
}

func checkParserBoundaries() throws {
        let valid = Data(#"{"alternatives":["A clearer line.","A clearer line."],"suggestions":[{"quote":"A sentence.","replacement":"A line.","reason":"Shorter."}]}"#.utf8)
        let result = try AIResponseParser.parseJSON(valid, action: .proofread, sourceDocument: "A sentence.")
        precondition(result.alternatives == ["A clearer line."])
        precondition(result.suggestions.count == 1)

        let ambiguous = Data(#"{"alternatives":[],"suggestions":[{"quote":"same","replacement":null,"reason":"trim"}]}"#.utf8)
        do {
            _ = try AIResponseParser.parseJSON(ambiguous, action: .trimLight, sourceDocument: "same same")
            preconditionFailure("ambiguous quote was accepted")
        } catch let error as AIError {
            precondition(error == .noUniqueMatch("same"))
        }

        let rewrite = Data(#"{"alternatives":[],"suggestions":[{"quote":"A sentence.","replacement":"Rewrite","reason":"trim"}]}"#.utf8)
        do {
            _ = try AIResponseParser.parseJSON(rewrite, action: .trimStrong, sourceDocument: "A sentence.")
            preconditionFailure("trim accepted a rewrite")
        } catch let error as AIError {
            precondition(error == .invalidResponse)
        }

        do {
            _ = try AIResponseParser.parseJSON(Data("bad".utf8), action: .alternatives, sourceDocument: "text")
            preconditionFailure("malformed response was accepted")
        } catch let error as AIError {
            precondition(error == .invalidResponse)
        }
        do {
            _ = try AIResponseParser.parseJSON(Data("{}".utf8), action: .alternatives, sourceDocument: "text")
            preconditionFailure("missing response fields were accepted")
        } catch let error as AIError {
            precondition(error == .invalidResponse)
        }

        let claudeEvents = Data(#"[{"type":"system","subtype":"init"},{"type":"result","structured_output":{"alternatives":["A new line."],"suggestions":[]}}]"#.utf8)
        let claude = try AIResponseParser.parseClaudeOutput(claudeEvents, action: .alternatives, sourceDocument: "text")
        precondition(claude.alternatives == ["A new line."])
        do {
            _ = try AIResponseParser.parseClaudeOutput(Data(#"[{"type":"system"}]"#.utf8), action: .alternatives, sourceDocument: "text")
            preconditionFailure("Claude event array without a result was accepted")
        } catch let error as AIError {
            precondition(error == .invalidResponse)
        }

}

func checkOversizeRequest() async throws {
        let oversized = AIRequest(action: .proofread, document: String(repeating: "x", count: 50_001))
        precondition(oversized.document.count == 50_000)
        let service = AIService(session: .shared, keyLookup: { _ in nil }, processRunner: CLIProcessRunner())
        do {
            _ = try await service.generate(oversized, configuration: AIConfiguration())
            preconditionFailure("oversized request was accepted")
        } catch let error as AIError {
            precondition(error == .oversizedDocument)
        }
}

func checkAPIAdapter() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer mock-key")
            let answer = try JSONSerialization.data(withJSONObject: ["alternatives": [String](),
                "suggestions": [["quote": "A sentence.", "replacement": "A line.", "reason": "Shorter."]]])
            return (200, try JSONSerialization.data(withJSONObject: ["output_text": String(decoding: answer, as: UTF8.self)]))
        }
        let service = AIService(session: session, keyLookup: { _ in "mock-key" }, processRunner: CLIProcessRunner())
        let answer = try await service.generate(AIRequest(action: .proofread, document: "A sentence."),
                                                configuration: AIConfiguration(provider: .codex, connection: .api, model: "mock-model"))
        precondition(answer.suggestions.first?.replacement == "A line.")

        MockURLProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            precondition(request.value(forHTTPHeaderField: "x-api-key") == "claude-mock-key")
            precondition(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            let annotation = try JSONSerialization.data(withJSONObject: ["alternatives": [String](),
                "suggestions": [["quote": "A sentence.", "replacement": NSNull(), "reason": "Clear example."]]])
            return (200, try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": String(decoding: annotation, as: UTF8.self)]]]))
        }
        let claudeService = AIService(session: session, keyLookup: { _ in "claude-mock-key" }, processRunner: CLIProcessRunner())
        let claudeAnswer = try await claudeService.generate(AIRequest(action: .smoothness, document: "A sentence."),
                                                            configuration: AIConfiguration(provider: .claude, connection: .api, model: "claude-mock"))
        precondition(claudeAnswer.suggestions.first?.replacement == nil)

        MockURLProtocol.handler = { _ in (429, Data("provider details must stay private".utf8)) }
        do {
            _ = try await service.generate(AIRequest(action: .proofread, document: "A sentence."),
                                           configuration: AIConfiguration(provider: .codex, connection: .api, model: "mock-model"))
            preconditionFailure("provider failure was accepted")
        } catch {
            precondition(!String(describing: error).contains("provider details"))
        }
}

func checkCLIAndTimeout() async throws {
        setenv("OPENAI_API_KEY", "WRITE_ON_TEST_SENTINEL", 1)
        precondition(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == "WRITE_ON_TEST_SENTINEL")
        let validScript = try fixture("""
        #!/bin/sh
        [ -z "${OPENAI_API_KEY:-}" ] || exit 8
        cat >/dev/null
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"alternatives\\":[],\\"suggestions\\":[]}"}}'
        """)
        defer { try? FileManager.default.removeItem(at: validScript) }
        let runner = CLIProcessRunner()
        let bytes = try await runner.run(provider: .claude, executablePath: validScript.path, model: "", prompt: "private prompt", timeout: 5)
        let parsed = try AIResponseParser.parseCodexEvents(bytes, action: .proofread, sourceDocument: "A sentence.")
        precondition(parsed.suggestions.isEmpty)

        let sleepingScript = try fixture("""
        #!/bin/sh
        cat >/dev/null
        exec /bin/sleep 5
        """)
        defer { try? FileManager.default.removeItem(at: sleepingScript) }
        let earlyExitScript = try fixture("""
        #!/bin/sh
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: earlyExitScript) }
        _ = try? await runner.run(provider: .claude, executablePath: earlyExitScript.path, model: "",
                                  prompt: String(repeating: "x", count: 2_000_000), timeout: 5)
        let started = Date()
        do {
            _ = try await runner.run(provider: .claude, executablePath: sleepingScript.path, model: "", prompt: "private prompt", timeout: 0.1)
            preconditionFailure("process did not time out")
        } catch let error as AIError {
            precondition(error == .timedOut)
        }
        precondition(Date().timeIntervalSince(started) < 3)

        let task = Task { try await runner.run(provider: .claude, executablePath: sleepingScript.path, model: "", prompt: "private prompt", timeout: 5) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("cancelled process returned normally")
        } catch let error as AIError {
            precondition(error == .cancelled)
        }

        try await checkDescendantCleanup(runner: runner, cancellation: true)
        try await checkDescendantCleanup(runner: runner, cancellation: false)
}

func checkDescendantCleanup(runner: CLIProcessRunner, cancellation: Bool) async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("writeon-ai-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try fixture("""
        #!/bin/sh
        /bin/sleep 30 &
        echo $! > '\(pidFile.path)'
        cat >/dev/null
        wait
        """)
        defer { try? FileManager.default.removeItem(at: script) }
        let task = Task {
            try await runner.run(provider: .claude, executablePath: script.path, model: "", prompt: "private prompt", timeout: cancellation ? 5 : 1.5)
        }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let pidText = try? String(contentsOf: pidFile, encoding: .utf8), let childPID = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            task.cancel()
            preconditionFailure("fixture child did not start")
        }
        if cancellation { task.cancel() }
        do {
            _ = try await task.value
            preconditionFailure("fixture process should have stopped")
        } catch let error as AIError {
            precondition(error == (cancellation ? .cancelled : .timedOut))
        }
        let childDeadline = Date().addingTimeInterval(2)
        while Darwin.kill(childPID, 0) == 0, Date() < childDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(Darwin.kill(childPID, 0) == -1, "CLI descendant was left running")
}

func fixture(_ source: String) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("writeon-ai-check-\(UUID().uuidString)")
        try Data(source.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw AIError.invalidResponse }
            let (status, data) = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
                throw AIError.invalidResponse
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

import XCTest
@testable import WriteOnAI

final class CLIProcessRunnerTests: XCTestCase {
    func testCodexUsesStdinAndParsesJSONLFromIsolatedNoKeyEnvironment() async throws {
        let executable = try fixture("""
        #!/bin/sh
        [ -z "${OPENAI_API_KEY:-}" ] || exit 8
        if [ "${1:-}" = "mcp" ]; then
          [ "${2:-}" = "list" ] || exit 9
          printf '[]'
          exit 0
        fi
        cat >/dev/null
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"alternatives\\":[],\\"suggestions\\":[]}"}}'
        """)
        let runner = CLIProcessRunner()
        let bytes = try await runner.run(provider: .codex, executablePath: executable.path, model: "", prompt: "test prompt", timeout: 5)
        let parsed = try AIResponseParser.parseCodexEvents(bytes, action: .proofread, sourceDocument: "A sentence.")
        XCTAssertTrue(parsed.suggestions.isEmpty)
    }

    func testSubscriptionCommandTimesOutAndCleansUp() async throws {
        let executable = try fixture("""
        #!/bin/sh
        cat >/dev/null
        sleep 5
        """)
        let started = Date()
        do {
            _ = try await CLIProcessRunner().run(provider: .claude, executablePath: executable.path, model: "", prompt: "test", timeout: 0.1)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AIError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTaskCancellationStopsChild() async throws {
        let executable = try fixture("""
        #!/bin/sh
        cat >/dev/null
        sleep 5
        """)
        let task = Task { try await CLIProcessRunner().run(provider: .claude, executablePath: executable.path, model: "", prompt: "test", timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? AIError, .cancelled)
        }
    }

    private func fixture(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writeon-ai-fixture-\(UUID().uuidString)")
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

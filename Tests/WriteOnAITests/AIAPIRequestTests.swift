import XCTest
@testable import WriteOnAI

final class AIAPIRequestTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testOpenAIUsesResponsesAPIAndValidatesTheReturnedQuote() async throws {
        let session = makeSession()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try XCTUnwrap(request.httpBody).flatMapJSON()
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertNotNil(body["text"])
            let inner = try JSONSerialization.data(withJSONObject: ["alternatives": [String](), "suggestions": [["quote": "A sentence.", "replacement": "A line.", "reason": "Shorter."]]])
            return (200, try JSONSerialization.data(withJSONObject: ["output_text": String(decoding: inner, as: UTF8.self)]))
        }
        let service = AIService(session: session, keyLookup: { _ in "test-key" }, processRunner: CLIProcessRunner())
        let result = try await service.generate(AIRequest(action: .proofread, document: "A sentence."), configuration: AIConfiguration(provider: .codex, connection: .api, model: "test-model"))
        XCTAssertEqual(result.suggestions.first?.replacement, "A line.")
    }

    func testClaudeUsesMessagesAPIAndReturnsSafeStatusError() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "claude-test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            return (429, Data("secret provider response must not leak".utf8))
        }
        let service = AIService(session: makeSession(), keyLookup: { _ in "claude-test-key" }, processRunner: CLIProcessRunner())
        do {
            _ = try await service.generate(AIRequest(action: .trimLight, document: "A sentence."), configuration: AIConfiguration(provider: .claude, connection: .api, model: "test-model"))
            XCTFail("Expected rate limit failure")
        } catch {
            XCTAssertTrue(((error as? LocalizedError)?.errorDescription ?? "").contains("rate limit"))
            XCTAssertFalse(String(describing: error).contains("secret provider response"))
        }
    }

    func testMissingAPIKeyFailsBeforeNetworkRequest() async {
        let service = AIService(session: makeSession(), keyLookup: { _ in nil }, processRunner: CLIProcessRunner())
        do {
            _ = try await service.generate(AIRequest(action: .proofread, document: "A sentence."), configuration: AIConfiguration(connection: .api, model: "test"))
            XCTFail("Expected missing key error")
        } catch {
            XCTAssertEqual(error as? AIError, .missingAPIKey)
        }
    }

    func testEmptyCodexSubscriptionUsesLightweightRequestDefaultsWithoutChangingSavedSettings() {
        let configuration = AIConfiguration()
        XCTAssertEqual(configuration.modelForRequest, "gpt-6-luna")
        XCTAssertEqual(configuration.codexRequestOverrides, ["model_reasoning_effort=\"low\"", "service_tier=\"default\""])
        XCTAssertEqual(configuration.model, "", "The user preference should remain blank")

        let custom = AIConfiguration(provider: .codex, connection: .subscription, model: "custom-model")
        XCTAssertEqual(custom.modelForRequest, "custom-model")
        XCTAssertTrue(custom.codexRequestOverrides.isEmpty)
        let api = AIConfiguration(provider: .codex, connection: .api)
        XCTAssertEqual(api.modelForRequest, "")
        XCTAssertTrue(api.codexRequestOverrides.isEmpty)
        let claude = AIConfiguration(provider: .claude, connection: .subscription)
        XCTAssertEqual(claude.modelForRequest, "")
        XCTAssertTrue(claude.codexRequestOverrides.isEmpty)
    }

    func testAlternativesRequestLifecycleBlocksRepeatAndRejectsLateCompletionAfterCancel() {
        var lifecycle = AIRequestLifecycle()
        let first = lifecycle.begin()
        XCTAssertNotNil(first)
        XCTAssertNil(lifecycle.begin(), "A second click must not restart the in-flight request")
        XCTAssertTrue(lifecycle.isCurrent(first!))

        lifecycle.cancel(first!)
        XCTAssertFalse(lifecycle.isCurrent(first!), "Cancellation must invalidate late callbacks")
        let second = lifecycle.begin()
        XCTAssertNotNil(second, "A fresh request must be allowed after cancellation")
        XCTAssertFalse(lifecycle.finish(first!), "A stale completion must not clear the new request")
        XCTAssertTrue(lifecycle.isCurrent(second!))
        XCTAssertTrue(lifecycle.finish(second!))
        XCTAssertFalse(lifecycle.isBusy)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private extension Data {
    func flatMapJSON() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any]) }
}

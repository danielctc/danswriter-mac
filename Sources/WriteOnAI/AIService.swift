import Foundation

public final class AIService {
    private let session: URLSession
    private let keyLookup: @Sendable (AIProvider) throws -> String?
    private let processRunner: CLIProcessRunner

    public convenience init() {
        self.init(session: .shared, keyLookup: { try KeychainStore.get(for: $0) }, processRunner: CLIProcessRunner())
    }

    init(session: URLSession, keyLookup: @escaping @Sendable (AIProvider) throws -> String?, processRunner: CLIProcessRunner) {
        self.session = session
        self.keyLookup = keyLookup
        self.processRunner = processRunner
    }

    public func generate(_ request: AIRequest, configuration: AIConfiguration) async throws -> AIResult {
        if let error = request.validationError { throw error }
        do { try Task.checkCancellation() } catch { throw AIError.cancelled }
        if configuration.connection == .api {
            return try await generateAPI(request, configuration: configuration)
        }
        let prompt = AIPrompt.make(request)
        let response: Data
        do {
            response = try await processRunner.run(provider: configuration.provider,
                                                   executablePath: configuration.executablePath,
                                                   model: configuration.modelForRequest,
                                                   prompt: prompt,
                                                   timeout: 90,
                                                   codexRequestOverrides: configuration.codexRequestOverrides)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.providerUnavailable(configuration.provider == .codex ? "Codex" : "Claude")
        }
        switch configuration.provider {
        case .codex:
            return try AIResponseParser.parseCodexEvents(response, action: request.action, sourceDocument: request.document, selectedText: request.selection)
        case .claude:
            return try AIResponseParser.parseClaudeOutput(response, action: request.action, sourceDocument: request.document, selectedText: request.selection)
        }
    }

    private func generateAPI(_ request: AIRequest, configuration: AIConfiguration) async throws -> AIResult {
        guard let key = try keyLookup(configuration.provider), !key.isEmpty else { throw AIError.missingAPIKey }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.providerUnavailable("Choose a model in Settings")
        }
        var urlRequest: URLRequest
        switch configuration.provider {
        case .codex:
            urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let schema: [String: Any] = ["type": "json_schema", "name": "writing_suggestions", "strict": true, "schema": AIPrompt.schema]
            let body: [String: Any] = ["model": configuration.model,
                                       "instructions": "Return only the JSON object described by the schema. Preserve exact unique quotes from the supplied document.",
                                       "input": AIPrompt.make(request),
                                       "text": ["format": schema]]
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        case .claude:
            urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["model": configuration.model, "max_tokens": 4096,
                                       "system": "Return only the JSON object described by the requested schema. Preserve exact unique quotes from the supplied document.",
                                       "messages": [["role": "user", "content": AIPrompt.make(request)]],
                                       "output_config": ["format": ["type": "json_schema", "schema": AIPrompt.schema]]]
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        urlRequest.timeoutInterval = 90
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await boundedFetch(urlRequest)
        } catch is CancellationError {
            throw AIError.cancelled
        } catch let error as AIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AIError.timedOut
        } catch {
            if Task.isCancelled { throw AIError.cancelled }
            throw AIError.providerUnavailable(configuration.provider == .codex ? "OpenAI API" : "Claude API")
        }
        guard data.count <= 1_000_000 else { throw AIError.outputTooLarge }
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw AIError.providerUnavailable("API authentication failed. Check the saved key")
            case 429: throw AIError.providerUnavailable("API rate limit or usage limit reached")
            default: throw AIError.providerUnavailable("API request failed (HTTP \(http.statusCode))")
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        let text: String?
        switch configuration.provider {
        case .codex:
            text = Self.openAIOutputText(json)
        case .claude:
            let content = json["content"] as? [[String: Any]] ?? []
            text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        }
        guard let text else { throw AIError.invalidResponse }
        return try AIResponseParser.parseJSON(Data(text.utf8), action: request.action, sourceDocument: request.document, selectedText: request.selection)
    }

    private static func openAIOutputText(_ json: [String: Any]?) -> String? {
        if let direct = json?["output_text"] as? String { return direct }
        let output = json?["output"] as? [[String: Any]] ?? []
        let pieces = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        return pieces.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined()
    }

    private func boundedFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: BoundedResponse.self) { group in
            group.addTask {
                let (bytes, response) = try await self.session.bytes(for: request)
                var data = Data()
                for try await byte in bytes {
                    if data.count >= 1_000_000 { throw AIError.outputTooLarge }
                    data.append(byte)
                }
                return BoundedResponse(data: data, response: response)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw AIError.timedOut
            }
            guard let result = try await group.next() else { throw AIError.invalidResponse }
            group.cancelAll()
            return (result.data, result.response)
        }
    }
}

private struct BoundedResponse: @unchecked Sendable {
    let data: Data
    let response: URLResponse
}

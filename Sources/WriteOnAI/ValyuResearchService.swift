import Foundation

public enum ValyuResearchMode: String, Codable, CaseIterable, Sendable {
    case fast
    case standard
    case heavy
    case max
}

public enum ValyuResearchStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, awaiting_input, paused
}

public struct ValyuResearchSource: Codable, Equatable, Sendable {
    public let title: String
    public let url: URL
    public let snippet: String?
    public let source: String?

    public init(title: String, url: URL, snippet: String? = nil, source: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.source = source
    }
}

public struct ValyuResearchResult: Codable, Equatable, Sendable {
    public let markdown: String
    public let sources: [ValyuResearchSource]

    public init(markdown: String, sources: [ValyuResearchSource]) {
        self.markdown = markdown
        self.sources = sources
    }
}

/// A resumable server task. `result` is present when a completed status includes output.
public struct ValyuResearchTask: Codable, Equatable, Sendable {
    public let id: String
    public let status: ValyuResearchStatus
    public let result: ValyuResearchResult?
    public let progressCurrent: Int?
    public let progressTotal: Int?

    public init(id: String, status: ValyuResearchStatus, result: ValyuResearchResult? = nil,
                progressCurrent: Int? = nil, progressTotal: Int? = nil) {
        self.id = id
        self.status = status
        self.result = result
        self.progressCurrent = progressCurrent
        self.progressTotal = progressTotal
    }
}

public enum ValyuResearchError: Error, LocalizedError, Equatable {
    case invalidCredential, keychain, missingCredential, invalidQuery, invalidTaskID
    case transport, responseTooLarge, invalidResponse, serviceUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: return "The Valyu key is invalid."
        case .keychain: return "DansWriter could not access the Valyu key in Keychain."
        case .missingCredential: return "Add a Valyu API key in the Research settings to use Valyu research."
        case .invalidQuery: return "Enter a research question between 1 and 8,000 characters."
        case .invalidTaskID: return "This research task ID is invalid."
        case .transport: return "DansWriter could not reach Valyu. Check your connection and try again."
        case .responseTooLarge: return "Valyu returned a response that was too large to process."
        case .invalidResponse: return "Valyu returned an unexpected response."
        case .serviceUnavailable: return "Valyu could not complete that request. Try again later."
        }
    }
}

public struct ValyuHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

public protocol ValyuHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ValyuHTTPResponse
}

/// URLSession transport with redirects disabled and a streamed response size limit.
public final class ValyuURLSessionTransport: ValyuHTTPTransport, @unchecked Sendable {
    public init() { }

    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> ValyuHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ValyuResearchError.invalidResponse }
            if response.expectedContentLength > Int64(maximumBytes) { throw ValyuResearchError.responseTooLarge }
            var body = Data()
            body.reserveCapacity(min(maximumBytes, max(0, response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 0)))
            for try await byte in bytes {
                guard body.count < maximumBytes else { throw ValyuResearchError.responseTooLarge }
                body.append(byte)
            }
            return ValyuHTTPResponse(statusCode: http.statusCode, body: body)
        } catch let error as ValyuResearchError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch where Task.isCancelled { throw CancellationError() }
        catch { throw ValyuResearchError.transport }
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor ValyuResearchService {
    private static let baseURL = URL(string: "https://api.valyu.ai/v1/deepresearch/tasks")!
    private static let responseLimit = 2 * 1_024 * 1_024
    private let transport: any ValyuHTTPTransport
    private let keyProvider: @Sendable () throws -> String?

    public init(transport: any ValyuHTTPTransport = ValyuURLSessionTransport(),
                keyProvider: @escaping @Sendable () throws -> String? = { try ValyuKeychainStore.get() }) {
        self.transport = transport
        self.keyProvider = keyProvider
    }

    /// Explicitly creates one billed Valyu task. There is no implicit retry.
    public func create(query: String, mode: ValyuResearchMode = .standard) async throws -> ValyuResearchTask {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8_000 else { throw ValyuResearchError.invalidQuery }
        let body = try JSONSerialization.data(withJSONObject: ["query": trimmed, "mode": mode.rawValue])
        let request = try makeRequest(url: Self.baseURL, method: "POST", body: body)
        return try decodeTask(from: await send(request), expectedID: nil)
    }

    public func status(taskID: String) async throws -> ValyuResearchTask {
        let request = try makeRequest(url: taskURL(taskID, suffix: "status"), method: "GET")
        return try decodeTask(from: await send(request), expectedID: taskID)
    }

    /// Cancellation is only sent when explicitly requested by the caller.
    public func cancel(taskID: String) async throws -> ValyuResearchTask {
        let request = try makeRequest(url: taskURL(taskID, suffix: "cancel"), method: "POST")
        let response = try await send(request)
        guard response.body.count <= Self.responseLimit else { throw ValyuResearchError.responseTooLarge }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw ValyuResearchError.missingCredential }
            if response.statusCode == 429 || response.statusCode >= 500 { throw ValyuResearchError.serviceUnavailable }
            throw ValyuResearchError.invalidResponse
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  (object["success"] as? Bool) == true,
                  let returnedID = object["deepresearch_id"] as? String,
                  returnedID == taskID else { throw ValyuResearchError.invalidResponse }
            return ValyuResearchTask(id: taskID, status: .cancelled)
        } catch let error as ValyuResearchError { throw error }
        catch { throw ValyuResearchError.invalidResponse }
    }

    private func taskURL(_ id: String, suffix: String) throws -> URL {
        guard id.count <= 128, id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ValyuResearchError.invalidTaskID
        }
        return Self.baseURL.appendingPathComponent(id).appendingPathComponent(suffix)
    }

    private func makeRequest(url: URL, method: String, body: Data? = nil) throws -> URLRequest {
        guard url.scheme == "https", url.host == "api.valyu.ai" else { throw ValyuResearchError.invalidResponse }
        guard let key = try keyProvider(), !key.isEmpty else { throw ValyuResearchError.missingCredential }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> ValyuHTTPResponse {
        do { return try await transport.send(request, maximumBytes: Self.responseLimit) }
        catch let error as ValyuResearchError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch where Task.isCancelled { throw CancellationError() }
        catch { throw ValyuResearchError.transport }
    }

    private func decodeTask(from response: ValyuHTTPResponse, expectedID: String?) throws -> ValyuResearchTask {
        guard response.body.count <= Self.responseLimit else { throw ValyuResearchError.responseTooLarge }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw ValyuResearchError.missingCredential }
            if response.statusCode == 429 || response.statusCode >= 500 { throw ValyuResearchError.serviceUnavailable }
            throw ValyuResearchError.invalidResponse
        }
        do {
            let raw = try JSONSerialization.jsonObject(with: response.body)
            guard let object = raw as? [String: Any] else { throw ValyuResearchError.invalidResponse }
            if let success = object["success"] as? Bool, !success { throw ValyuResearchError.serviceUnavailable }
            let id = (object["deepresearch_id"] as? String) ?? (object["task_id"] as? String) ?? (object["id"] as? String)
            guard let id, id.count <= 128, id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                  expectedID == nil || expectedID == id,
                  let statusText = object["status"] as? String,
                  let status = ValyuResearchStatus(rawValue: statusText.lowercased()) else {
                throw ValyuResearchError.invalidResponse
            }
            let output = object["output"] as? String
            if status == .completed, (output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                throw ValyuResearchError.invalidResponse
            }
            let sources = (object["sources"] as? [[String: Any]] ?? []).compactMap(decodeSource)
            let result: ValyuResearchResult? = output.map { ValyuResearchResult(markdown: $0, sources: sources) }
            let progress = object["progress"] as? [String: Any]
            return ValyuResearchTask(id: id, status: status, result: result,
                                     progressCurrent: progress?["current_step"] as? Int,
                                     progressTotal: progress?["total_steps"] as? Int)
        } catch let error as ValyuResearchError { throw error }
        catch { throw ValyuResearchError.invalidResponse }
    }

    private func decodeSource(_ value: [String: Any]) -> ValyuResearchSource? {
        guard let title = value["title"] as? String,
              let rawURL = value["url"] as? String,
              let url = URL(string: rawURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return ValyuResearchSource(title: String(title.prefix(500)), url: url,
                                   snippet: (value["snippet"] as? String).map { String($0.prefix(4_000)) },
                                   source: (value["source"] as? String).map { String($0.prefix(200)) })
    }
}

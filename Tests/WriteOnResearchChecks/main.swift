import Foundation
import WriteOnAI

private struct FixtureTransport: ValyuHTTPTransport {
    let statusCode: Int
    let body: Data
    let failure: Bool
    private let sink: RequestSink

    init(statusCode: Int = 200, json: String = "{}", failure: Bool = false, sink: RequestSink) {
        self.statusCode = statusCode
        self.body = Data(json.utf8)
        self.failure = failure
        self.sink = sink
    }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ValyuHTTPResponse {
        await sink.record(request)
        if failure { throw URLError(.cancelled) }
        return ValyuHTTPResponse(statusCode: statusCode, body: body)
    }
}

private actor RequestSink {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private struct WaitingTransport: ValyuHTTPTransport {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> ValyuHTTPResponse {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return ValyuHTTPResponse(statusCode: 200, body: Data())
    }
}

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct WriteOnResearchChecks {
    static func main() async {
        let sink = RequestSink()
        let queuedTransport = FixtureTransport(json: #"{"success":true,"deepresearch_id":"dr_123-test","status":"queued","unused_metadata":{"anything":true}}"#, sink: sink)
        let service = ValyuResearchService(transport: queuedTransport, keyProvider: { "fixture-key" })
        do {
            let task = try await service.create(query: "A careful question", mode: .standard)
            check(task.id == "dr_123-test" && task.status == .queued && task.result == nil, "queued create response")
            let requests = await sink.requests
            check(requests.count == 1, "one explicit task creation request")
            check(requests.first?.url?.absoluteString == "https://api.valyu.ai/v1/deepresearch/tasks", "fixed Valyu HTTPS endpoint")
            check(requests.first?.value(forHTTPHeaderField: "x-api-key") == "fixture-key", "key is sent only as auth header")
            let payload = requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            check(payload?["query"] == "A careful question" && payload?["mode"] == "standard", "current documented query and mode fields")
            check(!(String(data: requests.first?.httpBody ?? Data(), encoding: .utf8) ?? "").contains("fixture-key"), "key is absent from request body")
        } catch { fail("queued response decode", error) }

        let completedSink = RequestSink()
        let completedTransport = FixtureTransport(json: ##"{"deepresearch_id":"dr_456","status":"completed","output":"# Findings","sources":[{"title":"Source A","url":"https://example.org/paper","snippet":"Evidence","source":"web"}],"progress":{"current_step":4,"total_steps":4},"usage":{"total_cost":0.1}}"##, sink: completedSink)
        do {
            let task = try await ValyuResearchService(transport: completedTransport, keyProvider: { "fixture-key" }).status(taskID: "dr_456")
            check(task.status == .completed && task.result?.markdown == "# Findings", "completed output decodes as Markdown")
            check(task.result?.sources.first?.title == "Source A" && task.progressTotal == 4, "sources and progress decode")
        } catch { fail("completed response decode", error) }

        do {
            _ = try await ValyuResearchService(transport: FixtureTransport(json: #"{"success":true,"deepresearch_id":"dr_other","status":"running"}"#, sink: RequestSink()), keyProvider: { "fixture-key" }).status(taskID: "dr_expected")
            fail("mismatched status ID rejected", nil)
        } catch ValyuResearchError.invalidResponse { }
        catch { fail("mismatched status ID rejection", error) }

        do {
            _ = try await ValyuResearchService(transport: FixtureTransport(json: #"{"success":false,"deepresearch_id":"dr_400","status":"running","error":"fixture-key must not escape"}"#, sink: RequestSink()), keyProvider: { "fixture-key" }).create(query: "Question")
            fail("provider success false rejected", nil)
        } catch ValyuResearchError.serviceUnavailable { }
        catch { fail("provider error mapping", error) }

        do {
            _ = try await ValyuResearchService(transport: FixtureTransport(json: #"{"deepresearch_id":"dr_empty","status":"completed","output":"  "}"#, sink: RequestSink()), keyProvider: { "fixture-key" }).status(taskID: "dr_empty")
            fail("empty completed output rejected", nil)
        } catch ValyuResearchError.invalidResponse { }
        catch { fail("empty completed output validation", error) }

        do {
            _ = try await ValyuResearchService(transport: FixtureTransport(statusCode: 401, json: #"{"error":"secret fixture-key should not surface"}"#, sink: RequestSink()), keyProvider: { "fixture-key" }).create(query: "Question")
            fail("401 redaction", nil)
        } catch let error as ValyuResearchError {
            check(error.localizedDescription == "Add a Valyu API key in the Research settings to use Valyu research.", "provider error is safely redacted")
            check(!error.localizedDescription.contains("fixture-key"), "credential not in user-facing error")
        } catch { fail("401 mapped to safe error", error) }

        let cancelSink = RequestSink()
        do {
            _ = try await ValyuResearchService(transport: FixtureTransport(json: #"{"success":true,"message":"Task cancelled successfully","deepresearch_id":"dr_789"}"#, sink: cancelSink), keyProvider: { "fixture-key" }).cancel(taskID: "dr_789")
            let request = await cancelSink.requests.first
            check(request?.httpMethod == "POST" && request?.url?.path.hasSuffix("/dr_789/cancel") == true, "cancel uses only explicit cancel call")
        } catch { fail("cancel response", error) }

        do {
            _ = try await service.status(taskID: "../../evil?key=exfil")
            fail("hostile task ID rejected", nil)
        } catch ValyuResearchError.invalidTaskID { }
        catch { fail("hostile task ID rejection", error) }

        do {
            _ = try await service.create(query: String(repeating: "x", count: 8_001))
            fail("oversized query rejected", nil)
        } catch ValyuResearchError.invalidQuery { }
        catch { fail("oversized query rejection", error) }

        do {
            _ = try await ValyuResearchService(transport: FixtureTransport(failure: true, sink: RequestSink()), keyProvider: { "fixture-key" }).status(taskID: "dr_100")
            fail("network cancellation surfaced safely", nil)
        } catch let error as ValyuResearchError {
            check(error == .transport, "transport failure converted to safe error")
        } catch { fail("transport failure mapping", error) }

        do {
            let task = Task {
                try await ValyuResearchService(transport: WaitingTransport(), keyProvider: { "fixture-key" }).status(taskID: "dr_102")
            }
            task.cancel()
            _ = try await task.value
            fail("cancelled network task propagates cancellation", nil)
        } catch is CancellationError { }
        catch { fail("network task cancellation propagation", error) }

        do {
            _ = try await ValyuResearchService(transport: FixtureTransport(json: String(repeating: "x", count: 2 * 1_024 * 1_024 + 1), sink: RequestSink()), keyProvider: { "fixture-key" }).status(taskID: "dr_101")
            fail("oversized response rejected", nil)
        } catch ValyuResearchError.responseTooLarge { }
        catch { fail("oversized response rejection", error) }

        print("PASS: Valyu research checks (fixture transport only; no live API calls)")
    }

    private static func fail(_ message: String, _ error: Error?) -> Never {
        fputs("FAIL: \(message)\(error.map { ": \($0.localizedDescription)" } ?? "")\n", stderr)
        exit(1)
    }
}

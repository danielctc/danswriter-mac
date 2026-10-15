import Foundation
import WriteOnAI

private struct FixtureTransport: AppUpdateHTTPTransport {
    let status: Int
    let body: Data
    let shouldFail: Bool
    let shouldCancel: Bool
    private let sink: RequestSink

    init(status: Int = 200, json: String = "{}", body: Data? = nil, shouldFail: Bool = false,
         shouldCancel: Bool = false, sink: RequestSink) {
        self.status = status
        self.body = body ?? Data(json.utf8)
        self.shouldFail = shouldFail
        self.shouldCancel = shouldCancel
        self.sink = sink
    }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppUpdateHTTPResponse {
        await sink.record(request, maximumBytes: maximumBytes)
        if shouldCancel { throw CancellationError() }
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return AppUpdateHTTPResponse(statusCode: status, body: body)
    }
}

private actor RequestSink {
    private(set) var request: URLRequest?
    private(set) var maximumBytes = 0
    func record(_ request: URLRequest, maximumBytes: Int) {
        self.request = request
        self.maximumBytes = maximumBytes
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

@main
struct WriteOnUpdateChecks {
    static func main() async {
        check(AppUpdateVersion.components("1.2.3") == [1, 2, 3], "stable numeric version parses")
        check(AppUpdateVersion.components("v1.2.3") == [1, 2, 3], "v-prefixed release tag parses")
        check(AppUpdateVersion.components("1.2.3-beta.1") == nil, "prerelease version is rejected")
        check(AppUpdateVersion.components("01.2.3") == nil, "leading zero component is rejected")
        check(AppUpdateVersion.isNewer("1.10.0", than: "1.9.9"), "numeric version ordering")
        check(!AppUpdateVersion.isNewer("1.2.3", than: "1.2.3"), "same version is not newer")

        let sink = RequestSink()
        let releaseJSON = #"{"tag_name":"v1.2.0","draft":false,"prerelease":false,"body":"Notes are data only","html_url":"https://evil.example/","assets":[{"name":"DansWriter-1.2.0-arm64.dmg","browser_download_url":"https://evil.example/install.dmg"}]}"#
        do {
            let result = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.1.0",
                transport: FixtureTransport(json: releaseJSON, sink: sink)).check()
            guard case .update(let release) = result else { fail("new stable release should be offered") ; return }
            check(release.version == "1.2.0", "version comes from validated release tag")
            check(release.downloadURL.absoluteString == "https://github.com/example/danswriter/releases/download/v1.2.0/DansWriter-1.2.0-arm64.dmg", "download URL is constructed from fixed GitHub host, repo, tag and exact asset")
            check(release.notes == "Notes are data only", "release notes are only returned as inert data")
            let request = await sink.request
            check(request?.url?.absoluteString == "https://api.github.com/repos/example/danswriter/releases/latest", "request uses configured GitHub repository API endpoint")
            check(request?.httpMethod == "GET" && request?.timeoutInterval == 20, "request uses GET with explicit timeout")
            check(request?.value(forHTTPHeaderField: "Authorization") == nil, "public check sends no authorization")
            let responseLimit = await sink.maximumBytes
            check(responseLimit == 256 * 1_024, "response has a bounded byte limit")
        } catch { fail("valid release fixture", error); return }

        do {
            let result = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.2.0",
                transport: FixtureTransport(json: releaseJSON, sink: RequestSink())).check()
            check(result == .current, "current installed version is reported current")
        } catch { fail("current version fixture", error); return }

        do {
            let result = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.0.0",
                transport: FixtureTransport(status: 404, sink: RequestSink())).check()
            check(result == .noPublishedReleases, "GitHub 404 is reported as no published releases")
        } catch { fail("no releases fixture", error); return }

        for json in [
            #"{"tag_name":"v1.2.0","draft":true,"prerelease":false,"assets":[{"name":"DansWriter-1.2.0-arm64.dmg"}]}"#,
            #"{"tag_name":"v1.2.0-beta.1","draft":false,"prerelease":true,"assets":[{"name":"DansWriter-1.2.0-arm64.dmg"}]}"#
        ] {
            do {
                let result = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.0.0",
                    transport: FixtureTransport(json: json, sink: RequestSink())).check()
                check(result == .current, "draft and prerelease are not offered")
            } catch { fail("unsupported release fixture", error); return }
        }

        for fixture in [
            ("malformed JSON", FixtureTransport(json: "not-json", sink: RequestSink()), AppUpdateError.invalidResponse),
            ("invalid stable tag", FixtureTransport(json: #"{"tag_name":"latest","draft":false,"prerelease":false,"assets":[]}"#, sink: RequestSink()), .invalidResponse),
            ("missing expected asset", FixtureTransport(json: #"{"tag_name":"v1.2.0","draft":false,"prerelease":false,"assets":[{"name":"Other.dmg"}]}"#, sink: RequestSink()), .invalidResponse),
            ("oversized response", FixtureTransport(body: Data(repeating: 0x20, count: 256 * 1_024 + 1), sink: RequestSink()), .responseTooLarge),
            ("rate limit", FixtureTransport(status: 429, sink: RequestSink()), .serviceUnavailable)
        ] {
            do {
                _ = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.0.0", transport: fixture.1).check()
                fail("\(fixture.0) must not report current or offer an update")
            } catch let error as AppUpdateError {
                check(error == fixture.2, "\(fixture.0) maps to the expected update error")
            } catch { fail("\(fixture.0) fixture", error); return }
        }

        do {
            let result = try await AppUpdateService(repository: "not a URL", installedVersion: "1.0.0",
                transport: FixtureTransport(sink: RequestSink())).check()
            check(result == .unavailable, "invalid repository configuration fails closed without request")
        } catch { fail("invalid repository fixture", error); return }

        do {
            _ = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.x", transport: FixtureTransport(sink: RequestSink())).check()
            fail("invalid installed version must fail")
        } catch let error as AppUpdateError {
            check(error == .invalidVersion, "invalid installed version is surfaced")
        } catch { fail("invalid installed version fixture", error); return }

        do {
            _ = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.0.0",
                transport: FixtureTransport(shouldFail: true, sink: RequestSink())).check()
            fputs("FAIL: transport failure should be surfaced\n", stderr)
            exit(EXIT_FAILURE)
        } catch let error as AppUpdateError {
            check(error == .transport, "transport error is mapped to safe user-facing failure")
        } catch { fail("transport failure fixture", error); return }

        do {
            _ = try await AppUpdateService(repository: "example/danswriter", installedVersion: "1.0.0",
                transport: FixtureTransport(shouldCancel: true, sink: RequestSink())).check()
            fail("cancellation should be propagated")
        } catch is CancellationError {
            // Cancellation remains distinct from an update failure.
        } catch { fail("cancellation fixture", error); return }

        print("WRITE_ON_UPDATE_CHECKS_PASSED")
    }

    private static func fail(_ message: String, _ error: Error? = nil) -> Never {
        fputs("FAIL: \(message)\(error.map { ": \($0.localizedDescription)" } ?? "")\n", stderr)
        exit(EXIT_FAILURE)
    }
}

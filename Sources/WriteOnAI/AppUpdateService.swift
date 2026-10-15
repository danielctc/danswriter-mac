import Foundation

public struct AppUpdateRelease: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL
    public let notes: String?

    public init(version: String, downloadURL: URL, notes: String? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.notes = notes
    }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
    case unavailable
    case current
    case noPublishedReleases
    case update(AppUpdateRelease)
}

public enum AppUpdateError: Error, LocalizedError, Equatable {
    case invalidRepository
    case invalidVersion
    case transport
    case responseTooLarge
    case invalidResponse
    case serviceUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidRepository: return "Update checks are not configured for this build."
        case .invalidVersion: return "DansWriter could not read a valid version for this build."
        case .transport: return "DansWriter could not reach GitHub. Check your connection and try again."
        case .responseTooLarge, .invalidResponse: return "GitHub returned an unexpected update response."
        case .serviceUnavailable: return "GitHub could not complete the update check. Try again later."
        }
    }
}

public struct AppUpdateHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

public protocol AppUpdateHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppUpdateHTTPResponse
}

public final class AppUpdateURLSessionTransport: AppUpdateHTTPTransport, @unchecked Sendable {
    public init() { }

    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppUpdateHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: AppUpdateRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
            if response.expectedContentLength > Int64(maximumBytes) { throw AppUpdateError.responseTooLarge }
            var body = Data()
            body.reserveCapacity(min(maximumBytes, max(0, response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 0)))
            for try await byte in bytes {
                guard body.count < maximumBytes else { throw AppUpdateError.responseTooLarge }
                body.append(byte)
            }
            return AppUpdateHTTPResponse(statusCode: http.statusCode, body: body)
        } catch let error as AppUpdateError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch where Task.isCancelled { throw CancellationError() }
        catch { throw AppUpdateError.transport }
    }
}

private final class AppUpdateRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum AppUpdateVersion {
    /// Accepts stable numeric semantic versions only. A leading `v` is allowed for Git tags.
    public static func components(_ raw: String) -> [UInt64]? {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard value.count <= 64, value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { UInt64($0) }
        return numbers.count == 3 ? numbers : nil
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = components(candidate), let rhs = components(installed) else { return false }
        for index in 0..<3 where lhs[index] != rhs[index] { return lhs[index] > rhs[index] }
        return false
    }
}

public actor AppUpdateService {
    private static let responseLimit = 256 * 1_024
    private let repository: String?
    private let installedVersion: String
    private let transport: any AppUpdateHTTPTransport

    public init(repository: String?, installedVersion: String,
                transport: any AppUpdateHTTPTransport = AppUpdateURLSessionTransport()) {
        self.repository = repository
        self.installedVersion = installedVersion
        self.transport = transport
    }

    public func check() async throws -> AppUpdateCheckResult {
        guard let repository, Self.validRepository(repository) else { return .unavailable }
        guard AppUpdateVersion.components(installedVersion) != nil else { throw AppUpdateError.invalidVersion }
        let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DansWriter", forHTTPHeaderField: "User-Agent")

        let response: AppUpdateHTTPResponse
        do { response = try await transport.send(request, maximumBytes: Self.responseLimit) }
        catch let error as AppUpdateError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch where Task.isCancelled { throw CancellationError() }
        catch { throw AppUpdateError.transport }

        guard response.body.count <= Self.responseLimit else { throw AppUpdateError.responseTooLarge }
        if response.statusCode == 404 { return .noPublishedReleases }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 || response.statusCode >= 500 { throw AppUpdateError.serviceUnavailable }
            throw AppUpdateError.invalidResponse
        }
        let release: GitHubRelease
        do { release = try JSONDecoder().decode(GitHubRelease.self, from: response.body) }
        catch { throw AppUpdateError.invalidResponse }
        guard !release.draft, !release.prerelease else { return .current }
        let rawVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard AppUpdateVersion.components(rawVersion) != nil else { throw AppUpdateError.invalidResponse }
        let expectedAsset = "DansWriter-\(rawVersion)-arm64.dmg"
        guard release.assets.contains(where: { $0.name == expectedAsset }) else { throw AppUpdateError.invalidResponse }
        guard let url = URL(string: "https://github.com/\(repository)/releases/download/\(release.tagName)/\(expectedAsset)"),
              url.scheme == "https", url.host == "github.com" else { throw AppUpdateError.invalidResponse }
        guard AppUpdateVersion.isNewer(rawVersion, than: installedVersion) else { return .current }
        return .update(AppUpdateRelease(version: rawVersion, downloadURL: url, notes: release.body))
    }

    private static func validRepository(_ value: String) -> Bool {
        guard value.count <= 200,
              value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return false }
        return value.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease, body, assets }
        struct Asset: Decodable { let name: String }
    }
}

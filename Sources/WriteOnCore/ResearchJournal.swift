import Foundation

public enum ResearchDestination: Equatable, Sendable { case draft, overflow }

public struct ResearchSourceRecord: Codable, Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String?

    public init(title: String, url: String, snippet: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public struct ResearchJournalEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var taskID: String?
    public var query: String
    public var mode: String
    public var status: String
    public var reportMarkdown: String
    public var sources: [ResearchSourceRecord]
    public var updatedAt: Date

    public init(id: UUID = UUID(), taskID: String? = nil, query: String, mode: String, status: String = "queued", reportMarkdown: String = "", sources: [ResearchSourceRecord] = [], updatedAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.query = query
        self.mode = mode
        self.status = status
        self.reportMarkdown = reportMarkdown
        self.sources = sources
        self.updatedAt = updatedAt
    }
}

/// A small local journal for resumable research tasks and staged reports. It contains no credentials.
public struct ResearchJournal {
    public let fileURL: URL
    private let fileManager: FileManager
    private let maximumBytes = 5 * 1_024 * 1_024

    public init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let base = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("DansWriter", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        fileURL = base.appendingPathComponent("research-journal.json")
    }

    public func load() throws -> [ResearchJournalEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else { throw ResearchJournalError.tooLarge }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw ResearchJournalError.tooLarge }
        let entries = try JSONDecoder().decode([ResearchJournalEntry].self, from: data)
        guard entries.count <= 100 else { throw ResearchJournalError.tooManyEntries }
        for entry in entries { try validate(entry) }
        return entries
    }

    public func save(_ entries: [ResearchJournalEntry]) throws {
        guard entries.count <= 100 else { throw ResearchJournalError.tooManyEntries }
        for entry in entries { try validate(entry) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        guard data.count <= maximumBytes else { throw ResearchJournalError.tooLarge }
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func validate(_ entry: ResearchJournalEntry) throws {
        guard entry.query.count <= 20_000, entry.mode.count <= 32, entry.status.count <= 32,
              (entry.taskID?.count ?? 0) <= 200, entry.reportMarkdown.utf8.count <= 3_000_000,
              entry.sources.count <= 500 else { throw ResearchJournalError.invalidEntry }
        for source in entry.sources {
            guard source.title.count <= 500, source.url.count <= 2_000,
                  (source.snippet?.count ?? 0) <= 4_000,
                  let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { throw ResearchJournalError.invalidEntry }
        }
    }
}

public enum ResearchJournalError: Error { case tooLarge, tooManyEntries, invalidEntry }

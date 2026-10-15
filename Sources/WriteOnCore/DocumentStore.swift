import Foundation

public struct DocumentStore {
    private let directory: URL
    private let fileURL: URL
    private let backupURL: URL
    private static let maximumBytes = 5 * 1024 * 1024

    public init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DansWriter", isDirectory: true)
        self.directory = base
        self.fileURL = base.appendingPathComponent("recovery.writeon")
        self.backupURL = base.appendingPathComponent("recovery.writeon.bak")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    }

    public func save(_ document: WritingDocument) throws {
        try document.validate()
        let data = try Self.encoder().encode(document)
        guard data.count <= Self.maximumBytes else { throw WritingDocumentError.oversizedDocument }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Preserve the previous good recovery before replacing it.
            let previous = try Self.boundedData(at: fileURL)
            _ = try Self.readData(previous)
            try previous.write(to: backupURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func load() throws -> WritingDocument? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Self.readData(Self.boundedData(at: fileURL))
    }

    public static func read(from url: URL) throws -> WritingDocument {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= maximumBytes else { throw WritingDocumentError.oversizedDocument }
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt":
            guard let body = String(data: data, encoding: .utf8) else {
                throw WritingDocumentError.invalidDocument("Text file is not valid UTF-8")
            }
            let document = WritingDocument(title: url.deletingPathExtension().lastPathComponent, body: body)
            try document.validate()
            return document
        default:
            return try readData(data)
        }
    }

    public static func write(_ document: WritingDocument, to url: URL) throws {
        try document.validate()
        let data: Data
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt": data = Data(document.body.utf8)
        default: data = try encoder().encode(document)
        }
        guard data.count <= maximumBytes else { throw WritingDocumentError.oversizedDocument }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func readData(_ data: Data) throws -> WritingDocument {
        guard data.count <= maximumBytes else { throw WritingDocumentError.oversizedDocument }
        let document: WritingDocument
        do { document = try decoder().decode(WritingDocument.self, from: data) }
        catch { throw error }
        try document.validate()
        return document
    }

    private static func boundedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= maximumBytes else { throw WritingDocumentError.oversizedDocument }
        return try Data(contentsOf: url)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

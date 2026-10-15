import Foundation

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum AIConnection: String, Codable, CaseIterable, Sendable {
    case subscription
    case api
}

public struct AIConfiguration: Codable, Sendable {
    public var provider: AIProvider
    public var connection: AIConnection
    public var model: String
    public var executablePath: String

    /// The effective model for this request. Blank Codex subscription settings use
    /// a lighter default without changing the user's saved preference.
    public var modelForRequest: String {
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           provider == .codex, connection == .subscription { return "gpt-6-luna" }
        return model
    }

    /// Request-scoped Codex settings for the blank-model subscription default.
    public var codexRequestOverrides: [String] {
        guard model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider == .codex, connection == .subscription else { return [] }
        return ["model_reasoning_effort=\"low\"", "service_tier=\"default\""]
    }

    public init(provider: AIProvider = .codex, connection: AIConnection = .subscription, model: String = "", executablePath: String = "") {
        self.provider = provider
        self.connection = connection
        self.model = model
        self.executablePath = executablePath
    }

    public static func load() -> AIConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "WriteOn.ai.configuration"),
              let value = try? JSONDecoder().decode(AIConfiguration.self, from: data) else { return AIConfiguration() }
        return value
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "WriteOn.ai.configuration")
    }
}

/// Tracks one UI request so repeated clicks cannot replace it and stale callbacks
/// cannot finish a later request.
public struct AIRequestLifecycle: Sendable {
    private var activeID: UUID?
    public init() {}
    public var isBusy: Bool { activeID != nil }
    public func isCurrent(_ id: UUID) -> Bool { activeID == id }
    public mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID(); activeID = id; return id
    }
    @discardableResult public mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil; return true
    }
    public mutating func cancel(_ id: UUID) { if activeID == id { activeID = nil } }
}

public enum AIAction: String, CaseIterable, Sendable {
    case alternatives, proofread, smoothness, longSentences, convoluted, tone, hedges
    case trimLight, trimMedium, trimStrong, trimHalf

    public var title: String {
        switch self {
        case .alternatives: return "Alternatives"
        case .proofread: return "Proofread"
        case .smoothness: return "Smoothness"
        case .longSentences: return "Long sentences"
        case .convoluted: return "Convoluted passages"
        case .tone: return "Tone"
        case .hedges: return "Hedges"
        case .trimLight: return "Trim lightly"
        case .trimMedium: return "Trim moderately"
        case .trimStrong: return "Trim strongly"
        case .trimHalf: return "Trim by half"
        }
    }
}

public enum AIError: Error, LocalizedError, Sendable, Equatable {
    case oversizedDocument
    case oversizedSelection
    case noUniqueMatch(String)
    case invalidResponse
    case providerUnavailable(String)
    case timedOut
    case cancelled
    case outputTooLarge
    case keychain(String)
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .oversizedDocument: return "The document is too long for this request. Select a shorter passage."
        case .oversizedSelection: return "The selection is too long for this request. Select a shorter passage."
        case .noUniqueMatch: return "A suggestion could not be anchored uniquely. Nothing was changed."
        case .invalidResponse: return "The provider returned an unreadable response. Try again."
        case .providerUnavailable(let message):
            if ["Codex", "Claude", "OpenAI API", "Claude API"].contains(message) {
                return "\(message) could not complete the request. Check its sign-in or API settings and try again."
            }
            return message
        case .timedOut: return "The request took too long and was stopped. Try again."
        case .cancelled: return "The request was cancelled."
        case .outputTooLarge: return "The provider response was too large to process."
        case .keychain(let message): return "The API key could not be accessed in Keychain. \(message)"
        case .missingAPIKey: return "Save an API key for this provider in Settings before using API mode."
        }
    }
}

public struct AIRequest: Sendable {
    public let action: AIAction
    public let document: String
    public let selection: String
    public let existing: [String]
    let validationError: AIError?

    public init(action: AIAction, document: String, selection: String = "", existing: [String] = []) {
        if document.count > 50_000 {
            self.validationError = .oversizedDocument
            self.document = String(document.prefix(50_000))
        } else if selection.count > 8_000 {
            self.validationError = .oversizedSelection
            self.document = document
        } else {
            self.validationError = nil
            self.document = document
        }
        self.action = action
        self.selection = String(selection.prefix(8_000))
        self.existing = Array(existing.prefix(40)).map { String($0.prefix(2_000)) }
    }
}

public struct AISuggestion: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let quote: String
    public let replacement: String?
    public let reason: String

    public init(quote: String, replacement: String? = nil, reason: String) {
        self.id = UUID()
        self.quote = quote
        self.replacement = replacement
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case id, quote, replacement, reason }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        quote = try values.decode(String.self, forKey: .quote)
        replacement = try values.decodeIfPresent(String.self, forKey: .replacement)
        reason = try values.decode(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(quote, forKey: .quote)
        try values.encode(replacement, forKey: .replacement)
        try values.encode(reason, forKey: .reason)
    }
}

public struct AIResult: Sendable {
    public let alternatives: [String]
    public let suggestions: [AISuggestion]

    public init(alternatives: [String] = [], suggestions: [AISuggestion] = []) {
        self.alternatives = alternatives
        self.suggestions = suggestions
    }
}

enum AIResponseParser {
    static func parseJSON(_ data: Data, action: AIAction, sourceDocument: String, selectedText: String = "") throws -> AIResult {
        guard data.count <= 1_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if data.count > 1_000_000 { throw AIError.outputTooLarge }
            throw AIError.invalidResponse
        }
        guard let rawAlternatives = root["alternatives"] as? [String],
              let rawSuggestions = root["suggestions"] as? [[String: Any]],
              rawAlternatives.count <= 12, rawSuggestions.count <= 100,
              rawAlternatives.allSatisfy({ !$0.isEmpty && $0.count <= 8_000 }) else { throw AIError.invalidResponse }
        let alternatives = unique(rawAlternatives)
        var suggestions: [AISuggestion] = []
        for item in rawSuggestions.prefix(100) {
            guard let quote = item["quote"] as? String, !quote.isEmpty, quote.count <= 8_000,
                  let reason = item["reason"] as? String, !reason.isEmpty, reason.count <= 1_000 else { throw AIError.invalidResponse }
            let locations = occurrences(of: quote, in: sourceDocument)
            guard locations.count == 1 else { throw AIError.noUniqueMatch(quote) }
            guard item.keys.contains("replacement") else { throw AIError.invalidResponse }
            let replacement: String?
            if item["replacement"] is NSNull { replacement = nil }
            else if let value = item["replacement"] as? String, value.count <= 8_000 { replacement = value }
            else { throw AIError.invalidResponse }
            let trimActions: Set<AIAction> = [.trimLight, .trimMedium, .trimStrong, .trimHalf]
            if trimActions.contains(action), replacement != nil {
                throw AIError.invalidResponse
            }
            if !trimActions.contains(action), action != .proofread, replacement != nil { throw AIError.invalidResponse }
            if action == .proofread, replacement == nil { throw AIError.invalidResponse }
            if !selectedText.isEmpty, !selectedText.contains(quote) { throw AIError.noUniqueMatch(quote) }
            suggestions.append(AISuggestion(quote: quote, replacement: replacement, reason: reason))
        }
        return AIResult(alternatives: Array(alternatives), suggestions: suggestions)
    }

    static func parseCodexEvents(_ data: Data, action: AIAction, sourceDocument: String, selectedText: String = "") throws -> AIResult {
        guard data.count <= 1_000_000 else { throw AIError.outputTooLarge }
        var finalText: String?
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if row["type"] as? String == "item.completed",
               let item = row["item"] as? [String: Any],
               item["type"] as? String == "agent_message", let text = item["text"] as? String { finalText = text }
            if row["type"] as? String == "turn.failed" { throw AIError.providerUnavailable("Codex") }
        }
        guard let finalText else { throw AIError.invalidResponse }
        return try parseJSON(Data(finalText.utf8), action: action, sourceDocument: sourceDocument, selectedText: selectedText)
    }

    static func parseClaudeOutput(_ data: Data, action: AIAction, sourceDocument: String, selectedText: String = "") throws -> AIResult {
        guard data.count <= 1_000_000 else { throw AIError.outputTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw AIError.invalidResponse }
        let payload: [String: Any]?
        if let object = root as? [String: Any] {
            payload = object
        } else if let events = root as? [[String: Any]] {
            payload = events.reversed().first { $0["type"] as? String == "result" }
        } else {
            payload = nil
        }
        guard let payload else { throw AIError.invalidResponse }
        if payload["is_error"] as? Bool == true { throw AIError.providerUnavailable("Claude") }
        if let structured = payload["structured_output"], JSONSerialization.isValidJSONObject(structured),
           let bytes = try? JSONSerialization.data(withJSONObject: structured) {
            return try parseJSON(bytes, action: action, sourceDocument: sourceDocument, selectedText: selectedText)
        }
        guard let text = payload["result"] as? String else { throw AIError.invalidResponse }
        return try parseJSON(Data(text.utf8), action: action, sourceDocument: sourceDocument, selectedText: selectedText)
    }

    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }

    private static func occurrences(of quote: String, in document: String) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []
        var cursor = document.startIndex
        while cursor < document.endIndex, let range = document.range(of: quote, range: cursor..<document.endIndex) {
            matches.append(range)
            if matches.count > 1 { break }
            cursor = range.lowerBound < document.endIndex ? document.index(after: range.lowerBound) : document.endIndex
        }
        return matches
    }
}

import Foundation

public enum WritingDocumentError: Error, Equatable {
    case invalidRange
    case overlappingAlternatives
    case missingGroup
    case invalidAlternativeIndex
    case missingAlternative
    case invalidDocument(String)
    case unsupportedSchema(Int)
    case oversizedDocument
}

public struct TextRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public enum AlternativeSource: String, Codable, Sendable { case human, ai }

public struct Alternative: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var source: AlternativeSource
    public init(id: UUID = UUID(), text: String, source: AlternativeSource = .human) {
        self.id = id; self.text = text; self.source = source
    }
}

public struct AlternativeGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var range: TextRange
    public var options: [Alternative]
    public var selectedIndex: Int
    public init(id: UUID = UUID(), range: TextRange, options: [Alternative], selectedIndex: Int = 0) {
        self.id = id; self.range = range; self.options = options; self.selectedIndex = selectedIndex
    }
}

public struct GhostSpan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var range: TextRange
    public init(id: UUID = UUID(), range: TextRange) { self.id = id; self.range = range }
}

public enum PasteColour: String, Codable, CaseIterable, Sendable { case teal, blue, amber, coral, green }

public struct PasteSpan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var range: TextRange
    public var colour: PasteColour
    public init(id: UUID = UUID(), range: TextRange, colour: PasteColour) {
        self.id = id; self.range = range; self.colour = colour
    }
}

public struct WritingDocument: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var overflow: String
    public var alternatives: [AlternativeGroup]
    public var ghosts: [GhostSpan]
    public var pasteSpans: [PasteSpan]
    public var modifiedAt: Date
    private var schemaVersion: Int

    public init(title: String = "Untitled", body: String = "") {
        id = UUID(); self.title = title; self.body = body; overflow = ""
        alternatives = []; ghosts = []; pasteSpans = []; modifiedAt = Date(); schemaVersion = 1
    }

    private enum CodingKeys: String, CodingKey { case id, title, body, overflow, alternatives, ghosts, pasteSpans, modifiedAt, schemaVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        body = try c.decode(String.self, forKey: .body)
        overflow = try c.decodeIfPresent(String.self, forKey: .overflow) ?? ""
        alternatives = try c.decodeIfPresent([AlternativeGroup].self, forKey: .alternatives) ?? []
        ghosts = try c.decodeIfPresent([GhostSpan].self, forKey: .ghosts) ?? []
        pasteSpans = try c.decodeIfPresent([PasteSpan].self, forKey: .pasteSpans) ?? []
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public func text(in range: TextRange) throws -> String {
        let ns = body as NSString
        guard range.location >= 0, range.length >= 0, range.location <= ns.length,
              range.length <= ns.length - range.location,
              isScalarBoundary(range.location, in: ns), isScalarBoundary(range.location + range.length, in: ns),
              let swiftRange = Range(range.nsRange, in: body) else { throw WritingDocumentError.invalidRange }
        return String(body[swiftRange])
    }

    private func isScalarBoundary(_ offset: Int, in string: NSString) -> Bool {
        guard offset > 0, offset < string.length else { return true }
        let previous = string.character(at: offset - 1)
        let next = string.character(at: offset)
        return !(0xD800...0xDBFF).contains(previous) || !(0xDC00...0xDFFF).contains(next)
    }

    public var wordCount: Int {
        body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw WritingDocumentError.unsupportedSchema(schemaVersion) }
        guard !title.isEmpty, title.utf8.count <= 1_024, body.utf8.count <= 5_000_000,
              overflow.utf8.count <= 5_000_000, alternatives.count <= 10_000,
              ghosts.count <= 10_000, pasteSpans.count <= 10_000 else { throw WritingDocumentError.invalidDocument("Invalid title or document size") }
        var identifiers = Set<UUID>()
        var annotationBytes = 0
        for g in alternatives {
            guard g.range.length > 0, !g.options.isEmpty, g.options.count <= 100,
                  g.selectedIndex >= 0, g.selectedIndex < g.options.count,
                  identifiers.insert(g.id).inserted,
                  try text(in: g.range) == g.options[g.selectedIndex].text else {
                throw WritingDocumentError.invalidDocument("Alternative range does not match selected text")
            }
            for option in g.options {
                guard !option.text.isEmpty, option.text.utf8.count <= 64 * 1024, identifiers.insert(option.id).inserted else {
                    throw WritingDocumentError.invalidDocument("Invalid or duplicate alternative")
                }
                annotationBytes += option.text.utf8.count
            }
        }
        for ghost in ghosts {
            guard identifiers.insert(ghost.id).inserted else { throw WritingDocumentError.invalidDocument("Duplicate annotation identifier") }
            _ = try text(in: ghost.range)
        }
        for span in pasteSpans {
            guard span.range.length > 0, identifiers.insert(span.id).inserted else { throw WritingDocumentError.invalidDocument("Invalid paste span") }
            _ = try text(in: span.range)
        }
        guard annotationBytes <= 4 * 1024 * 1024 else { throw WritingDocumentError.invalidDocument("Alternative text is too large") }
        let sorted = alternatives.sorted { $0.range.location < $1.range.location }
        for pair in zip(sorted, sorted.dropFirst()) where pair.0.range.location + pair.0.range.length > pair.1.range.location {
            throw WritingDocumentError.invalidDocument("Alternative ranges overlap")
        }
        let sortedPaste = pasteSpans.sorted { $0.range.location < $1.range.location }
        for pair in zip(sortedPaste, sortedPaste.dropFirst()) where pair.0.range.location + pair.0.range.length > pair.1.range.location {
            throw WritingDocumentError.invalidDocument("Paste spans overlap")
        }
    }

    public mutating func replace(range: TextRange, with replacement: String) throws {
        _ = try text(in: range)
        if range.length == 0 && replacement.isEmpty { return }
        let start = range.location, end = start + range.length
        let newLength = (replacement as NSString).length
        let delta = newLength - range.length
        let insertion = range.length == 0
        var nextAlternatives: [AlternativeGroup] = []
        for var g in alternatives {
            let gs = g.range.location, ge = gs + g.range.length
            if insertion && start > gs && start < ge {
                let updated = (g.options[g.selectedIndex].text as NSString).replacingCharacters(in: NSRange(location: start - gs, length: 0), with: replacement)
                g.options[g.selectedIndex].text = updated
                g.range.length += newLength
                nextAlternatives.append(g)
            } else if end <= gs {
                g.range.location += delta
                nextAlternatives.append(g)
            } else if start >= ge {
                nextAlternatives.append(g)
            } else {
                // Any destructive overlap invalidates the whole mark.
            }
        }
        var nextGhosts: [GhostSpan] = []
        for var ghost in ghosts {
            let gs = ghost.range.location, ge = gs + ghost.range.length
            if insertion && start > gs && start < ge { ghost.range.length += newLength; nextGhosts.append(ghost) }
            else if end <= gs { ghost.range.location += delta; nextGhosts.append(ghost) }
            else if start >= ge { nextGhosts.append(ghost) }
            // A destructive overlap removes the entire ghost mark.
        }
        var nextPaste: [PasteSpan] = []
        for span in pasteSpans {
            let ps = span.range.location, pe = ps + span.range.length
            if insertion {
                if start <= ps { var shifted = span; shifted.range.location += newLength; nextPaste.append(shifted) }
                else if start >= pe { nextPaste.append(span) }
                else {
                    // Keep only the original marked text. Newly typed or pasted text is unmarked.
                    if start > ps { nextPaste.append(PasteSpan(id: span.id, range: TextRange(location: ps, length: start - ps), colour: span.colour)) }
                    if start < pe { nextPaste.append(PasteSpan(range: TextRange(location: start + newLength, length: pe - start), colour: span.colour)) }
                }
            } else if end <= ps { var shifted = span; shifted.range.location += delta; nextPaste.append(shifted) }
            else if start >= pe { nextPaste.append(span) }
            else {
                if ps < start { nextPaste.append(PasteSpan(id: span.id, range: TextRange(location: ps, length: start - ps), colour: span.colour)) }
                if pe > end { nextPaste.append(PasteSpan(range: TextRange(location: start + newLength, length: pe - end), colour: span.colour)) }
            }
        }
        body = (body as NSString).replacingCharacters(in: range.nsRange, with: replacement)
        alternatives = nextAlternatives
        ghosts = nextGhosts
        pasteSpans = nextPaste
        modifiedAt = Date()
    }

    public mutating func paste(range: TextRange, with text: String, colour: PasteColour) throws {
        var updated = self
        _ = try updated.text(in: range)
        try updated.replace(range: range, with: text)
        let length = (text as NSString).length
        if length > 0 { try updated.setPasteColour(range: TextRange(location: range.location, length: length), colour: colour) }
        try updated.validate()
        self = updated
    }

    public mutating func setPasteColour(range: TextRange, colour: PasteColour?) throws {
        var updated = self
        _ = try updated.text(in: range)
        guard range.length > 0 else { throw WritingDocumentError.invalidRange }
        let start = range.location, end = start + range.length
        var result: [PasteSpan] = []
        for span in updated.pasteSpans {
            let s = span.range.location, e = s + span.range.length
            if e <= start || s >= end { result.append(span); continue }
            if s < start { result.append(PasteSpan(id: span.id, range: TextRange(location: s, length: start - s), colour: span.colour)) }
            if e > end { result.append(PasteSpan(range: TextRange(location: end, length: e - end), colour: span.colour)) }
        }
        if let colour { result.append(PasteSpan(range: range, colour: colour)) }
        updated.pasteSpans = result.sorted { $0.range.location < $1.range.location }
        updated.modifiedAt = Date()
        try updated.validate()
        self = updated
    }

    public mutating func addAlternatives(range: TextRange, texts: [String], source: AlternativeSource) throws -> UUID {
        let original = try text(in: range)
        guard range.length > 0 else { throw WritingDocumentError.invalidRange }
        guard texts.count <= 99, texts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 * 1024 }) else {
            throw WritingDocumentError.invalidDocument("Alternative text is too large")
        }
        if let idx = alternatives.firstIndex(where: { $0.range == range }) {
            var additions: [String] = []
            for value in texts where !alternatives[idx].options.contains(where: { $0.text == value }) && !additions.contains(value) {
                additions.append(value)
            }
            guard alternatives[idx].options.count + additions.count <= 100 else { throw WritingDocumentError.invalidDocument("Too many alternatives") }
            for value in additions { alternatives[idx].options.append(Alternative(text: value, source: source)) }
            return alternatives[idx].id
        }
        guard original.utf8.count <= 64 * 1024, alternatives.count < 10_000 else {
            throw WritingDocumentError.invalidDocument("Alternative text or count is too large")
        }
        guard !alternatives.contains(where: { rangesOverlap($0.range, range) }) else { throw WritingDocumentError.overlappingAlternatives }
        var options = [Alternative(text: original, source: .human)]
        for value in texts where value != original && !options.contains(where: { $0.text == value }) { options.append(Alternative(text: value, source: source)) }
        let group = AlternativeGroup(range: range, options: options)
        alternatives.append(group); alternatives.sort { $0.range.location < $1.range.location }
        return group.id
    }

    public mutating func selectAlternative(groupID: UUID, index: Int) throws {
        var updated = self
        try updated.selectAlternativeInPlace(groupID: groupID, index: index)
        self = updated
    }

    private mutating func selectAlternativeInPlace(groupID: UUID, index: Int) throws {
        guard let i = alternatives.firstIndex(where: { $0.id == groupID }) else { throw WritingDocumentError.missingGroup }
        guard alternatives[i].options.indices.contains(index) else { throw WritingDocumentError.invalidAlternativeIndex }
        let group = alternatives[i]
        if index == group.selectedIndex { return }
        var oldRange = group.range
        let value = group.options[index].text
        guard !value.isEmpty else { throw WritingDocumentError.invalidDocument("Alternative text must not be empty") }
        let priorArticle = precedingArticle(before: oldRange.location)
        let replacement = value
        var selectedRange = oldRange
        if let article = priorArticle, let first = firstWord(value),
           (value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count == 1),
           !articleIsAnnotated(article) {
            let wanted = startsWithVowelSound(first) ? "an" : "a"
            if article.word.lowercased() != wanted {
                let articleRange = TextRange(location: article.location, length: article.length)
                try replace(range: articleRange, with: preservingCase(wanted, from: article.word))
                guard let shiftedIndex = alternatives.firstIndex(where: { $0.id == groupID }) else { throw WritingDocumentError.missingGroup }
                oldRange = alternatives[shiftedIndex].range
                selectedRange = oldRange
            }
        }
        // Keep this group alive while transforming all other annotations.
        let saved = alternatives[i]
        alternatives.remove(at: i)
        try replace(range: selectedRange, with: replacement)
        let shiftedIndex = alternatives.firstIndex(where: { $0.id == groupID })
        var restored = saved
        restored.range = TextRange(location: selectedRange.location, length: (replacement as NSString).length)
        restored.selectedIndex = index
        if shiftedIndex == nil { alternatives.append(restored) }
        alternatives.sort { $0.range.location < $1.range.location }
        _ = shiftedIndex
    }

    public mutating func removeAlternative(groupID: UUID, optionID: UUID) throws {
        var updated = self
        try updated.removeAlternativeInPlace(groupID: groupID, optionID: optionID)
        self = updated
    }

    private mutating func removeAlternativeInPlace(groupID: UUID, optionID: UUID) throws {
        guard let i = alternatives.firstIndex(where: { $0.id == groupID }) else { throw WritingDocumentError.missingGroup }
        guard let option = alternatives[i].options.firstIndex(where: { $0.id == optionID }) else { throw WritingDocumentError.missingAlternative }
        guard option != 0 else { throw WritingDocumentError.invalidAlternativeIndex }
        guard alternatives[i].options.count > 1 else { throw WritingDocumentError.invalidAlternativeIndex }
        let wasSelected = option == alternatives[i].selectedIndex
        alternatives[i].options.remove(at: option)
        if wasSelected {
            let fallback = alternatives[i].options.firstIndex(where: { $0.source == .human }) ?? 0
            try selectAlternative(groupID: groupID, index: fallback)
        } else if option < alternatives[i].selectedIndex { alternatives[i].selectedIndex -= 1 }
    }

    public mutating func ghost(range: TextRange) throws {
        _ = try text(in: range)
        guard !ghosts.contains(where: { $0.range == range }) else { return }
        guard ghosts.count < 10_000 else { throw WritingDocumentError.invalidDocument("Too many ghost spans") }
        ghosts.append(GhostSpan(range: range)); ghosts.sort { $0.range.location < $1.range.location }
    }
    public mutating func revive(range: TextRange) { ghosts.removeAll { $0.range == range } }

    public mutating func stash(range: TextRange) throws {
        var updated = self
        let value = try updated.text(in: range)
        updated.overflow += (updated.overflow.isEmpty || updated.overflow.hasSuffix("\n") ? "" : "\n") + value
        try updated.replace(range: range, with: "")
        self = updated
    }

    public mutating func applyCuts(_ ranges: [TextRange]) throws {
        let sorted = ranges.sorted { $0.location > $1.location }
        var previousStart = Int.max
        for range in sorted {
            _ = try text(in: range)
            guard range.location + range.length <= previousStart else { throw WritingDocumentError.invalidRange }
            previousStart = range.location
        }
        var updated = self
        for range in sorted { try updated.replace(range: range, with: "") }
        self = updated
    }

    private func rangesOverlap(_ a: TextRange, _ b: TextRange) -> Bool {
        a.location < b.location + b.length && b.location < a.location + a.length
    }
    private func precedingArticle(before offset: Int) -> (word: String, location: Int, length: Int)? {
        let ns = body as NSString
        guard offset > 0, offset <= ns.length else { return nil }
        var p = offset
        while p > 0, let scalar = scalarAt(ns, p - 1), scalar == " " || scalar == "\t" { p -= 1 }
        let end = p
        while p > 0 && scalarAt(ns, p - 1).map(CharacterSet.letters.contains) == true { p -= 1 }
        let word = ns.substring(with: NSRange(location: p, length: end - p))
        guard ["a", "an"].contains(word.lowercased()), p == 0 || scalarAt(ns, p - 1).map(CharacterSet.letters.contains) != true else { return nil }
        return (word, p, end - p)
    }
    private func articleIsAnnotated(_ article: (word: String, location: Int, length: Int)) -> Bool {
        let range = TextRange(location: article.location, length: article.length)
        return alternatives.contains(where: { rangesOverlap($0.range, range) }) || ghosts.contains(where: { rangesOverlap($0.range, range) })
    }
    private func scalarAt(_ string: NSString, _ offset: Int) -> UnicodeScalar? { UnicodeScalar(string.character(at: offset)) }
    private func firstWord(_ string: String) -> String? { string.split(whereSeparator: { !$0.isLetter }).first.map(String.init) }
    private func startsWithVowelSound(_ word: String) -> Bool {
        let s = word.lowercased()
        if ["hour", "honest", "honor", "heir"].contains(where: s.hasPrefix) { return true }
        if ["university", "user", "usual", "european", "one"].contains(where: s.hasPrefix) { return false }
        return "aeiou".contains(s.first ?? " ")
    }
    private func preservingCase(_ value: String, from source: String) -> String {
        source == source.uppercased() ? value.uppercased() : (source.first?.isUppercase == true ? value.capitalized : value)
    }

    public static var welcome: WritingDocument {
        var d = WritingDocument(title: "A small beginning", body: "Ideas often arrive before their shape is clear. Give them room to grow, then choose the words that sound like you.\n\nA quiet draft can become a useful story when each sentence earns its place.")
        let ns = d.body as NSString
        func span(_ value: String) -> TextRange {
            let found = ns.range(of: value)
            return TextRange(location: found.location, length: found.length)
        }
        let give = "Give them room", quiet = "quiet draft"
        d.alternatives = [
            AlternativeGroup(range: span(give), options: [Alternative(text: give), Alternative(text: "Let the idea breathe"), Alternative(text: "Make space for them")]),
            AlternativeGroup(range: span(quiet), options: [Alternative(text: quiet), Alternative(text: "early draft"), Alternative(text: "first version")])
        ]
        d.ghosts = [GhostSpan(range: span("each sentence"))]
        return d
    }
}

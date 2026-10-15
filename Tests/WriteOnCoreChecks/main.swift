import Foundation
import WriteOnCore

enum CheckFailure: Error { case failed(String) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

func runChecks() throws {
    var document = WritingDocument(body: "😀 hello later")
    let group = try document.addAlternatives(range: TextRange(location: 3, length: 5), texts: ["greetings"], source: .ai)
    try document.replace(range: TextRange(location: 5, length: 0), with: " brave")
    try require(document.alternatives[0].options[0].text == "he bravello", "insertion within marked text must update selected option")
    try require(document.alternatives[0].range == TextRange(location: 3, length: 11), "marked UTF-16 range length")
    try document.replace(range: TextRange(location: 0, length: 0), with: "X")
    try require(document.alternatives[0].id == group && document.alternatives[0].range.location == 4, "range shift before mark")

    var shifted = WritingDocument(body: "one two three")
    _ = try shifted.addAlternatives(range: TextRange(location: 0, length: 3), texts: ["ONE"], source: .ai)
    _ = try shifted.addAlternatives(range: TextRange(location: 8, length: 5), texts: ["THREE"], source: .ai)
    try shifted.replace(range: TextRange(location: 0, length: 0), with: "X ")
    try require(shifted.alternatives.map(\.range) == [TextRange(location: 2, length: 3), TextRange(location: 10, length: 5)], "edit before marked ranges shifts both once")
    try shifted.replace(range: TextRange(location: 6, length: 0), with: "very ")
    try require(shifted.alternatives[1].range == TextRange(location: 15, length: 5), "edit between marks shifts later mark once")

    let surrogateRead = try? WritingDocument(body: "😀").text(in: TextRange(location: 1, length: 1))
    try require(surrogateRead == nil, "surrogate-splitting range must fail")

    var coloured = WritingDocument(body: "A😀BCD")
    try coloured.paste(range: TextRange(location: 1, length: 4), with: "✨XY", colour: .teal)
    try require(coloured.pasteSpans.count == 1 && coloured.pasteSpans[0].range == TextRange(location: 1, length: 3), "paste records UTF-16 span including emoji")
    try coloured.replace(range: TextRange(location: 2, length: 0), with: "typed")
    try require(coloured.pasteSpans.map(\.range) == [TextRange(location: 1, length: 1), TextRange(location: 7, length: 2)], "typing inside paste mark splits provenance around unmarked insertion")
    try coloured.replace(range: TextRange(location: 8, length: 1), with: "q")
    try require(coloured.pasteSpans.map(\.range) == [TextRange(location: 1, length: 1), TextRange(location: 7, length: 1)], "replacement removes provenance from replaced text")
    try coloured.validate()

    var recolour = WritingDocument(body: "abcdefghij")
    try recolour.setPasteColour(range: TextRange(location: 1, length: 8), colour: .blue)
    try recolour.setPasteColour(range: TextRange(location: 4, length: 2), colour: .amber)
    try require(recolour.pasteSpans.map(\.colour) == [.blue, .amber, .blue], "partial recolour splits existing coloured span")
    try recolour.setPasteColour(range: TextRange(location: 3, length: 4), colour: nil)
    try require(recolour.pasteSpans.map(\.range) == [TextRange(location: 1, length: 2), TextRange(location: 7, length: 2)], "partial clear removes only selected provenance")
    let beforeBadMark = recolour
    do {
        try recolour.setPasteColour(range: TextRange(location: 8, length: 99), colour: .coral)
        throw CheckFailure.failed("out of bounds paste mark must fail")
    } catch WritingDocumentError.invalidRange {
        try require(recolour == beforeBadMark, "failed span mutation is transactional")
    }

    var crossing = WritingDocument(body: "aa BB cc DD ee")
    _ = try crossing.addAlternatives(range: TextRange(location: 3, length: 2), texts: ["bb"], source: .ai)
    _ = try crossing.addAlternatives(range: TextRange(location: 9, length: 2), texts: ["dd"], source: .ai)
    _ = try crossing.addAlternatives(range: TextRange(location: 12, length: 2), texts: ["ee"], source: .ai)
    try crossing.ghost(range: TextRange(location: 0, length: 2))
    try crossing.ghost(range: TextRange(location: 4, length: 2))
    try crossing.ghost(range: TextRange(location: 8, length: 2))
    try crossing.ghost(range: TextRange(location: 12, length: 2))
    try crossing.replace(range: TextRange(location: 4, length: 7), with: "X")
    try require(crossing.alternatives.map(\.range) == [TextRange(location: 6, length: 2)], "all intersected groups removed; trailing group shifted once")
    try require(crossing.ghosts.map(\.range) == [TextRange(location: 0, length: 2), TextRange(location: 6, length: 2)], "all intersected ghosts removed; trailing ghost shifted once")

    var editorial = WritingDocument(body: "Keep remove keep too")
    try editorial.ghost(range: TextRange(location: 5, length: 6))
    editorial.revive(range: TextRange(location: 5, length: 6))
    try require(editorial.ghosts.isEmpty, "revive removes ghost mark")
    try editorial.ghost(range: TextRange(location: 5, length: 6))
    try editorial.stash(range: TextRange(location: 5, length: 6))
    try require(editorial.body == "Keep  keep too" && editorial.overflow == "remove", "stash moves selection to overflow")
    try editorial.applyCuts([TextRange(location: 0, length: 5), TextRange(location: 6, length: 8)])
    try require(editorial.body == " ", "descending cuts remove exact original ranges")
    let beforeInvalidCuts = editorial
    do {
        try editorial.applyCuts([TextRange(location: 0, length: 1), TextRange(location: 0, length: 1)])
        throw CheckFailure.failed("overlapping cuts should fail")
    } catch WritingDocumentError.invalidRange {
        try require(editorial == beforeInvalidCuts, "overlapping cuts leave document untouched")
    }

    var article = WritingDocument(body: "This is a apple.")
    let articleID = try article.addAlternatives(range: TextRange(location: 10, length: 5), texts: ["orange", "pear"], source: .ai)
    try article.selectAlternative(groupID: articleID, index: 1)
    try require(article.body == "This is an orange.", "article agreement for selected alternative")
    var articleMarks = WritingDocument(body: "a cat tail")
    let markedCat = try articleMarks.addAlternatives(range: TextRange(location: 2, length: 3), texts: ["owl"], source: .ai)
    try articleMarks.setPasteColour(range: TextRange(location: 6, length: 4), colour: .blue)
    try articleMarks.setPasteColour(range: TextRange(location: 0, length: 5), colour: .teal)
    try articleMarks.selectAlternative(groupID: markedCat, index: 1)
    try require(articleMarks.body == "an owl tail", "article agreement edit uses shared range transformation")
    try require(articleMarks.pasteSpans.map(\.range) == [TextRange(location: 2, length: 1), TextRange(location: 7, length: 4)], "article lengthening transforms adjacent and spanning paste marks")
    try articleMarks.validate()

    var shortenedArticleMarks = WritingDocument(body: "an cat tail")
    let markedAfterAn = try shortenedArticleMarks.addAlternatives(range: TextRange(location: 3, length: 3), texts: ["dog"], source: .ai)
    try shortenedArticleMarks.setPasteColour(range: TextRange(location: 7, length: 4), colour: .amber)
    try shortenedArticleMarks.selectAlternative(groupID: markedAfterAn, index: 1)
    try require(shortenedArticleMarks.body == "a dog tail", "shortening article updates body")
    try require(shortenedArticleMarks.pasteSpans.map(\.range) == [TextRange(location: 6, length: 4)] && shortenedArticleMarks.pasteSpans[0].colour == .amber, "article shortening shifts following paste span")
    try shortenedArticleMarks.validate()

    var activePaste = WritingDocument(body: "cat")
    let activePasteID = try activePaste.addAlternatives(range: TextRange(location: 0, length: 3), texts: ["owl"], source: .ai)
    try activePaste.setPasteColour(range: TextRange(location: 0, length: 3), colour: .coral)
    try activePaste.selectAlternative(groupID: activePasteID, index: 0)
    try require(activePaste.pasteSpans.map(\.range) == [TextRange(location: 0, length: 3)] && activePaste.pasteSpans[0].colour == .coral, "selecting active option preserves paste colour")
    try activePaste.replace(range: TextRange(location: 1, length: 0), with: "")
    try require(activePaste.pasteSpans.count == 1, "empty insertion leaves paste span intact")
    let originalID = article.alternatives[0].options[0].id
    do {
        try article.removeAlternative(groupID: articleID, optionID: originalID)
        throw CheckFailure.failed("removing original should fail")
    } catch WritingDocumentError.invalidAlternativeIndex {
        try require(article.alternatives[0].options[0].id == originalID, "original remains after rejected removal")
    }
    let selectedID = article.alternatives[0].options[1].id
    try article.removeAlternative(groupID: articleID, optionID: selectedID)
    try require(article.body == "This is an apple.", "removing selected option restores original")

    var protectedArticle = WritingDocument(body: "a apple")
    _ = try protectedArticle.addAlternatives(range: TextRange(location: 0, length: 1), texts: ["the"], source: .human)
    let targetID = try protectedArticle.addAlternatives(range: TextRange(location: 2, length: 5), texts: ["orange"], source: .ai)
    try protectedArticle.ghost(range: TextRange(location: 0, length: 1))
    try protectedArticle.selectAlternative(groupID: targetID, index: 1)
    try require(protectedArticle.body == "a orange" && protectedArticle.ghosts.count == 1, "article adjustment preserves overlapping annotations")
    try protectedArticle.validate()

    var phraseAlternative = WritingDocument(body: "a apple")
    let phraseID = try phraseAlternative.addAlternatives(range: TextRange(location: 2, length: 5), texts: ["very orange"], source: .ai)
    try phraseAlternative.selectAlternative(groupID: phraseID, index: 1)
    try require(phraseAlternative.body == "a very orange", "article heuristic is limited to single-word alternatives")

    var duplicateIDs = WritingDocument(body: "one two")
    let duplicatedGroupID = UUID()
    duplicateIDs.alternatives = [
        AlternativeGroup(id: duplicatedGroupID, range: TextRange(location: 0, length: 3), options: [Alternative(text: "one")]),
        AlternativeGroup(id: duplicatedGroupID, range: TextRange(location: 4, length: 3), options: [Alternative(text: "two")])
    ]
    do {
        try duplicateIDs.validate()
        throw CheckFailure.failed("duplicate annotation identifier must fail")
    } catch is WritingDocumentError {}
    do {
        _ = try duplicateIDs.addAlternatives(range: TextRange(location: 3, length: 0), texts: ["x"], source: .ai)
        throw CheckFailure.failed("empty alternative anchor must fail")
    } catch WritingDocumentError.invalidRange {}

    var importedEmptyOption = WritingDocument(body: "keep important text")
    importedEmptyOption.alternatives = [AlternativeGroup(
        range: TextRange(location: 5, length: 9),
        options: [Alternative(text: "important"), Alternative(text: "")]
    )]
    do {
        try importedEmptyOption.validate()
        throw CheckFailure.failed("imported empty inactive option must be rejected")
    } catch is WritingDocumentError {}
    let beforeInvalidSelection = importedEmptyOption
    do {
        try importedEmptyOption.selectAlternative(groupID: importedEmptyOption.alternatives[0].id, index: 1)
        throw CheckFailure.failed("selecting an empty option must fail")
    } catch is WritingDocumentError {
        try require(importedEmptyOption == beforeInvalidSelection, "invalid selection leaves document untouched")
    }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try DocumentStore(directory: folder)
    let folderPermissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
    try require(folderPermissions?.intValue == 0o700, "recovery directory permissions are private")
    var saved = WritingDocument(title: "Round trip", body: "A draft ✨")
    _ = try saved.addAlternatives(range: TextRange(location: 0, length: 1), texts: ["The"], source: .human)
    try saved.ghost(range: TextRange(location: 2, length: 5))
    try saved.setPasteColour(range: TextRange(location: 8, length: 1), colour: .green)
    try store.save(saved)
    let loaded = try store.load()
    try require(loaded == saved, "recovery round-trip including exact modifiedAt")
    let legacyJSON = "{\"body\":\"legacy\",\"title\":\"Old\"}"
    let legacy = try JSONDecoder().decode(WritingDocument.self, from: Data(legacyJSON.utf8))
    try require(legacy.pasteSpans.isEmpty, "legacy document without pasteSpans decodes")
    var malformedSpan = WritingDocument(body: "short")
    malformedSpan.pasteSpans = [PasteSpan(range: TextRange(location: 4, length: 2), colour: .teal)]
    do { try malformedSpan.validate(); throw CheckFailure.failed("out of bounds paste span must fail validation") }
    catch is WritingDocumentError {}
    let filePermissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("recovery.writeon").path)[.posixPermissions] as? NSNumber
    try require(filePermissions?.intValue == 0o600, "recovery file permissions are private")
    let second = WritingDocument(title: "Second", body: "new body")
    try store.save(second)
    let backupDocument = try DocumentStore.read(from: folder.appendingPathComponent("recovery.writeon.bak"))
    try require(backupDocument == saved, "previous valid recovery retained as backup")

    for ext in ["txt", "md", "markdown"] {
        let textFile = folder.appendingPathComponent("draft.\(ext)")
        try DocumentStore.write(saved, to: textFile)
        let imported = try DocumentStore.read(from: textFile)
        try require(imported.body == saved.body && imported.alternatives.isEmpty && imported.ghosts.isEmpty, ".\(ext) import and export carry plain body only")
    }

    let jsonFile = folder.appendingPathComponent("preserve.writeon")
    let originalBytes = Data("existing".utf8)
    try originalBytes.write(to: jsonFile)
    var invalid = WritingDocument(body: "body")
    invalid.alternatives = [AlternativeGroup(range: TextRange(location: 0, length: 3), options: [Alternative(text: "stale")])]
    do {
        try DocumentStore.write(invalid, to: jsonFile)
        throw CheckFailure.failed("invalid document write must fail")
    } catch is WritingDocumentError {
        let remainingBytes = try Data(contentsOf: jsonFile)
        try require(remainingBytes == originalBytes, "failed save leaves existing file unchanged")
    }

    let corrupt = folder.appendingPathComponent("bad.writeon")
    try Data("{".utf8).write(to: corrupt)
    do {
        _ = try DocumentStore.read(from: corrupt)
        throw CheckFailure.failed("corrupt document read must fail")
    } catch is DecodingError {}
    let oversized = folder.appendingPathComponent("large.writeon")
    try Data(repeating: 0, count: 5 * 1024 * 1024 + 1).write(to: oversized)
    do {
        _ = try DocumentStore.read(from: oversized)
        throw CheckFailure.failed("oversized document read must fail")
    } catch WritingDocumentError.oversizedDocument {}
    print("WRITE_ON_CORE_CHECKS_PASSED")
}

do { try runChecks() }
catch { fputs("WriteOnCore check failed: \(error)\n", stderr); exit(1) }

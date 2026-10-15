import XCTest
@testable import WriteOnCore

final class WriteOnCoreTests: XCTestCase {
    func testUTF16EditsShiftRangesAndInsertionUpdatesSelectedOption() throws {
        var document = WritingDocument(body: "😀 hello later")
        let hello = TextRange(location: 3, length: 5)
        let id = try document.addAlternatives(range: hello, texts: ["greetings"], source: .ai)
        try document.replace(range: TextRange(location: 3 + 2, length: 0), with: " brave")
        XCTAssertEqual(document.alternatives.first?.range, TextRange(location: 3, length: 11))
        XCTAssertEqual(document.alternatives.first?.options[0].text, "he bravello")
        XCTAssertEqual(try document.text(in: document.alternatives[0].range), "he bravello")
        try document.replace(range: TextRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(document.alternatives.first?.id, id)
        XCTAssertEqual(document.alternatives.first?.range.location, 4)
    }

    func testAlternativesSelectionRemovalAndArticleAgreement() throws {
        var document = WritingDocument(body: "This is a apple.")
        let range = TextRange(location: 10, length: 5)
        let id = try document.addAlternatives(range: range, texts: ["orange", "pear"], source: .ai)
        try document.selectAlternative(groupID: id, index: 1)
        XCTAssertEqual(document.body, "This is an orange.")
        XCTAssertEqual(try document.text(in: document.alternatives[0].range), "orange")
        let originalID = document.alternatives[0].options[0].id
        try document.removeAlternative(groupID: id, optionID: document.alternatives[0].options[1].id)
        XCTAssertEqual(document.body, "This is an apple.")
        XCTAssertEqual(document.alternatives[0].options[0].id, originalID)
    }

    func testGhostReviveStashAndDescendingCuts() throws {
        var document = WritingDocument(body: "Keep remove keep too")
        try document.ghost(range: TextRange(location: 5, length: 6))
        document.revive(range: TextRange(location: 5, length: 6))
        XCTAssertTrue(document.ghosts.isEmpty)
        try document.stash(range: TextRange(location: 5, length: 6))
        XCTAssertEqual(document.body, "Keep  keep too")
        XCTAssertEqual(document.overflow, "remove")
        try document.applyCuts([TextRange(location: 0, length: 5), TextRange(location: 6, length: 8)])
        XCTAssertEqual(document.body, " ")
    }

    func testOverlappingMarksAreRemovedAndOverlappingGroupsRejected() throws {
        var document = WritingDocument(body: "one two three")
        let first = TextRange(location: 0, length: 3)
        try document.addAlternatives(range: first, texts: ["ONE"], source: .ai)
        XCTAssertThrowsError(try document.addAlternatives(range: TextRange(location: 2, length: 4), texts: ["x"], source: .human))
        try document.replace(range: TextRange(location: 1, length: 4), with: "X")
        XCTAssertTrue(document.alternatives.isEmpty)
        XCTAssertEqual(document.body, "oXwo three")
    }

    func testCrossingEditRemovesEveryAffectedMarkAndShiftsUnaffectedMarksOnce() throws {
        var document = WritingDocument(body: "aa BB cc DD ee")
        try document.addAlternatives(range: TextRange(location: 3, length: 2), texts: ["bb"], source: .ai)
        try document.addAlternatives(range: TextRange(location: 9, length: 2), texts: ["dd"], source: .ai)
        try document.addAlternatives(range: TextRange(location: 12, length: 2), texts: ["ee"], source: .ai)
        try document.ghost(range: TextRange(location: 0, length: 2))
        try document.ghost(range: TextRange(location: 4, length: 2))
        try document.ghost(range: TextRange(location: 8, length: 2))
        try document.ghost(range: TextRange(location: 12, length: 2))
        try document.replace(range: TextRange(location: 4, length: 7), with: "X")
        XCTAssertEqual(document.body, "aa BX ee")
        XCTAssertEqual(document.alternatives.map(\.range), [TextRange(location: 6, length: 2)])
        XCTAssertEqual(document.ghosts.map(\.range), [TextRange(location: 0, length: 2), TextRange(location: 6, length: 2)])
        XCTAssertNoThrow(try document.validate())
    }

    func testEditsBeforeAndBetweenMarksShiftEachLaterRangeOnce() throws {
        var document = WritingDocument(body: "one two three")
        _ = try document.addAlternatives(range: TextRange(location: 0, length: 3), texts: ["ONE"], source: .ai)
        _ = try document.addAlternatives(range: TextRange(location: 8, length: 5), texts: ["THREE"], source: .ai)
        try document.replace(range: TextRange(location: 0, length: 0), with: "X ")
        XCTAssertEqual(document.alternatives.map(\.range), [TextRange(location: 2, length: 3), TextRange(location: 10, length: 5)])
        try document.replace(range: TextRange(location: 6, length: 0), with: "very ")
        XCTAssertEqual(document.alternatives.map(\.range), [TextRange(location: 2, length: 3), TextRange(location: 15, length: 5)])
        XCTAssertEqual(try document.text(in: document.alternatives[1].range), "three")
    }

    func testDeletingLastSelectedAlternativeRestoresOriginal() throws {
        var document = WritingDocument(body: "a apple")
        let id = try document.addAlternatives(range: TextRange(location: 2, length: 5), texts: ["orange", "pear"], source: .ai)
        try document.selectAlternative(groupID: id, index: 2)
        XCTAssertEqual(document.body, "a pear")
        let selectedID = document.alternatives[0].options[2].id
        try document.removeAlternative(groupID: id, optionID: selectedID)
        XCTAssertEqual(document.body, "an apple")
        XCTAssertEqual(document.alternatives[0].selectedIndex, 0)
    }

    func testArticleAdjustmentLeavesAnnotatedArticleAndIgnoresPhraseAlternatives() throws {
        var document = WritingDocument(body: "a apple")
        _ = try document.addAlternatives(range: TextRange(location: 0, length: 1), texts: ["the"], source: .human)
        let targetID = try document.addAlternatives(range: TextRange(location: 2, length: 5), texts: ["orange"], source: .ai)
        try document.ghost(range: TextRange(location: 0, length: 1))
        try document.selectAlternative(groupID: targetID, index: 1)
        XCTAssertEqual(document.body, "a orange")
        XCTAssertEqual(document.ghosts.count, 1)
        XCTAssertNoThrow(try document.validate())

        var phrase = WritingDocument(body: "a apple")
        let phraseID = try phrase.addAlternatives(range: TextRange(location: 2, length: 5), texts: ["very orange"], source: .ai)
        try phrase.selectAlternative(groupID: phraseID, index: 1)
        XCTAssertEqual(phrase.body, "a very orange")
    }

    func testValidationRejectsDuplicateIdentifiersAndEmptyAlternativeAnchors() throws {
        var document = WritingDocument(body: "one two")
        let groupID = UUID()
        let optionID = UUID()
        document.alternatives = [
            AlternativeGroup(id: groupID, range: TextRange(location: 0, length: 3), options: [Alternative(id: optionID, text: "one")]),
            AlternativeGroup(id: groupID, range: TextRange(location: 4, length: 3), options: [Alternative(id: UUID(), text: "two")])
        ]
        XCTAssertThrowsError(try document.validate())
        XCTAssertThrowsError(try document.addAlternatives(range: TextRange(location: 3, length: 0), texts: ["x"], source: .ai))
    }

    func testValidationRejectsImportedEmptyInactiveOptionAndSelectionIsTransactional() throws {
        var document = WritingDocument(body: "keep important text")
        document.alternatives = [AlternativeGroup(
            range: TextRange(location: 5, length: 9),
            options: [Alternative(text: "important"), Alternative(text: "")]
        )]
        XCTAssertThrowsError(try document.validate())
        let before = document
        XCTAssertThrowsError(try document.selectAlternative(groupID: document.alternatives[0].id, index: 1))
        XCTAssertEqual(document, before)

        var valid = WritingDocument(body: "cat")
        let id = try valid.addAlternatives(range: TextRange(location: 0, length: 3), texts: ["dog"], source: .ai)
        let validBefore = valid
        XCTAssertThrowsError(try valid.selectAlternative(groupID: id, index: 99))
        XCTAssertEqual(valid, validBefore)
    }

    func testUTF16RangeCannotSplitSurrogatePair() {
        let document = WritingDocument(body: "A😀B")
        XCTAssertThrowsError(try document.text(in: TextRange(location: 2, length: 1)))
        XCTAssertThrowsError(try document.replace(range: TextRange(location: 2, length: 1), with: "x"))
    }

    func testPasteProvenanceTracksEditsAndRecoloursSelections() throws {
        var document = WritingDocument(body: "A😀BCD")
        try document.paste(range: TextRange(location: 1, length: 4), with: "✨XY", colour: .teal)
        XCTAssertEqual(document.pasteSpans.map(\.range), [TextRange(location: 1, length: 3)])
        try document.replace(range: TextRange(location: 2, length: 0), with: "typed")
        XCTAssertEqual(document.pasteSpans.map(\.range), [TextRange(location: 1, length: 1), TextRange(location: 7, length: 2)])
        try document.replace(range: TextRange(location: 8, length: 1), with: "q")
        XCTAssertEqual(document.pasteSpans.map(\.range), [TextRange(location: 1, length: 1), TextRange(location: 7, length: 1)])

        var colours = WritingDocument(body: "abcdefghij")
        try colours.setPasteColour(range: TextRange(location: 1, length: 8), colour: .blue)
        try colours.setPasteColour(range: TextRange(location: 4, length: 2), colour: .amber)
        XCTAssertEqual(colours.pasteSpans.map(\.colour), [.blue, .amber, .blue])
        try colours.setPasteColour(range: TextRange(location: 3, length: 4), colour: nil)
        XCTAssertEqual(colours.pasteSpans.map(\.range), [TextRange(location: 1, length: 2), TextRange(location: 7, length: 2)])
        XCTAssertNoThrow(try colours.validate())
    }

    func testPasteProvenancePersistsAndLegacyDocumentsDecode() throws {
        var document = WritingDocument(title: "Round trip", body: "draft ✨")
        try document.setPasteColour(range: TextRange(location: 0, length: 5), colour: .green)
        let data = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(WritingDocument.self, from: data), document)
        let legacy = try JSONDecoder().decode(WritingDocument.self, from: Data("{\"body\":\"legacy\"}".utf8))
        XCTAssertTrue(legacy.pasteSpans.isEmpty)

        let before = document
        XCTAssertThrowsError(try document.setPasteColour(range: TextRange(location: 5, length: 99), colour: .coral))
        XCTAssertEqual(document, before)
        var invalid = WritingDocument(body: "short")
        invalid.pasteSpans = [PasteSpan(range: TextRange(location: 4, length: 2), colour: .teal)]
        XCTAssertThrowsError(try invalid.validate())
    }

    func testArticleAgreementEditsTransformPasteRanges() throws {
        var document = WritingDocument(body: "a cat tail")
        let cat = try document.addAlternatives(range: TextRange(location: 2, length: 3), texts: ["owl"], source: .ai)
        try document.setPasteColour(range: TextRange(location: 6, length: 4), colour: .blue)
        try document.selectAlternative(groupID: cat, index: 1)
        XCTAssertEqual(document.body, "an owl tail")
        XCTAssertEqual(document.pasteSpans.map(\.range), [TextRange(location: 7, length: 4)])
        XCTAssertNoThrow(try document.validate())

        var shortening = WritingDocument(body: "an cat tail")
        let catAfterAn = try shortening.addAlternatives(range: TextRange(location: 3, length: 3), texts: ["dog"], source: .ai)
        try shortening.setPasteColour(range: TextRange(location: 7, length: 4), colour: .amber)
        try shortening.selectAlternative(groupID: catAfterAn, index: 1)
        XCTAssertEqual(shortening.body, "a dog tail")
        XCTAssertEqual(shortening.pasteSpans.map(\.range), [TextRange(location: 6, length: 4)])
        XCTAssertNoThrow(try shortening.validate())
    }

    func testSelectingActiveAlternativeAndEmptyInsertionKeepPasteMark() throws {
        var document = WritingDocument(body: "cat")
        let cat = try document.addAlternatives(range: TextRange(location: 0, length: 3), texts: ["owl"], source: .ai)
        try document.setPasteColour(range: TextRange(location: 0, length: 3), colour: .coral)
        try document.selectAlternative(groupID: cat, index: 0)
        try document.replace(range: TextRange(location: 1, length: 0), with: "")
        XCTAssertEqual(document.pasteSpans.map(\.range), [TextRange(location: 0, length: 3)])
    }

    func testOriginalCannotBeRemovedAndFailuresLeaveDocumentUntouched() throws {
        var document = WritingDocument(body: "a cat b dog")
        let id1 = try document.addAlternatives(range: TextRange(location: 2, length: 3), texts: ["hound"], source: .ai)
        _ = try document.addAlternatives(range: TextRange(location: 8, length: 3), texts: ["wolf"], source: .ai)
        let before = document
        XCTAssertThrowsError(try document.removeAlternative(groupID: id1, optionID: document.alternatives[0].options[0].id))
        XCTAssertEqual(document, before)
        XCTAssertThrowsError(try document.applyCuts([TextRange(location: 0, length: 4), TextRange(location: 3, length: 3)]))
        XCTAssertEqual(document, before)
        XCTAssertThrowsError(try document.stash(range: TextRange(location: 99, length: 2)))
        XCTAssertEqual(document, before)
    }

    func testPersistenceRoundTripAndCorruptOrOversizedInputs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try DocumentStore(directory: folder)
        var document = WritingDocument(title: "Round trip", body: "A draft ✨")
        try document.addAlternatives(range: TextRange(location: 0, length: 1), texts: ["The"], source: .human)
        try document.ghost(range: TextRange(location: 2, length: 5))
        try store.save(document)
        XCTAssertEqual(try store.load(), document)
        let corrupt = folder.appendingPathComponent("bad.writeon")
        try Data("{".utf8).write(to: corrupt)
        XCTAssertThrowsError(try DocumentStore.read(from: corrupt))
        let large = folder.appendingPathComponent("large.writeon")
        try Data(repeating: 0, count: 5 * 1024 * 1024 + 1).write(to: large)
        XCTAssertThrowsError(try DocumentStore.read(from: large))
    }

    func testMarkdownExtensionImportsAndExportsPlainBody() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = WritingDocument(title: "Draft", body: "# Heading\n\nBody")
        let url = folder.appendingPathComponent("draft.markdown")
        try DocumentStore.write(document, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), document.body)
        let imported = try DocumentStore.read(from: url)
        XCTAssertEqual(imported.body, document.body)
        XCTAssertTrue(imported.alternatives.isEmpty)
        XCTAssertTrue(imported.ghosts.isEmpty)
    }

    func testWelcomeHasTwoGroupsAndGhost() {
        let document = WritingDocument.welcome
        XCTAssertEqual(document.alternatives.count, 2)
        XCTAssertEqual(document.ghosts.count, 1)
        XCTAssertNoThrow(try document.validate())
    }
}

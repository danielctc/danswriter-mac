import XCTest
@testable import WriteOnAI

final class AIResponseParserTests: XCTestCase {
    func testParsesDistinctAlternativesAndExactUniqueAnnotations() throws {
        let data = Data("""
        {"alternatives":["A clearer line.","A clearer line."],"suggestions":[{"quote":"This sentence is long.","replacement":"This sentence is short.","reason":"Tighten it."}]}
        """.utf8)
        let result = try AIResponseParser.parseJSON(data, action: .proofread, sourceDocument: "This sentence is long.")
        XCTAssertEqual(result.alternatives, ["A clearer line."])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions[0].quote, "This sentence is long.")
    }

    func testRejectsEmptyAlternative() {
        let data = Data(#"{"alternatives":[""],"suggestions":[]}"#.utf8)
        XCTAssertThrowsError(try AIResponseParser.parseJSON(data, action: .alternatives, sourceDocument: "text")) { error in
            XCTAssertEqual(error as? AIError, .invalidResponse)
        }
    }

    func testRejectsAmbiguousQuoteRatherThanFuzzyAnchoring() {
        let data = Data(#"{"alternatives":[],"suggestions":[{"quote":"same phrase","replacement":null,"reason":"remove"}]}"#.utf8)
        XCTAssertThrowsError(try AIResponseParser.parseJSON(data, action: .trimLight, sourceDocument: "same phrase; same phrase")) { error in
            XCTAssertEqual(error as? AIError, .noUniqueMatch("same phrase"))
        }
    }

    func testRejectsMalformedProviderOutput() {
        XCTAssertThrowsError(try AIResponseParser.parseJSON(Data("not json".utf8), action: .alternatives, sourceDocument: "text")) { error in
            XCTAssertEqual(error as? AIError, .invalidResponse)
        }
    }

    func testRequestMarksOversizeForClearRejectionAndCapsStoredText() async {
        let request = AIRequest(action: .proofread, document: String(repeating: "a", count: 50_001))
        XCTAssertEqual(request.document.count, 50_000)
        let service = AIService(session: .shared, keyLookup: { _ in nil }, processRunner: CLIProcessRunner())
        do {
            _ = try await service.generate(request, configuration: AIConfiguration())
            XCTFail("Expected oversized document to be rejected")
        } catch {
            XCTAssertEqual(error as? AIError, .oversizedDocument)
        }
    }
}

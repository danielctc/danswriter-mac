import Foundation

enum AIPrompt {
    static func make(_ request: AIRequest) -> String {
        let focus = request.selection.isEmpty ? request.document : request.selection
        let purpose: String
        switch request.action {
        case .alternatives:
            purpose = "Generate up to 5 distinct rewrites of the selected passage. Put them in alternatives. Return no suggestions."
        case .trimLight: purpose = "Mark only clearly expendable words or clauses, aiming to remove about 5% of the focused text. Each suggestion is a deletion preview: quote exact text and set replacement to null. Never rewrite."
        case .trimMedium: purpose = "Mark only expendable words or clauses, aiming to remove about 10% of the focused text. Each suggestion is a deletion preview: quote exact text and set replacement to null. Never rewrite."
        case .trimStrong: purpose = "Mark only expendable words or clauses, aiming to remove about 20% of the focused text. Each suggestion is a deletion preview: quote exact text and set replacement to null. Never rewrite."
        case .trimHalf: purpose = "Mark only expendable words or clauses, aiming to remove about half of the focused text. Each suggestion is a deletion preview: quote exact text and set replacement to null. Never rewrite."
        case .proofread: purpose = "Find clear spelling, grammar, and punctuation problems. Suggest minimal corrections in replacement; use a non-null replacement."
        case .smoothness: purpose = "Highlight the smoothest sentences as positive examples. Return quote-only annotations with null replacements; do not rewrite."
        case .longSentences: purpose = "Mark long sentences. Return quote-only annotations with null replacements; do not rewrite."
        case .convoluted: purpose = "Mark convoluted passages. Return quote-only annotations with null replacements; do not rewrite."
        case .tone: purpose = "Mark passages whose tone is inconsistent or unclear. Return quote-only annotations with null replacements; do not rewrite."
        case .hedges: purpose = "Mark hedging words or phrases. Return quote-only annotations with null replacements; do not rewrite."
        }
        let existing = request.existing.isEmpty ? "None" : request.existing.joined(separator: "\n---\n")
        return """
        You are a careful writing assistant. Do not edit files or use tools. Return exactly one JSON object with keys alternatives (array of strings) and suggestions (array of objects with quote, replacement, reason). Marking actions use null replacement to annotate without changing text; trim actions use null replacement only for deletion previews; proofreading uses a non-null correction. Every quote must be copied exactly from the document and must occur exactly once. If a quote is not unique, do not return that suggestion. Do not invent source text. Preserve meaning and voice. Suggestions are for review; never claim anything was applied.

        Task: \(request.action.title). \(purpose)
        Selected passage:
        <focus>
        \(focus)
        </focus>
        Existing alternatives to avoid repeating:
        \(existing)
        Full document for local context (do not quote outside the focused passage unless selection is empty):
        <document>
        \(request.document)
        </document>
        """
    }

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "properties": [
            "alternatives": ["type": "array", "items": ["type": "string"]],
            "suggestions": ["type": "array", "items": [
                "type": "object", "additionalProperties": false,
                "properties": ["quote": ["type": "string"], "replacement": ["type": ["string", "null"]], "reason": ["type": "string"]],
                "required": ["quote", "replacement", "reason"]
            ]]
        ], "required": ["alternatives", "suggestions"]
    ]
}

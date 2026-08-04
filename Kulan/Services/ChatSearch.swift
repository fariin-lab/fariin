import Foundation

// In-conversation search engine — the standard search pipeline semantics (an FTS5 unicode61 tokenizer +
// prefix-match AND queries), reimplemented as our own code over Fariin's in-memory decrypted corpus.
// E2EE means the server can never search messages; the only possible index is client-side, built from
// text we've already decrypted, and never persisted as plaintext.
//
// Semantics replicated exactly:
//  • Normalization: NFC compose, case-fold, diacritic-fold (café ≡ cafe), width-fold (CJK), then strip
//    punctuation/symbols/control chars and collapse whitespace. (The reference implementation strips punctuation in
//    normalization and lets SQLite's unicode61 tokenizer do the case/diacritic folding — with no SQLite
//    we do both in code.)
//  • Query building: terms = words (with digits split out, so "abc123" → "abc") + a digits-only term
//    ("abc123" → "123", so numeric search works), deduped.
//  • Matching: EVERY query term must PREFIX-match at least one message token ("hel" matches "hello");
//    terms are ANDed. No OR, no phrase operators — the standard behavior.
enum ChatSearch {
    /// Fold + strip a string down to searchable form (applied identically to messages and queries).
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String()
        out.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")   // punctuation/symbols/controls → separators (stripped out)
            }
        }
        return out
    }

    /// A message's searchable tokens (compute ONCE per message when the corpus is built, not per keystroke).
    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Query terms (the standard query builder): words with digits split out + a digits-only term, deduped.
    static func queryTerms(_ query: String) -> [String] {
        let norm = normalize(query)
        guard !norm.isEmpty else { return [] }
        var terms = Set<String>()
        let wordsOnly = String(norm.map { $0.isNumber ? " " : $0 })
        for t in wordsOnly.split(separator: " ") where !t.isEmpty { terms.insert(String(t)) }
        let digits = norm.filter { $0.isNumber }
        if !digits.isEmpty { terms.insert(String(digits)) }
        return Array(terms)
    }

    /// AND-of-prefix-matches: every term must prefix-match at least one token.
    static func matches(tokens: [String], terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { term in tokens.contains { $0.hasPrefix(term) } }
    }
}

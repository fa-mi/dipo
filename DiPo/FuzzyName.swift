import Foundation

// MARK: - Names typed in a hurry
//
// "indimaret" is Indomaret. Typed on a phone at the till, a shop's name comes
// out a letter off often enough that reading it only as written leaves the
// category unguessed and the same shop under two names in the records. This
// finds the word a slip was aiming at: the user's own past spellings first,
// then the merchants DiPo knows (SmartBudgetManager.merchantMap).
//
// Kept tight on purpose, because a wrong "correction" is worse than none:
//   • words under six letters are never read as slips: too many real short
//     words sit one letter apart ("salah" and "salad", "batuk" and "batik");
//   • one slip up to ten letters, two from eleven;
//   • the first letter has to match: a slip rarely starts a word, and the
//     rule halves the false hits;
//   • a word in its own right is never a slip: one DiPo knows, or a common
//     word that happens to sit a letter from one ("pertama" beside Pertamax,
//     "renang" beside rendang; see `commonWords`);
//   • a merchant of more than one word is matched whole, word by word, so
//     "kenangan" alone is never taken for Kopi Kenangan;
//   • a word that only runs longer or shorter than a known one ("Watsons",
//     "indomar") is a form of it or a name still being typed, and is never
//     offered a correction (its category still follows);
//   • a word the user writes as a habit stands (see `fix`).
// And a name is only ever offered back, never changed on its own.

enum FuzzyName {

    /// How far off a word of this length can be and still read as a slip.
    static func allowance(forLength n: Int) -> Int {
        n < 6 ? 0 : (n < 11 ? 1 : 2)
    }

    /// Optimal string alignment distance: an extra letter, a missing one, a
    /// wrong one or two swapped neighbours ("shoppe") each count one. Gives
    /// up as soon as nothing can stay within `limit`, returning `limit + 1`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a), t = Array(b)
        guard abs(s.count - t.count) <= limit else { return limit + 1 }
        guard !s.isEmpty, !t.isEmpty else { return max(s.count, t.count) }
        var before = [Int](repeating: 0, count: t.count + 1)
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            var rowBest = i
            for j in 1...t.count {
                var cost = min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1))
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    cost = min(cost, before[j - 2] + 1)
                }
                current[j] = cost
                rowBest = min(rowBest, cost)
            }
            if rowBest > limit { return limit + 1 }
            (before, previous, current) = (previous, current, before)
        }
        return min(previous[t.count], limit + 1)
    }

    /// Whether `typed` (lowercased) reads as a slip for `known`: long enough,
    /// the same first letter, not a word in its own right, and close enough.
    static func isTypo(_ typed: String, of known: String) -> Bool {
        guard typed.first == known.first, typed != known, typed.count >= 6, !isWord(typed)
        else { return false }
        let allowed = allowance(forLength: known.count)
        return allowed > 0 && distance(typed, known, limit: allowed) <= allowed
    }

    /// Whether a run of words in `name` (lowercased, single-spaced) is a slip
    /// for `phrase`: "kopi kenagan" for "kopi kenangan". Word by word, so a
    /// short word has to be exact and a long one keeps its own allowance.
    static func contains(_ name: String, typoOf phrase: String) -> Bool {
        let words = name.split(separator: " "), parts = phrase.split(separator: " ")
        guard let lead = parts.first?.first, words.count >= parts.count else { return false }
        return (0...(words.count - parts.count)).contains { start in
            guard words[start].first == lead else { return false }
            let slips = zip(words[start...], parts).filter { $0 != $1 }
            return !slips.isEmpty && slips.allSatisfy { isTypo(String($0), of: String($1)) }
        }
    }

    // MARK: Words in their own right

    static func isWord(_ word: String) -> Bool {
        knownWords.contains(word) || commonWords.contains(word)
    }

    /// Every word of the names and keywords DiPo knows: spelled right already.
    static let knownWords: Set<String> = {
        let keywords: [String] = SmartBudgetManager.merchantMap.flatMap { $0.keywords }
            + LocalTxParser.categoryWords.flatMap { $0.1 }
        return Set(keywords.flatMap { $0.split(separator: " ").map(String.init) })
    }()

    /// Common Indonesian and English words, at least once per million words,
    /// that sit within a slip of a word DiPo knows: "keuangan" is no slip of
    /// Kopi Kenangan's "kenangan", nor "computer" of KRL Commuter. Printed by
    /// ci/fuzzy-words.py from wordfreq's lists; run it again after adding a
    /// keyword to merchantMap or LocalTxParser.categoryWords.
    static let commonWords: Set<String> = [
        "airline", "airliner", "angkat", "angket", "angkor", "angkut", "bakers", "belanda",
        "benson", "berger", "bersin", "booing", "booming", "bugger", "burner", "cleansing",
        "clearing", "commute", "computer", "denial", "deposit", "deposits", "doktor",
        "domingo", "electrician", "famili", "farmer", "fitnes", "fright", "galian",
        "indonesi", "inform", "informs", "kenanga", "kerena", "keuangan", "klinis",
        "landry", "larson", "lawton", "lonjong", "macdonald", "marked", "marker",
        "martabat", "medial", "packing", "pajang", "palang", "pandang", "parang", "parker",
        "parkit", "parting", "pasang", "pawang", "pedang", "perawat", "pertama", "renang",
        "rentang", "rindang", "saking", "saling", "sambung", "saring", "saying", "serapan",
        "serves", "serviks", "shaving", "shipping", "stopping", "tunangan", "tunjungan",
        "winata"
    ]

    // MARK: Offering a name back

    /// A word as the user has written it before, and how often.
    struct Known: Equatable {
        var spelling: String
        var count: Int
    }

    /// The words of past names, each under its most frequent spelling.
    static func vocabulary(of names: [String]) -> [String: Known] {
        var tally: [String: [String: Int]] = [:]
        for name in names {
            for piece in name.split(whereSeparator: \.isWhitespace) {
                let word = String(piece)
                guard word.count >= 6, word.allSatisfy(\.isLetter) else { continue }
                tally[word.lowercased(), default: [:]][word, default: 0] += 1
            }
        }
        return tally.compactMapValues { spellings in
            guard let best = spellings.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
            return Known(spelling: best.key, count: spellings.values.reduce(0, +))
        }
    }

    /// The merchants DiPo knows that are one word, six letters or longer.
    static let merchantWords: Set<String> = Set(
        SmartBudgetManager.merchantMap
            .flatMap { $0.keywords }
            .filter { $0.count >= 6 && $0.allSatisfy(\.isLetter) }
    )

    /// The merchants DiPo knows that are more than one word, matched whole.
    static let merchantPhrases: [String] = SmartBudgetManager.merchantMap
        .flatMap { $0.keywords }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { keyword in keyword.contains(" ") && keyword.allSatisfy { $0.isLetter || $0 == " " } }

    /// `name` with each slip replaced by the word it was aiming at, or nil
    /// when no word needed it. Merchants of more than one word go first, as
    /// a whole; then single words.
    static func corrected(_ name: String, history: [String: Known]) -> String? {
        var words = name.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Words read as part of a merchant's name, slipped or not, are not
        // read again one by one.
        var settled = Set<Int>()
        var changed = false
        for phrase in merchantPhrases {
            let parts = phrase.split(separator: " ").map(String.init)
            guard words.count >= parts.count else { continue }
            for start in 0...(words.count - parts.count) {
                let span = start..<(start + parts.count)
                guard !span.contains(where: { settled.contains($0) }) else { continue }
                let slips = zip(words[span].map { $0.lowercased() }, parts).filter { $0 != $1 }
                guard slips.allSatisfy({ isTypo($0, of: $1) && isSlip($0, of: $1) }) else { continue }
                settled.formUnion(span)
                guard !slips.isEmpty else { continue }
                for (index, known) in zip(span, parts) {
                    words[index] = written(like: words[index], isFirst: index == 0, known)
                }
                changed = true
            }
        }
        for index in words.indices where !settled.contains(index) {
            if let fix = fix(for: words[index], isFirst: index == 0, history: history) {
                words[index] = fix
                changed = true
            }
        }
        return changed ? words.joined(separator: " ") : nil
    }

    /// Not a longer or shorter form of the known word ("watsons" of
    /// "watson", "indomar" of "indomaret"): a form is a word in its own
    /// right, and a prefix is a name still being typed.
    private static func isSlip(_ typed: String, of known: String) -> Bool {
        !typed.contains(known) && !known.hasPrefix(typed)
    }

    /// The word `word` was aiming at. The user's own spellings first, as
    /// they wrote them: a word they have written at least twice, and three
    /// times as often as this one. Then the merchants DiPo knows, unless the
    /// user has written this word three times or more: by then it is theirs.
    private static func fix(for word: String, isFirst: Bool, history: [String: Known]) -> String? {
        guard word.count >= 6, word.allSatisfy(\.isLetter) else { return nil }
        let lower = word.lowercased()
        let own = history[lower]?.count ?? 0
        let mine = history.filter {
            $0.value.count >= max(2, own * 3) && isTypo(lower, of: $0.key) && isSlip(lower, of: $0.key)
        }
        if let best = mine.min(by: { a, b in
            let (da, db) = (distance(lower, a.key, limit: 2), distance(lower, b.key, limit: 2))
            return (da, -a.value.count, a.key) < (db, -b.value.count, b.key)
        }) {
            return best.value.spelling
        }
        guard own < 3 else { return nil }
        let best = merchantWords
            .filter { isTypo(lower, of: $0) && isSlip(lower, of: $0) }
            .min { (distance(lower, $0, limit: 2), $0) < (distance(lower, $1, limit: 2), $1) }
        return best.map { written(like: word, isFirst: isFirst, $0) }
    }

    /// A known merchant word in the case the user was typing: CAPS stay
    /// caps, a capital or a name's first word gets one, the rest stay lower.
    private static func written(like word: String, isFirst: Bool, _ known: String) -> String {
        if word.contains(where: \.isLetter), word == word.uppercased() { return known.uppercased() }
        if isFirst || word.first?.isUppercase == true {
            return known.prefix(1).uppercased() + known.dropFirst()
        }
        return known
    }
}

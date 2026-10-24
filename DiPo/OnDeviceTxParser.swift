import Foundation
import FoundationModels

// MARK: - Reading an entry with Apple Intelligence, on the phone
//
// Ask DiPo tries three readers in turn. LocalTxParser's rules are instant and
// free, but give up on anything loosely written. The server reads anything,
// but costs a credit and needs signal. On a phone with Apple Intelligence on
// (iPhone 15 Pro and later, in a language Apple supports), Apple's own
// on-device model sits between the two: free, offline, and the words never
// leave the phone. Everywhere else this is skipped and nothing changes.
//
// It is a small model, so it is trusted with as little as possible. It splits
// the message and names the parts; every amount it returns must be a number
// written in the message (`LocalTxParser.amounts`), each used once, or the
// whole reading is dropped and the message goes on to the server as before.
// Like the rules, it fails closed: a missed entry costs a credit, a wrong one
// records the wrong number. And what it reads still lands on the same
// "check, then add" cards as the rules' — nothing is recorded unseen.
enum OnDeviceTxParser {

    /// Apple Intelligence is on, the model is downloaded, and it reads the
    /// phone's language. (iOS 26 and later, like everything here that
    /// touches the model; the rules below it build for any iOS.)
    @available(iOS 26.0, *)
    static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale()
    }

    /// Past this it is a pasted statement or a question, not an entry, and
    /// more than the model's small context should be asked to hold.
    static let maxLength = 400

    private static let instructions = """
        You turn a short note about money into ledger entries. The note may mix English and Indonesian.
        Make one entry for each purchase, payment or money received. Make no entries when the note asks a question or names no amount.
        amount: the number written for that entry, as a plain number. 25rb, 25k and 25 ribu are 25000. 1,5jt and 1.5 juta are 1500000. Never add numbers up or work out a number that is not written.
        name: a short name for what it was, without the amount, such as Kopi, Parkir or Gaji.
        isExpense: false only when money came in, such as salary, a refund or a gift.
        """

    /// Nil when this phone can't run the model, the text is no entry, or the
    /// reading doesn't hold up — the caller then carries on to the server.
    @available(iOS 26.0, *)
    static func parse(_ text: String) async -> LocalTxParser.Result? {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !note.isEmpty, note.count <= maxLength, !isQuestion(note),
              !LocalTxParser.amounts(in: note).isEmpty else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            // Greedy: the same note reads the same way every time.
            let response = try await session.respond(
                to: note, generating: OnDeviceTxDraft.self,
                options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 400))
            return vetted(response.content.items.map(candidate), text: note)
        } catch {
            // Guardrails, a language the model doesn't read, a full context:
            // all of them mean "let the server have it".
            return nil
        }
    }

    /// Openers of a "what if" rather than an entry: "kalau beli HP 3jt cukup
    /// nggak", "should I pay 2jt now". With an amount in them they look like
    /// entries, and the model can't be relied on to tell; the server answers
    /// them, which is what was asked.
    private static let askingOpeners = ["kalau ", "jika ", "seandainya ", "andai ", "apa ", "bisa ",
                                        "boleh ", "cukup ", "mending ", "sebaiknya ", "if ", "should ",
                                        "can i ", "could i ", "is it ", "will "]

    /// A question rather than an entry, so not this reader's to take.
    static func isQuestion(_ text: String) -> Bool {
        let s = text.lowercased()
        return s.contains("?") || LocalTxParser.looksLikeQuestion(s)
            || askingOpeners.contains { s.hasPrefix($0) }
    }

    /// One entry as the model read it, before any of it is trusted.
    struct Candidate {
        var name: String
        var amount: Double
        var isExpense: Bool
        var category: TxCategory
    }

    /// The reading, kept only when every amount in it is one written in
    /// `text` (each written amount used once) and every entry has a name.
    /// One bad entry drops the lot, as in LocalTxParser: half a list is
    /// worse than none, because the missing half goes unnoticed.
    static func vetted(_ candidates: [Candidate], text: String) -> LocalTxParser.Result? {
        guard !candidates.isEmpty, candidates.count <= 6 else { return nil }
        var written = LocalTxParser.amounts(in: text)
        var items: [LocalTxParser.ParsedItem] = []
        for c in candidates {
            guard c.amount.isFinite,
                  let i = written.firstIndex(where: { abs($0 - c.amount) < 0.5 }) else { return nil }
            written.remove(at: i)
            let name = c.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard name.contains(where: \.isLetter), name.count <= 40 else { return nil }
            // Money in can't sit in an expense category, nor the other way
            // round; the direction wins and the category falls back.
            let category = c.isExpense != c.category.isIncomeCategory ? c.category
                         : (c.isExpense ? .other : .incomeOther)
            items.append(LocalTxParser.ParsedItem(name: name, amount: c.amount,
                                                  isExpense: c.isExpense, category: category))
        }
        return LocalTxParser.Result(items: items)
    }

    @available(iOS 26.0, *)
    private static func candidate(_ entry: OnDeviceTxEntry) -> Candidate {
        Candidate(name: entry.name, amount: entry.amount, isExpense: entry.isExpense,
                  category: category(of: entry.category))
    }

    @available(iOS 26.0, *)
    static func category(of kind: OnDeviceTxKind) -> TxCategory {
        switch kind {
        case .food:         return .food
        case .transport:    return .transport
        case .shopping:     return .shopping
        case .bills:        return .bills
        case .health:       return .health
        case .travel:       return .travel
        case .rentOrFamily: return .commitment
        case .other:        return .other
        case .salary:       return .salary
        case .freelance:    return .freelance
        case .business:     return .business
        case .bonus:        return .bonus
        case .gift:         return .gift
        case .otherIncome:  return .incomeOther
        }
    }
}

// MARK: - What the model is asked to fill in
//
// `nonisolated`: the model fills these in off the main actor, and the app's
// default isolation would otherwise tie them to it.

@available(iOS 26.0, *)
@Generable
nonisolated struct OnDeviceTxDraft {
    @Guide(description: "One entry per purchase, payment or money received in the note")
    var items: [OnDeviceTxEntry]
}

@available(iOS 26.0, *)
@Generable
nonisolated struct OnDeviceTxEntry {
    @Guide(description: "A short name for what it was, without the amount")
    var name: String
    @Guide(description: "The amount written for this entry, as a plain number")
    var amount: Double
    @Guide(description: "False only when money came in")
    var isExpense: Bool
    var category: OnDeviceTxKind
}

@available(iOS 26.0, *)
@Generable
nonisolated enum OnDeviceTxKind: CaseIterable {
    case food, transport, shopping, bills, health, travel, rentOrFamily, other
    case salary, freelance, business, bonus, gift, otherIncome
}

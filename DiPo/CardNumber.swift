import Foundation
import SwiftData

// MARK: - What a card number is allowed to be
//
// DiPo never needs the middle of a card number. It shows the last two or four
// digits, and it reads the first six to work out the bank. The six digits in
// between were kept for one reason only — so the number could be read back in
// full — and holding them cost more than that was worth: they sat in plain text
// in the store AND in every exported backup, which is a file made to leave the
// phone.
//
// So they are not kept. Not encrypted, not hidden: absent. A backup that is
// copied into a chat cannot leak what the app never wrote down.
//
// The app's own header claimed these were "encrypted at rest using AES-GCM".
// They never were — the migration that would have done it discarded its own
// output and was never called from anywhere.

enum CardNumber {

    /// How many digits are kept at each end.
    static let keptLeading = 6   // the BIN: which bank issued the card
    static let keptTrailing = 4  // what the user recognises the card by

    /// The character standing in for a digit that is not stored.
    static let maskCharacter: Character = "•"

    /// The form that may be written to the store.
    ///
    /// `4234 5678 1234 7890` becomes `423456••••••7890` — same length, same
    /// grouping when formatted, and every part the app actually uses survives:
    /// `suffix(2)`, `suffix(4)`, and the six-digit BIN behind issuer detection,
    /// which filters to digits first and so reads straight past the mask.
    ///
    /// Anything already masked passes through unchanged, so this is safe to run
    /// again on data it has already seen.
    static func stored(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        // Nothing to drop — a partial number, or not a number at all. A digital
        // wallet keeps its provider name in this same field ("gopay"), and
        // reducing that to its digits would erase the card's identity.
        guard digits.count > keptLeading + keptTrailing else { return raw }
        let head = digits.prefix(keptLeading)
        let tail = digits.suffix(keptTrailing)
        let hidden = String(repeating: String(maskCharacter),
                            count: digits.count - keptLeading - keptTrailing)
        return head + hidden + tail
    }

    /// True when a stored value still holds digits it should not.
    static func holdsMiddleDigits(_ value: String) -> Bool {
        value.filter(\.isNumber).count > keptLeading + keptTrailing
    }

    /// Drops the middle digits from every card already in the store.
    ///
    /// Runs on every launch and does nothing once there is nothing left to trim,
    /// which is what makes it safe to leave in: a card written by an older build
    /// of the app — or restored from an old backup by a build that predates this
    /// — is cleaned the next time DiPo opens.
    @MainActor
    @discardableResult
    static func trimStoredCards(context: ModelContext) -> Int {
        guard let cards = try? context.fetch(FetchDescriptor<BankCard>()) else { return 0 }
        var trimmed = 0
        for card in cards where holdsMiddleDigits(card.cardNumber) {
            card.cardNumber = stored(card.cardNumber)
            trimmed += 1
        }
        if trimmed > 0 { try? context.save() }
        return trimmed
    }
}

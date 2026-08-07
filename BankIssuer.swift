import SwiftUI

// MARK: - Bank Issuer Palette
//
// Colours a card by its ISSUING BANK, not just the network (Visa/Mastercard).
// The user picks the bank in the card form; when the typed BIN is a confident
// match we pre-select it for them. Anything not chosen and not confidently
// detected falls back to a DETERMINISTIC neutral colour derived from the BIN,
// so the same card always looks the same without guessing a wrong bank.

struct BankGradient: Equatable {
    let start: String
    let end: String
    var accent: String? = nil
}

struct BankIssuer: Identifiable, Equatable {
    let id: String          // stable key, persisted on the card
    let name: String
    let gradient: BankGradient
    /// Confident 6-digit BIN prefixes only. Kept deliberately small — a WRONG
    /// mapping (BRI card showing BCA colours) is worse than no match, so we seed
    /// only verified prefixes and let the manual picker cover everything else.
    let bins: [String]

    // MARK: Catalogue
    // Colours from each bank's brand identity (confirmed with the user).
    static let all: [BankIssuer] = [
        .init(id: "mandiri",  name: "Mandiri",         gradient: .init(start: "#113C86", end: "#0A2A63", accent: "#F5B301"), bins: ["552810"]),
        .init(id: "bri",      name: "BRI",             gradient: .init(start: "#00A0E3", end: "#005AA5"), bins: ["522184"]),
        .init(id: "bni",      name: "BNI",             gradient: .init(start: "#F5820E", end: "#00747C"), bins: []),
        .init(id: "bca",      name: "BCA",             gradient: .init(start: "#0067B1", end: "#004A87"), bins: []),
        .init(id: "bsi",      name: "BSI",             gradient: .init(start: "#00A99D", end: "#F2B705"), bins: []),
        .init(id: "btn",      name: "BTN",             gradient: .init(start: "#0E3E9A", end: "#E11B2E"), bins: []),
        .init(id: "cimb",     name: "CIMB Niaga",      gradient: .init(start: "#E01722", end: "#8E0B12"), bins: []),
        .init(id: "danamon",  name: "Danamon",         gradient: .init(start: "#F36F21", end: "#C43D00"), bins: []),
        .init(id: "permata",  name: "Permata",         gradient: .init(start: "#E4002B", end: "#9E001E"), bins: []),
        .init(id: "maybank",  name: "Maybank",         gradient: .init(start: "#FFC61E", end: "#1A1A1A"), bins: []),
        .init(id: "ocbc",     name: "OCBC",            gradient: .init(start: "#E30613", end: "#A00000"), bins: []),
        .init(id: "mega",     name: "Bank Mega",       gradient: .init(start: "#F58220", end: "#0A2C6B"), bins: []),
        .init(id: "jenius",   name: "Jenius / BTPN",   gradient: .init(start: "#00AEEF", end: "#0072BC"), bins: []),
        .init(id: "jago",     name: "Bank Jago",       gradient: .init(start: "#FF7A00", end: "#FFC300"), bins: []),
        .init(id: "seabank",  name: "SeaBank",         gradient: .init(start: "#16265C", end: "#2F4DA6", accent: "#FF5C00"), bins: []),
        .init(id: "allo",     name: "Allo Bank",       gradient: .init(start: "#7A2FF6", end: "#4318A8"), bins: []),
        .init(id: "linebank", name: "Line Bank",       gradient: .init(start: "#06C755", end: "#04A144"), bins: []),
        .init(id: "blu",      name: "blu (BCA)",       gradient: .init(start: "#00C4DE", end: "#0092C6"), bins: []),
        .init(id: "dki",      name: "Bank DKI",        gradient: .init(start: "#0057A8", end: "#F58220"), bins: []),
        .init(id: "bjb",      name: "bank bjb",        gradient: .init(start: "#0067B2", end: "#003D73"), bins: []),
        .init(id: "jatim",    name: "Bank Jatim",      gradient: .init(start: "#C8102E", end: "#7A0A1C"), bins: []),
        .init(id: "neo",      name: "Neo Commerce",    gradient: .init(start: "#FFD200", end: "#E5A500"), bins: []),
    ]

    static func find(_ id: String?) -> BankIssuer? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Confident BIN → issuer, longest-prefix wins. `nil` when no confident match.
    static func detect(from cardNumber: String) -> BankIssuer? {
        let digits = cardNumber.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        var best: BankIssuer?; var bestLen = 0
        for issuer in all {
            for bin in issuer.bins where digits.hasPrefix(bin) && bin.count > bestLen {
                bestLen = bin.count; best = issuer
            }
        }
        return best
    }

    // MARK: Deterministic fallback
    // Muted, professional gradients. An unknown issuer always maps to the same
    // one (keyed on its BIN) so a given card is visually stable.
    static let neutralPalette: [BankGradient] = [
        .init(start: "#2A3330", end: "#1A2028"),
        .init(start: "#3B3355", end: "#241E3A"),
        .init(start: "#14403A", end: "#0A2622"),
        .init(start: "#3A2E22", end: "#221A12"),
        .init(start: "#253A4D", end: "#14232E"),
        .init(start: "#402630", end: "#241419"),
        .init(start: "#2E3A22", end: "#1A2213"),
        .init(start: "#34303C", end: "#1F1C24"),
    ]

    /// Stable across launches (Swift's `hashValue` is randomised, so we can't
    /// use it — the colour would change every run).
    private static func stableHash(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return abs(h)
    }

    static func fallbackGradient(for cardNumber: String) -> BankGradient {
        let bin = String(cardNumber.filter(\.isNumber).prefix(6))
        guard !bin.isEmpty else { return neutralPalette[0] }
        return neutralPalette[stableHash(bin) % neutralPalette.count]
    }

    /// Resolve the gradient to render for a card, in priority order:
    /// explicit issuer pick → confident BIN detection → deterministic fallback.
    static func resolveGradient(issuerID: String?, cardNumber: String) -> BankGradient {
        if let picked = find(issuerID) { return picked.gradient }
        if let key = issuerID, key.hasPrefix("neutral-"),
           let i = Int(key.dropFirst("neutral-".count)), neutralPalette.indices.contains(i) {
            return neutralPalette[i]
        }
        if let detected = detect(from: cardNumber) { return detected.gradient }
        return fallbackGradient(for: cardNumber)
    }
}

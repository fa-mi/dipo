import Foundation

// MARK: - DiPo Quest: what is asked
//
// A Duolingo-style path of short money lessons, written for people who shop
// at the market, keep a small business and save in small amounts. Six units,
// four levels each (the fourth a review), five questions a level — about two
// minutes a play.
//
// The arithmetic questions (which pack is cheaper, the change, a loan's
// interest, a sale's profit) are generated from a seed, so a level is new
// every time it is played and the numbers can grow with the level. The
// judgement questions (need or want, scam or safe, true or false) come from
// fixed banks with an explanation for each answer. Everything is on the
// device: no network, no AI credits.

struct QuestQuestion: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case cheaper, change, total, needWant, saving, days, interest, loan, scam, profit, price, fact
    }

    /// Unique within one play of a level.
    let id: String
    let kind: Kind
    let prompt: String
    let options: [String]
    let answer: Int
    /// Shown under the verdict, right or wrong: the working, or the reason.
    let explain: String

    var title: String { loc("quest.kind.\(kind.rawValue)") }
}

struct QuestLevel: Hashable, Identifiable {
    /// 1-based.
    let unit: Int
    /// 1...levelsPerUnit; the last one is the unit's review.
    let index: Int

    var id: String { "u\(unit)l\(index)" }
    var isReview: Bool { index == QuestCatalog.levelsPerUnit }
}

struct QuestUnit: Identifiable {
    let id: Int
    /// The unit's question kinds, its main one first.
    let kinds: [QuestQuestion.Kind]

    var title: String { loc("quest.unit.\(id).title") }
    var subtitle: String { loc("quest.unit.\(id).sub") }
    var levels: [QuestLevel] { (1...QuestCatalog.levelsPerUnit).map { QuestLevel(unit: id, index: $0) } }
}

enum QuestCatalog {
    static let levelsPerUnit = 4
    static let questionsPerLevel = 5

    static let units: [QuestUnit] = [
        QuestUnit(id: 1, kinds: [.cheaper, .change, .total, .fact]),
        QuestUnit(id: 2, kinds: [.needWant, .total, .cheaper, .fact]),
        QuestUnit(id: 3, kinds: [.saving, .days, .needWant, .fact]),
        QuestUnit(id: 4, kinds: [.interest, .loan, .fact, .saving]),
        QuestUnit(id: 5, kinds: [.scam, .fact, .loan, .scam]),
        QuestUnit(id: 6, kinds: [.profit, .price, .change, .fact]),
    ]

    static var allLevels: [QuestLevel] { units.flatMap(\.levels) }

    /// The questions for one play of a level. The same seed gives the same
    /// questions, which is what the tests lean on.
    static func questions(for level: QuestLevel, seed: UInt64) -> [QuestQuestion] {
        guard let unit = units.first(where: { $0.id == level.unit }) else { return [] }
        let k = unit.kinds
        // Early levels lean on the unit's main kinds; the review takes all four.
        let plan: [QuestQuestion.Kind]
        switch level.index {
        case 1:  plan = [k[0], k[1], k[0], k[1], k[0]]
        case 2:  plan = [k[1], k[0], k[2], k[0], k[1]]
        case 3:  plan = [k[2], k[0], k[3], k[1], k[2]]
        default: plan = [k[0], k[1], k[2], k[3], k[0]]
        }
        var gen = QuestGenerator(rng: SplitMix(seed: seed &+ UInt64(level.unit * 100 + level.index)),
                                 difficulty: level.index, unit: unit.id)
        return plan.enumerated().map { i, kind in gen.make(kind, n: i) }
    }
}

// MARK: - Question generator

struct QuestGenerator {
    var rng: SplitMix
    /// 1...4: the level's place in its unit. Higher means closer numbers.
    let difficulty: Int
    let unit: Int
    /// Bank items already asked in this play, so none repeats.
    private var used: Set<String> = []

    init(rng: SplitMix, difficulty: Int, unit: Int) {
        self.rng = rng
        self.difficulty = max(1, min(4, difficulty))
        self.unit = unit
    }

    mutating func make(_ kind: QuestQuestion.Kind, n: Int) -> QuestQuestion {
        switch kind {
        case .cheaper:  return cheaper(n)
        case .change:   return change(n)
        case .total:    return total(n)
        case .needWant: return needWant(n)
        case .saving:   return saving(n)
        case .days:     return days(n)
        case .interest: return interest(n)
        case .loan:     return loan(n)
        case .scam:     return scam(n)
        case .profit:   return profit(n)
        case .price:    return price(n)
        case .fact:     return fact(n)
        }
    }

    // MARK: Helpers

    /// Static, so it can be handed to `amounts` without touching `self`.
    private static func rp(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: "IDR") }

    private mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(rng.next() % UInt64(range.count))
    }

    private mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }

    private mutating func shuffled<T>(_ items: [T]) -> [T] {
        var a = items
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, int(0...i)) }
        return a
    }

    /// The answer among up to three distinct, positive wrong values, shuffled.
    private mutating func amounts(_ answer: Double, wrong: [Double],
                                  label: (Double) -> String) -> (options: [String], answer: Int) {
        var values = [answer]
        for w in wrong where w > 0 && !values.contains(where: { abs($0 - w) < 0.5 }) && values.count < 4 {
            values.append(w)
        }
        let order = shuffled(values)
        return (order.map(label), order.firstIndex(where: { abs($0 - answer) < 0.5 }) ?? 0)
    }

    private static func round(_ v: Double, to step: Double) -> Double { (v / step).rounded() * step }

    private mutating func fromBank(_ prefix: String, count: Int, among allowed: [Int]? = nil) -> Int {
        let pool = (allowed ?? Array(0..<count)).filter { !used.contains("\(prefix)\($0)") }
        let i = pick(pool.isEmpty ? (allowed ?? Array(0..<count)) : pool)
        used.insert("\(prefix)\(i)")
        return i
    }

    // MARK: Shopping

    static let packItems: [(key: String, unit: String, base: Double)] = [
        ("rice", "kg", 14_000), ("oil", "L", 17_000), ("sugar", "kg", 17_000),
        ("flour", "kg", 12_000), ("eggs", "kg", 28_000),
    ]

    /// Three packs of one staple; one is cheapest per kilo or litre, and it is
    /// not always the biggest.
    private mutating func cheaper(_ n: Int) -> QuestQuestion {
        let item = pick(Self.packItems)
        let sizes = pick([[1, 2, 5], [2, 5, 10], [1, 3, 5]])
        let gaps: [Double] = difficulty <= 1 ? [0, 0.12, 0.24] : difficulty == 2 ? [0, 0.08, 0.16] : [0, 0.05, 0.1]
        let base = item.base * (0.9 + rng.next01() * 0.2)
        var prices: [Double] = []
        var perUnit: [Double] = []
        for _ in 0..<12 {
            let g = shuffled(gaps)
            prices = sizes.indices.map { Self.round(Double(sizes[$0]) * base * (1 + g[$0]), to: 500) }
            perUnit = sizes.indices.map { prices[$0] / Double(sizes[$0]) }
            let sorted = perUnit.sorted()
            if sorted[0] < sorted[1] * 0.99 { break }
        }
        let best = perUnit.indices.min { perUnit[$0] < perUnit[$1] } ?? 0
        let label = { (i: Int) in "\(sizes[i]) \(item.unit)" }
        let options = sizes.indices.map { String(format: loc("quest.cheaper.option"), label($0), Self.rp(prices[$0])) }
        return QuestQuestion(
            id: "cheaper-\(n)", kind: .cheaper,
            prompt: String(format: loc("quest.cheaper.prompt"), loc("quest.item.\(item.key)"), item.unit),
            options: options, answer: best,
            explain: String(format: loc("quest.cheaper.explain"), label(best), Self.rp(perUnit[best].rounded()), item.unit))
    }

    private mutating func change(_ n: Int) -> QuestQuestion {
        let price = Double(difficulty <= 2 ? int(2...19) * 500 : int(5...95) * 500)
        let notes: [Double] = [5_000, 10_000, 20_000, 50_000, 100_000]
        let bigger = notes.filter { $0 > price }
        let note = difficulty >= 4 && bigger.count > 1 ? bigger[int(0...1)] : (bigger.first ?? 100_000)
        let answer = note - price
        let (options, index) = amounts(answer, wrong: [answer + 1_000, answer - 1_000, answer + 500,
                                                       answer - 500, answer + 5_000], label: Self.rp)
        return QuestQuestion(
            id: "change-\(n)", kind: .change,
            prompt: String(format: loc("quest.change.prompt"), Self.rp(price), Self.rp(note)),
            options: options, answer: index,
            explain: String(format: loc("quest.change.explain"), Self.rp(note), Self.rp(price), Self.rp(answer)))
    }

    static let basket: [(key: String, base: Double)] = [
        ("rice", 14_000), ("eggs", 22_000), ("oil", 17_000), ("soap", 4_500),
        ("noodles", 15_500), ("coffee", 12_000), ("sugar", 17_000),
    ]

    private mutating func total(_ n: Int) -> QuestQuestion {
        let items = Array(shuffled(Self.basket).prefix(3))
        let prices = items.map { Self.round($0.base + Double(int(-2...2)) * 500, to: 500) }
        let sum = prices.reduce(0, +)
        let (options, index) = amounts(sum, wrong: [sum + 1_000, sum - 1_000, sum + 500, sum - 2_000], label: Self.rp)
        return QuestQuestion(
            id: "total-\(n)", kind: .total,
            prompt: String(format: loc("quest.total.prompt"),
                           loc("quest.basket.\(items[0].key)"), Self.rp(prices[0]),
                           loc("quest.basket.\(items[1].key)"), Self.rp(prices[1]),
                           loc("quest.basket.\(items[2].key)"), Self.rp(prices[2])),
            options: options, answer: index,
            explain: String(format: loc("quest.total.explain"), Self.rp(prices[0]), Self.rp(prices[1]), Self.rp(prices[2]), Self.rp(sum)))
    }

    /// true = a need.
    static let needWantBank: [Bool] = [true, true, false, false, true, true, false, true, false, true, false, true]

    private mutating func needWant(_ n: Int) -> QuestQuestion {
        let i = fromBank("nw", count: Self.needWantBank.count)
        let isNeed = Self.needWantBank[i]
        return QuestQuestion(
            id: "needWant-\(n)", kind: .needWant,
            prompt: String(format: loc("quest.nw.prompt"), loc("quest.nw.\(i)")),
            options: [loc("quest.opt.need"), loc("quest.opt.want")], answer: isNeed ? 0 : 1,
            explain: loc(isNeed ? "quest.nw.why_need" : "quest.nw.why_want"))
    }

    // MARK: Saving

    private mutating func saving(_ n: Int) -> QuestQuestion {
        let income = Double(difficulty <= 2 ? int(2...6) * 500_000 : int(4...20) * 250_000)
        let pct = difficulty <= 1 ? pick([10, 20]) : difficulty <= 3 ? pick([10, 15, 20, 25]) : pick([5, 15, 25, 30])
        let answer = income * Double(pct) / 100
        let (options, index) = amounts(answer, wrong: [income * Double(pct + 5) / 100, income * Double(pct - 5) / 100,
                                                       answer / 10, answer + 50_000], label: Self.rp)
        return QuestQuestion(
            id: "saving-\(n)", kind: .saving,
            prompt: String(format: loc("quest.saving.prompt"), Self.rp(income), pct),
            options: options, answer: index,
            explain: String(format: loc("quest.saving.explain"), Self.rp(income), pct, Self.rp(answer)))
    }

    static let goals: [(key: String, prices: [Double])] = [
        ("shoes", [150_000, 200_000, 250_000]), ("uniform", [150_000, 300_000]),
        ("bicycle", [600_000, 900_000, 1_200_000]), ("goat", [1_500_000, 2_000_000, 2_500_000]),
        ("phone", [1_200_000, 1_500_000, 2_000_000]),
    ]

    private mutating func days(_ n: Int) -> QuestQuestion {
        var goal = pick(Self.goals)
        var target = pick(goal.prices)
        var perDay = 10_000.0
        for _ in 0..<12 {
            let fits = [5_000.0, 10_000, 20_000, 25_000, 50_000].filter {
                target.truncatingRemainder(dividingBy: $0) == 0 && (5...120).contains(Int(target / $0))
            }
            if let p = fits.isEmpty ? nil : pick(fits) { perDay = p; break }
            goal = pick(Self.goals); target = pick(goal.prices)
        }
        let answer = Int(target / perDay)
        let wrong = [answer + 5, answer - 5, answer * 2, answer / 2, answer + 10].map(Double.init)
        let (options, index) = amounts(Double(answer), wrong: wrong) { String(format: loc("quest.days.option"), Int($0)) }
        return QuestQuestion(
            id: "days-\(n)", kind: .days,
            prompt: String(format: loc("quest.days.prompt"), loc("quest.goal.\(goal.key)"), Self.rp(target), Self.rp(perDay)),
            options: options, answer: index,
            explain: String(format: loc("quest.days.explain"), Self.rp(target), Self.rp(perDay), answer))
    }

    // MARK: Debt

    private mutating func interest(_ n: Int) -> QuestQuestion {
        let principal = Double(difficulty <= 2 ? int(2...10) * 500_000 : int(4...20) * 500_000)
        let rate = pick([1, 2, 3, 4])
        let months = pick([3, 6, 10, 12])
        let monthly = principal * Double(rate) / 100
        let answer = monthly * Double(months)
        let (options, index) = amounts(answer, wrong: [monthly, answer + monthly, answer * 2, answer - monthly], label: Self.rp)
        return QuestQuestion(
            id: "interest-\(n)", kind: .interest,
            prompt: String(format: loc("quest.interest.prompt"), Self.rp(principal), rate, months),
            options: options, answer: index,
            explain: String(format: loc("quest.interest.explain"), Self.rp(principal), rate, months, Self.rp(answer),
                            Self.rp(principal + answer)))
    }

    /// A monthly rate against a fixed total to repay: compare the totals.
    private mutating func loan(_ n: Int) -> QuestQuestion {
        let principal = Double(int(2...10) * 500_000)
        let rate = pick([2, 3, 4])
        let months = pick([6, 10, 12])
        let byRate = principal * (1 + Double(rate * months) / 100)
        let gap = difficulty <= 2 ? 0.15 : 0.07
        let fixed = Self.round(byRate * (rng.next01() < 0.5 ? 1 - gap : 1 + gap), to: 50_000)
        let rateCheaper = byRate < fixed
        return QuestQuestion(
            id: "loan-\(n)", kind: .loan,
            prompt: String(format: loc("quest.loan.prompt"), Self.rp(principal)),
            options: [String(format: loc("quest.loan.a"), rate, months),
                      String(format: loc("quest.loan.b"), Self.rp(fixed), months)],
            answer: rateCheaper ? 0 : 1,
            explain: String(format: loc("quest.loan.explain"), Self.rp(byRate), Self.rp(fixed)))
    }

    // MARK: Scams

    /// true = a scam.
    static let scamBank: [Bool] = [true, true, true, true, true, true, false, false, false, false]

    private mutating func scam(_ n: Int) -> QuestQuestion {
        let i = fromBank("scam", count: Self.scamBank.count)
        return QuestQuestion(
            id: "scam-\(n)", kind: .scam,
            prompt: String(format: loc("quest.scam.prompt"), loc("quest.scam.\(i)")),
            options: [loc("quest.opt.scam"), loc("quest.opt.safe")], answer: Self.scamBank[i] ? 0 : 1,
            explain: loc("quest.scam.\(i).why"))
    }

    // MARK: Business

    static let products = ["fritters", "icedTea", "cake", "porridge"]

    private mutating func profit(_ n: Int) -> QuestQuestion {
        let product = pick(Self.products)
        let count = pick(difficulty <= 2 ? [10, 20, 30] : [25, 40, 50, 100])
        let sell = Double(pick([1_000, 1_500, 2_000, 2_500, 3_000, 5_000]))
        let cost = max(250, Self.round(sell * (0.4 + rng.next01() * 0.3), to: 250))
        let answer = Double(count) * (sell - cost)
        let revenue = Double(count) * sell
        let (options, index) = amounts(answer, wrong: [revenue, Double(count) * cost, sell - cost,
                                                       answer + Double(count) * 250], label: Self.rp)
        return QuestQuestion(
            id: "profit-\(n)", kind: .profit,
            prompt: String(format: loc("quest.profit.prompt"), count, loc("quest.product.\(product)"), Self.rp(sell), Self.rp(cost)),
            options: options, answer: index,
            explain: String(format: loc("quest.profit.explain"), Self.rp(sell), Self.rp(cost), count, Self.rp(answer), Self.rp(revenue)))
    }

    private mutating func price(_ n: Int) -> QuestQuestion {
        let product = pick(Self.products)
        let cost = Double(int(2...20) * 500)
        let margin = pick([20, 25, 30, 50])
        let markup = cost * Double(margin) / 100
        let answer = cost + markup
        let (options, index) = amounts(answer, wrong: [markup, answer + 500, cost + Double(margin) * 100,
                                                       cost * 2], label: Self.rp)
        return QuestQuestion(
            id: "price-\(n)", kind: .price,
            prompt: String(format: loc("quest.price.prompt"), loc("quest.product.\(product)"), Self.rp(cost), margin),
            options: options, answer: index,
            explain: String(format: loc("quest.price.explain"), Self.rp(cost), margin, Self.rp(markup), Self.rp(answer)))
    }

    // MARK: True or false

    /// (true?, unit) — each statement belongs to one unit's topic.
    static let factBank: [(isTrue: Bool, unit: Int)] = [
        (false, 1), (true, 1), (false, 1),
        (true, 2), (true, 2), (false, 2),
        (true, 3), (true, 3), (false, 3),
        (false, 4), (true, 4), (false, 4),
        (true, 5), (false, 5), (true, 5),
        (true, 6), (false, 6), (true, 6),
    ]

    private mutating func fact(_ n: Int) -> QuestQuestion {
        let ofUnit = Self.factBank.indices.filter { Self.factBank[$0].unit == unit }
        let i = fromBank("fact", count: Self.factBank.count, among: ofUnit.isEmpty ? nil : ofUnit)
        return QuestQuestion(
            id: "fact-\(n)", kind: .fact,
            prompt: String(format: loc("quest.fact.prompt"), loc("quest.fact.\(i)")),
            options: [loc("quest.opt.true"), loc("quest.opt.false")], answer: Self.factBank[i].isTrue ? 0 : 1,
            explain: loc("quest.fact.\(i).why"))
    }
}

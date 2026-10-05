import Foundation

// MARK: - How much house or car is safe to take on
//
// The loan calculators answer "what does this loan cost"; this answers the
// question people actually bring to them — "how big a loan, and so how
// expensive a house or car, can I carry?" It works backwards from the user's
// own records:
//
//   1. Room for a new instalment. Two ceilings, the lower one wins:
//      • lenders' own check: every debt instalment together — existing debts,
//        credit-card instalments and the card's minimum payment, plus the new
//        one — at most 30% of income (the repayment-capacity rule Indonesian
//        banks and multifinance apply);
//      • DiPo's healthy line for the whole fixed load: those debts plus
//        rent, subscriptions and other fixed bills, at most 36% of income —
//        the same line the Fixed Monthly Payments card draws, so a loan sized
//        here lands exactly on "Healthy" there.
//   2. The biggest loan that instalment pays off at the rate and term typed in
//      (reducing balance for KPR, flat for a vehicle — as each is quoted).
//   3. Cash for the down payment: what is in the accounts and liquid holdings
//      beyond the emergency fund. Emptying the emergency fund for a down
//      payment trades one risk for a worse one.
//   4. Price = loan + down payment, capped so the down payment is at least
//      the usual minimum share (10% of a house, 20% of a vehicle).

enum LoanAffordability {
    /// All debt instalments together, as a share of income — lenders' ceiling.
    static let lenderCeiling = 0.30
    /// Minimum down payment banks and multifinance commonly ask for.
    static let houseMinDown = 0.10
    static let vehicleMinDown = 0.20

    enum Method { case annuity, flat }

    /// Which of the limits sets the price.
    enum Limit: Equatable {
        /// No room for a new instalment: fixed payments already use it.
        case noRoom
        /// Income limits it: more savings wouldn't raise the price.
        case instalment
        /// Savings limit it: the instalment could carry more, the down payment can't.
        case downPayment
    }

    struct Result: Equatable {
        var maxInstalment: Double
        var maxLoan: Double
        var downPaymentCash: Double
        var maxPrice: Double
        var limit: Limit
        /// Ceiling that binds the instalment, for saying which rule it was.
        var lenderRuleBinds: Bool
        /// How far fixed payments are over the line when there is no room.
        var overBy: Double
        /// Extra savings that would let the price reach what the instalment can carry.
        var downPaymentShortfall: Double
        /// The price the instalment alone could carry, with the minimum down payment.
        var priceIfSaved: Double
    }

    /// The largest principal a monthly payment repays over `years`.
    static func principal(forInstalment m: Double, annualRatePercent: Double, years: Double,
                          method: Method) -> Double {
        guard m > 0 else { return 0 }
        let n = max(years * 12, 1)
        switch method {
        case .annuity:
            let r = annualRatePercent / 100 / 12
            guard r > 0 else { return m * n }
            return m * (1 - pow(1 + r, -n)) / r
        case .flat:
            // monthly = P × (1 + rate × years) / n
            return m * n / (1 + annualRatePercent / 100 * years)
        }
    }

    /// - Parameters:
    ///   - income: monthly income the load card uses.
    ///   - debtPayments: existing debt instalments, card instalments and card minimums.
    ///   - fixedBills: rent, subscriptions and other fixed commitments.
    ///   - spareCash: cash and liquid holdings beyond the emergency fund.
    static func evaluate(income: Double, debtPayments: Double, fixedBills: Double,
                         spareCash: Double, annualRatePercent: Double, years: Double,
                         method: Method, minDownShare: Double) -> Result {
        let byLender = income * lenderCeiling - debtPayments
        let byLoad = income * ObligationLoad.healthyCeiling - debtPayments - fixedBills
        let room = min(byLender, byLoad)
        let cash = max(spareCash, 0)
        guard income > 0, room > 0 else {
            return Result(maxInstalment: 0, maxLoan: 0, downPaymentCash: cash, maxPrice: 0,
                          limit: .noRoom, lenderRuleBinds: byLender < byLoad,
                          overBy: max(-room, 0), downPaymentShortfall: 0, priceIfSaved: 0)
        }
        let loan = principal(forInstalment: room, annualRatePercent: annualRatePercent,
                             years: years, method: method)
        // Price P = loan + down payment, with the loan at most `loan`, the
        // down payment at most `cash` and at least minDownShare × P.
        let byIncome = loan / (1 - minDownShare)    // whole instalment used, minimum down payment
        let bySavings = minDownShare > 0 ? cash / minDownShare : .infinity
        let price = min(loan + cash, bySavings)
        let savingsBind = bySavings < byIncome
        return Result(maxInstalment: room,
                      maxLoan: price - cash,
                      downPaymentCash: cash,
                      maxPrice: price,
                      limit: savingsBind ? .downPayment : .instalment,
                      lenderRuleBinds: byLender < byLoad,
                      overBy: 0,
                      downPaymentShortfall: savingsBind ? byIncome * minDownShare - cash : 0,
                      priceIfSaved: byIncome)
    }
}

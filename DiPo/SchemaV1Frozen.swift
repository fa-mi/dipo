import Foundation
import SwiftData

// MARK: - Schema V1, frozen
//
// The stored shape of every @Model as it was when DiPoSchemaV2 was added —
// step 1 of "Changing a @Model" in SchemaVersions.swift. These copies exist
// only so SwiftData can recognise a V1 store and migrate it to V2; nothing
// else uses them. NEVER edit them: a V1 that stops matching what is on
// users' phones sends their ledger to StoreRecovery's quarantine.
//
// Stored properties only, with the same types, defaults, attributes and
// relationships as the live classes had. Computed properties, helpers and
// real initialisers are left out: no V1 object is ever created by hand.

extension DiPoSchemaV1 {

    @Model
    final class BankCard {
        var id: UUID
        var holderName: String
        var cardNumber: String
        var balance: Double
        var expireDate: String
        var gradientStart: String
        var gradientEnd: String
        var sortOrder: Int
        var currency: String
        var isDigitalWallet: Bool
        var walletProvider: String
        var phoneNumber: String
        var isHidden: Bool
        var issuerID: String = ""
        var isCreditCard: Bool = false
        var creditLimit: Double = 0
        var openingOwed: Double = 0
        var creditSince: Date? = nil
        @Relationship(deleteRule: .cascade)
        var transactions: [DiPoSchemaV1.TxRecord] = []

        init() {
            self.id = UUID()
            self.holderName = ""
            self.cardNumber = ""
            self.balance = 0
            self.expireDate = ""
            self.gradientStart = ""
            self.gradientEnd = ""
            self.sortOrder = 0
            self.currency = ""
            self.isDigitalWallet = false
            self.walletProvider = ""
            self.phoneNumber = ""
            self.isHidden = false
        }
    }

    @Model
    final class TxRecord {
        var id: UUID
        var name: String
        var date: Date
        var amount: Double
        var type: String
        var icon: String
        var iconBgHex: String
        var categoryRaw: String
        var currency: String
        var notes: String
        var linkedDebtID: String = ""
        var linkedGoalID: String = ""
        var linkedReceivableID: String = ""
        var subtype: String = "normal"
        var oneOffOverride: Bool? = nil
        var fxOriginalAmount: Double = 0
        var fxOriginalCurrency: String = ""
        var fxRate: Double = 0

        init() {
            self.id = UUID()
            self.name = ""
            self.date = Date(timeIntervalSince1970: 0)
            self.amount = 0
            self.type = ""
            self.icon = ""
            self.iconBgHex = ""
            self.categoryRaw = ""
            self.currency = ""
            self.notes = ""
        }
    }

    @Model
    final class SalarySchedule {
        var id: UUID
        var label: String
        var amount: Double
        var dayOfMonth: Int
        var currency: String
        var isActive: Bool
        var cardID: UUID?
        var createdAt: Date
        var lastCreditedMonth: Int
        var lastCreditedYear: Int
        var isPinned: Bool
        var autoRecord: Bool = true

        init() {
            self.id = UUID()
            self.label = ""
            self.amount = 0
            self.dayOfMonth = 0
            self.currency = ""
            self.isActive = false
            self.cardID = nil
            self.createdAt = Date(timeIntervalSince1970: 0)
            self.lastCreditedMonth = 0
            self.lastCreditedYear = 0
            self.isPinned = false
        }
    }

    @Model
    final class DebtRecord {
        var id: UUID
        var name: String
        var type: String
        var totalAmount: Double
        var currentBalance: Double
        var minimumPayment: Double
        var annualInterestRate: Double
        var dueDayOfMonth: Int
        var currency: String
        var isActive: Bool
        var createdAt: Date
        var notes: String
        var hasBeenTracked: Bool = false
        var manuallyClosed: Bool = false

        init() {
            self.id = UUID()
            self.name = ""
            self.type = ""
            self.totalAmount = 0
            self.currentBalance = 0
            self.minimumPayment = 0
            self.annualInterestRate = 0
            self.dueDayOfMonth = 0
            self.currency = ""
            self.isActive = false
            self.createdAt = Date(timeIntervalSince1970: 0)
            self.notes = ""
        }
    }

    @Model
    final class SavingsGoal {
        var id: UUID
        var name: String
        var emoji: String
        var targetAmount: Double
        var savedAmount: Double
        var currency: String
        var targetDate: Date?
        var priority: Int
        var isCompleted: Bool
        var createdAt: Date
        var notes: String
        var monthlyContribution: Double
        var isPinned: Bool = false

        init() {
            self.id = UUID()
            self.name = ""
            self.emoji = ""
            self.targetAmount = 0
            self.savedAmount = 0
            self.currency = ""
            self.targetDate = nil
            self.priority = 0
            self.isCompleted = false
            self.createdAt = Date(timeIntervalSince1970: 0)
            self.notes = ""
            self.monthlyContribution = 0
        }
    }

    @Model
    final class RecurringExpense {
        var id: UUID
        var label: String
        var amount: Double
        var dayOfMonth: Int
        var currency: String
        var categoryRaw: String
        var isActive: Bool
        var cardID: UUID?
        var createdAt: Date
        var lastChargedMonth: Int
        var lastChargedYear: Int
        var autoRecord: Bool = true

        init() {
            self.id = UUID()
            self.label = ""
            self.amount = 0
            self.dayOfMonth = 0
            self.currency = ""
            self.categoryRaw = ""
            self.isActive = false
            self.cardID = nil
            self.createdAt = Date(timeIntervalSince1970: 0)
            self.lastChargedMonth = 0
            self.lastChargedYear = 0
        }
    }

    @Model
    final class Receivable {
        var id: UUID
        var personName: String
        var amount: Double
        var currency: String
        var lentAt: Date
        var dueDate: Date?
        var notes: String
        var isSettled: Bool
        var createdAt: Date

        init() {
            self.id = UUID()
            self.personName = ""
            self.amount = 0
            self.currency = ""
            self.lentAt = Date(timeIntervalSince1970: 0)
            self.dueDate = nil
            self.notes = ""
            self.isSettled = false
            self.createdAt = Date(timeIntervalSince1970: 0)
        }
    }

    @Model
    final class CardInstallment {
        var id: UUID
        var cardID: UUID
        var merchant: String
        var totalAmount: Double
        var tenorMonths: Int
        var startDate: Date
        var flatRatePercent: Double
        var currency: String
        var isActive: Bool
        var createdAt: Date

        init() {
            self.id = UUID()
            self.cardID = UUID()
            self.merchant = ""
            self.totalAmount = 0
            self.tenorMonths = 0
            self.startDate = Date(timeIntervalSince1970: 0)
            self.flatRatePercent = 0
            self.currency = ""
            self.isActive = false
            self.createdAt = Date(timeIntervalSince1970: 0)
        }
    }

    @Model
    final class CardBudgetConfig {
        @Attribute(.unique) var cardID: String
        var dailyRatio: Double
        var lifestyleRatio: Double
        var investDebtRatio: Double
        var updatedAt: Date

        init() {
            self.cardID = ""
            self.dailyRatio = 0
            self.lifestyleRatio = 0
            self.investDebtRatio = 0
            self.updatedAt = Date(timeIntervalSince1970: 0)
        }
    }

    @Model
    final class CycleIntent {
        var kindRaw: String
        var cycleKey: String
        var note: String
        var isRecurring: Bool
        var createdAt: Date

        init() {
            self.kindRaw = ""
            self.cycleKey = ""
            self.note = ""
            self.isRecurring = false
            self.createdAt = Date(timeIntervalSince1970: 0)
        }
    }

    @Model
    final class InvestmentHolding {
        var id: UUID
        var typeRaw: String
        var name: String
        var symbol: String
        var currency: String
        var createdAt: Date
        var lastPrice: Double
        var prevClose: Double
        var priceUpdatedAt: Date?
        var manualPrice: Bool
        var priceHistory: [Double] = []
        var sortOrder: Int
        @Relationship(deleteRule: .cascade)
        var lots: [DiPoSchemaV1.InvestmentLot] = []

        init() {
            self.id = UUID()
            self.typeRaw = ""
            self.name = ""
            self.symbol = ""
            self.currency = ""
            self.createdAt = Date(timeIntervalSince1970: 0)
            self.lastPrice = 0
            self.prevClose = 0
            self.priceUpdatedAt = nil
            self.manualPrice = false
            self.sortOrder = 0
        }
    }

    @Model
    final class InvestmentLot {
        var id: UUID
        var date: Date
        var kindRaw: String
        var units: Double
        var pricePerUnit: Double
        var fee: Double
        var cashAmount: Double
        var note: String
        var linkedCardTxID: String

        init() {
            self.id = UUID()
            self.date = Date(timeIntervalSince1970: 0)
            self.kindRaw = ""
            self.units = 0
            self.pricePerUnit = 0
            self.fee = 0
            self.cashAmount = 0
            self.note = ""
            self.linkedCardTxID = ""
        }
    }

    @Model
    final class DailyRollup {
        @Attribute(.unique) var dayKey: String
        var cardID: String
        var dayStart: Date
        var incomeByCurrency: [String: Double]
        var expenseByCurrency: [String: Double]
        var transferNetByCurrency: [String: Double]
        var expenseByCategory: [String: Double]
        var incomeByCategory: [String: Double]
        var grossExpenseByCategory: [String: Double] = [:]
        var grossInflowByCurrency: [String: Double] = [:]
        var txCount: Int
        var updatedAt: Date

        init() {
            self.dayKey = ""
            self.cardID = ""
            self.dayStart = Date(timeIntervalSince1970: 0)
            self.incomeByCurrency = [:]
            self.expenseByCurrency = [:]
            self.transferNetByCurrency = [:]
            self.expenseByCategory = [:]
            self.incomeByCategory = [:]
            self.txCount = 0
            self.updatedAt = Date(timeIntervalSince1970: 0)
        }
    }

    @Model
    final class DayCheckIn {
        var dayKey: String
        var answeredAt: Date

        init() {
            self.dayKey = ""
            self.answeredAt = Date(timeIntervalSince1970: 0)
        }
    }

    @Model
    final class PendingTransaction {
        var id: UUID
        var capturedAt: Date
        var sourceRaw: String
        var rawText: String
        var name: String
        var amount: Double
        var currency: String
        var date: Date
        var categoryRaw: String
        var cardID: UUID?

        init() {
            self.id = UUID()
            self.capturedAt = Date(timeIntervalSince1970: 0)
            self.sourceRaw = ""
            self.rawText = ""
            self.name = ""
            self.amount = 0
            self.currency = ""
            self.date = Date(timeIntervalSince1970: 0)
            self.categoryRaw = ""
            self.cardID = nil
        }
    }
}

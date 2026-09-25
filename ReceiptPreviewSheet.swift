// ReceiptPreviewSheet.swift
// Final step of the scan flow: the parsed receipt as an editable expense form,
// laid out like Add Transaction (amount, merchant, category tiles, card
// swiper, date, notes) under a strip with the photo and how clearly it read.
// One Save button; the transaction is created against the chosen card.

import SwiftUI
import SwiftData
import UIKit

struct ReceiptPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    /// Whole history — lets a scanned receipt benefit from the same learned
    /// merchant categories a typed transaction gets.
    @Query private var allTransactions: [TxRecord]

    /// The scan result. We mutate this locally as the user edits.
    @State var scan: ReceiptScanResult
    /// The original receipt photo, kept for visual reference.
    let receiptImage: UIImage
    /// Called when the user wants to retake the photo.
    let onRetake: () -> Void
    /// Called when a TxRecord has been successfully created and saved.
    let onSaved: () -> Void

    @Query private var installments: [CardInstallment]

    @State private var amountText: String = ""
    @State private var selectedCardIndex: Int = 0
    @State private var showImageZoom = false
    @State private var saveError: String? = nil

    private var availableCards: [BankCard] { cards }

    /// Does this card belong to the bank the receipt says paid?
    ///
    /// Matched against both the card's own issuer catalogue entry and the
    /// holder label the user typed, since a card added manually may carry the
    /// bank's name only in the latter. Substring in EITHER direction, because
    /// a slip may say "Bank BCA" where the catalogue says "BCA".
    private func cardMatchesIssuer(_ card: BankCard) -> Bool {
        let key = scan.issuer
            .lowercased()
            .replacingOccurrences(of: "bank", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard key.count >= 2 else { return false }

        var names: [String] = [card.holderName.lowercased()]
        if !card.issuerID.isEmpty, let issuer = BankIssuer.find(card.issuerID) {
            names.append(issuer.name.lowercased())
        }
        return names.contains { name in
            guard !name.isEmpty else { return false }
            return name.contains(key) || key.contains(name)
        }
    }

    private var selectedCard: BankCard? {
        guard !availableCards.isEmpty else { return nil }
        return availableCards[min(selectedCardIndex, availableCards.count - 1)]
    }

    private var canSave: Bool {
        // A positive amount is required: OCR failures used to land here as
        // silent Rp 0 saves. A 100%-promo receipt can still be entered by hand.
        scan.amount > 0
            && !scan.merchantName.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedCard != nil
    }

    private var lowConfidence: Bool { scan.confidence < 0.85 }

    // One form, always editable, laid out like Add Transaction — the same
    // amount field, the same category tiles, the same card swiper.
    //
    // It used to open read-only behind an "Edit" button that turned into
    // "Done" beside "Submit", so the screen offered two check-mark buttons
    // with different meanings; the category was a system menu whose label
    // wrapped over two lines; cards were a sideways strip of chips; and two
    // banners (a confidence note and a tip) said roughly the same thing.
    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        receiptStrip
                            .padding(.horizontal, 22)
                        amountSection
                        VStack(alignment: .leading, spacing: 10) {
                            IconField(label: loc("receipt.field.vendor"),
                                      icon: "storefront",
                                      placeholder: loc("receipt.field.merchant_placeholder"),
                                      text: $scan.merchantName)
                                // The scan guesses once, from what it read off
                                // the paper. When the user corrects the name,
                                // guess again the way Add Transaction does on
                                // every keystroke — otherwise a fixed "famimart"
                                // stays filed under whatever the misread got.
                                .onChange(of: scan.merchantName) { _, newName in
                                    if let suggested = CategorySuggestionHint.autoPick(
                                        for: newName, transactions: allTransactions,
                                        categories: expenseCategories) {
                                        // No animation — same reason as Add
                                        // Transaction: it tracks the typing.
                                        scan.category = suggested
                                    }
                                }
                            CategorySuggestionHint(name: scan.merchantName,
                                                   transactions: allTransactions,
                                                   categories: expenseCategories,
                                                   selection: $scan.category)
                        }
                        .padding(.horizontal, 22)
                        VStack(alignment: .leading, spacing: 10) {
                            FormSectionLabel(text: loc("common.category"))
                                .padding(.horizontal, 22)
                            CategoryTilePicker(categories: expenseCategories, selection: $scan.category)
                        }
                        cardSection
                        VStack(alignment: .leading, spacing: 10) {
                            FormSectionLabel(text: loc("tx.date_time"))
                            DateTimeFields(date: $scan.date)
                        }
                        .padding(.horizontal, 22)
                        IconField(label: loc("receipt.field.notes"),
                                  icon: "text.alignleft",
                                  placeholder: loc("receipt.field.notes_placeholder"),
                                  text: $scan.notes,
                                  optionalHint: loc("common.optional"))
                            .padding(.horizontal, 22)
                        if let err = saveError {
                            InlineBanner(tone: .error, message: err)
                                .padding(.horizontal, 22)
                        }
                        Spacer(minLength: 90)
                    }
                    .padding(.top, 8)
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationTitle(loc("receipt.preview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) {
                        HapticManager.shared.tap()
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear {
                amountText = formatAmountForEditing(scan.amount, currency: scan.currency)
                // Prefer the card that actually paid. The slip names the bank
                // that moved the money, so a BCA payment should not preselect
                // a BRI card just because it came first in the right currency.
                if let idx = availableCards.firstIndex(where: {
                    $0.resolvedCurrency == scan.currency && cardMatchesIssuer($0)
                }) {
                    selectedCardIndex = idx
                } else if let idx = availableCards.firstIndex(where: { $0.resolvedCurrency == scan.currency }) {
                    selectedCardIndex = idx
                }
                // The parser only knows the shipped keyword map. The user's own
                // history is the better answer, applied where it can still be
                // seen and changed before saving.
                if let learned = SmartBudgetManager.learnedCategory(
                    for: scan.merchantName, transactions: allTransactions) {
                    scan.category = learned.category
                }
            }
            .sheet(isPresented: $showImageZoom) {
                ZoomableImageView(image: receiptImage)
                    .presentationDetents([.large])
                    .presentationBackground(.black)
            }
        }
    }

    // MARK: - Sections

    /// The photo, how well it was read, and the two things you might do about
    /// it — look closer, or take it again — in one row instead of a tall
    /// banner, a confidence box and a tip.
    private var receiptStrip: some View {
        let tint = lowConfidence ? AppTheme.orange : AppTheme.accent
        return HStack(spacing: 14) {
            Button {
                HapticManager.shared.tap()
                showImageZoom = true
            } label: {
                Image(uiImage: receiptImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 70, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(5)
                    }
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel(loc("receipt.tap_to_zoom"))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: lowConfidence ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(loc(lowConfidence ? "receipt.check_fields" : "receipt.looks_clear"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    pill(icon: "magnifyingglass", text: loc("receipt.tap_to_zoom")) { showImageZoom = true }
                    pill(icon: "camera.fill", text: loc("receipt.retake")) { onRetake() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func pill(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap()
            action()
        } label: {
            Label(text, systemImage: icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(AppTheme.cardMid.opacity(0.8), in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    /// The same amount field as Add Transaction: currency on the left, the
    /// number large, and the formatted echo underneath.
    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormSectionLabel(text: loc("receipt.field.amount"))
            HStack(spacing: 12) {
                Menu {
                    ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                        Button {
                            HapticManager.shared.tap()
                            scan.currency = c.code
                        } label: {
                            Label("\(c.flag) \(c.code) — \(c.name)",
                                  systemImage: scan.currency == c.code ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(CurrencyManager.symbol(for: scan.currency))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(scan.currency)
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(.caption2)).imageScale(.small)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                }
                TextField("0", text: $amountText)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: amountText) { _, v in scan.amount = parseAmount(v) }
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            if let p = AmountInputHelper.preview(amountText, currency: scan.currency) {
                Text(p)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var cardSection: some View {
        if availableCards.isEmpty {
            InlineBanner(tone: .warning, message: loc("common.add_card_tx"))
                .padding(.horizontal, 22)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                FormSectionLabel(text: loc("receipt.field.card"))
                    .padding(.horizontal, 22)
                CardSwipePicker(cards: availableCards, selectedIndex: $selectedCardIndex) { card in
                    card.isCreditCard
                        ? (loc("cc.available"),
                           CurrencyManager.shared.formatted(card.availableCredit(installments),
                                                            currency: card.resolvedCurrency))
                        : (loc("home.balance_total"), card.formattedBalance)
                }
                // A foreign-currency receipt is stored in the card's currency;
                // say what it will become before it is saved, not after.
                if let card = selectedCard, scan.amount > 0, card.resolvedCurrency != scan.currency {
                    let converted = CurrencyManager.shared.convert(scan.amount, from: scan.currency,
                                                                   to: card.resolvedCurrency)
                    InlineBanner(tone: .info,
                                 message: String(format: loc("receipt.converted_note"),
                                                 CurrencyManager.shared.formatted(converted,
                                                                                  currency: card.resolvedCurrency)))
                        .padding(.horizontal, 22)
                }
            }
        }
    }

    private var saveBar: some View {
        Button {
            save()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(.body))
                Text(loc("receipt.preview.submit")).font(.system(.callout, weight: .bold))
            }
            .foregroundStyle(canSave ? AppTheme.onVividFill : AppTheme.textSecondary)
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .background(canSave ? AppTheme.accentFill : AppTheme.textSecondary.opacity(0.25),
                        in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!canSave)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(AppTheme.bg)
    }

    // MARK: - Helpers

    private var expenseCategories: [TxCategory] {
        [.shopping, .food, .travel, .bills, .transport, .health, .commitment, .debtPayment, .other]
    }

    private func formatAmountForEditing(_ amount: Double, currency: String) -> String {
        let noDecimals = ["IDR", "JPY", "KRW", "VND"]
        if noDecimals.contains(currency.uppercased()) {
            return String(Int(amount))
        }
        return String(format: "%.2f", amount)
    }

    private func parseAmount(_ text: String) -> Double {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        let lastDot = cleaned.lastIndex(of: ".")
        let lastComma = cleaned.lastIndex(of: ",")
        var normalized = cleaned
        if let dot = lastDot, let comma = lastComma {
            if comma > dot {
                normalized = cleaned.replacingOccurrences(of: ".", with: "")
                normalized = normalized.replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if cleaned.contains(",") && !cleaned.contains(".") {
            let parts = cleaned.split(separator: ",")
            if parts.count == 2, parts[1].count == 3 {
                normalized = cleaned.replacingOccurrences(of: ",", with: "")
            } else {
                normalized = cleaned.replacingOccurrences(of: ",", with: ".")
            }
        }
        return Double(normalized) ?? 0
    }

    // MARK: - Save

    private func save() {
        guard let card = selectedCard else { return }
        // Match canSave's > 0 rule. Defense-in-depth in case some upstream
        // path bypasses the disabled-button affordance.
        guard scan.amount > 0 else {
            saveError = loc("receipt.error.amount_required")
            return
        }

        let storedCurrency: String
        let storedAmount: Double
        if scan.currency != card.resolvedCurrency {
            storedCurrency = card.resolvedCurrency
            storedAmount = CurrencyManager.shared.convert(
                scan.amount, from: scan.currency, to: card.resolvedCurrency
            )
        } else {
            storedCurrency = scan.currency
            storedAmount = scan.amount
        }

        let iconText = String(scan.merchantName.prefix(2).uppercased())
        let tx = TxRecord(
            name: scan.merchantName,
            date: scan.date,
            amount: -abs(storedAmount),
            type: "tx.type.purchase",
            icon: iconText,
            iconBgHex: scan.category.iconBg,
            category: scan.category,
            currency: storedCurrency,
            notes: scan.notes
        )
        card.transactions.append(tx)

        do {
            try context.save()
            HapticManager.shared.success()
            // Confirm the result, exactly like a typed transaction does —
            // a scanned receipt used to save with no on-screen confirmation.
            ActionFeedbackCenter.shared.transactionSaved(
                amount: tx.amount, currency: storedCurrency,
                category: scan.category, cardLabel: card.pickerLabel)
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
            HapticManager.shared.error()
        }
    }
}

// MARK: - Zoomable Image

private struct ZoomableImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, min(4, lastScale * value))
                            }
                            .onEnded { _ in lastScale = scale }
                    )
            }
            Button {
                HapticManager.shared.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(.title))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
.accessibilityLabel(loc("a11y.close"))
            .padding()
        }
    }
}

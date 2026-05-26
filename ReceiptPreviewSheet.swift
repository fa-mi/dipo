// ReceiptPreviewSheet.swift
// Final step of the scan flow: a "Receipt Info" card showing the parsed
// fields with edit-in-place rows + Edit / Submit actions at the bottom.
//
// Design:
//   - Receipt photo banner at the top (tap to zoom for verification).
//   - Compact label/value rows with thin dividers — easy to scan.
//   - "Edit" toggles the rows into editable mode (TextField/Picker/DatePicker).
//   - "Submit" creates the TxRecord against the chosen card and dismisses.
//   - A tip banner reminds users they can edit before submitting.
//
// Why two modes (read-only vs. edit) instead of always-editable? It mirrors
// the mock and reduces visual noise on first review — most users only want
// to confirm the result rather than change anything.

import SwiftUI
import SwiftData
import UIKit

struct ReceiptPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    /// The scan result. We mutate this locally as the user edits.
    @State var scan: ReceiptScanResult
    /// The original receipt photo, kept for visual reference.
    let receiptImage: UIImage
    /// Called when the user wants to retake the photo.
    let onRetake: () -> Void
    /// Called when a TxRecord has been successfully created and saved.
    let onSaved: () -> Void

    @State private var amountText: String = ""
    @State private var selectedCardIndex: Int = 0
    @State private var showImageZoom = false
    @State private var saveError: String? = nil
    @State private var isEditing: Bool = false

    private var availableCards: [BankCard] { cards }

    private var selectedCard: BankCard? {
        guard !availableCards.isEmpty else { return nil }
        return availableCards[min(selectedCardIndex, availableCards.count - 1)]
    }

    private var canSave: Bool {
        // Require a positive amount. Previously we allowed `>= 0` to support
        // 100%-promo receipts (Rp 0 totals are technically legit), but in
        // practice OCR failures landed here as silent Rp 0 saves and users
        // ended up with zero-value transactions they didn't notice. The
        // reliability gain outweighs the rare 100%-promo edge case — those
        // can still be entered manually from Add Transaction.
        scan.amount > 0 && !scan.merchantName.isEmpty && selectedCard != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        receiptThumbnail
                        infoCard
                        if let err = saveError {
                            errorBanner(err)
                        }
                        tipBanner
                        actionButtons
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(loc("receipt.preview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        HapticManager.shared.tap()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.textPrimary)
                    }
                }
            }
            .onAppear {
                amountText = formatAmountForEditing(scan.amount, currency: scan.currency)
                if let idx = availableCards.firstIndex(where: { $0.resolvedCurrency == scan.currency }) {
                    selectedCardIndex = idx
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

    private var receiptThumbnail: some View {
        Button {
            HapticManager.shared.tap()
            showImageZoom = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: receiptImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                    Text(loc("receipt.tap_to_zoom")).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(10)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            // Vendor
            row(label: loc("receipt.field.vendor")) {
                if isEditing {
                    TextField(loc("receipt.field.merchant_placeholder"), text: $scan.merchantName)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                } else {
                    Text(scan.merchantName.isEmpty ? "—" : scan.merchantName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                }
            }
            divider
            // Category
            row(label: loc("receipt.field.category")) {
                if isEditing {
                    Picker("", selection: $scan.category) {
                        ForEach(expenseCategories, id: \.self) { cat in
                            Text(cat.displayLabel).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AppTheme.textPrimary)
                    .labelsHidden()
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: scan.category.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(scan.category.color)
                        Text(scan.category.displayLabel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                }
            }
            divider
            // Amount (with currency symbol embedded in label like the mock)
            row(label: String(format: loc("receipt.field.amount_with_symbol"),
                              CurrencyManager.symbol(for: scan.currency))) {
                if isEditing {
                    HStack(spacing: 8) {
                        Picker("", selection: $scan.currency) {
                            ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                                Text("\(c.flag) \(c.code)").tag(c.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(AppTheme.textSecondary)
                        .labelsHidden()
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(maxWidth: 110)
                            .onChange(of: amountText) { _, v in scan.amount = parseAmount(v) }
                    }
                } else {
                    Text(CurrencyManager.shared.formatted(scan.amount, currency: scan.currency))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }
            divider
            // Purchase date
            row(label: loc("receipt.field.purchase_date")) {
                if isEditing {
                    DatePicker("", selection: $scan.date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .tint(AppTheme.accent)
                } else {
                    Text(formatDate(scan.date))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }
            // Card selector — only when multiple cards exist
            if availableCards.count > 1 {
                divider
                row(label: loc("receipt.field.card")) {
                    Picker("", selection: $selectedCardIndex) {
                        ForEach(availableCards.indices, id: \.self) { i in
                            Text(cardLabel(availableCards[i])).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AppTheme.textPrimary)
                    .labelsHidden()
                }
            }
            divider
            // Notes
            row(label: loc("receipt.field.notes")) {
                if isEditing {
                    TextField(loc("tx.notes_placeholder"), text: $scan.notes, axis: .vertical)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1...3)
                } else {
                    Text(scan.notes.isEmpty ? "N/A" : scan.notes)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(scan.notes.isEmpty ? AppTheme.textSecondary : AppTheme.textPrimary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cardMid.opacity(0.4), lineWidth: 1)
        )
    }

    private var tipBanner: some View {
        HStack(spacing: 10) {
            Text("💡")
                .font(.system(size: 13))
            Text(loc("receipt.preview.tip"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                HapticManager.shared.tap()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isEditing.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 13, weight: .semibold))
                    Text(isEditing ? loc("common.done") : loc("receipt.preview.edit"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppTheme.cardMid, lineWidth: 1)
                )
            }
            .buttonStyle(ScaleButtonStyle())

            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                    Text(loc("receipt.preview.submit"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSave ? AppTheme.accent : AppTheme.textSecondary.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: canSave ? AppTheme.accent.opacity(0.35) : .clear, radius: 12, y: 6)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!canSave)
        }
        .padding(.top, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.red)
                .font(.system(size: 14))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.red)
            Spacer()
        }
        .padding(12)
        .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Row helpers

    private func row<Content: View>(label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.cardMid.opacity(0.5))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }

    // MARK: - Helpers

    private var expenseCategories: [TxCategory] {
        [.shopping, .food, .travel, .bills, .transport, .health, .other]
    }

    private func cardLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty { return card.walletProvider }
        let last4 = card.cardNumber.filter { $0.isNumber }.suffix(4)
        return "\(card.holderName) ••\(last4)"
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        f.locale = LanguageManager.shared.currentLocale
        return f.string(from: date)
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
                    .font(.system(size: 28))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding()
        }
    }
}

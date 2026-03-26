// ReceiptPreviewSheet.swift
// Shown after a scan completes. Lets the user verify or correct the parsed
// fields before they're saved as a TxRecord.
//
// Design principles:
//   - Show the receipt image alongside the editable fields so the user can
//     compare visually without flipping screens.
//   - Color the confidence badge so users know whether to trust the result.
//   - All fields are editable — never trust the scanner blindly.
//   - "Save" is the primary action; "Retake" lets them try again with a better photo.

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
    @State private var appeared = false

    private var availableCards: [BankCard] { cards }

    private var selectedCard: BankCard? {
        guard !availableCards.isEmpty else { return nil }
        return availableCards[min(selectedCardIndex, availableCards.count - 1)]
    }

    /// True when the form is in a saveable state.
    private var canSave: Bool {
        scan.amount > 0 && !scan.merchantName.isEmpty && selectedCard != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    confidenceBanner
                    receiptThumbnail
                    formFields
                    if let err = saveError {
                        errorBanner(err)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle(loc("receipt.preview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(loc("common.save")) { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSave ? AppTheme.accent : AppTheme.textSecondary.opacity(0.4))
                        .disabled(!canSave)
                }
            }
            .onAppear {
                amountText = formatAmountForEditing(scan.amount, currency: scan.currency)
                // Pre-select a card whose currency matches the scanned currency.
                if let idx = availableCards.firstIndex(where: { $0.resolvedCurrency == scan.currency }) {
                    selectedCardIndex = idx
                }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
            }
            .sheet(isPresented: $showImageZoom) {
                ZoomableImageView(image: receiptImage)
                    .presentationDetents([.large])
                    .presentationBackground(.black)
            }
        }
    }

    // MARK: - Sections

    private var confidenceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: scan.mode == .haikuAI ? "sparkles" : "checkmark.seal.fill")
                .foregroundStyle(Color(hex: scan.confidenceColorHex))
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.confidenceLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(scan.mode == .haikuAI ? loc("receipt.processed_by_ai") : loc("receipt.processed_locally"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(hex: scan.confidenceColorHex).opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: scan.confidenceColorHex).opacity(0.25), lineWidth: 1)
        )
    }

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
                    .frame(height: 160)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                // Subtle "tap to zoom" hint
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

    private var formFields: some View {
        VStack(spacing: 14) {
            // Merchant
            fieldRow(label: loc("receipt.field.merchant"), icon: "storefront.fill") {
                TextField(loc("receipt.field.merchant_placeholder"), text: $scan.merchantName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .autocorrectionDisabled()
            }

            // Amount
            fieldRow(label: loc("receipt.field.amount"), icon: "banknote.fill") {
                HStack(spacing: 8) {
                    Text(CurrencyManager.symbol(for: scan.currency))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .onChange(of: amountText) { _, newValue in
                            scan.amount = parseAmount(newValue)
                        }
                }
            }

            // Currency selector
            fieldRow(label: loc("receipt.field.currency"), icon: "dollarsign.circle.fill") {
                Picker("", selection: $scan.currency) {
                    ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                        Text("\(c.flag) \(c.code)").tag(c.code)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.textPrimary)
            }

            // Date
            fieldRow(label: loc("receipt.field.date"), icon: "calendar") {
                DatePicker("", selection: $scan.date, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .tint(AppTheme.accent)
            }

            // Category
            fieldRow(label: loc("receipt.field.category"), icon: scan.category.icon) {
                Picker("", selection: $scan.category) {
                    // Only expense categories make sense for a receipt.
                    ForEach(expenseCategories, id: \.self) { cat in
                        Label(cat.displayLabel, systemImage: cat.icon).tag(cat)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.textPrimary)
            }

            // Card
            if availableCards.count > 1 {
                fieldRow(label: loc("receipt.field.card"), icon: "creditcard.fill") {
                    Picker("", selection: $selectedCardIndex) {
                        ForEach(availableCards.indices, id: \.self) { i in
                            Text(cardLabel(availableCards[i])).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AppTheme.textPrimary)
                }
            }

            // Notes
            if !scan.notes.isEmpty {
                fieldRow(label: loc("receipt.field.notes"), icon: "note.text") {
                    TextField("", text: $scan.notes, axis: .vertical)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2...4)
                }
            }

            // Retake button — secondary action, less prominent than Save in toolbar
            Button {
                HapticManager.shared.tap()
                onRetake()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.rotate.fill").font(.system(size: 13))
                    Text(loc("receipt.retake")).font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.top, 4)
        }
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

    // MARK: - Helpers

    /// A single field row with icon + label + custom content. Keeps the form
    /// visually consistent without duplicating layout code per field.
    private func fieldRow<Content: View>(label: String, icon: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.accent.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                content()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
    }

    private var expenseCategories: [TxCategory] {
        [.shopping, .food, .travel, .bills, .transport, .health, .other]
    }

    private func cardLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty { return card.walletProvider }
        let last4 = card.cardNumber.filter { $0.isNumber }.suffix(4)
        return "\(card.holderName) ••\(last4)"
    }

    /// Format an amount for the editor. IDR uses no decimals; USD uses two.
    private func formatAmountForEditing(_ amount: Double, currency: String) -> String {
        let noDecimals = ["IDR", "JPY", "KRW", "VND"]
        if noDecimals.contains(currency.uppercased()) {
            return String(Int(amount))
        }
        return String(format: "%.2f", amount)
    }

    /// Parse the user-edited amount string back to Double. Accepts both
    /// Indonesian (1.234.567,89) and US (1,234.56) formats.
    private func parseAmount(_ text: String) -> Double {
        // Reuse the same logic as the parser to stay consistent.
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        // If it has both . and , — assume the LAST one is decimal.
        let lastDot = cleaned.lastIndex(of: ".")
        let lastComma = cleaned.lastIndex(of: ",")
        var normalized = cleaned
        if let dot = lastDot, let comma = lastComma {
            if comma > dot {
                // ID format: 1.234,56
                normalized = cleaned.replacingOccurrences(of: ".", with: "")
                normalized = normalized.replacingOccurrences(of: ",", with: ".")
            } else {
                // US format: 1,234.56
                normalized = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if cleaned.contains(",") && !cleaned.contains(".") {
            // Could be ID decimal "150,50" or US thousands "1,500"
            // Heuristic: if exactly 3 digits after comma, treat as US thousands;
            // otherwise as ID decimal.
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
        guard scan.amount > 0 else {
            saveError = loc("receipt.error.amount_required")
            return
        }

        // Convert to card's currency if user picked a different currency
        // (e.g., scanned receipt is in IDR but they picked the USD card).
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

        // Build the TxRecord. Amount is negative because this is an expense.
        let tx = TxRecord(
            name: scan.merchantName,
            date: scan.date,
            amount: -abs(storedAmount),
            type: "tx.type.purchase",
            icon: scan.category.icon,
            iconBgHex: scan.category.iconBg,
            category: scan.category,
            currency: storedCurrency,
            notes: scan.notes
        )
        card.transactions.append(tx)
        // Update card balance to reflect the new expense.
        card.balance -= storedAmount

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

/// Pinch-to-zoom view of the receipt photo. Lets the user verify hard-to-read
/// details without retaking the photo.
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
                            .onEnded { _ in
                                lastScale = scale
                            }
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

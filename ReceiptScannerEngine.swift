// ReceiptScannerEngine.swift
// Orchestrates the hybrid Vision + Claude Haiku scanning pipeline.
//
// Why hybrid? Apple Vision is free and offline, perfect for ~80% of receipts
// that are clean and well-printed. For the remaining ~20% (faded thermal,
// crumpled, weird angles, handwritten additions), we fall back to Claude
// Haiku 4.5 which costs ~Rp 50/scan but achieves 90-95% accuracy.
//
// Decision tree:
//   1. Always run Vision first (fast, free, private).
//   2. Parse the OCR text into ReceiptScanResult.
//   3. If confidence >= threshold → return immediately, no Haiku call.
//   4. If confidence < threshold AND online AND user is Royal → call Haiku.
//   5. If Haiku returns better result (higher confidence) → use it.
//   6. Otherwise return the Vision result with low-confidence warning.
//
// SECURITY NOTE: Claude API key MUST live on a backend, never in the iOS app.
// This file calls a backend endpoint that proxies to Anthropic. The backend
// is responsible for: API key storage, rate limiting per user, and ensuring
// the requesting user has Royal subscription.

import Foundation
import UIKit
// `@preconcurrency` silences Swift 6 Sendable diagnostics from Vision's
// VNImageRequestHandler / VNRecognizeTextRequest types. Vision predates
// strict concurrency and Apple hasn't annotated those types yet — until
// they do, we acknowledge the risk and move on rather than wrap every
// call site in unsafe boilerplate.
@preconcurrency import Vision

/// Public-facing scanner. Use `ReceiptScannerEngine.shared.scan(image:cardCurrency:)`.
@MainActor
@Observable
final class ReceiptScannerEngine {
    static let shared = ReceiptScannerEngine()
    private init() {}

    /// Currently in progress? UI uses this to show a spinner.
    var isScanning: Bool = false

    /// Last error, if any. UI clears on next scan.
    var lastError: ReceiptScanError? = nil

    // MARK: - Public API

    /// Scan a receipt image and return a parsed result.
    ///
    /// - Parameters:
    ///   - image: the photo of the receipt (will be downscaled if too large).
    ///   - cardCurrency: currency of the card the user will save the tx to.
    ///     Used as fallback when no currency markers are found in the receipt.
    ///   - useHaikuFallback: set to false to disable Haiku entirely (testing).
    /// - Returns: a parsed result. Caller should review with the user before saving.
    func scan(image: UIImage,
              cardCurrency: String,
              useHaikuFallback: Bool = true) async throws -> ReceiptScanResult {
        // Royal gate — receipt scan is a Royal feature. Non-paying users
        // sample it via the 7-day Royal trial (during which plan == royal).
        // Defense in depth; the UI also gates the scan entry point.
        guard PremiumManager.shared.canAccess(.scanReceipt) else {
            throw ReceiptScanError.premiumRequired
        }

        isScanning = true
        lastError = nil
        defer { isScanning = false }

        // Step 1: downscale to keep Vision fast and Haiku cheap.
        guard let prepared = downscale(image, maxDim: ReceiptScanConfig.maxImageDimension) else {
            throw ReceiptScanError.imageQualityTooLow
        }

        // Step 2: run Vision OCR (always — even if we'll fall back, it's nearly free).
        let rawText: String
        do {
            rawText = try await runVisionOCR(on: prepared)
        } catch {
            // Vision failed entirely — try Haiku as primary path if allowed.
            if useHaikuFallback && NetworkService.shared.isOnline {
                return try await scanWithHaiku(image: prepared, cardCurrency: cardCurrency)
            }
            throw ReceiptScanError.noTextDetected
        }

        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReceiptScanError.noTextDetected
        }

        // Step 3: parse Vision output.
        let visionResult = ReceiptParser.parse(rawText: rawText, fallbackCurrency: cardCurrency)

        // Step 4: decide whether to escalate to Haiku.
        // Only escalate on low confidence — amount=0 alone is NOT a trigger,
        // since some receipts legitimately have Rp 0 totals (100% promo discount,
        // points-redeemed coffee, etc.). If both amount=0 AND confidence is low,
        // confidence check below will catch it.
        let shouldEscalate = visionResult.confidence < ReceiptScanConfig.haikuFallbackThreshold
        if useHaikuFallback && shouldEscalate && NetworkService.shared.isOnline {
            do {
                let haikuResult = try await scanWithHaiku(image: prepared, cardCurrency: cardCurrency)
                // Use Haiku result only if it's actually better than Vision's.
                if haikuResult.confidence > visionResult.confidence {
                    return haikuResult
                }
            } catch {
                // Haiku failed — fall through to Vision result. Don't surface this
                // error to the user since Vision still gave us something usable.
                print("[Receipt] Haiku fallback failed: \(error.localizedDescription)")
            }
        }

        // Only fail with "no amount found" if both amount=0 AND we have no
        // merchant identified. A legitimate Rp 0 receipt will have a merchant
        // name and the user can confirm in the preview.
        if visionResult.amount <= 0 && visionResult.merchantName == loc("receipt.unknown_merchant") {
            throw ReceiptScanError.noAmountFound
        }

        return visionResult
    }

    // MARK: - Vision OCR

    /// Run Apple Vision text recognition on the given image.
    /// Returns a single string with newlines preserved between recognized lines.
    private func runVisionOCR(on image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw ReceiptScanError.imageQualityTooLow
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    cont.resume(throwing: ReceiptScanError.unknown(error.localizedDescription))
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: "")
                    return
                }
                // Sort observations top-to-bottom (Vision returns in confidence
                // order by default — that scrambles receipt structure).
                let sorted = observations.sorted { a, b in
                    // Y in Vision is bottom-up, so larger Y = higher on receipt.
                    a.boundingBox.maxY > b.boundingBox.maxY
                }
                let lines = sorted.compactMap { obs -> String? in
                    obs.topCandidates(1).first?.string
                }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            // Settings tuned for receipts (printed text, often uppercase).
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Indonesian + English. Order matters: first language is preferred.
            request.recognitionLanguages = ["id-ID", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            // Run on background queue — Vision is CPU-heavy and would block UI.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(throwing: ReceiptScanError.unknown(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Claude Haiku Fallback

    /// Send the image to Claude Haiku 4.5 via our backend proxy, ask for
    /// structured JSON, and return a ReceiptScanResult.
    ///
    /// The backend endpoint must:
    ///   - Verify the user's Royal subscription
    ///   - Hold the Anthropic API key (NEVER ship it in the iOS app)
    ///   - Rate-limit per user (suggest 50/day)
    ///   - Forward to Anthropic with the prompt below
    ///   - Return Anthropic's response unchanged
    private func scanWithHaiku(image: UIImage, cardCurrency: String) async throws -> ReceiptScanResult {
        guard let jpeg = image.jpegData(compressionQuality: ReceiptScanConfig.haikuJpegCompression) else {
            throw ReceiptScanError.imageQualityTooLow
        }
        let base64 = jpeg.base64EncodedString()

        // Backend endpoint — set this to your Cloudflare Worker / Vercel Function URL.
        // Returning a structured JSON body keeps client code simple.
        // ⚠️ Replace YOUR_BACKEND_URL with the real one before shipping.
        let endpointURL = "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/scan-receipt"

        struct ScanRequest: Encodable {
            let imageBase64: String
            let cardCurrency: String
            let userPlan: String
            // Required by the worker's per-user credit ledger — identifies
            // whose credit balance to check & decrement.
            let userId: String
        }
        struct ScanResponse: Decodable {
            let merchantName: String
            let amount: Double
            let currency: String
            let dateISO: String?       // "2026-04-28" — backend's job to parse
            let categoryHint: String?  // optional category suggestion
            let confidence: Double     // 0..1
            let notes: String?
            // Remaining monthly AI credits after this scan. Optional so old
            // worker responses (pre-credit-ledger) still decode.
            let creditsLeft: Int?
        }

        let payload = ScanRequest(
            imageBase64: base64,
            cardCurrency: cardCurrency,
            userPlan: PremiumManager.shared.plan.rawValue,
            userId: UserSession.shared.userID ?? ""
        )

        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(payload)
        } catch {
            throw ReceiptScanError.aiServiceUnavailable(underlying: "encode failed")
        }

        let endpoint = Endpoint(
            path: endpointURL,
            method: .post,
            headers: ["X-DiPo-Client": "iOS"],
            body: bodyData
        )

        do {
            let response: ScanResponse = try await NetworkService.shared.fetch(endpoint)
            // Parse date from backend (ISO 8601). Fallback to today if missing.
            let date: Date = {
                guard let iso = response.dateISO,
                      let parsed = ISO8601DateFormatter().date(from: iso) ?? {
                          let f = DateFormatter()
                          f.dateFormat = "yyyy-MM-dd"
                          f.locale = Locale(identifier: "en_US_POSIX")
                          return f.date(from: iso)
                      }() else {
                    return .now
                }
                return parsed
            }()

            // Resolve category from hint, falling back to merchant lookup.
            let category: TxCategory = {
                if let hint = response.categoryHint,
                   let cat = TxCategory(rawValue: hint) {
                    return cat
                }
                return SmartBudgetManager.suggestCategory(for: response.merchantName, txType: "Expense") ?? .other
            }()

            // Sanity-check Haiku's currency answer. The model occasionally
            // returns "USD" for a clearly-IDR receipt (e.g., it sees "Rp 49.000"
            // but reports currency "USD" with amount 107600). When the merchant
            // name matches a known Indonesian merchant OR the card currency is
            // IDR, override Haiku's currency to IDR. Better to be conservative
            // than display $107,600 for a receipt that's actually Rp 107,600.
            var resolvedCurrency = response.currency
            let resolvedAmount = response.amount
            let isKnownIndonesianMerchant = SmartBudgetManager
                .suggestCategory(for: response.merchantName, txType: "Expense") != nil
            if response.currency == "USD" &&
               (isKnownIndonesianMerchant || cardCurrency == "IDR") &&
               response.amount > 100 /* USD receipts above $100 from these merchants are unrealistic */ {
                print("[Receipt] Haiku currency suspicious: USD with amount \(response.amount) from \(response.merchantName). Overriding to IDR.")
                resolvedCurrency = "IDR"
                // amount is still in IDR (Haiku just labeled it wrong)
            }

            return ReceiptScanResult(
                merchantName: response.merchantName,
                amount: resolvedAmount,
                currency: resolvedCurrency,
                date: date,
                category: category,
                confidence: response.confidence,
                mode: .haikuAI,
                rawText: "[Processed by AI]",
                notes: response.notes ?? ""
            )
        } catch let netError as NetworkError {
            // HTTP 402 from the worker = user's monthly AI credits are
            // exhausted. Map it to a dedicated error so the UI can show a
            // "credits ran out" message instead of a generic failure.
            if case .httpError(let code) = netError, code == 402 {
                throw ReceiptScanError.outOfCredits
            }
            throw ReceiptScanError.aiServiceUnavailable(underlying: netError.localizedDescription)
        } catch {
            throw ReceiptScanError.aiServiceUnavailable(underlying: error.localizedDescription)
        }
    }

    // MARK: - Image Helpers

    /// Downscale an image so its longer side is at most `maxDim`. Preserves aspect
    /// ratio. Receipts don't need pixel-perfect detail; downscaling reduces both
    /// Vision processing time and Haiku token cost significantly.
    private func downscale(_ image: UIImage, maxDim: CGFloat) -> UIImage? {
        let size = image.size
        let longerSide = max(size.width, size.height)
        guard longerSide > maxDim else { return image }

        let scale = maxDim / longerSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // We want pixel dimensions, not point dimensions
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Backend Prompt Documentation
//
// The backend should send Anthropic this prompt (Claude Haiku 4.5) along
// with the receipt image. Documenting it here so iOS and backend stay in sync.
//
// SYSTEM:
//   You are an expert receipt OCR system specialized in Indonesian merchants
//   (Indomaret, Alfamart, Tokopedia, Shopee, Grab, Gojek, etc.) and US format.
//   Extract structured data and return ONLY a JSON object with no other text.
//
// USER (with image attached):
//   Extract from this receipt:
//   - merchantName: store name (Title Case)
//   - amount: final total paid as a number (no currency symbol)
//   - currency: ISO code (IDR for Rupiah, USD for Dollar, etc.)
//   - dateISO: transaction date in YYYY-MM-DD, or null if not visible
//   - categoryHint: one of [Shopping, Food & Drinks, Travel, Bills, Transport,
//     Health, Other], based on merchant type
//   - confidence: 0.0 to 1.0 — how sure are you?
//   - notes: brief item summary, max 60 chars, or null
//
//   The receipt may be in Bahasa Indonesia. Indonesian number format uses
//   "." as thousands separator and "," as decimal (e.g., "Rp 1.234.567,89").
//   Card's currency context: {cardCurrency}.
//
//   Respond ONLY with the JSON object. No prose, no code fences.

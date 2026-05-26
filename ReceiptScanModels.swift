// ReceiptScanModels.swift
// Shared types for the receipt scanning feature (Royal-tier).
//
// Architecture overview:
// 1. User taps FAB → camera/photo picker opens
// 2. Image captured → Vision OCR runs locally (free, offline)
// 3. ReceiptParser extracts merchant/amount/date from raw text
// 4. If confidence is low → fallback to Claude Haiku (small cost, internet)
// 5. ScanResult shown to user for review/edit before saving as TxRecord
//
// Privacy: receipt photos are processed in-memory and never persisted to disk.

import Foundation
import UIKit

// MARK: - Scan Mode

/// Which engine produced the result. Used for analytics and confidence display.
enum ScanMode: String {
    case vision    // On-device Apple Vision (free, offline)
    case haikuAI   // Claude Haiku 4.5 fallback (small cost, online)
    case manual    // User typed everything from scratch (no scan)
}

// MARK: - Scan Result

/// The parsed output of a receipt scan, ready to be edited and saved as TxRecord.
/// All fields are optional/best-effort except `rawText` so the user can correct
/// anything the parser misread. Confidence reflects parser certainty, not OCR.
struct ReceiptScanResult: Equatable {
    /// Merchant/store name extracted from the receipt header.
    var merchantName: String

    /// Total amount paid. Always positive; sign is applied when creating TxRecord.
    var amount: Double

    /// ISO currency code detected from receipt or inferred from card. "IDR", "USD", etc.
    var currency: String

    /// Transaction date. Falls back to today if no date could be parsed.
    var date: Date

    /// Best-guess category based on merchantName matching merchantMap.
    /// User can override in the preview sheet.
    var category: TxCategory

    /// 0.0–1.0 confidence that the parsed fields are correct.
    /// Used to color-code the preview sheet (green ≥0.85, yellow ≥0.6, red <0.6).
    var confidence: Double

    /// Which engine produced this result.
    var mode: ScanMode

    /// Full raw OCR text — kept for debugging and for the user to see if needed.
    /// NOT saved to TxRecord (would bloat storage with text user doesn't need).
    var rawText: String

    /// Optional notes auto-generated from line items (e.g., "Indomie, Aqua, Pulpen").
    /// Saved to TxRecord.notes when present.
    var notes: String

    /// Convenience: human-readable confidence label.
    var confidenceLabel: String {
        switch confidence {
        case 0.85...:    return loc("receipt.confidence.high")
        case 0.6..<0.85: return loc("receipt.confidence.medium")
        default:         return loc("receipt.confidence.low")
        }
    }

    /// Convenience: color tied to confidence band.
    var confidenceColorHex: String {
        switch confidence {
        case 0.85...:    return "#10B981"  // green
        case 0.6..<0.85: return "#F59E0B"  // amber
        default:         return "#EF4444"  // red
        }
    }
}

// MARK: - Scan Error

/// Specific failure modes so the UI can show actionable messages instead of
/// a generic "something went wrong". Each case maps to a user-facing string.
enum ReceiptScanError: Error, LocalizedError {
    /// Vision returned no text at all — image is blank, dark, or not a receipt.
    case noTextDetected
    /// Text was found but no plausible total amount could be parsed.
    /// User should retake the photo with the total visible.
    case noAmountFound
    /// User denied camera or photo library permission.
    case permissionDenied
    /// Image is too blurry, too small, or otherwise unprocessable.
    case imageQualityTooLow
    /// Network call to Claude Haiku failed (timeout, no internet, server error).
    /// Vision result may still be usable — UI decides whether to show partial data.
    case aiServiceUnavailable(underlying: String)
    /// Royal feature gate — user is not on Royal plan.
    case premiumRequired
    /// User has run out of monthly AI credits (worker returned HTTP 402).
    case outOfCredits
    /// Generic catch-all with a debug message.
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .noTextDetected:        return loc("receipt.error.no_text")
        case .noAmountFound:         return loc("receipt.error.no_amount")
        case .permissionDenied:      return loc("receipt.error.permission")
        case .imageQualityTooLow:    return loc("receipt.error.quality")
        case .aiServiceUnavailable:  return loc("receipt.error.ai_unavailable")
        case .premiumRequired:       return loc("receipt.error.premium")
        case .outOfCredits:          return loc("receipt.error.out_of_credits")
        case .unknown(let msg):      return msg
        }
    }

    /// Whether the user should be invited to retake the photo.
    var isRetryable: Bool {
        switch self {
        case .noTextDetected, .imageQualityTooLow, .aiServiceUnavailable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Scan Config

/// Tunable parameters for the scan pipeline. Centralized here so they're easy
/// to adjust without hunting through engine code.
struct ReceiptScanConfig {
    /// Below this confidence, the engine attempts the Haiku fallback.
    /// Tuned conservatively — most clean receipts will exceed this with Vision alone.
    static let haikuFallbackThreshold: Double = 0.65

    /// Maximum image dimension in pixels. Larger images are downscaled before OCR
    /// to keep Vision fast and Haiku token cost predictable.
    static let maxImageDimension: CGFloat = 2048

    /// JPEG compression for the version sent to Haiku. 0.7 is a good tradeoff
    /// between file size (token cost) and OCR-friendliness for thermal receipts.
    static let haikuJpegCompression: CGFloat = 0.7

    /// Vision OCR timeout. If it exceeds this, we proceed with what we have.
    static let visionTimeoutSeconds: TimeInterval = 8

    /// Total timeout for the entire scan flow (Vision + optional Haiku).
    /// Keep this under 30s — users get anxious past that.
    static let totalTimeoutSeconds: TimeInterval = 25
}

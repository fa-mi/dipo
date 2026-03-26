// ReceiptScanFlow.swift
// Orchestrates the full scan flow as a single sheet from the user's POV:
//
//   1. Source chooser (camera vs photo library) — confirmation dialog
//   2. Image picker presents — user takes photo or picks one
//   3. Loading view with progress messages while OCR runs
//   4. Preview sheet for review/edit
//   5. On save → dismiss everything and notify Home that a tx was added
//
// We use a state machine because nested sheets in SwiftUI are notoriously
// fragile — easier to model as one root view that shows different content
// based on phase.

import SwiftUI
import UIKit
import AVFoundation

enum ReceiptScanPhase: Equatable {
    case chooseSource           // Action sheet visible
    case capturing(ReceiptImageSource)  // ImagePicker visible
    case scanning(UIImage)      // Loading spinner + progress
    case reviewing(UIImage, ReceiptScanResult)  // Preview sheet
    case error(UIImage?, ReceiptScanError)
}

struct ReceiptScanFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phase: ReceiptScanPhase = .chooseSource
    @State private var showSourceDialog: Bool = true
    @State private var showPermissionAlert: Bool = false
    @State private var showSettingsAlert: Bool = false

    /// Default card currency for parser fallback. Caller (HomeView) passes
    /// the currently focused card's currency.
    let cardCurrency: String

    /// Called after a tx is successfully saved, so Home can refresh.
    let onCompleted: () -> Void

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            // Phase-specific content
            switch phase {
            case .chooseSource:
                placeholderHint
            case .capturing:
                placeholderHint
            case .scanning:
                ScanningView()
            case .reviewing:
                placeholderHint  // The preview is shown as a sheet over this
            case .error(_, let err):
                ErrorView(error: err) {
                    // Retry → back to source picker
                    phase = .chooseSource
                    showSourceDialog = true
                } onDismiss: {
                    dismiss()
                }
            }
        }
        // Source chooser
        .confirmationDialog(loc("receipt.source.title"),
                            isPresented: $showSourceDialog,
                            titleVisibility: .visible) {
            Button(loc("receipt.source.camera")) {
                Task { await pickSource(.camera) }
            }
            Button(loc("receipt.source.photo_library")) {
                Task { await pickSource(.photoLibrary) }
            }
            Button(loc("common.cancel"), role: .cancel) {
                dismiss()
            }
        } message: {
            Text(loc("receipt.source.message"))
        }
        // Camera / photo picker
        .fullScreenCover(isPresented: Binding(
            get: { if case .capturing = phase { return true } else { return false } },
            set: { if !$0 { /* canceled */ phase = .chooseSource; showSourceDialog = true } }
        )) {
            if case .capturing(let src) = phase {
                ReceiptImagePicker(
                    source: src,
                    onPicked: { image in
                        phase = .scanning(image)
                        Task { await runScan(image: image) }
                    },
                    onCancel: {
                        phase = .chooseSource
                        showSourceDialog = true
                    }
                )
                .ignoresSafeArea()
            }
        }
        // Preview sheet
        .sheet(isPresented: Binding(
            get: { if case .reviewing = phase { return true } else { return false } },
            set: { if !$0 { dismiss() } }
        )) {
            if case .reviewing(let img, let result) = phase {
                ReceiptPreviewSheet(
                    scan: result,
                    receiptImage: img,
                    onRetake: {
                        phase = .chooseSource
                        showSourceDialog = true
                    },
                    onSaved: {
                        onCompleted()
                        dismiss()
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
            }
        }
        // Permission denied alert
        .alert(loc("receipt.permission.denied_title"), isPresented: $showSettingsAlert) {
            Button(loc("receipt.permission.open_settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                dismiss()
            }
            Button(loc("common.cancel"), role: .cancel) { dismiss() }
        } message: {
            Text(loc("receipt.permission.denied_body"))
        }
    }

    // MARK: - Phases

    private var placeholderHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.accent.opacity(0.6))
            Text(loc("receipt.preparing"))
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Actions

    private func pickSource(_ source: ReceiptImageSource) async {
        // Camera needs explicit permission. Photo library auth is handled by
        // UIImagePickerController itself when it presents.
        if source == .camera {
            let granted = await CameraPermissionHelper.request()
            if !granted {
                showSettingsAlert = true
                return
            }
        }
        await MainActor.run {
            phase = .capturing(source)
        }
    }

    private func runScan(image: UIImage) async {
        do {
            let result = try await ReceiptScannerEngine.shared.scan(
                image: image, cardCurrency: cardCurrency
            )
            await MainActor.run {
                HapticManager.shared.success()
                phase = .reviewing(image, result)
            }
        } catch let err as ReceiptScanError {
            await MainActor.run {
                HapticManager.shared.error()
                phase = .error(image, err)
            }
        } catch {
            await MainActor.run {
                HapticManager.shared.error()
                phase = .error(image, .unknown(error.localizedDescription))
            }
        }
    }
}

// MARK: - Scanning View

/// Animated loading view shown while OCR runs. Cycles through messages so the
/// user sees that something is happening; otherwise a long Vision call (3-8s)
/// feels broken. Privacy-reassuring text matters here — users are sending a
/// photo and may worry where it goes.
private struct ScanningView: View {
    @State private var messageIndex = 0
    @State private var pulse = false

    private let messages: [String] = [
        loc("receipt.scanning.reading"),
        loc("receipt.scanning.detecting_merchant"),
        loc("receipt.scanning.extracting_amount"),
        loc("receipt.scanning.categorizing"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(AppTheme.accent.opacity(0.2), lineWidth: 4)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(pulse ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: pulse)
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 32))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 6) {
                Text(messages[messageIndex])
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .id(messageIndex)
                    .transition(.opacity)
                Text(loc("receipt.scanning.privacy_note"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
        .onAppear {
            pulse = true
            // Cycle through messages every 1.5s so the user has visual feedback
            // even on slow scans.
            Task {
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            messageIndex = (messageIndex + 1) % messages.count
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Error View

private struct ErrorView: View {
    let error: ReceiptScanError
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.orange)
            Text(loc("receipt.error.title"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(error.errorDescription ?? loc("receipt.error.generic"))
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            HStack(spacing: 12) {
                if error.isRetryable {
                    Button {
                        HapticManager.shared.tap()
                        onRetry()
                    } label: {
                        Text(loc("receipt.error.retry"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 11)
                            .background(AppTheme.accent, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                Button {
                    HapticManager.shared.tap()
                    onDismiss()
                } label: {
                    Text(loc("common.cancel"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(AppTheme.cardDark, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 22)
    }
}

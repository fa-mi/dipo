// ReceiptScanFlow.swift
// 3-screen receipt scanning experience that lives inside the Add Transaction
// flow (no longer a floating FAB on Home). Phases:
//
//   1. Landing  — illustration card + tip + "Start Scan" button. Lets the
//                 user pick between live camera and photo library.
//   2. Camera   — custom AVFoundation preview with green corner-bracket frame
//                 overlay, flash toggle, capture button, and live progress bar
//                 above the frame while OCR runs after capture.
//   3. Preview  — Receipt Info card with editable fields + Edit/Submit.
//
// Why a custom camera instead of UIImagePickerController? The design needs a
// branded scan UI (green brackets, in-frame progress bar, no system chrome)
// which UIImagePickerController doesn't permit customizing. The trade-off is
// extra code to manage AVCaptureSession lifecycle, but the UX matches the
// product vision exactly.
//
// State machine note: nested sheet/fullScreenCover transitions in SwiftUI are
// fragile. We keep the flow as a single root view that swaps content based on
// `phase`, and present only the preview as a sheet at the end. The custom
// camera lives inline (not as a sheet) so we avoid the nested-cover bug that
// previously caused the "Mempersiapkan…" stuck state.

import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import Combine

/// State machine for the scan flow.
enum ReceiptScanPhase {
    case landing                 // Hero card + Start Scan
    case picking                 // Photo library picker open
    case camera                  // Live camera with overlay
    case scanning(UIImage)       // OCR running, captured image visible
    case reviewing(UIImage, ReceiptScanResult)  // Editable preview sheet
    case error(UIImage?, ReceiptScanError)
}

struct ReceiptScanFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phase: ReceiptScanPhase = .landing
    @State private var scanProgress: Double = 0
    @State private var selectedTab: LandingTab = .scan
    @State private var showSettingsAlert: Bool = false
    /// Track the running OCR task so the user can cancel mid-scan from the
    /// progress view. Vision itself doesn't support cancellation, but we can
    /// drop the result and skip the transition into preview if the user bailed.
    @State private var scanTask: Task<Void, Never>? = nil

    /// Card currency to use as fallback for the parser.
    let cardCurrency: String

    /// Called after a tx is successfully saved.
    let onCompleted: () -> Void

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            switch phase {
            case .landing:
                LandingView(
                    selectedTab: $selectedTab,
                    onStart: startCapture,
                    onClose: { dismiss() }
                )
            case .picking:
                // Empty — photo picker is shown as a sheet below.
                Color.clear
            case .camera:
                ScanCameraView(
                    onCaptured: { image in
                        phase = .scanning(image)
                        runScan(image: image)
                    },
                    onCancel: {
                        phase = .landing
                    }
                )
                .ignoresSafeArea()
            case .scanning(let image):
                ScanningProgressView(
                    image: image,
                    progress: $scanProgress,
                    onCancel: cancelScan
                )
            case .reviewing:
                // Backdrop while preview sheet is up.
                ScanBackdrop()
            case .error(_, let err):
                ScanErrorView(
                    error: err,
                    onRetry: { phase = .landing },
                    onDismiss: { dismiss() }
                )
            }
        }
        // Photo library picker
        .sheet(isPresented: Binding(
            get: { if case .picking = phase { return true } else { return false } },
            set: { if !$0, case .picking = phase { phase = .landing } }
        )) {
            PhotoPickerView(
                onPicked: { image in
                    phase = .scanning(image)
                    runScan(image: image)
                },
                onCancel: { phase = .landing }
            )
            .ignoresSafeArea()
        }
        // Editable preview
        .sheet(isPresented: Binding(
            get: { if case .reviewing = phase { return true } else { return false } },
            set: { if !$0 { dismiss() } }
        )) {
            if case .reviewing(let img, let result) = phase {
                ReceiptPreviewSheet(
                    scan: result,
                    receiptImage: img,
                    onRetake: {
                        phase = .landing
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
        // Camera permission alert
        .alert(loc("receipt.permission.denied_title"), isPresented: $showSettingsAlert) {
            Button(loc("receipt.permission.open_settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(loc("common.cancel"), role: .cancel) { }
        } message: {
            Text(loc("receipt.permission.denied_body"))
        }
    }

    // MARK: - Actions

    /// Start capture — either camera or photo library based on selected tab.
    private func startCapture() {
        HapticManager.shared.tap()
        if selectedTab == .scan {
            Task {
                let granted = await CameraPermissionHelper.request()
                await MainActor.run {
                    if granted {
                        phase = .camera
                    } else {
                        showSettingsAlert = true
                    }
                }
            }
        } else {
            phase = .picking
        }
    }

    private func runScan(image: UIImage) {
        // Animate the progress bar while OCR runs. Even though Vision is fast,
        // the user expects a "scanning" feel. We tween 0→0.85 across ~3s and
        // jump to 1.0 once the result lands; if the engine is slower we stay
        // near 85% until it completes.
        scanProgress = 0
        withAnimation(.easeOut(duration: 3.0)) {
            scanProgress = 0.85
        }
        scanTask = Task {
            do {
                let result = try await ReceiptScannerEngine.shared.scan(
                    image: image, cardCurrency: cardCurrency
                )
                // Bail if the user tapped Cancel while we were waiting on Vision.
                try Task.checkCancellation()
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.25)) { scanProgress = 1.0 }
                    HapticManager.shared.success()
                }
                // Tiny pause so the user perceives the bar finish before the
                // sheet animates in.
                try? await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                await MainActor.run {
                    phase = .reviewing(image, result)
                }
            } catch is CancellationError {
                // User canceled — already handled by cancelScan(); nothing to do.
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

    /// Abort the scan and return to the landing screen. Vision can't be
    /// preempted mid-recognition, but the cancellation check inside the task
    /// prevents the result from triggering a phase transition after the user
    /// has bailed.
    private func cancelScan() {
        HapticManager.shared.tap()
        scanTask?.cancel()
        scanTask = nil
        withAnimation(.easeOut(duration: 0.2)) { scanProgress = 0 }
        phase = .landing
    }
}

// MARK: - Landing tabs

enum LandingTab: String, CaseIterable {
    case scan
    case upload
}

// MARK: - Landing View

/// Hero screen with illustration card + Start Scan button.
private struct LandingView: View {
    @Binding var selectedTab: LandingTab
    let onStart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button {
                    HapticManager.shared.tap()
                    onClose()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 36, height: 36)
                }
                Text(loc("receipt.landing.title"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)

            // Tab segmented control
            HStack(spacing: 0) {
                ForEach(LandingTab.allCases, id: \.self) { tab in
                    Button {
                        HapticManager.shared.select()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(label(for: tab))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selectedTab == tab ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(AppTheme.cardDark)
                                        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                                }
                            }
                    }
                }
            }
            .padding(4)
            .background(AppTheme.cardMid.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 22)
            .padding(.top, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    // Illustration card
                    ZStack {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(LinearGradient(
                                colors: [
                                    Color(hex: "#E8E4FF"),
                                    Color(hex: "#D9F2EA")
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        ReceiptIllustration()
                            .padding(40)
                    }
                    .frame(height: 280)
                    .padding(.horizontal, 22)
                    .padding(.top, 22)

                    // Heading + body
                    VStack(spacing: 10) {
                        Text(selectedTab == .scan
                             ? loc("receipt.landing.scan_heading")
                             : loc("receipt.landing.upload_heading"))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("receipt.landing.subtitle"))
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    Spacer(minLength: 8)

                    // Tip banner
                    HStack(spacing: 10) {
                        Text("💡")
                            .font(.system(size: 14))
                        Text(loc("receipt.landing.tip"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.accent)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 22)

                    // CTA
                    Button(action: onStart) {
                        HStack(spacing: 10) {
                            Image(systemName: selectedTab == .scan ? "doc.text.viewfinder" : "photo.on.rectangle")
                                .font(.system(size: 16, weight: .semibold))
                            Text(selectedTab == .scan
                                 ? loc("receipt.landing.start_scan")
                                 : loc("receipt.landing.upload_now"))
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: AppTheme.accent.opacity(0.35), radius: 14, y: 8)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func label(for tab: LandingTab) -> String {
        switch tab {
        case .scan:   return loc("receipt.landing.tab_scan")
        case .upload: return loc("receipt.landing.tab_upload")
        }
    }
}

/// Stylized phone-with-receipt illustration drawn purely with SF Symbols and
/// shapes — no asset dependency. Mirrors the figma mock spirit without needing
/// to ship a PNG.
private struct ReceiptIllustration: View {
    var body: some View {
        ZStack {
            // Floating coin badges
            Circle()
                .fill(AppTheme.accent)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "dollarsign")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                )
                .offset(x: -78, y: -82)
                .shadow(color: AppTheme.accent.opacity(0.3), radius: 8, y: 4)

            Circle()
                .fill(AppTheme.orange)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "dollarsign")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white)
                )
                .offset(x: 70, y: -90)

            Circle()
                .fill(AppTheme.purple.opacity(0.8))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "dollarsign")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                )
                .offset(x: 80, y: 26)

            // Star sparkles
            Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#FFC857"))
                .offset(x: -86, y: 12)
            Image(systemName: "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.purple.opacity(0.6))
                .offset(x: -64, y: 56)

            // Phone body
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(hex: "#5B6BE8"))
                    .frame(width: 130, height: 200)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 6)
                // Receipt inside phone
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: 70, height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 56, height: 5)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 64, height: 5)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 50, height: 5)
                }
                .padding(.vertical, 18).padding(.horizontal, 14)
                .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 92, height: 132)
            }
        }
    }
}

// MARK: - Custom Camera (AVFoundation)

/// Live camera preview with green corner-bracket overlay + capture controls.
/// Uses a UIViewRepresentable for the AVCaptureVideoPreviewLayer underneath
/// and a SwiftUI overlay for the controls (so they can be themed easily).
struct ScanCameraView: View {
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = CameraSessionController()
    @State private var torchOn: Bool = false

    var body: some View {
        ZStack {
            // Live preview underneath
            CameraPreviewLayer(controller: camera)
                .ignoresSafeArea()

            // Dim outside-of-frame area
            FrameMaskOverlay()
                .allowsHitTesting(false)

            // Green corner brackets framing the receipt area
            CornerBracketsOverlay()
                .allowsHitTesting(false)

            // Top controls
            VStack {
                HStack {
                    circleButton(icon: "xmark") { onCancel() }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 80)

                // Helper hint
                Text(loc("receipt.camera.hint"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.top, 8)

                Spacer()
            }

            // Bottom controls
            VStack {
                Spacer()
                HStack(spacing: 32) {
                    bottomButton(icon: torchOn ? "bolt.fill" : "bolt") {
                        torchOn.toggle()
                        camera.setTorch(on: torchOn)
                    }
                    Button {
                        HapticManager.shared.rigidImpact()
                        camera.capture { image in
                            guard let image else { return }
                            DispatchQueue.main.async { onCaptured(image) }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 72, height: 72)
                            Circle()
                                .stroke(.white, lineWidth: 3)
                                .frame(width: 84, height: 84)
                            Image(systemName: "viewfinder")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    bottomButton(icon: "checkmark") {
                        // Same as capture — provided to mirror the mock layout
                        HapticManager.shared.tap()
                        camera.capture { image in
                            guard let image else { return }
                            DispatchQueue.main.async { onCaptured(image) }
                        }
                    }
                }
                .padding(.bottom, 36)
            }
        }
        .onAppear { camera.start() }
        .onDisappear {
            camera.setTorch(on: false)
            camera.stop()
        }
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.gray.opacity(0.4), in: Circle())
        }
    }

    private func bottomButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 52, height: 52)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

/// Dim mask drawn with an even-odd path — keeps the receipt frame clear.
private struct FrameMaskOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let frameRect = receiptFrameRect(in: geo.size)
            ZStack {
                Color.black.opacity(0.45)
                Rectangle()
                    .fill(.black)
                    .frame(width: frameRect.width, height: frameRect.height)
                    .position(x: frameRect.midX, y: frameRect.midY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

/// Decorative green corner brackets surrounding the receipt frame.
private struct CornerBracketsOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let r = receiptFrameRect(in: geo.size)
            ZStack {
                ForEach(BracketCorner.allCases, id: \.self) { corner in
                    BracketShape(corner: corner)
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 38, height: 38)
                        .position(corner.position(in: r))
                }
            }
        }
    }
}

private enum BracketCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX + 19, y: rect.minY + 19)
        case .topRight:    return CGPoint(x: rect.maxX - 19, y: rect.minY + 19)
        case .bottomLeft:  return CGPoint(x: rect.minX + 19, y: rect.maxY - 19)
        case .bottomRight: return CGPoint(x: rect.maxX - 19, y: rect.maxY - 19)
        }
    }
}

private struct BracketShape: Shape {
    let corner: BracketCorner
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len: CGFloat = rect.width
        switch corner {
        case .topLeft:
            p.move(to: CGPoint(x: 0, y: len))
            p.addLine(to: .zero)
            p.addLine(to: CGPoint(x: len, y: 0))
        case .topRight:
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: len, y: 0))
            p.addLine(to: CGPoint(x: len, y: len))
        case .bottomLeft:
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 0, y: len))
            p.addLine(to: CGPoint(x: len, y: len))
        case .bottomRight:
            p.move(to: CGPoint(x: 0, y: len))
            p.addLine(to: CGPoint(x: len, y: len))
            p.addLine(to: CGPoint(x: len, y: 0))
        }
        return p
    }
}

/// Computes the receipt-shaped capture frame relative to the camera preview.
private func receiptFrameRect(in size: CGSize) -> CGRect {
    let inset: CGFloat = 32
    let topInset: CGFloat = 130
    let bottomInset: CGFloat = 180
    return CGRect(
        x: inset,
        y: topInset,
        width: size.width - inset * 2,
        height: size.height - topInset - bottomInset
    )
}

// MARK: - Camera Session Controller

/// Owns the AVCaptureSession and exposes start/stop/capture/torch helpers.
///
/// Why no @MainActor on the class: SwiftUI's @StateObject needs ObservableObject,
/// and combining @MainActor with auto-synthesized ObservableObject conformance
/// produces a "does not conform" error on some Swift toolchain versions because
/// the synthesized `objectWillChange` publisher gets actor-isolated. We declare
/// it explicitly as `nonisolated` to sidestep that. The controller has no
/// observable @Published state today; the property exists purely to satisfy
/// the protocol so it can be held by @StateObject for lifetime management.
final class CameraSessionController: NSObject, ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var captureCompletion: ((UIImage?) -> Void)?
    private var configured = false
    private let sessionQueue = DispatchQueue(label: "dipo.camera.session")

    func start() {
        configureIfNeeded()
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.captureCompletion = completion
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off  // Torch handles low-light better for receipts
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            print("[Camera] Torch error: \(error.localizedDescription)")
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        sessionQueue.async { [session, photoOutput] in
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()
        }
    }
}

// `CameraSessionController` picks up implicit main-actor isolation from its
// `ObservableObject` conformance. AVFoundation calls
// `photoOutput(_:didFinishProcessingPhoto:error:)` from its own background
// queue, so we declare the delegate method `nonisolated` — the body already
// hops to main via `DispatchQueue.main.async` before touching any
// observable state, so the runtime contract is safe.
extension CameraSessionController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        // Decode the photo on whatever queue AVFoundation handed us — this
        // is CPU work and there's no benefit to forcing it onto main.
        let image: UIImage? = {
            guard let data = photo.fileDataRepresentation(),
                  let img = UIImage(data: data) else { return nil }
            return img
        }()
        // Then hop to main to read+clear `captureCompletion` and invoke it.
        // `captureCompletion` is main-actor-isolated (the enclosing class
        // is implicitly @MainActor via ObservableObject), so we use a Task
        // hop instead of `DispatchQueue.main.async` — the latter satisfies
        // the runtime but not the Swift 6 strict-concurrency checker.
        Task { @MainActor [weak self] in
            let completion = self?.captureCompletion
            self?.captureCompletion = nil
            completion?(image)
        }
    }
}

// MARK: - Camera Preview Layer Wrapper

struct CameraPreviewLayer: UIViewRepresentable {
    let controller: CameraSessionController

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = controller.session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Photo Library Picker Wrapper

struct PhotoPickerView: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerView
        init(_ parent: PhotoPickerView) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onCancel()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                guard let self else { return }
                if let img = obj as? UIImage {
                    DispatchQueue.main.async { self.parent.onPicked(img) }
                } else {
                    DispatchQueue.main.async { self.parent.onCancel() }
                }
            }
        }
    }
}

// MARK: - Scanning Progress View

/// Shown while OCR runs. Re-uses the green-bracket framing of the camera view
/// so the transition feels continuous, but here the captured image is shown
/// behind a slight tint and a progress bar drops from the top.
private struct ScanningProgressView: View {
    let image: UIImage
    @Binding var progress: Double
    let onCancel: () -> Void
    @State private var messageIndex = 0
    private let messages: [String] = [
        loc("receipt.scanning.reading"),
        loc("receipt.scanning.detecting_merchant"),
        loc("receipt.scanning.extracting_amount"),
        loc("receipt.scanning.categorizing"),
    ]

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.35))
                .clipped()

            FrameMaskOverlay()
                .allowsHitTesting(false)
            CornerBracketsOverlay()
                .allowsHitTesting(false)

            VStack {
                // Cancel button — gives the user an escape hatch when OCR
                // takes too long or when they realize they captured the wrong
                // thing. Without this they'd be stuck staring at the progress
                // bar until the engine completes.
                HStack {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                // Top progress section
                VStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.25))
                                .frame(height: 8)
                            Capsule()
                                .fill(AppTheme.accent)
                                .frame(width: max(8, geo.size.width * progress), height: 8)
                        }
                    }
                    .frame(height: 8)

                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 11))
                        Text(String(format: loc("receipt.scanning.progress"), Int(progress * 100)))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppTheme.accent, in: Capsule())
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)

                Spacer()

                // Cycling status message + secondary cancel for convenience
                VStack(spacing: 12) {
                    Text(messages[messageIndex])
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                        .id(messageIndex)
                        .transition(.opacity)

                    Button {
                        onCancel()
                    } label: {
                        Text(loc("common.cancel"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.5), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                    }
                }
                .padding(.bottom, 36)
            }
        }
        .onAppear {
            Task {
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(900))
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

// MARK: - Backdrop while preview sheet is up

private struct ScanBackdrop: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.accent.opacity(0.6))
            Text(loc("receipt.scan_complete"))
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}

// MARK: - Error View

private struct ScanErrorView: View {
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

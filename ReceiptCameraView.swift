// ReceiptCameraView.swift
// Camera permission helper used by the receipt scan flow.
//
// Historical note: this file used to host a UIImagePickerController wrapper
// (ReceiptImagePicker) and a source-chooser stub. Both were removed when the
// scan flow was redesigned to use a custom AVFoundation camera (see
// ScanCameraView in ReceiptScanFlow.swift) and a PHPickerViewController
// wrapper for photo library selection. Only the camera permission helper
// remains here because it's still useful for any caller that needs to
// pre-flight camera access before presenting the custom camera.

import Foundation
import AVFoundation

// MARK: - Permission Helper

/// Checks and requests camera permission. Photo library access goes through
/// PHPickerViewController, which handles its own permission UI.
enum CameraPermissionHelper {

    /// Check current camera permission state without prompting.
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Request access. Returns true if granted (existing or new), false if denied.
    /// Safe to call multiple times — system shows the prompt only on first call.
    static func request() async -> Bool {
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            // Denied or restricted — user must change in Settings.
            return false
        }
    }
}

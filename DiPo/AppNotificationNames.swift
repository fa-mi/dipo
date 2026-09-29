import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// Moved out of ProfileView.swift, unchanged. App-wide notification names.

// MARK: - Notification Names

extension Notification.Name {
    static let profilePhotoDidChange = Notification.Name("profilePhotoDidChange")
    /// Posted by empty-state CTAs in HomeView/StatisticsView to request the
    /// MainTabView's central "+" sheet (AddTransactionSheet) to open. Lets
    /// child views trigger the add flow without owning the sheet binding.
    static let requestOpenAddTransaction = Notification.Name("requestOpenAddTransaction")
    /// Posted when an external entry point (currently: the Home Screen
    /// widget's Smart Insights teaser deep-link `dipo://upgrade-royal`)
    /// wants to present the Royal paywall sheet. MainTabView listens and
    /// owns the sheet binding so any tab can land on the paywall without
    /// detours through the Profile tab first.
    static let requestOpenPaywall        = Notification.Name("requestOpenPaywall")
    /// Posted when a support-reply notification's "Learn more" / deep link
    /// (`dipo://support`) is opened. MainTabView presents the Support screen
    /// so the user lands on their ticket thread from anywhere.
    static let requestOpenSupport        = Notification.Name("requestOpenSupport")
    /// Posted when a notification's "what to do next" button is tapped, so the
    /// alert can hand the user straight to the screen that fixes it instead of
    /// leaving them to find it. MainTabView owns the sheets.
    static let requestOpenSmartBudget    = Notification.Name("requestOpenSmartBudget")
    /// Posted by AskDiPoVoiceIntent (Back Tap / Siri / Shortcuts).
    static let requestOpenVoiceEntry     = Notification.Name("requestOpenVoiceEntry")
    /// Back Tap handed over a screenshot. Distinct from
    /// `requestOpenAddTransaction` because the gesture already said what the
    /// user wants — routing it through the transaction form first renders a
    /// screen nobody asked for on the way to the scanner.
    static let requestOpenScanFromShortcut = Notification.Name("requestOpenScanFromShortcut")
    /// Posted when the share extension opens `dipo://scan-shared`. The image
    /// itself waits in `SharedScanInbox`; MainTabView collects it.
    static let requestOpenSharedScan       = Notification.Name("requestOpenSharedScan")
    static let requestOpenDebt           = Notification.Name("requestOpenDebt")
    static let requestOpenSavingsGoals   = Notification.Name("requestOpenSavingsGoals")
}

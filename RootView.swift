import SwiftUI
import SwiftData
import UserNotifications

// MARK: - Root View
// @Query here means ANY change to BankCard in SwiftData
// instantly propagates to appVM.cards across the whole app.

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase)   private var scenePhase

    // This @Query is the live observer — SwiftData notifies it
    // the moment any card is inserted, updated, or deleted
    @Query(sort: \BankCard.sortOrder) private var liveCards: [BankCard]

    @State private var appVM  = AppViewModel()
    @State private var authVM = AuthViewModel()

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            switch authVM.authState {
            case .splash:
                SplashView().transition(.opacity)
            case .setup:
                SetupView(authVM: authVM)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity))
            case .lock:
                LockView(authVM: authVM)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 1.05).combined(with: .opacity)))
            case .authenticated:
                MainTabView(vm: appVM, authVM: authVM)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .scale(scale: 0.95).combined(with: .opacity)))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: authVM.authState)

        // KEY: whenever SwiftData adds/removes/edits any BankCard,
        // liveCards updates automatically → sync straight into appVM
        .onChange(of: liveCards) { _, newCards in
            appVM.cards = newCards
            if appVM.selectedCardIndex >= newCards.count {
                appVM.selectedCardIndex = max(0, newCards.count - 1)
            }
        }

        .onChange(of: scenePhase) { _, newPhase in
            authVM.handleScenePhase(newPhase)
            if newPhase == .active {
                appVM.cards = liveCards
                SalaryCreditEngine.processIfNeeded(context: context)
            }
        }

        .onAppear {
            appVM.cards = liveCards
            UserSession.shared.checkAppleCredentialState { _ in }
            authVM.bootstrap()
            HapticManager.shared.prepare()
            CurrencyManager.shared.fetchRate()
            SalaryCreditEngine.processIfNeeded(context: context)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted, UserDefaults.standard.bool(forKey: "daily_reminder_on") {
                    NotificationManager.scheduleDailyReminder()
                }
            }
        }
    }
}

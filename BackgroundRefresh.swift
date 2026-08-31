import Foundation
import BackgroundTasks
import SwiftData

// MARK: - Background Refresh
//
// Why this exists.
//
// DiPo's reminders come in two kinds, and only one of them worked while the
// app was closed:
//
//   • PRE-SCHEDULED — payday, debt due dates, card expiry, weekly recap.
//     These are handed to iOS as `UNCalendarNotificationTrigger`s, so iOS
//     delivers them on time whether or not DiPo is running. These were fine.
//
//   • COMPUTED — "Daily needs over budget", overspend, spending spikes.
//     These cannot be pre-scheduled because nobody knows on the 1st whether
//     you'll be over budget on the 14th. They are derived from the current
//     transaction set, and that derivation only ran inside
//     `NotificationScheduler.refresh(context:)` — which was called from
//     RootView on launch and on foreground.
//
// So the second kind could only reach the user AFTER they opened the app —
// which is precisely when they no longer need to be told, because the same
// warning is already on the Home screen. The alert was arriving too late to
// change any decision.
//
// A background task closes that gap: iOS wakes DiPo periodically, we re-run
// the same evaluation against fresh data, and any alert fires as a real push.
//
// Honest limitation: `BGAppRefreshTask` is opportunistic. iOS decides when to
// run it based on how often the user actually opens the app, battery state and
// Low Power Mode — typically a handful of times a day, not on a fixed clock.
// This makes DiPo's warnings arrive on their own; it does not make them
// instant, and no local-only app can promise that without a server.
enum BackgroundRefresh {

    /// Must match the entry in Info.plist → BGTaskSchedulerPermittedIdentifiers.
    static let taskIdentifier = "com.fahmiaquinas.DiPo.refresh"

    /// Ask for a wake-up no sooner than this. A lower bound, not a promise —
    /// iOS routinely runs it much later. Two hours keeps the evaluation
    /// meaningfully fresh without asking for more wake-ups than the OS will
    /// grant (over-requesting makes iOS throttle the app, not obey it).
    private static let earliestInterval: TimeInterval = 2 * 60 * 60

    /// Register the handler. MUST be called before the app finishes launching
    /// (iOS raises an exception for a task submitted with no registered
    /// handler), so this belongs in `didFinishLaunchingWithOptions`.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    /// Queue the next wake-up. Safe to call repeatedly — submitting replaces
    /// any pending request with the same identifier rather than stacking.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected and harmless in the Simulator (which has no background
            // scheduler) and when the user has disabled Background App Refresh.
            // Never surface this: the app works fine without it, alerts just
            // wait for the next launch as they always did.
            print("[BackgroundRefresh] Could not schedule: \(error.localizedDescription)")
        }
    }

    // MARK: Execution

    private static func handle(_ task: BGAppRefreshTask) {
        // Chain the next one FIRST. If the work below throws or the OS kills us
        // mid-run, the chain must not die with it — an unscheduled task never
        // reschedules itself, and background refresh would silently stop
        // forever after a single bad run.
        schedule()

        let work = Task { @MainActor in
            await runEvaluation()
            task.setTaskCompleted(success: true)
        }

        // iOS gives roughly 30 seconds. If it wants the time back, stop cleanly
        // rather than being terminated — a task killed by the OS counts against
        // the app's future scheduling budget.
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// The same catch-up + evaluation the app performs on launch, minus
    /// anything that touches the UI.
    ///
    /// The auto-record engines run here too, and deliberately so: a kos charge
    /// or salary credit that lands while the app is closed would otherwise stay
    /// unrecorded, and every budget figure computed below would be judging an
    /// incomplete month. Both engines are idempotent — they stamp the month
    /// they charged and never double-post.
    @MainActor
    private static func runEvaluation() async {
        let context = DiPoApp.sharedModelContainer.mainContext

        SalaryCreditEngine.processIfNeeded(context: context)
        RecurringExpenseEngine.processIfNeeded(context: context)

        // Re-derive every reminder from the data as it stands right now. This
        // is the call that was previously reachable only by opening the app.
        NotificationScheduler.refresh(context: context)

        // Keep the Home Screen widget honest with whatever just changed.
        WidgetDataSync.refresh(context: context)
    }
}

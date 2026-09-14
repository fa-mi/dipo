import UIKit

// MARK: - Haptic Manager

final class HapticManager {
    static let shared = HapticManager()
    private init() {}

    private let impactMed = UIImpactFeedbackGenerator(style: .medium)
    private let light     = UIImpactFeedbackGenerator(style: .light)
    private let rigid     = UIImpactFeedbackGenerator(style: .rigid)
    private let soft      = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()
    private let notif     = UINotificationFeedbackGenerator()

    func prepare() {
        impactMed.prepare(); light.prepare()
        rigid.prepare(); soft.prepare(); selection.prepare(); notif.prepare()
    }

    func tap()          { light.impactOccurred() }
    func mediumImpact() { impactMed.impactOccurred() }
    func rigidImpact()  { rigid.impactOccurred() }
    /// A soft tap at a chosen strength — for feedback that repeats, like each
    /// recognised word while dictating, where a full tap would buzz.
    func pulse(_ intensity: CGFloat) { soft.impactOccurred(intensity: intensity) }
    func select()       { selection.selectionChanged() }
    func success()      { notif.notificationOccurred(.success) }
    func warning()      { notif.notificationOccurred(.warning) }
    func error()        { notif.notificationOccurred(.error) }
}

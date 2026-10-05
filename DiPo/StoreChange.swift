import SwiftUI
import SwiftData
import Combine

// MARK: - Recompute on save, not on every render
//
// Figures built from the whole history — net worth, the financial ladder, the
// cash a down payment can come from — read every transaction on every card.
// As computed properties they ran on every redraw, several times over on
// Home, and on every keystroke in the loan calculator: the lag people felt
// grows with the history. Kept in @State and refreshed with this, they run
// when the screen appears and when something is saved, which is the only time
// their inputs can change.

extension View {
    /// Runs `action` on appear and after any SwiftData save.
    func onStoreChange(perform action: @escaping () -> Void) -> some View {
        onAppear(perform: action)
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                .receive(on: RunLoop.main)) { _ in action() }
    }
}

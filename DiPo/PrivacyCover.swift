import SwiftUI

// MARK: - Privacy cover
//
// iOS photographs the screen when the app leaves the foreground and shows
// that picture in the app switcher. Without a cover, that picture was of
// balances and transactions, visible to anyone swiping through the switcher
// of a shared or borrowed phone. A phone is often shared in a family, so
// this covers the app whenever it isn't active, for everyone, not only for
// those who turned the app lock on (RootView).
//
// The cover is DiPo's own icon on DiPo's ground: the same picture the app
// switcher puts above the card, so the card reads as DiPo, resting. It is
// opaque on purpose. A blur keeps the shape of a large figure readable, and
// a material is not always drawn into the snapshot.
//
// No animation: the cover must already be drawn when the snapshot is taken.
struct PrivacyCover: View {
    /// The icon's size, and its corner radius in the app icon's proportion.
    static let iconSize: CGFloat = 80

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            Image("DiPoCoverIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: Self.iconSize * 0.2237, style: .continuous))
        }
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}

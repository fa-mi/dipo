import SwiftUI
import SwiftData

// The header at the top of Home. The accounts under it are in HomeBalance.swift.

struct HomeHeader: View {
    let vm: AppViewModel
    @Binding var showSearch: Bool
    @Binding var showNotifications: Bool
    private var notifMgr: NotificationManager { NotificationManager.shared }

    /// Decoded once and held — not re-decoded on every body pass.
    ///
    /// This was a computed property that pulled the JPEG out of UserDefaults and
    /// ran `UIImage(data:)` *every* time Home re-rendered: every transaction
    /// added, every card swipe, every filter tap. The avatar changes roughly
    /// never, so that work was pure cost on the one screen that must stay smooth.
    @State private var avatar: UIImage? = nil
    @State private var name: String = ""
    /// Observed so the ring changes the moment the plan does.
    @State private var premium = PremiumManager.shared
    /// Without a photo the header wore DiPo's face. Switched off in Profile,
    /// it wears the user's initial instead.
    @AppStorage(HomePrefs.showDiPoKey) private var showDiPo = true

    /// The first letter of the name, for the stand-in avatar. "User" is the
    /// placeholder for no name at all, so it gets the silhouette instead.
    static func initial(of name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "User", let first = trimmed.first else { return nil }
        return String(first).uppercased()
    }

    private var isRoyal: Bool { premium.plan == .royal }

    /// "Good morning" to "Good night", by the hour.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 4..<11:  return loc("home.greeting_morning")
        case 11..<15: return loc("home.greeting_afternoon")
        case 15..<19: return loc("home.greeting_evening")
        default:      return loc("home.greeting_night")
        }
    }

    /// Royal wears its colour as a ring — purple running into a warm gold, the
    /// crown's own pairing — with the crown tucked at the edge. Free keeps a
    /// quiet hairline, so the difference is a badge, not a demotion.
    private var avatarRing: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRoyal {
                Circle()
                    .strokeBorder(AngularGradient(colors: [PremiumPlan.royal.color, Color(hex: "#E879F9"),
                                                           Color(hex: "#FBBF24"), PremiumPlan.royal.color],
                                                  center: .center, angle: .degrees(-60)),
                                  lineWidth: 2.5)
                Image(systemName: "crown.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(PremiumPlan.royal.color, in: Circle())
                    .overlay(Circle().stroke(AppTheme.bg, lineWidth: 2))
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            } else {
                Circle().strokeBorder(AppTheme.cardMid, lineWidth: 1.5)
            }
        }
        .frame(width: 54, height: 54)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Face and name are ONE control, not a decoration beside a label.
            // The name earns its line back by being the title of a button that
            // opens the place where you change the name.
            Button {
                HapticManager.shared.tap()
                vm.openProfile()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [AppTheme.cardMid, AppTheme.cardDark],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 45, height: 45)
                        if let avatar {
                            Image(uiImage: avatar)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 45, height: 45)
                                .clipShape(Circle())
                        } else if showDiPo {
                            Image("DiPoMascot")
                                .resizable()
                                .scaledToFill()
                                .frame(width: 49, height: 49)
                                .frame(width: 45, height: 45)
                                .clipShape(Circle())
                        } else if let initial = Self.initial(of: name) {
                            Text(initial)
                                .font(.system(.title3, weight: .bold))
                                .foregroundStyle(AppTheme.textSecondary)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(.title3))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        avatarRing
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(greeting + ",")
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                        HStack(spacing: 4) {
                            Text(name)
                                .font(.system(.callout, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            }
            .buttonStyle(ScaleButtonStyle())

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                Button { HapticManager.shared.tap(); showSearch = true } label: {
                    ZStack {
                        Circle().fill(AppTheme.cardDark).frame(width: 42, height: 42)
                        Image(systemName: "magnifyingglass").font(.system(.body)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
.accessibilityLabel(loc("a11y.search"))
                .buttonStyle(ScaleButtonStyle())

                Button { HapticManager.shared.tap(); showNotifications = true } label: {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Circle().fill(AppTheme.cardDark).frame(width: 42, height: 42)
                            Image(systemName: notifMgr.hasUnread ? "bell.badge.fill" : "bell")
                                .font(.system(.body))
                                .foregroundStyle(notifMgr.hasUnread ? AppTheme.accent : AppTheme.textSecondary)
                                // Rings once when a new notification lands.
                                .symbolEffect(.bounce, value: notifMgr.unreadCount)
                        }
                        if notifMgr.unreadCount > 0 {
                            ZStack {
                                Circle().fill(AppTheme.redFill).frame(width: 18, height: 18)
                                Text(notifMgr.unreadCount > 9 ? "9+" : "\(notifMgr.unreadCount)")
                                    .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.onVividFill)
                            }
                            .offset(x: 4, y: -4)
                        }
                    }
                }
                .buttonStyle(ScaleButtonStyle())
                // Read as "Notifications, 3 unread" — the badge digit alone
                // was announced with no noun attached.
                .accessibilityLabel(loc("a11y.notifications"))
                .accessibilityValue(notifMgr.unreadCount > 0
                                    ? String(format: loc("a11y.unread_count"), notifMgr.unreadCount) : "")
            }
        }
        .onAppear(perform: loadIdentity)
        // Every tab stays mounted, so `onAppear` fires once per launch. Editing
        // the name or photo over on Profile has to say so explicitly, or Home
        // would keep greeting the user by their old name until the next launch.
        .onReceive(NotificationCenter.default.publisher(for: .profilePhotoDidChange)) { _ in
            loadIdentity()
        }
    }

    private func loadIdentity() {
        name = Keychain.load(key: "user_name") ?? "User"
        if let data = UserDefaults.standard.data(forKey: "profile_photo") {
            avatar = UIImage(data: data)
        } else {
            avatar = nil
        }
    }
}

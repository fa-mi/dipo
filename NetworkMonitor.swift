import Network
import SwiftUI

// MARK: - Network Monitor

@Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    private(set) var isConnected:     Bool = true
    private(set) var justReconnected: Bool = false

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "dipo.network.monitor", qos: .utility)
    private var wasOffline = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self.isConnected = connected
                if connected && self.wasOffline {
                    self.justReconnected = true
                    IndonesianHolidayService.shared.prefetch()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.justReconnected = false
                    }
                }
                self.wasOffline = !connected
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Offline banner
//
// Everything DiPo records lives on the phone, so losing signal takes away
// only the few things that talk to a server: the AI chat's model replies,
// the receipt fallback to Haiku, sign-in, purchases, web sync. This used to
// be a full-screen, opaque page with no way past it: the whole app was
// locked until the signal came back. For someone on patchy rural coverage
// that means locked exactly when they are standing at the warung wanting to
// log what they just paid.
//
// Now it is a small pill at the top that says so and lets every touch
// through. The features that need the network already handle being offline
// on their own: the receipt scan keeps its on-device reading, and the chat
// keeps what was typed (see AIChatViewModel.keepForLater).
struct NoInternetOverlay: View {
    @State private var monitor = NetworkMonitor.shared

    var body: some View {
        VStack {
            if !monitor.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.orange)
                    Text(loc("network.offline_banner"))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(
                    Capsule().fill(AppTheme.cardMid)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                )
                .padding(.top, 54)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
            Spacer()
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: monitor.isConnected)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .zIndex(998)
    }
}

// MARK: - Reconnected Toast (small, shown briefly after coming back online)

struct ReconnectedToast: View {
    @State private var monitor = NetworkMonitor.shared

    var body: some View {
        VStack {
            if monitor.justReconnected {
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.system(.footnote, weight: .semibold))
                    Text(loc("network.back_online"))
                        .font(.system(.footnote, weight: .semibold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(
                    Capsule().fill(AppTheme.accentFill)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                )
                .padding(.top, 54)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: monitor.justReconnected)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .zIndex(999)
    }
}

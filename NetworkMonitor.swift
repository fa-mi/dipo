import Network
import SwiftUI

// MARK: - Network Monitor
// Uses Apple's NWPathMonitor (no third-party dependency).
// Publishes isConnected so any view can react to connectivity changes.

@Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    private(set) var isConnected: Bool = true
    private(set) var justReconnected: Bool = false  // pulses true for 3s after reconnect

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
                    // Just came back online — retry any pending fetches
                    self.justReconnected = true
                    IndonesianHolidayService.shared.prefetch()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.justReconnected = false
                    }
                }
                self.wasOffline = !connected
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Offline Banner View
// Drop this into the root ZStack — slides down from top when offline,
// slides back up when reconnected.

struct OfflineBanner: View {
    @State private var monitor = NetworkMonitor.shared

    var body: some View {
        VStack {
            if !monitor.isConnected {
                offlinePill
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if monitor.justReconnected {
                reconnectedPill
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: monitor.isConnected)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: monitor.justReconnected)
        .ignoresSafeArea(edges: .top)
        .zIndex(999)
        .allowsHitTesting(false)  // doesn't block taps underneath
    }

    private var offlinePill: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("No internet connection")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color(hex: "#FF5B5B"))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        )
        .padding(.top, 54)  // clear the status bar / Dynamic Island
    }

    private var reconnectedPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi")
                .font(.system(size: 13, weight: .semibold))
            Text("Back online")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color(hex: "#1DB87A"))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .padding(.top, 54)
    }
}

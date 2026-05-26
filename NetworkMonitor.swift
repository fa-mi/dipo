import Network
import SwiftUI

// MARK: - Network Monitor

@Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    private(set) var isConnected:     Bool = true
    private(set) var justReconnected: Bool = false
    private(set) var isChecking:      Bool = false   // spinner while retrying

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "dipo.network.monitor", qos: .utility)
    private var wasOffline = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self.isConnected = connected
                self.isChecking  = false
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

    /// Called by the Retry button — briefly shows spinner then re-checks path.
    func retry() {
        isChecking = true
        // Re-evaluate current path after short delay to give NWPathMonitor time
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            let connected = self.monitor.currentPath.status == .satisfied
            self.isConnected = connected
            self.isChecking  = false
            if connected {
                self.justReconnected = true
                IndonesianHolidayService.shared.prefetch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.justReconnected = false
                }
            }
        }
    }
}

// MARK: - No Internet Full-Screen View
// Shown as an overlay over the whole app when there is no connection.
// Slides away automatically when connection is restored.

struct NoInternetOverlay: View {
    @State private var monitor  = NetworkMonitor.shared
    @State private var appeared = false

    var body: some View {
        ZStack {
            if !monitor.isConnected {
                offlineScreen
                    .transition(.asymmetric(
                        insertion:  .move(edge: .bottom).combined(with: .opacity),
                        removal:    .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: monitor.isConnected)
        .zIndex(998)
    }

    private var offlineScreen: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Mascot — full color, no circle
                Image("DiPoMascot")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .animation(.spring(response: 0.6).delay(0.1), value: appeared)

                Spacer().frame(height: 28)

                // Title
                Text(loc("network.no_connection"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5).delay(0.18), value: appeared)

                Spacer().frame(height: 10)

                // Subtitle
                Text(loc("network.message"))
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 40)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5).delay(0.22), value: appeared)

                Spacer().frame(height: 40)

                // Retry button
                retryButton
                    .padding(.horizontal, 32)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5).delay(0.28), value: appeared)

                Spacer()

                // Footer hint
                Text(loc("network.data_safe"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                    .padding(.bottom, 40)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5).delay(0.32), value: appeared)
            }
        }
        .onAppear  { withAnimation { appeared = true } }
        .onDisappear { appeared = false }
    }

    private var retryButton: some View {
        Button { monitor.retry() } label: {
            HStack(spacing: 10) {
                if monitor.isChecking {
                    ProgressView().tint(.white).scaleEffect(0.85)
                    Text(loc("network.checking"))
                        .font(.system(size: 16, weight: .semibold))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                    Text(loc("network.check"))
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                monitor.isChecking
                    ? AppTheme.textSecondary.opacity(0.4)
                    : Color(hex: "#FF5B5B"),
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(monitor.isChecking)
        .animation(.easeInOut(duration: 0.2), value: monitor.isChecking)
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
                        .font(.system(size: 13, weight: .semibold))
                    Text(loc("network.back_online"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(
                    Capsule().fill(AppTheme.accent)
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

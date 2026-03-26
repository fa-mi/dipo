import SwiftUI

// MARK: - Main Tab View

struct MainTabView: View {
    @Bindable var vm: AppViewModel
    @Bindable var authVM: AuthViewModel
    @Namespace private var tabNS
    @State private var showAddSheet = false
    @State private var showNoCardBanner = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Group {
                        switch tab {
                        case .home:    HomeView(vm: vm)
                        case .stats:   StatisticsView(statsVM: StatsViewModel(), appVM: vm)
                        case .add:     Color.clear
                        case .cards:   CardListView(vm: vm)
                        case .profile: ProfileView(authVM: authVM)
                        }
                    }
                    .opacity(vm.activeTab == tab ? 1 : 0)
                    .scaleEffect(vm.activeTab == tab ? 1 : 0.97)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.activeTab)
                }
            }

            // No-card toast banner
            if showNoCardBanner {
                HStack(spacing: 10) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.accent)
                    Text("Add a card first before logging a transaction")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            CustomTabBar(vm: vm, namespace: tabNS, showAddSheet: $showAddSheet,
                         showNoCardBanner: $showNoCardBanner)
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showNoCardBanner)
        .sheet(isPresented: $showAddSheet) {
            AddTransactionSheet(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - Custom Tab Bar

struct CustomTabBar: View {
    @Bindable var vm: AppViewModel
    var namespace: Namespace.ID
    @Binding var showAddSheet: Bool
    @Binding var showNoCardBanner: Bool

    private var hasCards: Bool { !vm.cards.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                if tab == .add {
                    TabLogoButton(
                        action: {
                            if hasCards {
                                HapticManager.shared.success()
                                showAddSheet = true
                            } else {
                                HapticManager.shared.error()
                                withAnimation { showNoCardBanner = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                    withAnimation { showNoCardBanner = false }
                                }
                            }
                        },
                        isEnabled: true
                    )
                } else {
                    Button { vm.selectTab(tab) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                if vm.activeTab == tab {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(AppTheme.accent.opacity(0.15))
                                        .frame(width: 44, height: 36)
                                        .matchedGeometryEffect(id: "tab_bg", in: namespace)
                                }
                                Image(systemName: tab.icon)
                                    .font(.system(size: 20,
                                                  weight: vm.activeTab == tab ? .semibold : .regular))
                                    .foregroundStyle(vm.activeTab == tab
                                                     ? AppTheme.accent
                                                     : AppTheme.textSecondary)
                                    .scaleEffect(vm.activeTab == tab ? 1.05 : 1)
                                    .animation(.spring(response: 0.3, dampingFraction: 0.6),
                                               value: vm.activeTab)
                            }
                            Text(tab.label)
                                .font(.system(size: 10,
                                              weight: vm.activeTab == tab ? .semibold : .regular))
                                .foregroundStyle(vm.activeTab == tab
                                                 ? AppTheme.accent
                                                 : AppTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(AppTheme.cardDark)
                .shadow(color: .black.opacity(0.3), radius: 20, y: -4)
        }
        .padding(.horizontal, 10)
    }
}

import SwiftUI
import SwiftData

// Moved out of UtilityViews.swift, unchanged.

// MARK: - Custom Date Range Sheet

struct CustomDateRangeSheet: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Environment(\.dismiss) private var dismiss

    @State private var localStart: Date = Date()
    @State private var localEnd: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(AppTheme.cardMid)
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("tx.custom_range"))
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("tx.max_range"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)

            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(loc("tx.start_date"))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DatePicker("", selection: $localStart, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                        .environment(\.locale, LanguageManager.shared.currentLocale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: localStart) { _, newStart in
                            let maxEnd = Calendar.current.safeDate(byAdding: .month, value: 1, to: newStart)
                            if localEnd > maxEnd { localEnd = maxEnd }
                            if localEnd < newStart { localEnd = newStart }
                        }
                }

                VStack(spacing: 6) {
                    Text(loc("tx.end_date"))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let maxEnd = Calendar.current.safeDate(byAdding: .month, value: 1, to: localStart)
                    DatePicker("", selection: $localEnd,
                               in: localStart...min(maxEnd, Date()), displayedComponents: .date)
                        .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                        .environment(\.locale, LanguageManager.shared.currentLocale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                let days = max(Calendar.current.dateComponents([.day], from: localStart, to: localEnd).day ?? 0, 0)
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").font(.system(.footnote)).foregroundStyle(AppTheme.accent)
                    Text(days == 1 ? String(format: loc("search.day_results"), days) : String(format: loc("search.days_results"), days))
                        .font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            }
            .padding(.horizontal, 22).padding(.top, 20)

            Spacer()

            Button {
                startDate = Calendar.current.startOfDay(for: localStart)
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: localEnd)
                comps.hour = 23; comps.minute = 59; comps.second = 59
                endDate = Calendar.current.date(from: comps) ?? localEnd
                HapticManager.shared.success()
                dismiss()
            } label: {
                Text(loc("tx.apply_range"))
                    .font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22).padding(.bottom, 32)
        }
        .onAppear { localStart = startDate; localEnd = endDate }
    }
}

import SwiftUI
import PhotosUI
import FirebaseFirestore

// MARK: - Support Category

enum SupportCategory: String, CaseIterable {
    // rawValue MUST stay English — it's persisted to Firestore as the
    // ticket's `category` field. Changing it would break filtering on existing
    // documents and cause raw-value -> enum decoding to fail for old tickets.
    // Use `displayLabel` for any UI text instead.
    case bug     = "Bug Report"
    case feature = "Feature Request"
    case billing = "Billing"
    case other   = "Other"

    /// Localized label for UI. Reads from LanguageManager so the chip / ticket
    /// card / meta header all reflect the user's selected language without
    /// touching the Firestore-bound rawValue.
    var displayLabel: String {
        switch self {
        case .bug:     return loc("support.bug")
        case .feature: return loc("support.feature")
        case .billing: return loc("support.billing")
        case .other:   return loc("support.other")
        }
    }

    var icon: String {
        switch self {
        case .bug:     return "ant.fill"
        case .feature: return "lightbulb.fill"
        case .billing: return "creditcard.fill"
        case .other:   return "ellipsis.bubble.fill"
        }
    }

    var color: Color {
        switch self {
        case .bug:     return Color(hex: "#FF6B6B")
        case .feature: return Color(hex: "#38BDF8")
        case .billing: return Color(hex: "#FB923C")
        case .other:   return Color(hex: "#8A9693")
        }
    }
}

// MARK: - Ticket Status Config

private struct TicketStatusConfig {
    let label: String
    let color: Color
    let icon:  String
    let step:  Int      // 0=open 1=answered 2=closed

    static func from(_ status: String) -> TicketStatusConfig {
        // status string comes from Firestore (always English) — we keep the
        // switch on raw English values but localize the label for display.
        switch status {
        case "answered": return .init(label: loc("support.answered"), color: AppTheme.accent,       icon: "checkmark.circle.fill", step: 1)
        case "closed":   return .init(label: loc("support.closed"),   color: AppTheme.textSecondary, icon: "xmark.circle.fill",     step: 2)
        default:         return .init(label: loc("support.open"),     color: Color(hex: "#FB923C"),  icon: "clock.fill",            step: 0)
        }
    }
}

// MARK: - Contact Admin Sheet

struct ContactAdminSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showNewTicket  = false
    @State private var selectedTicket: SupportTicket?
    private let svc = FirebaseSupportService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                Group {
                    if svc.isLoading { loadingView }
                    else { ticketList }
                }
            }
            .navigationTitle(loc("support.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.close")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        HapticManager.shared.tap()
                        showNewTicket = true
                    } label: {
                        Text(loc("support.new"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(AppTheme.accent.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .task { await svc.fetchTickets() }
        .sheet(isPresented: $showNewTicket) {
            NavigationStack { NewTicketForm { showNewTicket = false } }
                .onDisappear { Task { await svc.fetchTickets() } }
        }
        .sheet(item: $selectedTicket) { ticket in
            TicketThreadView(ticket: ticket)
                .onDisappear { Task { await svc.fetchTickets() } }
        }
    }

    // MARK: - Ticket List

    private var ticketList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if svc.tickets.isEmpty {
                    emptyState
                } else {
                    // Summary header
                    summaryHeader
                        .padding(.horizontal, 22)

                    // Ticket cards
                    ForEach(svc.tickets) { ticket in
                        ticketCard(ticket)
                            .padding(.horizontal, 22)
                            .onTapGesture { HapticManager.shared.tap(); selectedTicket = ticket }
                    }
                }

                Spacer(minLength: 60)
            }
            .padding(.top, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)

            // Error state — shown when fetch fails (e.g. Firestore permission denied)
            if let err = svc.fetchError {
                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(AppTheme.red.opacity(0.08)).frame(width: 72, height: 72)
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 30)).foregroundStyle(AppTheme.red.opacity(0.7))
                    }
                    VStack(spacing: 6) {
                        Text(loc("support.load_error"))
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        Text(err)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.red.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Text(loc("support.firestore_error"))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                    Button {
                        HapticManager.shared.tap()
                        Task { await svc.fetchTickets() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 14))
                            Text(loc("common.retry")).font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(AppTheme.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            } else {
                // Normal empty state — no error, just no tickets yet
                ZStack {
                    Circle().fill(AppTheme.accent.opacity(0.08)).frame(width: 90, height: 90)
                    Image(systemName: "headphones.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(AppTheme.accent.opacity(0.6))
                }
                VStack(spacing: 8) {
                    Text(loc("support.no_tickets"))
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    Text(loc("support.no_tickets_sub"))
                        .font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center).lineSpacing(3)
                        .padding(.horizontal, 32)
                }
            }

            Spacer(minLength: 20)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 44, height: 44)
                Image(systemName: "headphones.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("support.your_tickets"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(String(format: loc("support.tickets_summary"),
                            svc.tickets.count,
                            svc.tickets.filter { $0.status == "open" }.count))
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            // Unread indicator
            let unreadCount = svc.tickets.filter { $0.hasUnreadReply }.count
            if unreadCount > 0 {
                Text(String(format: loc("support.unread_count"), unreadCount))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private func ticketCard(_ ticket: SupportTicket) -> some View {
        let cat    = SupportCategory(rawValue: ticket.category) ?? .other
        let status = TicketStatusConfig.from(ticket.status)
        let bg: Color     = ticket.hasUnreadReply ? AppTheme.accent.opacity(0.05) : AppTheme.cardDark
        let border: Color = ticket.hasUnreadReply ? AppTheme.accent.opacity(0.3)  : AppTheme.cardMid

        VStack(spacing: 0) {
            // Top row
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(cat.color.opacity(0.15)).frame(width: 42, height: 42)
                    Image(systemName: cat.icon).font(.system(size: 17)).foregroundStyle(cat.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ticket.subject)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if ticket.hasUnreadReply {
                            HStack(spacing: 4) {
                                Circle().fill(AppTheme.accent).frame(width: 6, height: 6)
                                Text(loc("support.new_reply"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Text(cat.displayLabel)
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Text("·")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Text(ticket.updatedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        if !ticket.mediaBase64.isEmpty {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 9)).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary.opacity(0.5))
            }
            .padding(14)

            // Status progress bar
            Divider().background(AppTheme.cardMid).padding(.horizontal, 14)
            ticketProgressBar(status: status)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(bg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(border, lineWidth: 1))
    }

    @ViewBuilder
    private func ticketProgressBar(status: TicketStatusConfig) -> some View {
        let steps: [(label: String, icon: String, active: Bool)] = [
            (loc("support.submitted_step"), "tray.fill",          status.step >= 0),
            (loc("support.in_review"),      "magnifyingglass",     status.step >= 1),
            (loc("support.answered"),       "checkmark.circle.fill", status.step >= 1),
            (loc("support.closed"),         "archivebox.fill",     status.step >= 2),
        ]

        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                // Step dot
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(step.active ? AppTheme.accent : AppTheme.cardMid)
                            .frame(width: 18, height: 18)
                        Image(systemName: step.icon)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(step.active ? .white : AppTheme.textSecondary.opacity(0.5))
                    }
                    Text(step.label)
                        .font(.system(size: 8, weight: step.active ? .semibold : .regular))
                        .foregroundStyle(step.active ? AppTheme.accent : AppTheme.textSecondary.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                // Connector line (not after last)
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(steps[i + 1].active ? AppTheme.accent : AppTheme.cardMid)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 14)
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().tint(AppTheme.accent)
            Text(loc("support.loading")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New Ticket Form

struct NewTicketForm: View {
    var onDone: () -> Void

    @State private var subject         = ""
    @State private var message         = ""
    @State private var category: SupportCategory = .bug
    @State private var pickerItems:    [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage]          = []
    @State private var isSubmitting    = false
    @State private var submitted       = false
    @State private var errorMsg:       String?
    @State private var appeared        = false

    private var canSend: Bool {
        !subject.isEmpty && !message.isEmpty && !isSubmitting
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            if submitted { sentView } else { formView }
        }
        .navigationTitle(loc("support.new_ticket"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(loc("common.cancel")) { HapticManager.shared.tap(); onDone() }
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6).delay(0.1)) { appeared = true } }
    }

    private var formView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                formHeader
                formCategoryPicker
                formSubjectField
                formMessageField
                if category == .bug { formMediaPicker }
                if let err = errorMsg {
                    InlineBanner(tone: .error, message: err)
                        .padding(.horizontal, 22)
                }
                formSendButton
                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
    }

    // MARK: Form helpers

    private var formHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 32)).foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("support.help"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("support.response_time"))
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.05), value: appeared)
    }

    private var formCategoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SupportCategory.allCases, id: \.rawValue) { cat in categoryChip(cat) }
            }
            .padding(.horizontal, 22)
        }
        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.1), value: appeared)
    }

    @ViewBuilder
    private func categoryChip(_ cat: SupportCategory) -> some View {
        let isSelected = (category == cat)
        let fg: Color     = isSelected ? .white : AppTheme.textSecondary
        let bg: Color     = isSelected ? cat.color : AppTheme.cardDark
        let border: Color = isSelected ? Color.clear : AppTheme.cardMid
        Button {
            HapticManager.shared.tap()
            withAnimation { category = cat }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: cat.icon).font(.system(size: 12))
                Text(cat.displayLabel).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var formSubjectField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("support.subject"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
            TextField(loc("support.subject_placeholder"), text: $subject)
                .font(.system(size: 15)).foregroundStyle(AppTheme.textPrimary)
                .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.15), value: appeared)
    }

    private var formMessageField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("support.message"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.system(size: 15)).foregroundStyle(AppTheme.textPrimary)
                    .frame(minHeight: 120).padding(10)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                if message.isEmpty {
                    Text(loc("support.message_placeholder"))
                        .font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                        .padding(18).allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.2), value: appeared)
    }

    private var formMediaPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("support.attach"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                    Text(loc("support.attach_sub"))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                }
                Spacer()
                Text("\(selectedImages.count)/3")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            }
            mediaThumbnailRow
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.22), value: appeared)
    }

    private var mediaThumbnailRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(selectedImages.enumerated()), id: \.offset) { i, img in
                    thumbnailItem(image: img, index: i)
                }
                if selectedImages.count < 3 { addPhotoButton }
            }
        }
    }

    @ViewBuilder
    private func thumbnailItem(image img: UIImage, index i: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
            Button {
                withAnimation(.spring(response: 0.3)) {
                    if selectedImages.indices.contains(i) { selectedImages.remove(at: i) }
                }
            } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.55)).frame(width: 22, height: 22)
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
            .offset(x: 5, y: -5)
        }
    }

    private var addPhotoButton: some View {
        let dashPattern: [CGFloat] = [5]
        return PhotosPicker(selection: $pickerItems, maxSelectionCount: 3 - selectedImages.count, matching: .images) {
            VStack(spacing: 6) {
                Image(systemName: "camera.fill").font(.system(size: 18)).foregroundStyle(AppTheme.accent)
                Text(loc("support.add_photo")).font(.system(size: 10, weight: .medium)).foregroundStyle(AppTheme.accent)
            }
            .frame(width: 80, height: 80)
            .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppTheme.accent.opacity(0.35),
                style: StrokeStyle(lineWidth: 1.5, dash: dashPattern)))
        }
        .onChange(of: pickerItems) { _, items in loadImages(from: items) }
    }

    private var formSendButton: some View {
        let buttonColor: Color = canSend ? AppTheme.accent : AppTheme.textSecondary.opacity(0.3)
        return Button { Task { await submit() } } label: {
            sendButtonLabel.background(buttonColor, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!canSend)
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.5).delay(0.25), value: appeared)
    }

    @ViewBuilder
    private var sendButtonLabel: some View {
        HStack(spacing: 10) {
            if isSubmitting { ProgressView().tint(.white).scaleEffect(0.9) }
            else { Image(systemName: "paperplane.fill").font(.system(size: 16)) }
            Text(isSubmitting ? loc("support.sending") : loc("support.send")).font(.system(size: 16, weight: .bold))
        }
        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private var sentView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 90, height: 90)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 10) {
                Text(loc("support.submitted")).font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("support.submitted_sub"))
                    .font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Button { onDone() } label: {
                Text(loc("common.done")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(ScaleButtonStyle()).padding(.horizontal, 32)
            Spacer()
        }
    }

    // MARK: Helpers

    private func loadImages(from items: [PhotosPickerItem]) {
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let img  = UIImage(data: data) else { continue }
                await MainActor.run { if selectedImages.count < 3 { selectedImages.append(img) } }
            }
            await MainActor.run { pickerItems = [] }
        }
    }

    private func submit() async {
        guard !subject.isEmpty, !message.isEmpty else { return }
        await MainActor.run { isSubmitting = true; errorMsg = nil }
        do {
            _ = try await FirebaseSupportService.shared.submitTicket(
                category: category.rawValue, subject: subject, message: message, images: selectedImages)
            HapticManager.shared.success()
            // ✅ Notify user their ticket was successfully created
            await MainActor.run {
                NotificationManager.shared.postTicketCreated(subject: subject)
                withAnimation(.spring(response: 0.5)) { submitted = true }
            }
        } catch {
            await MainActor.run {
                errorMsg = String(format: loc("support.send_failed"), error.localizedDescription)
                HapticManager.shared.error()
            }
        }
        await MainActor.run { isSubmitting = false }
    }
}

// MARK: - Ticket Thread View

struct TicketThreadView: View {
    let ticket: SupportTicket

    @Environment(\.dismiss) private var dismiss
    @State private var replies:          [SupportReply]    = []
    @State private var isLoading         = true
    @State private var fullscreenBase64: IdentifiableString?
    @State private var liveStatus: String = ""
    @State private var statusChangeAnim  = false
    // ✅ User reply composer
    @State private var replyText         = ""
    @State private var isSending         = false
    @State private var sendError:        String?

    private var currentStatus: String { liveStatus.isEmpty ? ticket.status : liveStatus }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if isLoading { ProgressView().tint(AppTheme.accent) } else { threadBody }
            }
            .navigationTitle(ticket.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.done")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .task {
            liveStatus = ticket.status
            do { replies = try await FirebaseSupportService.shared.fetchReplies(ticketId: ticket.id) } catch {}
            isLoading = false
            await FirebaseSupportService.shared.markRepliesRead(ticketId: ticket.id)
            // ✅ Start live listener for both new replies AND status changes
            await FirebaseSupportService.shared.listenToTicket(
                ticketId: ticket.id,
                onReplyAdded: { newReplies in replies = newReplies },
                onStatusChanged: { newStatus in
                    withAnimation(.spring(response: 0.5)) {
                        liveStatus       = newStatus
                        statusChangeAnim = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        statusChangeAnim = false
                    }
                }
            )
        }
        .sheet(item: $fullscreenBase64) { item in FullscreenImageView(base64String: item.value) }
    }

    private var threadBody: some View {
        VStack(spacing: 0) {
            // Messages scroll
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    ticketMetaHeader
                    userBubble(text: ticket.message, date: ticket.createdAt,
                               mediaBase64: ticket.mediaBase64,
                               category: SupportCategory(rawValue: ticket.category) ?? .other)
                    ForEach(replies) { reply in
                        if reply.isAdmin { adminBubble(reply) } else { userReplyBubble(reply) }
                    }
                    statusFooter
                    Spacer(minLength: 20)
                }
                .padding(.top, 16)
            }

            // ✅ Reply composer — always visible unless ticket is closed
            if currentStatus != "closed" {
                replyComposer
            }
        }
    }

    // MARK: - Reply Composer

    private var replyComposer: some View {
        VStack(spacing: 0) {
            Divider().background(AppTheme.cardMid)

            VStack(spacing: 10) {
                if let err = sendError {
                    InlineBanner(tone: .error, message: err)
                        .padding(.horizontal, 16)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    // Text field
                    ZStack(alignment: .topLeading) {
                        if replyText.isEmpty {
                            Text(loc("support.write_reply"))
                                .font(.system(size: 14))
                                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        TextEditor(text: $replyText)
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 38, maxHeight: 100)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.cardMid, lineWidth: 1))

                    // Send button
                    Button {
                        Task { await sendReply() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? AppTheme.cardMid : AppTheme.accent)
                                .frame(width: 36, height: 36)
                            if isSending {
                                ProgressView().tint(.white).scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 10)
            .background(AppTheme.cardDark)
        }
    }

    private func sendReply() async {
        let msg = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        await MainActor.run { isSending = true; sendError = nil }
        do {
            try await FirebaseSupportService.shared.submitUserReply(
                ticketId: ticket.id, message: msg)
            HapticManager.shared.success()
            await MainActor.run { replyText = "" }
        } catch {
            await MainActor.run {
                sendError = String(format: loc("support.send_failed"), error.localizedDescription)
                HapticManager.shared.error()
            }
        }
        await MainActor.run { isSending = false }
    }

    // MARK: - Ticket meta header with live status + progress

    private var ticketMetaHeader: some View {
        let cat    = SupportCategory(rawValue: ticket.category) ?? .other
        let status = TicketStatusConfig.from(currentStatus)

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(cat.color.opacity(0.12)).frame(width: 40, height: 40)
                    Image(systemName: cat.icon).font(.system(size: 16)).foregroundStyle(cat.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(cat.displayLabel)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        // Live status badge — pulses when it just changed
                        HStack(spacing: 4) {
                            Circle().fill(status.color).frame(width: 6, height: 6)
                                .scaleEffect(statusChangeAnim ? 1.5 : 1)
                                .animation(.easeInOut(duration: 0.4).repeatCount(3, autoreverses: true), value: statusChangeAnim)
                            Text(status.label)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(status.color)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(status.color.opacity(0.12), in: Capsule())
                        .scaleEffect(statusChangeAnim ? 1.05 : 1)
                        .animation(.spring(response: 0.4), value: statusChangeAnim)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 10))
                        Text(String(format: loc("support.opened"), ticket.createdAt.displayDateShort))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
            }

            // Progress track
            progressTrack(step: TicketStatusConfig.from(currentStatus).step)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.cardMid, lineWidth: 1))
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private func progressTrack(step: Int) -> some View {
        let steps: [(icon: String, label: String)] = [
            ("tray.fill",             loc("support.submitted_step")),
            ("eyes",                  loc("support.in_review")),
            ("checkmark.circle.fill", loc("support.answered")),
            ("archivebox.fill",       loc("support.closed")),
        ]
        // step 0=open(shows submitted+in review), 1=answered, 2=closed
        let activeUpTo = step == 0 ? 1 : step == 1 ? 2 : 3

        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                let active = i <= activeUpTo
                let isCurrent = i == activeUpTo
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(active ? AppTheme.accent : AppTheme.cardMid)
                            .frame(width: 22, height: 22)
                        if isCurrent && step < 2 {
                            Circle()
                                .stroke(AppTheme.accent.opacity(0.3), lineWidth: 3)
                                .frame(width: 28, height: 28)
                        }
                        Image(systemName: s.icon)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(active ? .white : AppTheme.textSecondary.opacity(0.4))
                    }
                    Text(s.label)
                        .font(.system(size: 8, weight: isCurrent ? .bold : .regular))
                        .foregroundStyle(active ? (isCurrent ? AppTheme.accent : AppTheme.textSecondary) : AppTheme.textSecondary.opacity(0.4))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                if i < steps.count - 1 {
                    Rectangle()
                        .fill(i < activeUpTo ? AppTheme.accent : AppTheme.cardMid)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                        .animation(.spring(response: 0.6).delay(Double(i) * 0.1), value: activeUpTo)
                }
            }
        }
        .animation(.spring(response: 0.5), value: step)
    }

    // MARK: Status footer message

    private var statusFooter: some View {
        let status = TicketStatusConfig.from(currentStatus)
        let message: String
        let icon: String
        switch currentStatus {
        case "answered":
            message = loc("support.footer.answered")
            icon    = "checkmark.circle"
        case "closed":
            message = loc("support.footer.closed")
            icon    = "archivebox"
        default:
            message = loc("support.footer.open")
            icon    = "clock"
        }
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(status.color)
            Text(message).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 22)
        .animation(.spring(response: 0.4), value: currentStatus)
    }

    // MARK: Bubbles

    @ViewBuilder
    private func userBubble(text: String, date: Date, mediaBase64: [String], category: SupportCategory) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Spacer(minLength: 50)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(loc("support.you")).font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                        Text(date.displayDateTimeShort)
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Text(text).font(.system(size: 14)).foregroundStyle(.white).lineSpacing(4)
                        .padding(14)
                        .background(category.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if !mediaBase64.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(mediaBase64.enumerated()), id: \.offset) { _, b64 in
                                bubbleThumbnail(base64: b64)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private func bubbleThumbnail(base64: String) -> some View {
        if let data  = Data(base64Encoded: base64),
           let uiImg = UIImage(data: data) {
            Image(uiImage: uiImg).resizable().scaledToFill()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { fullscreenBase64 = IdentifiableString(value: base64) }
        } else {
            RoundedRectangle(cornerRadius: 10).fill(AppTheme.cardMid).frame(width: 80, height: 80)
                .overlay(Image(systemName: "photo.badge.exclamationmark").font(.system(size: 22)).foregroundStyle(AppTheme.textSecondary))
        }
    }

    @ViewBuilder
    private func adminBubble(_ reply: SupportReply) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: "headphones").font(.system(size: 15)).foregroundStyle(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(loc("support.staff")).font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.accent)
                    Text(reply.createdAt.displayDateTimeShort)
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    if !reply.isReadByUser { Circle().fill(AppTheme.accent).frame(width: 6, height: 6) }
                }
                Text(reply.message).font(.system(size: 14)).foregroundStyle(AppTheme.textPrimary).lineSpacing(4)
                    .padding(14)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
            }
            Spacer(minLength: 50)
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private func userReplyBubble(_ reply: SupportReply) -> some View {
        HStack {
            Spacer(minLength: 50)
            VStack(alignment: .trailing, spacing: 4) {
                Text(reply.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                Text(reply.message).font(.system(size: 14)).foregroundStyle(.white).lineSpacing(4)
                    .padding(14)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Fullscreen Image View

struct FullscreenImageView: View {
    let base64String: String
    @Environment(\.dismiss) private var dismiss

    private var image: UIImage? {
        guard let data = Data(base64Encoded: base64String) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = image {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .padding(20)
        }
    }
}

import SwiftUI

// ⛔ THE JOIN PAGE OF A PUBLIC GROUP — 2026-10-19 groups v2. Opened from a global search row or a
// fariin.com/<name> link (GroupDirectory.open), presented by the Chats tab. Photo, name, @name,
// member count, description, and Join (or Request to Join when the group approves each person).
// A member never sees it: the chat opens instead. Laid out like the invite link's join sheet.
//
// TODO(groups v2): "messages before joining" belongs under the description here. Not built: it
// needs groups sent without end-to-end encryption and a server read path for outsiders.

struct PublicGroupSheet: View {
    let target: PublicGroupTarget
    @Environment(\.dismiss) private var dismiss

    @State private var preview: PublicGroupPreview?
    @State private var refusedText: String?
    @State private var failedText: String?
    @State private var joining = false
    @State private var requestSent = false
    @State private var joinError: String?
    @State private var contentHeight: CGFloat = 380

    private static let blue = Color(hex: 0x2392FE)

    // ⛔ A FULL PAGE, NOT A SHEET (owner 2026-10-20: "open the group page directly, Join at the
    // bottom; once joined, the composer"). The group up top, Join pinned where the composer will
    // be; joining opens the chat itself. Messages before joining are still not shown (TODO above).
    var body: some View {
        VStack(spacing: 0) {
            closeBar
            ScrollView { content.padding(.top, 24) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { joinBar }
        .task { await load() }
    }

    /// The Join button where the composer sits once you are in.
    @ViewBuilder private var joinBar: some View {
        if let p = preview {
            VStack(spacing: 8) {
                statusLine(p)
                capsuleButton(buttonTitle(p), enabled: !joining && !(requestSent || p.requested)) { join(p) }
            }
            .padding(.bottom, 8)
        }
    }

    private var closeBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    @ViewBuilder private var content: some View {
        if let p = preview {
            groupBody(p)
        } else if let why = refusedText {
            message(symbol: "person.3", why)
        } else if let why = failedText {
            VStack(spacing: 16) {
                message(symbol: "wifi.exclamationmark", why)
                capsuleButton("Try Again", enabled: true) {
                    failedText = nil
                    Task { await load() }
                }
            }
        } else {
            ProgressView().frame(height: 220)
        }
    }

    @ViewBuilder private func groupBody(_ p: PublicGroupPreview) -> some View {
        VStack(spacing: 0) {
            AvatarView(name: p.title, photoUrl: p.photoUrl, size: 100)
                .padding(.top, 2)
            Text(p.title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            Text(headline(p))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if !p.description.isEmpty {
                Text(p.description)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
            }
        }
    }

    private func headline(_ p: PublicGroupPreview) -> String {
        let count = GroupDirectory.membersLine(p.memberCount)
        return p.username.isEmpty ? count : "@\(p.username) · \(count)"
    }

    @ViewBuilder private func statusLine(_ p: PublicGroupPreview) -> some View {
        if let joinError {
            Text(joinError)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 16)
        } else if requestSent || p.requested {
            Text("Your request is waiting for an admin.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
        }
    }

    private func buttonTitle(_ p: PublicGroupPreview) -> String {
        if requestSent || p.requested { return "Request Sent" }
        if joining { return p.needsApproval ? "Sending…" : "Joining…" }
        return p.needsApproval ? "Request to Join" : "Join Group"
    }

    private func capsuleButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(enabled ? Self.blue : Color(.tertiarySystemFill)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func message(symbol: String, _ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 16))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 12)
        .padding(.bottom, 36)
    }

    // MARK: - Work

    private func load() async {
        switch await GroupDirectory.preview(name: target.name, cid: target.cid) {
        case .found(let p):
            if p.isMember { openChat(p); return }
            preview = p
        case .refused(let why):
            if preview == nil { refusedText = why }
        case .failed(let why):
            if preview == nil { failedText = why }
        }
    }

    private func openChat(_ p: PublicGroupPreview) {
        AppRouter.shared.pendingPublicGroup = nil
        GroupDirectory.openChat(p.cid, title: p.title, photo: p.photoUrl)
        dismiss()
    }

    private func join(_ p: PublicGroupPreview) {
        guard !joining else { return }
        guard NetworkState.shared.isOnline else { joinError = "No internet connection. Try again."; return }
        joining = true
        joinError = nil
        Task {
            do {
                switch try await GroupDirectory.join(cid: p.cid) {
                case .joined, .already: openChat(p)
                case .requested: requestSent = true
                }
            } catch {
                joinError = error.localizedDescription
            }
            joining = false
        }
    }
}

/// A public group in global search: photo, name, "@name · N members". Laid out like the stranger
/// row above it (56pt photo, headline and subheadline), so the Global Search section reads as one.
/// A table cell: the table's own selection handles the tap (no Button inside).
struct PublicGroupHitRow: View {
    let hit: PublicGroupHit

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: hit.title, photoUrl: hit.photoUrl, size: 56)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(hit.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

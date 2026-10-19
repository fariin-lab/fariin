import SwiftUI

// ⛔ THE INVITE LINKS PAGE (groups v2 step 4, 2026-10-19), laid out like the reference app's link
// list in Kulan's look, in our own words:
//   1. the primary link: its address in a rounded pill with a "..." menu (Copy, QR Code, Reset Link,
//      Turn Off Link), Copy and Share side by side, then the faces of the first people in and a count;
//   2. Approve New Members for that link, one line under it;
//   3. More Links: Create a New Link, then each extra link with a round icon coloured by its state;
//   4. Revoked Links, with Delete All Revoked.
// Everything goes through the server (GroupInviteService, the functions-groups link callables). Every
// failure is shown in the alert; nothing is swallowed and nothing is shown as done before the server
// says so.

struct GroupLinksPage: View {
    let cid: String
    let groupTitle: String

    @State private var list: GroupLinkList?
    @State private var loadError: String?
    @State private var working = false
    @State private var linkError: String?
    @State private var confirmReset = false
    @State private var confirmOff = false
    @State private var confirmDeleteAll = false
    @State private var revokeTarget: GroupLink?
    @State private var editTarget: LinkEditTarget?
    @State private var qrLink: GroupLink?
    @State private var shareText: String?
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?
    /// Approve New Members as just chosen, shown until the reload after the write.
    @State private var heldApproval: Bool?

    var body: some View {
        List { content }
            .navigationTitle("Invite Links").navigationBarTitleDisplayMode(.inline)
            .task { await reload() }
            .refreshable { await reload() }
            .overlay(alignment: .bottom) { copiedToast }
            .modifier(GroupLinksDialogs(
                linkError: $linkError, confirmReset: $confirmReset, confirmOff: $confirmOff,
                confirmDeleteAll: $confirmDeleteAll, revokeTarget: $revokeTarget,
                onReset: reset, onOff: turnOff, onDeleteAll: deleteAllRevoked, onRevoke: revoke))
            .sheet(item: $qrLink) { l in GroupLinkQRSheet(title: groupTitle, link: l.url) }
            .sheet(item: Binding(get: { shareText.map { LinkShareText(id: $0) } },
                                 set: { shareText = $0?.id })) { t in
                ForwardPicker(shareText: t.id)
            }
            .sheet(item: $editTarget) { t in
                GroupLinkEditPage(cid: cid, link: t.link) { Task { await reload() } }
            }
    }

    @ViewBuilder private var content: some View {
        if let list {
            primarySection(list.primary)
            if let p = list.primary { approvalSection(p) }
            moreSection(list.links)
            if !list.revoked.isEmpty { revokedSection(list.revoked) }
        } else if let loadError {
            Section {
                VStack(spacing: 12) {
                    Text(loadError).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await reload() } }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
        }
    }

    // MARK: - Sections

    private func primarySection(_ p: GroupLink?) -> some View {
        Section {
            PrimaryLinkCard(link: p, working: working,
                            onCopy: copy, onShareInApp: { shareText = $0.url }, onQR: { qrLink = $0 },
                            onReset: { confirmReset = true }, onOff: { confirmOff = true },
                            onCreate: createPrimary)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        } header: {
            Text("Invite Link")
        } footer: {
            Text(p == nil ? "This group has no invite link. People can only be added by its members."
                          : "Anyone with Fariin who has this link can join the group.")
        }
    }

    private func approvalSection(_ p: GroupLink) -> some View {
        Section {
            // The chosen value is held until the reload after the write lands (2026-10-19 fix
            // round): the switch flicked back to the old value while the server answered.
            Toggle("Approve New Members", isOn: Binding(
                get: { heldApproval ?? p.requestApproval },
                set: { on in setApproval(p, on) }))
                .disabled(working)
        } footer: {
            Text("When this is on, an admin approves each person before they join with this link.")
        }
    }

    private func moreSection(_ links: [GroupLink]) -> some View {
        Section("More Links") {
            Button { editTarget = LinkEditTarget(link: nil) } label: {
                Label("Create a New Link", systemImage: "plus").foregroundStyle(Color.accentColor)
            }
            ForEach(links) { l in
                Menu { linkMenu(l) } label: { GroupLinkRow(link: l) }
            }
        }
    }

    private func revokedSection(_ links: [GroupLink]) -> some View {
        Section("Revoked Links") {
            Button(role: .destructive) { confirmDeleteAll = true } label: {
                Label("Delete All Revoked", systemImage: "trash")
            }
            .disabled(working)
            ForEach(links) { l in
                Menu {
                    Button(role: .destructive) { delete(l) } label: { Label("Delete Link", systemImage: "trash") }
                } label: { GroupLinkRow(link: l) }
            }
        }
    }

    @ViewBuilder private func linkMenu(_ l: GroupLink) -> some View {
        Button { copy(l) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { shareText = l.url } label: { Label("Send in Fariin", systemImage: "paperplane") }
        ShareLink(item: URL(string: l.url) ?? URL(string: "https://fariin.com")!) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button { qrLink = l } label: { Label("QR Code", systemImage: "qrcode") }
        Button { editTarget = LinkEditTarget(link: l) } label: { Label("Edit", systemImage: "pencil") }
        Button(role: .destructive) { revokeTarget = l } label: { Label("Revoke", systemImage: "xmark.circle") }
    }

    @ViewBuilder private var copiedToast: some View {
        if copied {
            Text("Link copied")
                .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.black.opacity(0.75), in: Capsule())
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Work

    private func reload() async {
        do {
            list = try await GroupInviteService.listLinks(cid: cid)
            loadError = nil
        } catch {
            if list == nil {
                loadError = GroupInviteService.errorText(error, "The links could not be loaded. Try again.")
            } else {
                linkError = GroupInviteService.errorText(error, "The links could not be refreshed. Try again.")
            }
        }
    }

    private func copy(_ l: GroupLink) {
        UIPasteboard.general.string = l.url
        Haptics.notify(.success)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copied = true }
        // A second copy restarts the toast's time instead of the first copy's timer hiding it early.
        copiedTask?.cancel()
        copiedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }

    /// Runs one change, shows its failure, then reloads what the server really holds.
    /// `after` runs once the reload is in, before the page is live again.
    private func change(_ fallback: String, after: (() -> Void)? = nil,
                        _ work: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        Task {
            do { try await work() } catch { linkError = GroupInviteService.errorText(error, fallback) }
            await reload()
            after?()
            working = false
        }
    }

    private func createPrimary() {
        change("The link was not created. Try again.") { _ = try await GroupInviteService.createPrimaryLink(cid: cid) }
    }
    private func reset() {
        change("The link was not reset. The old one still works. Try again.") {
            _ = try await GroupInviteService.createPrimaryLink(cid: cid)
        }
    }
    private func turnOff() {
        guard let p = list?.primary else { return }
        change("The link is still on. Try again.") { _ = try await GroupInviteService.revokeLink(cid: cid, code: p.code) }
    }
    private func revoke(_ l: GroupLink) {
        change("The link was not revoked. Try again.") { _ = try await GroupInviteService.revokeLink(cid: cid, code: l.code) }
    }
    private func delete(_ l: GroupLink) {
        change("The link was not deleted. Try again.") { try await GroupInviteService.deleteLink(cid: cid, code: l.code) }
    }
    private func deleteAllRevoked() {
        change("The revoked links were not deleted. Try again.") { _ = try await GroupInviteService.deleteAllRevoked(cid: cid) }
    }
    private func setApproval(_ p: GroupLink, _ on: Bool) {
        guard !working else { return }
        heldApproval = on
        change("The setting was not changed. Try again.", after: { heldApproval = nil }) {
            _ = try await GroupInviteService.editLink(cid: cid, code: p.code, changes: ["requestApproval": on])
        }
    }
}

/// The page's alert and confirmations, apart so the page's body stays small for the type checker.
private struct GroupLinksDialogs: ViewModifier {
    @Binding var linkError: String?
    @Binding var confirmReset: Bool
    @Binding var confirmOff: Bool
    @Binding var confirmDeleteAll: Bool
    @Binding var revokeTarget: GroupLink?
    let onReset: () -> Void
    let onOff: () -> Void
    let onDeleteAll: () -> Void
    let onRevoke: (GroupLink) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Couldn't change the link",
                   isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(linkError ?? "") }
            .confirmationDialog("Reset Link", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Link", role: .destructive) { onReset() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("A new link replaces this one, and the current link stops working for everyone who has it.") }
            .confirmationDialog("Turn Off Link", isPresented: $confirmOff, titleVisibility: .visible) {
                Button("Turn Off Link", role: .destructive) { onOff() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Nobody will be able to join with this link. You can make a new one later.") }
            .confirmationDialog("Delete All Revoked", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { onDeleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Revoked links are removed from this list for good.") }
            .confirmationDialog("Revoke Link",
                                isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }),
                                titleVisibility: .visible, presenting: revokeTarget) { l in
                Button("Revoke", role: .destructive) { onRevoke(l) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("The link stops working at once. It moves to Revoked Links.") }
    }
}

// MARK: - The primary link card

private struct PrimaryLinkCard: View {
    let link: GroupLink?
    let working: Bool
    let onCopy: (GroupLink) -> Void
    let onShareInApp: (GroupLink) -> Void
    let onQR: (GroupLink) -> Void
    let onReset: () -> Void
    let onOff: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            pill
            buttons
            if let link { JoinedFacesRow(link: link) }
        }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Text(link?.shortURL ?? "No invite link")
                .font(.system(size: 17))
                .foregroundStyle(link == nil ? Color.secondary : Color.primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
            if let link {
                Menu {
                    Button { onCopy(link) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { onQR(link) } label: { Label("QR Code", systemImage: "qrcode") }
                    Button { onReset() } label: { Label("Reset Link", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { onOff() } label: { Label("Turn Off Link", systemImage: "xmark.circle") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(working)
                .accessibilityLabel("More")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 52)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
    }

    @ViewBuilder private var buttons: some View {
        if let link {
            HStack(spacing: 8) {
                Button { onCopy(link) } label: { LinkCapsuleLabel(title: "Copy", icon: "doc.on.doc") }
                    .buttonStyle(.plain)
                Menu {
                    Button { onShareInApp(link) } label: { Label("Send in Fariin", systemImage: "paperplane") }
                    ShareLink(item: URL(string: link.url) ?? URL(string: "https://fariin.com")!) {
                        Label("Other Apps", systemImage: "square.and.arrow.up")
                    }
                } label: { LinkCapsuleLabel(title: "Share", icon: "square.and.arrow.up") }
            }
        } else {
            Button(action: onCreate) { LinkCapsuleLabel(title: working ? "Creating…" : "Create Link", icon: "link") }
                .buttonStyle(.plain)
                .disabled(working)
        }
    }
}

/// A 52pt round blue button face (the card's Copy and Share).
private struct LinkCapsuleLabel: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(Color(hex: 0x2392FE)))
            .contentShape(Capsule())
    }
}

/// Up to three faces of the first people in, and how many came by the link.
private struct JoinedFacesRow: View {
    let link: GroupLink

    var body: some View {
        HStack(spacing: 8) {
            if !link.joined.isEmpty {
                HStack(spacing: -8) {
                    ForEach(link.joined.prefix(3)) { f in
                        AvatarView(name: f.name, photoUrl: f.photoUrl, size: 24)
                            .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                    }
                }
            }
            Text(line).font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var line: String {
        switch link.usedCount {
        case 0: return "No one joined yet"
        case 1: return "1 person joined"
        default: return "\(link.usedCount) people joined"
        }
    }
}

// MARK: - One link row

struct GroupLinkRow: View {
    let link: GroupLink

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(GroupLinkLook.colour(link)))
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title).font(.system(size: 17)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(GroupLinkLook.statusLine(link)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// How a link looks by its state: the icon colour and the line under its name.
enum GroupLinkLook {
    private static let day: Double = 86_400_000

    static func colour(_ l: GroupLink) -> Color {
        let now = Date().timeIntervalSince1970 * 1000
        switch l.state(now: now) {
        case .revoked: return Color(uiColor: .systemGray)
        case .expired, .usedUp: return .red
        case .active:
            if l.isPrimary { return Color(hex: 0x2392FE) }
            return nearEnd(l, now: now) ? .orange : .green
        }
    }

    /// Within a day of its time limit, or with at most a fifth of its uses left.
    static func nearEnd(_ l: GroupLink, now: Double) -> Bool {
        if l.expireAt > 0 && l.expireAt - now < day { return true }
        if l.usageLimit > 0 && Double(l.usageLimit - l.usedCount) <= Double(l.usageLimit) * 0.2 { return true }
        return false
    }

    static func statusLine(_ l: GroupLink) -> String {
        let now = Date().timeIntervalSince1970 * 1000
        switch l.state(now: now) {
        case .revoked: return joined(l) + " · Revoked"
        case .expired: return joined(l) + " · Expired"
        case .usedUp: return joined(l) + " · Used up"
        case .active:
            var parts = [joined(l)]
            if l.requestApproval { parts.append("Needs approval") }
            if l.expireAt > 0 { parts.append(timeLeft(l.expireAt - now) + " left") }
            return parts.joined(separator: " · ")
        }
    }

    private static func joined(_ l: GroupLink) -> String {
        if l.usageLimit > 0 && !l.requestApproval { return "\(l.usedCount) of \(l.usageLimit) joined" }
        return l.usedCount == 0 ? "No one joined" : "\(l.usedCount) joined"
    }

    static func timeLeft(_ ms: Double) -> String {
        let minutes = Int(max(0, ms) / 60_000)
        if minutes < 60 { return minutes <= 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }
}

/// The link handed to the Send To sheet, as an `Identifiable` for `.sheet(item:)`.
private struct LinkShareText: Identifiable { let id: String }

/// Create (link nil) or edit one link.
struct LinkEditTarget: Identifiable {
    let link: GroupLink?
    let id = UUID()
}

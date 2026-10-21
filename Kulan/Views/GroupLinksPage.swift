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

/// The last list seen per group (owner 2026-10-20: a spinner every time the page opened). The page
/// paints from it at once and refreshes behind, as the chat lists do.
/// ⛔ NO SPINNER ON OPEN (owner 2026-10-21: "every time I enter, it is loading"). The reference app
/// draws this page from links it already holds on the phone and refreshes behind it. Ours: the last
/// answer is kept in memory AND on disk (one small file per group), and Group Settings fetches it
/// ahead, so the page opens on real links and the server copy replaces them quietly.
@MainActor enum GroupLinksCache {
    static var lists: [String: GroupLinkList] = [:]

    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("groupLinks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ cid: String) -> URL? {
        guard KulanApp.safeSegment(cid) else { return nil }
        return dir?.appendingPathComponent("\(cid).json")
    }

    /// Memory first, then the saved file.
    static func list(_ cid: String) -> GroupLinkList? {
        if let l = lists[cid] { return l }
        guard let url = file(cid), let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let l = GroupLinkList(raw)
        lists[cid] = l
        return l
    }

    static func store(cid: String, list: GroupLinkList, raw: [String: Any]) {
        lists[cid] = list
        guard let url = file(cid), JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Fetched ahead (Group Settings), so the page opens already filled.
    static func warm(_ cid: String) {
        Task { _ = try? await GroupInviteService.listLinks(cid: cid) }
    }
}

struct GroupLinksPage: View {
    let cid: String
    let groupTitle: String

    init(cid: String, groupTitle: String) {
        self.cid = cid
        self.groupTitle = groupTitle
        _list = State(initialValue: GroupLinksCache.list(cid))
    }

    @State private var list: GroupLinkList?
    /// The group, for the QR card's photo and member count (owner 2026-10-20).
    private var groupConv: Conversation? { ConversationsRepository.shared.conversations.first { $0.id == cid } }
    @State private var loadError: String?
    @State private var working = false
    @State private var linkError: String?
    @State private var confirmReset = false
    @State private var confirmOff = false
    @State private var confirmDeleteAll = false
    @State private var revokeTarget: GroupLink?
    @State private var editTarget: LinkEditTarget?
    @State private var qrLink: GroupLink?
    @State private var publicQR = false
    @State private var triedAutoLink = false
    /// The link whose own sheet is up (owner 2026-10-20: a tap opens a sheet, not a menu).
    @State private var detailLink: GroupLink?
    /// What the sheet asked for once it is down (a page sheet cannot open over it).
    @State private var afterDetail: (() -> Void)?
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
            .sheet(item: $detailLink, onDismiss: {
                let next = afterDetail; afterDetail = nil
                next?()
            }) { l in
                GroupLinkSheet(cid: cid, link: l,
                               onCopy: { copy(l) },
                               onSend: { afterDetail = { shareText = l.url } },
                               onQR: { afterDetail = { qrLink = l } },
                               onEdit: { afterDetail = { editTarget = LinkEditTarget(link: l) } },
                               onRevoke: { afterDetail = { revokeTarget = l } },
                               onDelete: { afterDetail = { delete(l) } })
            }
            .sheet(isPresented: $publicQR) {
                GroupLinkQRSheet(title: groupTitle, link: publicURL ?? "https://fariin.com",
                                 photo: groupConv?.avatarUrl, memberCount: groupConv?.users.count)
            }
            .sheet(item: $qrLink) { l in GroupLinkQRSheet(title: groupTitle, link: l.url, photo: groupConv?.avatarUrl, memberCount: groupConv?.users.count) }
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
            // ⛔ A PUBLIC GROUP'S LINK IS ITS PUBLIC NAME (owner 2026-10-20: the page said "No invite
            // link"): fariin.com/<name> on top, as the reference app shows a public group's address.
            // Changed under Group Type. Extra links stay under More Links.
            if let url = publicURL {
                publicSection(url)
            } else {
                primarySection(list.primary)
                if let p = list.primary {
                    linkActionsSection
                    approvalSection(p)
                }
            }
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

    /// The group's public address when it is public, else nil.
    private var publicURL: String? {
        guard let c = groupConv, c.isPublic, !c.publicName.isEmpty else { return nil }
        return "https://fariin.com/\(c.publicName)"
    }

    private func publicSection(_ url: String) -> some View {
        Section {
            VStack(spacing: 14) {
                Button { copyText(url) } label: {
                    HStack(spacing: 8) {
                        Text(url.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 17)).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("Tap to copy").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).frame(height: 52).frame(maxWidth: .infinity)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                HStack(spacing: 0) {
                    // The owner's own icons (2026-10-21).
                    publicCircle("ic_link_copy", "Copy") { copyText(url) }
                    publicCircle("ic_link_send", "Send") { shareText = url }
                    ShareLink(item: URL(string: url) ?? URL(string: "https://fariin.com")!) {
                        PosterActionIcon(icon: "square.and.arrow.up", diameter: 54, onPhoto: false, label: "Share")
                    }
                    .buttonStyle(.plain)
                    publicCircle("ic_qr", "QR Code") { publicQR = true }
                }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        } header: {
            Text("Public Link")
        } footer: {
            Text("Anyone can find this group and join it with this link. Change it under Group Type.")
        }
    }

    private func publicCircle(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { PosterActionIcon(icon: icon, diameter: 54, onPhoto: false, label: title) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
    }

    private func primarySection(_ p: GroupLink?) -> some View {
        Section {
            PrimaryLinkCard(link: p, working: working,
                            onCopy: copy, onShareInApp: { shareText = $0.url }, onQR: { qrLink = $0 },
                            onCreate: createPrimary, onJoined: { detailLink = $0 })
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        } header: {
            Text("Invite Link")
        } footer: {
            Text(p == nil ? "This group has no invite link. People can only be added by its members."
                          : "Anyone with Fariin who has this link can join the group.")
        }
    }

    /// Reset and Turn Off as plain rows (owner 2026-10-19: they hid behind the ⋯), each asked first.
    private var linkActionsSection: some View {
        Section {
            Button { confirmReset = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 17)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Link")
                        Text("Makes a new link. The old one stops working.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .disabled(working)
            // ⛔ NO TURN OFF (owner 2026-10-20): a group always has its link. Reset makes a new one and
            // stops the old; there is no way to have none.
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
                Button { detailLink = l } label: { GroupLinkRow(link: l) }
                    .buttonStyle(.plain)
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
                Button { detailLink = l } label: { GroupLinkRow(link: l) }
                    .buttonStyle(.plain)
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
            let fresh = try await GroupInviteService.listLinks(cid: cid)
            list = fresh   // listLinks has saved it (memory + disk)
            loadError = nil
            // A group with no link (turned off before Turn Off went away): one is made at once.
            // Once per page, for a loaded group that is open (audit 2026-10-20: an ended group tried
            // on every open, and a public one not loaded yet got a stray private link).
            if fresh.primary == nil, !working, !triedAutoLink, let c = groupConv,
               !c.isPublic, c.groupMod.state == "ok" {
                triedAutoLink = true
                createPrimary()
            }
        } catch {
            if list == nil {
                loadError = GroupInviteService.errorText(error, "The links could not be loaded. Try again.")
            } else {
                linkError = GroupInviteService.errorText(error, "The links could not be refreshed. Try again.")
            }
        }
    }

    private func copy(_ l: GroupLink) { copyText(l.url) }

    private func copyText(_ url: String) {
        UIPasteboard.general.string = url
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
            .alert("Reset Link", isPresented: $confirmReset) {
                Button("Reset Link", role: .destructive) { onReset() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("A new link replaces this one, and the current link stops working for everyone who has it.") }
            .alert("Turn Off Link", isPresented: $confirmOff) {
                Button("Turn Off Link", role: .destructive) { onOff() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Nobody will be able to join with this link. You can make a new one later.") }
            .alert("Delete All Revoked", isPresented: $confirmDeleteAll) {
                Button("Delete All", role: .destructive) { onDeleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Revoked links are removed from this list for good.") }
            .alert("Revoke Link",
                                isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }), presenting: revokeTarget) { l in
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
    let onCreate: () -> Void
    /// "N people joined" opens the link's own sheet with who they are (owner 2026-10-20).
    var onJoined: (GroupLink) -> Void = { _ in }

    // ⛔ NOTHING HIDDEN (owner 2026-10-19: the ⋯ and the Share menu kept the actions out of sight).
    // Tap the link to copy it; four named glass circles under it; Reset and Turn Off are rows on
    // the page below this card.
    var body: some View {
        VStack(spacing: 14) {
            pill
            buttons
            if let link {
                Button { onJoined(link) } label: {
                    HStack(spacing: 4) {
                        JoinedFacesRow(link: link)
                        if link.usedCount > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(link.usedCount == 0)
                .accessibilityHint("Shows who joined with this link")
            }
        }
    }

    private var pill: some View {
        Button { if let link { onCopy(link) } } label: {
            HStack(spacing: 8) {
                Text(link?.shortURL ?? "No invite link")
                    .font(.system(size: 17))
                    .foregroundStyle(link == nil ? Color.secondary : Color.primary)
                    .lineLimit(1).truncationMode(.middle)
                if link != nil {
                    Text("Tap to copy").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(link == nil)
        .accessibilityLabel(link.map { "\($0.shortURL), copy" } ?? "No invite link")
    }

    @ViewBuilder private var buttons: some View {
        if let link {
            HStack(spacing: 0) {
                // The owner's own icons (2026-10-21).
                circle("ic_link_copy", "Copy") { onCopy(link) }
                circle("ic_link_send", "Send") { onShareInApp(link) }
                ShareLink(item: URL(string: link.url) ?? URL(string: "https://fariin.com")!) {
                    PosterActionIcon(icon: "square.and.arrow.up", diameter: 54, onPhoto: false, label: "Share")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share to other apps")
                circle("ic_qr", "QR Code") { onQR(link) }
            }
        } else {
            Button(action: onCreate) { LinkCapsuleLabel(title: working ? "Creating…" : "Create Link", icon: "link") }
                .buttonStyle(.plain)
                .disabled(working)
        }
    }

    private func circle(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PosterActionIcon(icon: icon, diameter: 54, onPhoto: false, label: title)
        }
        // Plain, or a List row fires every button in it on one tap.
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A 52pt round blue button face (the card's Create Link when there is none).
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

/// ⛔ ONE LINK'S OWN SHEET (owner 2026-10-20: "a tap opens a sheet, and I can see who joined with
/// this link"). Our own layout: the link in the pill that copies, a line saying where it stands,
/// the glass circles to hand it on, then People Joined (newest first, with when), and at the bottom
/// Revoke for a live link or Delete for one that is over. Edit sits top right while it is live.
struct GroupLinkSheet: View {
    let cid: String
    let link: GroupLink
    let onCopy: () -> Void
    let onSend: () -> Void
    let onQR: () -> Void
    let onEdit: () -> Void
    let onRevoke: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var people: [GroupInviteService.LinkJoiner]?
    @State private var failed = false
    @State private var copied = false

    private var live: Bool { link.state(now: Date().timeIntervalSince1970 * 1000) == .active }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        pill
                        Text(GroupLinkLook.statusLine(link))
                            .font(.footnote).foregroundStyle(.secondary)
                        if live { actions }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                peopleSection
                // The main link has its own Reset and Turn Off on the page; its sheet only shows it.
                if !link.isPrimary { Section {
                    if live {
                        Button(role: .destructive) { onRevoke(); dismiss() } label: {
                            Text("Revoke Link").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button(role: .destructive) { onDelete(); dismiss() } label: {
                            Text("Delete Link").frame(maxWidth: .infinity)
                        }
                    }
                } }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(link.name.isEmpty ? "Invite Link" : link.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
                if live && !link.isPrimary {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { onEdit(); dismiss() }
                    }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var pill: some View {
        Button {
            onCopy()
            withAnimation(.easeInOut(duration: 0.2)) { copied = true }
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); withAnimation { copied = false } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: copied ? "checkmark" : "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                Text(link.shortURL).font(.subheadline).foregroundStyle(live ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 16).frame(height: 44).frame(maxWidth: .infinity)
            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!live)
        .padding(.horizontal, 20)
        .accessibilityLabel("Invite link. Copy")
    }

    private var actions: some View {
        HStack(spacing: 0) {
            circle("paperplane", "Send") { onSend(); dismiss() }
            if let url = URL(string: link.url) {
                ShareLink(item: url) {
                    PosterActionIcon(icon: "square.and.arrow.up", diameter: 54, onPhoto: false, label: "Share")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            circle("qrcode", "QR Code") { onQR(); dismiss() }
        }
        .padding(.horizontal, 20)
    }

    private func circle(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PosterActionIcon(icon: icon, diameter: 54, onPhoto: false, label: title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var peopleSection: some View {
        Section {
            if let people {
                if people.isEmpty {
                    Text("No one has joined with this link yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(people) { p in
                        HStack(spacing: 12) {
                            AvatarView(name: p.name, photoUrl: p.photoUrl, size: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).lineLimit(1)
                                Text(Self.when(p)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .opacity(p.member ? 1 : 0.55)
                    }
                }
            } else if failed {
                Button("Couldn't load. Try again") { Task { await load() } }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            Text(people.map { $0.isEmpty ? "People Joined" : "\($0.count) Joined" } ?? "People Joined")
        }
    }

    private static func when(_ p: GroupInviteService.LinkJoiner) -> String {
        let left = p.member ? "" : " · Left the group"
        guard let at = p.at else { return "Joined" + left }
        let cal = Calendar.current
        let time = at.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(at) { return "Joined today at \(time)" + left }
        if cal.isDateInYesterday(at) { return "Joined yesterday at \(time)" + left }
        return "Joined \(at.formatted(.dateTime.day().month(.abbreviated))) at \(time)" + left
    }

    private func load() async {
        failed = false
        do { people = try await GroupInviteService.linkJoiners(cid: cid, code: link.code) }
        catch { if people == nil { failed = true } }
    }
}

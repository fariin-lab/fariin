import SwiftUI
import FirebaseFirestore
import FirebaseFunctions

// Group invite links (reference-style). 2026-10-19 groups v2 step 4: THE SERVER OWNS THEM. The
// app no longer reads or writes `invites/{code}` (firestore.rules says no to both); every link is
// made, changed, revoked, deleted and listed through the functions-groups callables
// (createGroupLink, editGroupLink, revokeGroupLink, deleteGroupLink, listGroupLinks, getShareLink).
// A group has one primary link (the one Share hands out) and any number of extra links with a
// name, a time limit, a usage limit or admin approval. Joining is still joinGroupViaInvite.

// MARK: - Models

/// One invite link as `listGroupLinks` and the other link callables send it.
struct GroupLink: Identifiable, Equatable {
    enum State { case active, expired, usedUp, revoked }
    struct Face: Identifiable, Equatable {
        let uid: String
        let name: String
        let photoUrl: String?
        var id: String { uid }
    }
    let code: String
    var name: String
    var isPrimary: Bool
    var createdBy: String
    var createdByName: String
    var createdAt: Double     // ms since epoch
    var expireAt: Double      // ms since epoch, 0 = never
    var usageLimit: Int       // 0 = unlimited
    var usedCount: Int
    var requestApproval: Bool
    var revoked: Bool
    var joined: [Face]        // the first few people in, still in the group
    var id: String { code }

    // An https link, not kulan://. This is the string an admin copies and sends to somebody who
    // by definition is NOT in the group yet, and quite possibly does not have Fariin at all — the
    // one audience a custom scheme cannot reach. See KulanApp.route(from:).
    var url: String { KulanApp.groupLink(code: code) }
    /// The link as the page prints it: no "https://".
    var shortURL: String { url.replacingOccurrences(of: "https://", with: "") }
    /// A named link shows its name; any other its address.
    var title: String { name.isEmpty ? shortURL : name }

    /// Worked out here, not taken from the server's answer, so a link that expires while the page
    /// is open turns red without a reload.
    func state(now: Double = Date().timeIntervalSince1970 * 1000) -> State {
        if revoked { return .revoked }
        if expireAt > 0 && expireAt <= now { return .expired }
        if usageLimit > 0 && usedCount >= usageLimit { return .usedUp }
        return .active
    }

    init?(_ d: [String: Any]) {
        guard let code = d["code"] as? String, KulanApp.safeSegment(code) else { return nil }
        self.code = code
        self.name = d["name"] as? String ?? ""
        self.isPrimary = d["isPrimary"] as? Bool ?? false
        self.createdBy = d["createdBy"] as? String ?? ""
        self.createdByName = d["createdByName"] as? String ?? ""
        self.createdAt = (d["createdAt"] as? NSNumber)?.doubleValue ?? 0
        self.expireAt = (d["expireAt"] as? NSNumber)?.doubleValue ?? 0
        self.usageLimit = (d["usageLimit"] as? NSNumber)?.intValue ?? 0
        self.usedCount = (d["usedCount"] as? NSNumber)?.intValue ?? 0
        self.requestApproval = d["requestApproval"] as? Bool ?? false
        self.revoked = d["revoked"] as? Bool ?? false
        self.joined = (d["joined"] as? [[String: Any]] ?? []).compactMap { f in
            guard let uid = f["uid"] as? String else { return nil }
            let ph = f["photoUrl"] as? String ?? ""
            return Face(uid: uid, name: f["name"] as? String ?? "", photoUrl: ph.isEmpty ? nil : ph)
        }
    }
}

/// The link page's three lists (`listGroupLinks`).
struct GroupLinkList: Equatable {
    var primary: GroupLink?
    var links: [GroupLink]
    var revoked: [GroupLink]
    var isOwner: Bool

    init(_ d: [String: Any]) {
        primary = (d["primary"] as? [String: Any]).flatMap { GroupLink($0) }
        links = (d["links"] as? [[String: Any]] ?? []).compactMap { GroupLink($0) }
        revoked = (d["revoked"] as? [[String: Any]] ?? []).compactMap { GroupLink($0) }
        isOwner = d["isOwner"] as? Bool ?? false
    }
}

struct JoinRequest: Identifiable, Equatable {
    let uid: String
    var name: String
    var photo: String?
    var id: String { uid }
    init(uid: String, data: [String: Any]) {
        self.uid = uid
        self.name = data["name"] as? String ?? "New member"
        self.photo = data["photo"] as? String
    }
}

// Identifiable wrapper so a kulan://g/<code> can drive a .sheet(item:).
struct InviteCodeItem: Identifiable { var id: String { code }; let code: String }

// MARK: - Service

enum GroupInviteService {
    private static var db: Firestore { FirestoreHub.db }
    private static var fns: Functions { Functions.functions(region: "me-central1") }

    // MARK: Links (all on the server, 2026-10-19 step 4)

    private static func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        let res = try await fns.httpsCallable(name).call(args)
        return res.data as? [String: Any] ?? [:]
    }

    /// The link a link callable answered with; a reply without one is an error, never a silent nil.
    private static func link(from d: [String: Any]) throws -> GroupLink {
        guard let l = (d["link"] as? [String: Any]).flatMap({ GroupLink($0) }) else {
            throw NSError(domain: "GroupLinks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The server sent back no link. Try again."])
        }
        return l
    }

    /// The link page: the primary link, the others this admin may see, the revoked ones.
    static func listLinks(cid: String) async throws -> GroupLinkList {
        let raw = try await call("listGroupLinks", ["cid": cid])
        let list = GroupLinkList(raw)
        await GroupLinksCache.store(cid: cid, list: list, raw: raw)
        return list
    }

    /// A new primary link (the first one, or Reset Link: the old one is revoked in the same step).
    /// The approval setting carries over from the old one unless `requestApproval` is given.
    static func createPrimaryLink(cid: String, requestApproval: Bool? = nil) async throws -> GroupLink {
        var args: [String: Any] = ["cid": cid, "primary": true]
        if let requestApproval { args["requestApproval"] = requestApproval }
        return try link(from: try await call("createGroupLink", args))
    }

    /// An extra link. `options`: name, expireAt (ms, 0 = none), usageLimit (0 = none), requestApproval.
    static func createLink(cid: String, options: [String: Any]) async throws -> GroupLink {
        var args = options
        args["cid"] = cid
        return try link(from: try await call("createGroupLink", args))
    }

    /// Changes only the keys given; the server keeps the rest.
    static func editLink(cid: String, code: String, changes: [String: Any]) async throws -> GroupLink {
        var args = changes
        args["cid"] = cid
        args["code"] = code
        return try link(from: try await call("editGroupLink", args))
    }

    static func revokeLink(cid: String, code: String) async throws -> GroupLink {
        try link(from: try await call("revokeGroupLink", ["cid": cid, "code": code]))
    }

    /// One person who came in by a link, for the link's sheet. `at` is nil for a join from before
    /// the full list was kept.
    struct LinkJoiner: Identifiable {
        let uid: String
        let name: String
        let photoUrl: String?
        let at: Date?
        let member: Bool
        var id: String { uid }
    }

    /// Who joined by this link, newest first (groupLinkJoiners; link managers only).
    static func linkJoiners(cid: String, code: String) async throws -> [LinkJoiner] {
        let d = try await call("groupLinkJoiners", ["cid": cid, "code": code])
        return (d["people"] as? [[String: Any]] ?? []).compactMap { p in
            guard let uid = p["uid"] as? String else { return nil }
            let at = (p["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return LinkJoiner(uid: uid, name: p["name"] as? String ?? "Member",
                              photoUrl: p["photoUrl"] as? String, at: at,
                              member: p["member"] as? Bool ?? true)
        }
    }

    static func deleteLink(cid: String, code: String) async throws {
        _ = try await call("deleteGroupLink", ["cid": cid, "code": code])
    }

    /// Every revoked link this admin may change. Returns how many went.
    @discardableResult
    static func deleteAllRevoked(cid: String) async throws -> Int {
        let d = try await call("deleteGroupLink", ["cid": cid, "allRevoked": true])
        return (d["deleted"] as? NSNumber)?.intValue ?? 0
    }

    /// The primary link's code for an admin who shares it; nil when the group has none.
    static func shareCode(cid: String) async throws -> String? {
        let d = try await call("getShareLink", ["cid": cid])
        guard let code = d["code"] as? String, KulanApp.safeSegment(code) else { return nil }
        return code
    }

    /// Words for a failed link change. The server's own sentence when it refused for a reason the
    /// person can act on; otherwise `fallback` (offline, timed out, a server fault).
    static func errorText(_ error: Error, _ fallback: String) -> String {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain else {
            return ns.domain == "GroupLinks" ? ns.localizedDescription : fallback
        }
        let told: [FunctionsErrorCode] = [.invalidArgument, .permissionDenied, .notFound,
                                          .failedPrecondition, .resourceExhausted, .deadlineExceeded]
        if told.contains(where: { $0.rawValue == ns.code }) { return ns.localizedDescription }
        return NetworkState.shared.isOnline ? fallback : "No internet connection. Try again."
    }

    /// Join via the Cloud Function. Returns (status, cid): "joined" / "already" / "requested".
    static func joinViaInvite(code: String) async throws -> (status: String, cid: String) {
        let res = try await fns.httpsCallable("joinGroupViaInvite").call(["code": code])
        let d = res.data as? [String: Any] ?? [:]
        return (d["status"] as? String ?? "", d["cid"] as? String ?? "")
    }

    static func approveJoin(cid: String, uid: String) async throws {
        _ = try await fns.httpsCallable("approveJoinRequest").call(["cid": cid, "uid": uid])
    }
    static func denyJoin(cid: String, uid: String) async throws {
        _ = try await fns.httpsCallable("denyJoinRequest").call(["cid": cid, "uid": uid])
    }

    /// Owner-only: permanently delete the whole group (messages + invites + conversation).
    static func deleteGroup(cid: String) async throws {
        _ = try await fns.httpsCallable("deleteGroup").call(["cid": cid])
    }

    /// Live pending join-requests for a group (admins show these).
    static func joinRequests(cid: String, _ cb: @escaping ([JoinRequest]) -> Void) -> ListenerRegistration {
        db.collection("conversations").document(cid).collection("joinRequests")
            .addSnapshotListener { snap, _ in
                // A refused or failed read keeps the last list, so waiting people are never shown
                // as "No one is waiting" (audit 2026-10-20).
                guard let snap else { return }
                cb(snap.documents.map { JoinRequest(uid: $0.documentID, data: $0.data()) })
            }
    }
}

// MARK: - Invite link sheet (admin)

/// The admin's link page. 2026-10-19 groups v2 step 4: the page itself is `GroupLinksPage`
/// (GroupLinksPage.swift); this keeps the name and initialiser every caller already uses.
/// `initialCode` is no longer read: the page asks the server (listGroupLinks).
struct InviteLinkSheet: View {
    let cid: String
    let groupTitle: String
    let groupPhoto: String?
    var initialCode: String = ""
    /// Pushed as a full page (owner 2026-10-18: "open a full page, not a sheet"): no stack of its own
    /// and no Done; the page's back button closes it.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        InviteStackIfNeeded(on: !embedded) {
            GroupLinksPage(cid: cid, groupTitle: groupTitle)
                .toolbar { if !embedded { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } } }
        }
    }
}

// MARK: - Join group sheet (a group link: its card, the link itself, a QR code, kulan://g/<code>)

/// ⛔ THE REFERENCE APP'S JOIN SHEET — owner 2026-10-18, with its screenshots. A group link's first tap
/// opens this, not the group: X top left, the big group photo, the name, "N members", a line, then
/// up to three of MY contacts who are already in it ("<Name> and 2 others already joined this
/// group", our own words), and one blue Join Group capsule. A group I am already in never shows it
/// (`GroupLinkDoor.open` goes to the chat; a stale answer here closes and does the same).
///
/// Everything on it comes from `groupLinkPreview` (`GroupLinkDoor`), looked up when the card was
/// drawn, so it is usually filled on its first frame. The join itself is the old path,
/// `joinGroupViaInvite`, with its approval rule: a group that reviews requests says Request to Join,
/// then Request Sent.
struct JoinGroupSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var preview: GroupLinkPreview?
    @State private var refusedText: String?
    @State private var failedText: String?
    @State private var joining = false
    @State private var requestSent = false
    @State private var joinError: String?
    @State private var contentHeight: CGFloat = 380

    private static let blue = Color(hex: 0x2392FE)

    var body: some View {
        VStack(spacing: 0) {
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

            content
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(max(300, contentHeight))])
        .presentationDragIndicator(.hidden)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let p = preview {
            groupBody(p)
        } else if let why = refusedText {
            // The server says which way the link died (expired, used up, turned off) in `why`.
            message(symbol: "link", why, title: "Can't join with this link")
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

    @ViewBuilder private func groupBody(_ p: GroupLinkPreview) -> some View {
        VStack(spacing: 0) {
            AvatarView(name: p.title, photoUrl: p.photoUrl, size: 100)
                .padding(.top, 2)
            Text(p.title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            Text(p.membersLine)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            // 2026-10-19 groups v2 step 4: what the group is about, as its admins wrote it.
            if !p.description.isEmpty {
                Text(p.description)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
            }

            // Only when someone I chat with is in it (owner 2026-10-21): strangers' faces and a
            // second "N members" under the first one told me nothing.
            if !p.faces.isEmpty, !p.mutuals.isEmpty {
                Divider().padding(.horizontal, 20).padding(.top, 20)
                mutualsRow(p).padding(.top, 16).padding(.horizontal, 24)
            }

            // A refusal (banned, link off) first: it is why Join is grey (audit 2026-10-26 item 19).
            if let why = refusedText ?? joinError {
                Text(why)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            } else if requestSent || p.requested {
                Text("An admin will review your request.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
            }

            capsuleButton(buttonTitle(p), enabled: refusedText == nil && !joining && !(requestSent || p.requested),
                          loading: joining) { join(p) }
                .padding(.top, 24)
        }
    }

    private func buttonTitle(_ p: GroupLinkPreview) -> String {
        if p.isChannel { return joining ? "Following…" : "Follow Channel" }   // 2026-10-28
        if requestSent || p.requested { return "Request Sent" }
        if joining { return p.needsApproval ? "Sending…" : "Joining…" }
        return p.needsApproval ? "Request to Join" : "Join Group"
    }

    /// Up to three small faces, overlapping (people I talk to first), and the ones I know by name.
    @ViewBuilder private func mutualsRow(_ p: GroupLinkPreview) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(p.faces.prefix(3)) { m in
                    AvatarView(name: m.name, photoUrl: m.photoUrl, size: 28)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            Text(p.mutuals.isEmpty ? p.membersLine : mutualsLine(p))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }

    private func mutualsLine(_ p: GroupLinkPreview) -> String {
        guard let first = p.mutuals.first else { return "" }
        let others = max(0, max(p.mutualCount, p.mutuals.count) - 1)
        if others == 0 { return "\(first.name) already joined this group" }
        return "\(first.name) and \(others) \(others == 1 ? "other" : "others") already joined this group"
    }

    /// `loading`: the button KEEPS ITS BLUE and shows a white spinner in place of the words (owner
    /// 2026-10-24: tapping Join turned it grey with "Joining…", the reference keeps the colour and
    /// spins). Still not tappable while it spins.
    private func capsuleButton(_ title: String, enabled: Bool, loading: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(loading ? 0 : 1)
                if loading { BusyArc.small(.white) }
            }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled || loading ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(enabled || loading ? Self.blue : Color(.tertiarySystemFill)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Busy is not disabled: a disabled button is drawn faded (owner 2026-10-26). Taps stop instead.
        .disabled(!enabled && !loading)
        .allowsHitTesting(!loading)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func message(symbol: String, _ text: String, title: String? = nil) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
            if let title {
                Text(title).font(.system(size: 19, weight: .semibold)).multilineTextAlignment(.center)
            }
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
        // The answer the card's lookup already has: on screen in the first frame.
        if let hit = GroupLinkDoor.cached(code) {
            if openIfMember(hit) { return }
            preview = hit
        }
        switch await GroupLinkDoor.load(code) {
        case .found(let p):
            if openIfMember(p) { return }
            preview = p
        case .refused(let why):
            // With a cached card on screen too: Join goes grey with the server's words (audit
            // 2026-10-26 item 19). Without one, the "Can't join with this link" page as before.
            refusedText = why
        case .failed(let why):
            if preview == nil { failedText = why }
        }
    }

    /// A member never sees the sheet: it closes and the chat opens.
    private func openIfMember(_ p: GroupLinkPreview) -> Bool {
        guard p.isMember, let cid = p.cid else { return false }
        openChat(cid, p)
        return true
    }

    private func openChat(_ cid: String, _ p: GroupLinkPreview) {
        let router = AppRouter.shared
        router.pendingInviteCode = nil
        router.pendingChatName = p.title
        router.pendingChatPhoto = p.photoUrl
        router.pendingChatId = cid
        dismiss()
    }

    private func join(_ p: GroupLinkPreview) {
        guard !joining else { return }
        guard NetworkState.shared.isOnline else { joinError = "No internet connection. Try again."; return }
        joining = true
        joinError = nil
        Task {
            do {
                let r = try await GroupInviteService.joinViaInvite(code: code)
                switch r.status {
                case "joined", "already", "following":   // "following": a channel's link (2026-10-28)
                    GroupLinkDoor.noteJoined(code, cid: r.cid)
                    openChat(r.cid, p)
                case "requested":
                    GroupLinkDoor.noteRequested(code)
                    requestSent = true
                    Haptics.notify(.success)
                    // Closes by itself once "Request Sent" has been read (owner 2026-10-21).
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        dismiss()
                    }
                default:
                    joinError = "Couldn't join. The link may be invalid."
                }
            } catch {
                // Banned sticks: Join goes grey with the server's words (audit 2026-10-26 item 19).
                let words = (error as NSError).localizedDescription
                if words.localizedCaseInsensitiveContains("banned") { refusedText = words } else { joinError = words }
            }
            joining = false
        }
    }
}

/// A NavigationStack only when the screen is its own sheet; a pushed page already has one.
private struct InviteStackIfNeeded<Content: View>: View {
    let on: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        if on { NavigationStack { content() } } else { content() }
    }
}

/// The link handed to the Send To sheet, as an `Identifiable` for `.sheet(item:)`.
private struct InviteShareText: Identifiable { let id: String }

/// ⛔ A MEMBER'S LINK PAGE (owner 2026-10-19): when the admins let members share the link, a member
/// gets the link itself and the ways to send it, and nothing to change. The group's face and the link
/// in one card, then Copy Link, Send in Fariin, Share, QR Code.
struct GroupLinkShareView: View {
    let title: String
    let photo: String?
    let link: String
    @State private var shareText: String?
    @State private var showQR = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    AvatarView(name: title, photoUrl: photo, size: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(link).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .profileSurface(plain: card)

                VStack(spacing: 0) {
                    row("Copy Link", "doc.on.doc") {
                        UIPasteboard.general.string = link
                        Haptics.notify(.success)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut(duration: 0.25)) { copied = false }
                        }
                    }
                    Divider().padding(.leading, 16)
                    row("Send in Fariin", "paperplane") { shareText = link }
                    Divider().padding(.leading, 16)
                    ShareLink(item: URL(string: link) ?? URL(string: "https://fariin.com")!) {
                        rowLabel("Share", "ic_link_share")
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 16)
                    row("QR Code", "qrcode") { showQR = true }
                }
                .profileSurface(plain: card)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Group Link").navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
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
        .sheet(item: Binding(get: { shareText.map { InviteShareText(id: $0) } },
                             set: { shareText = $0?.id })) { t in
            ForwardPicker(shareText: t.id)
        }
        .sheet(isPresented: $showQR) { GroupLinkQRSheet(title: title, link: link, photo: photo) }
    }

    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, icon) }.buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(glyph: icon).font(.system(size: 18)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

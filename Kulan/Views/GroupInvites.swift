import SwiftUI
import FirebaseFirestore
import FirebaseFunctions

// Group invite links (reference-style). An invite is a top-level `invites/{code}` doc pointing at a
// group, with optional expiry + usage cap + "require admin approval". Any signed-in user can READ one
// (to resolve a kulan://g/<code> deep link); only a group admin can create/edit/revoke. Joining goes
// through the joinGroupViaInvite Cloud Function (admin SDK) so a stranger never writes the group doc.

// MARK: - Models

struct GroupInvite: Identifiable, Equatable {
    let code: String
    var cid: String
    var groupTitle: String
    var groupPhoto: String?
    var expireAt: Double      // ms since epoch, 0 = never
    var usageLimit: Int       // 0 = unlimited
    var usedCount: Int
    var requestApproval: Bool
    var revoked: Bool
    var id: String { code }

    // An https link, not kulan://. This is the string an admin copies and sends to somebody who
    // by definition is NOT in the group yet, and quite possibly does not have Fariin at all — the
    // one audience a custom scheme cannot reach. See KulanApp.route(from:).
    var url: String { KulanApp.groupLink(code: code) }
    var isExpired: Bool { expireAt > 0 && expireAt < Date().timeIntervalSince1970 * 1000 }
    var isFull: Bool { usageLimit > 0 && usedCount >= usageLimit }
    var isActive: Bool { !revoked && !isExpired && !isFull }

    init?(code: String, data: [String: Any]) {
        guard let cid = data["cid"] as? String else { return nil }
        self.code = code
        self.cid = cid
        self.groupTitle = data["groupTitle"] as? String ?? "Group"
        self.groupPhoto = (data["groupPhoto"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.expireAt = (data["expireAt"] as? NSNumber)?.doubleValue ?? 0
        self.usageLimit = (data["usageLimit"] as? NSNumber)?.intValue ?? 0
        self.usedCount = (data["usedCount"] as? NSNumber)?.intValue ?? 0
        self.requestApproval = data["requestApproval"] as? Bool ?? false
        self.revoked = data["revoked"] as? Bool ?? false
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
    private static var db: Firestore { Firestore.firestore() }
    private static var fns: Functions { Functions.functions(region: "me-central1") }

    static func randomCode(_ n: Int = 10) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // no look-alikes
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    /// Admin: create the group's primary invite link (replaces any existing one). Returns the code.
    @discardableResult
    static func createInvite(cid: String, groupTitle: String, groupPhoto: String?,
                             expireAt: Double = 0, usageLimit: Int = 0, requestApproval: Bool = false) async throws -> String {
        // Revoke any existing primary link first, so a group never ends up with two live links (one of
        // which the admin can no longer see or revoke). 2026-10-19: a failed revoke now stops here
        // and throws, instead of going on to make a second live link.
        let snap = try await db.collection("conversations").document(cid).getDocument()
        if let old = snap.data()?["inviteCode"] as? String, !old.isEmpty {
            try await db.collection("invites").document(old).updateData(["revoked": true])
        }
        let code = randomCode()
        try await db.collection("invites").document(code).setData([
            "cid": cid,
            "groupTitle": groupTitle,
            "groupPhoto": groupPhoto ?? "",
            "expireAt": expireAt,
            "usageLimit": usageLimit,
            "usedCount": 0,
            "requestApproval": requestApproval,
            "revoked": false,
            "createdBy": AuthService.shared.uid ?? "",
            "createdAt": FieldValue.serverTimestamp(),
        ])
        // Point the group at its current link so members/admins can find it. If that write fails the
        // new link is one nobody can see or revoke, so it is revoked again and the error goes up.
        do {
            try await db.collection("conversations").document(cid).updateData([
                "inviteCode": code, "updatedAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            try? await db.collection("invites").document(code).updateData(["revoked": true])
            throw error
        }
        return code
    }

    /// Admin: edit an existing invite's options in place.
    static func updateInvite(code: String, fields: [String: Any]) async throws {
        try await db.collection("invites").document(code).updateData(fields)
    }

    /// Admin: revoke the link and clear the group's pointer.
    static func revokeInvite(cid: String, code: String) async throws {
        try await db.collection("invites").document(code).updateData(["revoked": true])
        // Best effort on purpose: the link is already dead above, and a pointer left at a revoked
        // code reads as "no link" (GroupInvite.isActive) and is replaced by the next create.
        try? await db.collection("conversations").document(cid).updateData([
            "inviteCode": "", "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    static func fetchInvite(code: String) async -> GroupInvite? {
        // A code from a link is outside text (audit, 2026-09-24). `document(_:)` does not fail on a
        // bad id, it raises an ObjC exception `try?` cannot catch: an empty code, or a link like
        // /g/a%2Fb (decoded to "a/b", a collection path), crashed the app on tap. Such a code can
        // never be a real invite, so it takes the sheet's own "invalid" answer instead.
        guard !code.isEmpty, !code.contains("/"), code != ".", code != "..",
              !(code.hasPrefix("__") && code.hasSuffix("__")) else { return nil }
        guard let snap = try? await db.collection("invites").document(code).getDocument(),
              let data = snap.data() else { return nil }
        return GroupInvite(code: code, data: data)
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
                cb(snap?.documents.map { JoinRequest(uid: $0.documentID, data: $0.data()) } ?? [])
            }
    }
}

// MARK: - Invite link sheet (admin)

struct InviteLinkSheet: View {
    let cid: String
    let groupTitle: String
    let groupPhoto: String?
    var initialCode: String = ""
    /// Pushed as a full page (owner 2026-10-18: "open a full page, not a sheet"): no stack of its own
    /// and no Done; the page's back button closes it.
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var invite: GroupInvite?
    @State private var loading = true
    @State private var working = false
    @State private var confirmRevoke = false
    @State private var confirmNewLink = false

    private let expiryOptions: [(String, Double)] = [("Never", 0), ("1 day", 86_400), ("1 week", 604_800), ("1 month", 2_592_000)]
    private let limitOptions: [(String, Int)] = [("No limit", 0), ("10 uses", 10), ("50 uses", 50), ("100 uses", 100)]

    var body: some View {
        InviteStackIfNeeded(on: !embedded) {
            // ⛔ THE OWNER'S LAYOUT (2026-10-18, his picture): the Group Link switch with the link
            // under it; Share and Reset Link; Require Admin Approval with one line under it. Copy and
            // the QR code live in Share's menu now; expiry and usage limit left this page (a link that
            // already has them keeps them, the server still applies them).
            List {
                if loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
                } else {
                    let inv = invite.flatMap { $0.isActive ? $0 : nil }
                    Section {
                        Toggle("Group Link", isOn: Binding(
                            get: { inv != nil || working },
                            set: { on in if on { create() } else { revoke() } }))
                            .disabled(working)
                        if let inv {
                            Text(inv.url)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } footer: {
                        // The link's state in one line (owner 2026-10-19): how people get in, and who
                        // may hand the link out.
                        if let inv { Text(stateLine(inv)) }
                    }
                    if let inv {
                        Section {
                            Menu {
                                Button { shareText = inv.url } label: { Label("Send in Fariin", systemImage: "paperplane") }
                                Button { UIPasteboard.general.string = inv.url } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                                Button { showQR = true } label: { Label("QR Code", systemImage: "qrcode") }
                                ShareLink(item: URL(string: inv.url) ?? URL(string: "https://fariin.com")!) {
                                    Label("More", systemImage: "ellipsis")
                                }
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up").foregroundStyle(.primary)
                            }
                            // It kills the link everyone already has, so it asks first.
                            Button { confirmNewLink = true } label: {
                                Label("Reset Link", systemImage: "arrow.clockwise").foregroundStyle(.primary)
                            }
                        }
                        .confirmationDialog("Reset Link", isPresented: $confirmNewLink, titleVisibility: .visible) {
                            Button("Reset Link", role: .destructive) { regenerate() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("The current link stops working for everyone who has it.")
                        }
                        Section {
                            Toggle("Require Admin Approval", isOn: Binding(
                                get: { inv.requestApproval },
                                set: { on in setField(["requestApproval": on]); invite?.requestApproval = on }))
                        } footer: {
                            Text("An admin has to approve each person who joins with the link.")
                        }
                    }
                }
            }
            .sheet(item: Binding(get: { shareText.map { InviteShareText(id: $0) } },
                                 set: { shareText = $0?.id })) { t in
                ForwardPicker(shareText: t.id)
            }
            .navigationTitle("Group Link").navigationBarTitleDisplayMode(.inline)
            .toolbar { if !embedded { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } } }
            .task { await load() }
            .alert("Couldn't change the link",
                   isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(linkError ?? "")
            }
            // 2026-09-24 fix-all #126: the code, white behind it so any camera reads it in either theme.
            .sheet(isPresented: $showQR) {
                VStack(spacing: 16) {
                    Text(groupTitle).font(.headline)
                    if let url = invite?.url, let img = qrImage(from: url) {
                        Image(uiImage: img)
                            .interpolation(.none).resizable().scaledToFit()
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .frame(maxWidth: 292)
                    }
                    if let url = invite?.url {
                        Text(url).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .presentationDetents([.medium])
            }
        }
    }
    @State private var showQR = false   // 2026-09-24 fix-all #126, private like the sheet's other state

    private func stateLine(_ inv: GroupInvite) -> String {
        let membersShare = ConversationsRepository.shared.conversations
            .first { $0.id == cid }?.membersCanShareLink ?? false
        let join = inv.requestApproval ? "An admin approves each person who asks to join."
                                       : "Anyone with the link joins straight away."
        let share = membersShare ? "Members can share it too." : "Only admins can share it."
        return "\(join) \(share)"
    }
    @State private var shareText: String?   // the link, going out through the app's Send To sheet

    private func expiryLabel(_ at: Double) -> String {
        guard at > 0 else { return "Never" }
        let d = Date(timeIntervalSince1970: at / 1000)
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    private func load() async {
        if !initialCode.isEmpty { invite = await GroupInviteService.fetchInvite(code: initialCode) }
        loading = false
    }
    // 2026-10-19: these used to swallow every error with try? and then show the change as made. Now
    // a failure shows `linkError` and the page keeps (or re-reads) what is really stored.
    private func create() {
        working = true
        Task {
            do {
                let code = try await GroupInviteService.createInvite(cid: cid, groupTitle: groupTitle, groupPhoto: groupPhoto)
                invite = await GroupInviteService.fetchInvite(code: code)
            } catch {
                linkError = "The link was not created. Check your connection and try again."
            }
            working = false
        }
    }
    private func regenerate() {
        guard let old = invite?.code else { return }
        working = true
        Task {
            do {
                try await GroupInviteService.revokeInvite(cid: cid, code: old)
            } catch {
                linkError = "The link was not reset. Check your connection and try again."
                working = false
                return
            }
            do {
                let code = try await GroupInviteService.createInvite(cid: cid, groupTitle: groupTitle, groupPhoto: groupPhoto)
                invite = await GroupInviteService.fetchInvite(code: code)
            } catch {
                // The old link is already off, so the page shows no link rather than a dead one.
                invite = nil
                linkError = "The old link was turned off, but a new one was not made. Turn Group Link on to try again."
            }
            working = false
        }
    }
    private func revoke() {
        guard let code = invite?.code else { return }
        working = true
        Task {
            do {
                try await GroupInviteService.revokeInvite(cid: cid, code: code)
                invite = nil
            } catch {
                linkError = "The link is still on. Check your connection and try again."
            }
            working = false
        }
    }
    private func setField(_ fields: [String: Any]) {
        guard let code = invite?.code else { return }
        Task {
            do {
                try await GroupInviteService.updateInvite(code: code, fields: fields)
            } catch {
                // The toggle moved before the write; put it back to what is stored.
                if let stored = await GroupInviteService.fetchInvite(code: code) { invite = stored }
                linkError = "The setting was not changed. Check your connection and try again."
            }
        }
    }
    @State private var linkError: String?
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
            message(symbol: "link", why)
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

            if !p.mutuals.isEmpty {
                Divider().padding(.horizontal, 20).padding(.top, 20)
                mutualsRow(p).padding(.top, 16).padding(.horizontal, 24)
            }

            if let joinError {
                Text(joinError)
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

            capsuleButton(buttonTitle(p), enabled: !joining && !(requestSent || p.requested)) { join(p) }
                .padding(.top, 24)
        }
    }

    private func buttonTitle(_ p: GroupLinkPreview) -> String {
        if requestSent || p.requested { return "Request Sent" }
        if joining { return p.needsApproval ? "Sending…" : "Joining…" }
        return p.needsApproval ? "Request to Join" : "Join Group"
    }

    /// Up to three small faces, overlapping, and who they are.
    @ViewBuilder private func mutualsRow(_ p: GroupLinkPreview) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(p.mutuals.prefix(3)) { m in
                    AvatarView(name: m.name, photoUrl: m.photoUrl, size: 28)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            Text(mutualsLine(p))
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
            if preview == nil { refusedText = why }
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
                case "joined", "already":
                    GroupLinkDoor.noteJoined(code, cid: r.cid)
                    openChat(r.cid, p)
                case "requested":
                    GroupLinkDoor.noteRequested(code)
                    requestSent = true
                default:
                    joinError = "Couldn't join. The link may be invalid."
                }
            } catch {
                joinError = (error as NSError).localizedDescription
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
                        rowLabel("Share", "square.and.arrow.up")
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
        .sheet(isPresented: $showQR) { GroupLinkQRSheet(title: title, link: link) }
    }

    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, icon) }.buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

import SwiftUI
import FirebaseFirestore
import FirebaseFunctions

// Group invite links (Telegram-style). An invite is a top-level `invites/{code}` doc pointing at a
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
        // which the admin can no longer see or revoke).
        if let snap = try? await db.collection("conversations").document(cid).getDocument(),
           let old = snap.data()?["inviteCode"] as? String, !old.isEmpty {
            try? await db.collection("invites").document(old).updateData(["revoked": true])
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
        // Point the group at its current link so members/admins can find it.
        try? await db.collection("conversations").document(cid).updateData([
            "inviteCode": code, "updatedAt": FieldValue.serverTimestamp(),
        ])
        return code
    }

    /// Admin: edit an existing invite's options in place.
    static func updateInvite(code: String, fields: [String: Any]) async throws {
        try await db.collection("invites").document(code).updateData(fields)
    }

    /// Admin: revoke the link and clear the group's pointer.
    static func revokeInvite(cid: String, code: String) async throws {
        try await db.collection("invites").document(code).updateData(["revoked": true])
        try? await db.collection("conversations").document(cid).updateData([
            "inviteCode": "", "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    static func fetchInvite(code: String) async -> GroupInvite? {
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
    @Environment(\.dismiss) private var dismiss
    @State private var invite: GroupInvite?
    @State private var loading = true
    @State private var working = false

    private let expiryOptions: [(String, Double)] = [("Never", 0), ("1 day", 86_400), ("1 week", 604_800), ("1 month", 2_592_000)]
    private let limitOptions: [(String, Int)] = [("No limit", 0), ("10 uses", 10), ("50 uses", 50), ("100 uses", 100)]

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
                } else if let inv = invite, inv.isActive {
                    Section {
                        Text(inv.url).font(.callout.monospaced()).textSelection(.enabled)
                        Button { UIPasteboard.general.string = inv.url } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                        ShareLink(item: URL(string: inv.url) ?? URL(string: "https://fariin.com")!) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        Text(inv.usageLimit > 0 ? "Used \(inv.usedCount) of \(inv.usageLimit)." : "Anyone with this link can join.")
                    }
                    Section("Options") {
                        Toggle("Require admin approval", isOn: Binding(
                            get: { inv.requestApproval },
                            set: { on in setField(["requestApproval": on]); invite?.requestApproval = on }))
                        Menu {
                            ForEach(expiryOptions, id: \.0) { opt in
                                Button(opt.0) {
                                    let at = opt.1 == 0 ? 0 : (Date().timeIntervalSince1970 + opt.1) * 1000
                                    setField(["expireAt": at]); invite?.expireAt = at
                                }
                            }
                        } label: { LabeledContent("Expires", value: expiryLabel(inv.expireAt)) }
                        Menu {
                            ForEach(limitOptions, id: \.0) { opt in
                                Button(opt.0) { setField(["usageLimit": opt.1]); invite?.usageLimit = opt.1 }
                            }
                        } label: { LabeledContent("Usage limit", value: inv.usageLimit == 0 ? "No limit" : "\(inv.usageLimit)") }
                    }
                    Section {
                        Button(role: .destructive) { revoke() } label: { Label("Revoke Link", systemImage: "xmark.circle") }
                        Button { regenerate() } label: { Label("New Link", systemImage: "arrow.triangle.2.circlepath") }
                    }
                } else {
                    Section {
                        Button { create() } label: {
                            Label(working ? "Creating…" : "Create Invite Link", systemImage: "link.badge.plus")
                        }.disabled(working)
                    } footer: {
                        Text("Share a link so people can join this group without being added by a contact.")
                    }
                }
            }
            .navigationTitle("Invite via Link").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

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
    private func create() {
        working = true
        Task {
            let code = try? await GroupInviteService.createInvite(cid: cid, groupTitle: groupTitle, groupPhoto: groupPhoto)
            if let code { invite = await GroupInviteService.fetchInvite(code: code) }
            working = false
        }
    }
    private func regenerate() {
        guard let old = invite?.code else { return }
        working = true
        Task {
            try? await GroupInviteService.revokeInvite(cid: cid, code: old)
            let code = try? await GroupInviteService.createInvite(cid: cid, groupTitle: groupTitle, groupPhoto: groupPhoto)
            if let code { invite = await GroupInviteService.fetchInvite(code: code) }
            working = false
        }
    }
    private func revoke() {
        guard let code = invite?.code else { return }
        Task { try? await GroupInviteService.revokeInvite(cid: cid, code: code); invite = nil }
    }
    private func setField(_ fields: [String: Any]) {
        guard let code = invite?.code else { return }
        Task { try? await GroupInviteService.updateInvite(code: code, fields: fields) }
    }
}

// MARK: - Join group sheet (opened from a kulan://g/<code> deep link)

struct JoinGroupSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var invite: GroupInvite?
    @State private var loading = true
    @State private var joining = false
    @State private var doneMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if loading {
                    ProgressView().padding(.top, 60)
                } else if let msg = doneMessage {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                    Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                } else if let inv = invite, inv.isActive {
                    Spacer()
                    AvatarView(name: inv.groupTitle, photoUrl: inv.groupPhoto, size: 96)
                    Text(inv.groupTitle).font(.title2.weight(.bold))
                    Text(inv.requestApproval ? "Request to join this group" : "You've been invited to join this group")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                    Button {
                        join()
                    } label: {
                        Text(joining ? "Joining…" : (inv.requestApproval ? "Request to Join" : "Join Group"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(joining)
                    .padding(.horizontal)
                } else {
                    Spacer()
                    Image(systemName: "link.badge.plus").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("This invite link is invalid, expired, or full.").multilineTextAlignment(.center).padding(.horizontal)
                    Spacer()
                }
            }
            .padding(.bottom, 24)
            .navigationTitle("Join Group").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .task { invite = await GroupInviteService.fetchInvite(code: code); loading = false }
        }
    }

    private func join() {
        joining = true
        Task {
            do {
                let r = try await GroupInviteService.joinViaInvite(code: code)
                switch r.status {
                case "joined", "already":
                    AppRouter.shared.pendingInviteCode = nil
                    AppRouter.shared.pendingChatId = r.cid
                    dismiss()
                case "requested":
                    doneMessage = "Request sent. You'll join once an admin approves."
                default:
                    doneMessage = "Couldn't join. The link may be invalid."
                }
            } catch {
                doneMessage = (error as NSError).localizedDescription
            }
            joining = false
        }
    }
}

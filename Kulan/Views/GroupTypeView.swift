import SwiftUI
import FirebaseFirestore

// ⛔ GROUP TYPE — 2026-10-19 groups v2, laid out like the reference app's page (our own words).
// Private: people join only by an invite link or when an admin adds them. Public: the group has an
// @name, shows in global search and opens from fariin.com/<name>. Reached from Group Settings, by
// admins with the change-info right only (the server refuses everyone else the same way).
// Every change goes through GroupDirectory.setName (functions-username setGroupUsername).

struct GroupTypeView: View {
    let cid: String
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    init(cid: String) { self.cid = cid }
    @Environment(\.dismiss) private var dismiss

    @State private var wantsPublic: Bool?
    @State private var name = ""
    @State private var check: GroupNameCheck = .idle
    @State private var saving = false
    @State private var confirmPrivate = false
    @State private var saveError: String?
    @State private var seeded = false

    @State private var ownConv: Conversation?
    @State private var convListener: ListenerRegistration?
    /// The group's own document first, so the page never depends on the chat list's window
    /// (the Group Settings page's lesson, 2026-10-19).
    private var conv: Conversation? { ownConv ?? repo.conversations.first { $0.id == cid } }
    private var canEdit: Bool { conv?.adminCan(me, .changeInfo) ?? false }
    private var isPublicNow: Bool { conv?.isPublic ?? false }
    private var showPublic: Bool { wantsPublic ?? isPublicNow }
    private var nameChanged: Bool { name != (conv?.publicName ?? "") }
    private var canSave: Bool {
        guard canEdit, !saving, showPublic else { return false }
        return nameChanged && check == .available
    }

    var body: some View {
        List {
            typeSection
            if showPublic { linkSection; linkAndContentSections } else { privateSections }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group Type")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    // Blue, as the tag page's Done (owner 2026-10-20).
                    Button("Save") { save(name) }.disabled(!canSave)
                        .buttonStyle(.glassProminent).tint(Color(hex: 0x2392FE))
                }
            }
        }
        .disabled(!canEdit)
        .onAppear(perform: start)
        .onDisappear { convListener?.remove(); convListener = nil }
        // 2026-10-20 (owner): after `FirestoreHub.swap` the group listener belongs to the stuck
        // client. Let go of it off-main and listen again on the fresh one. A save that was waiting
        // on the stuck client never returns, so Save is freed for a retry.
        .onReceive(NotificationCenter.default.publisher(for: FirestoreHub.swapped)) { _ in
            saving = false
            guard convListener != nil else { return }
            FirestoreHub.drop([convListener])
            convListener = nil
            start()
        }
        .task(id: name) { await runCheck() }
        .task { await loadShareCode() }
        .overlay(alignment: .bottom) {
            if copied {
                Text("Link copied").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .liquidGlass(Capsule()).padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        .alert("Make this group private?", isPresented: $confirmPrivate) {
            Button("Make Private", role: .destructive) { save("") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("fariin.com/\(conv?.publicName ?? "") will stop working. The link stays reserved for this group for 30 days, then anyone can take it.")
        }
        .alert("Could not save", isPresented: Binding(get: { saveError != nil },
                                                      set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
    }

    // MARK: Private: the invite link and content protection here (owner 2026-10-20)

    @State private var shareCode: String?
    @State private var protectOn: Bool?
    @State private var showSend = false
    @State private var copied = false

    private var inviteURL: String? {
        let code = shareCode ?? conv?.inviteCode ?? ""
        return code.isEmpty ? nil : KulanApp.groupLink(code: code)
    }

    private func loadShareCode() async {
        shareCode = try? await GroupInviteService.shareCode(cid: cid)
    }

    // Owner's mockup 2026-10-21: group photo, name and the full link in one card, Share Link under it.
    @ViewBuilder private var privateSections: some View {
        Section {
            if let url = inviteURL {
                // The card copies the link on a tap, as the old pill did.
                Button {
                    UIPasteboard.general.string = url
                    Haptics.notify(.success)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                } label: {
                    HStack(spacing: 16) {
                        AvatarView(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl, size: 76)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conv?.title ?? "Group").font(.headline).foregroundStyle(.primary).lineLimit(1)
                            Text(url).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The app's own Share With sheet, as the links page sends (owner 2026-10-20).
                Button { showSend = true } label: {
                    Text("Share Link").fontWeight(.semibold).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        // The app's tint is `.primary` (white in dark mode, so the button was blank).
                        .background(Capsule().fill(Color(hex: 0x2392FE)))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showSend) { ForwardPicker(shareText: url) }
            } else {
                Text("This group has no invite link on.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Invite link")
        } footer: {
            Text("People can join your group with this link. You can reset it any time.")
        }
        .listRowSeparator(.hidden)
        linkAndContentSections
    }

    /// Invite Links, under either type (owner 2026-10-20: a public group shows it under its public
    /// link too). Protect Content left this page on the 10-21 mockup; it stays on Permissions.
    @ViewBuilder private var linkAndContentSections: some View {
        Section {
            NavigationLink {
                InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                                initialCode: shareCode ?? conv?.inviteCode ?? "", embedded: true)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "link").font(.system(size: 17)).frame(width: 26)
                    Text("Invite Links")
                }
            }
        } footer: {
            Text("Make extra links that end after a time or a number of people.")
        }
    }

    /// Kept for a later home; not shown (owner mockup 2026-10-21 has no Protect Content here).
    @ViewBuilder private var protectContentSection: some View {
        Section {
            // Holds the tap at once (owner 2026-10-20: it was hard to switch off, because it read the
            // group copy, which snapped it back until the save came round). Follows the group after.
            Toggle("Protect Content", isOn: Binding(
                get: { protectOn ?? conv?.isRestricted ?? false },
                set: { v in
                    protectOn = v
                    Task {
                        do { try await ChatService.setGroupRestricted(cid, on: v) }
                        catch { protectOn = nil; saveError = error.localizedDescription }
                    }
                }))
                .onChange(of: conv?.isRestricted) { _, now in if now == protectOn { protectOn = nil } }
        } header: {
            Text("Forwarding from this group")
        } footer: {
            Text((conv?.isRestricted ?? false)
                 ? "Members can't forward, copy, save or screenshot content from this group."
                 : "Members can copy, save and forward content from this group.")
        }
    }

    private var typeSection: some View {
        Section {
            // Public first (owner 2026-10-21).
            typeRow("Public Group", selected: showPublic) { pick(publicType: true) }
            typeRow("Private Group", selected: !showPublic) { pick(publicType: false) }
        } header: {
            Text("Group Type")
        } footer: {
            Text(showPublic
                 ? "Anyone can find this group in search and join it without an invite."
                 : "People can join only with an invite link, or when an admin adds them.")
        }
    }

    private func typeRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var linkSection: some View {
        Section {
            HStack(spacing: 0) {
                Text("fariin.com/").foregroundStyle(.secondary)
                TextField("link", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
            }
        } header: {
            Text("Public Link")
        } footer: {
            linkFooter
        }
    }

    @ViewBuilder private var linkFooter: some View {
        if !nameChanged && !name.isEmpty {
            Text("People can open this group with fariin.com/\(name).")
        } else if check != .idle {
            Text(check.text).foregroundStyle(checkColor)
        } else {
            Text("Pick a link of \(GroupDirectory.nameMin) to \(GroupDirectory.nameMax) characters: letters, numbers and _.")
        }
    }

    private var checkColor: Color {
        switch check {
        case .available: return .green
        case .checking, .idle, .failed: return .secondary
        default: return .red
        }
    }

    // MARK: - Work

    private func start() {
        if !seeded { seeded = true; name = conv?.publicName ?? "" }
        guard convListener == nil else { return }
        convListener = FirestoreHub.db.collection("conversations").document(cid)
            .addSnapshotListener { snap, _ in
                guard let snap, snap.exists, let data = snap.data() else { return }
                let c = Conversation(id: snap.documentID, data: data)
                if ownConv == nil, name.isEmpty { name = c.publicName }
                ownConv = c
            }
    }

    private func pick(publicType: Bool) {
        if publicType { wantsPublic = true; return }
        // Going private gives the link up, so it asks first. A group that was never public just
        // shows Private again.
        if isPublicNow { confirmPrivate = true } else { wantsPublic = false }
    }

    private func runCheck() async {
        guard showPublic, nameChanged else { check = .idle; return }
        if let p = GroupDirectory.localProblem(name) { check = p; return }
        check = .checking
        try? await Task.sleep(nanoseconds: 400_000_000)   // settle while typing
        guard !Task.isCancelled else { return }
        let r = await GroupDirectory.check(cid: cid, name: name)
        guard !Task.isCancelled else { return }
        check = r
    }

    private func save(_ value: String) {
        guard !saving else { return }
        saving = true
        Task {
            do {
                try await GroupDirectory.setName(cid: cid, name: value)
                wantsPublic = !value.isEmpty
                if value.isEmpty { name = "" }
                check = .idle
                // Saved: back to Group Settings (owner 2026-10-20: the page stayed after Save).
                saving = false
                dismiss()
                return
            } catch {
                saveError = error.localizedDescription
                // Taken at Save (someone was quicker): the line under the field says so too, not
                // "free to use" (audit 2026-10-20).
                if saveError == GroupNameCheck.taken.text { check = .taken }
            }
            saving = false
        }
    }
}

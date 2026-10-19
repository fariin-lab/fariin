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
            if showPublic { linkSection }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group Type")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Save") { save(name) }.disabled(!canSave)
                }
            }
        }
        .disabled(!canEdit)
        .onAppear(perform: start)
        .onDisappear { convListener?.remove(); convListener = nil }
        .task(id: name) { await runCheck() }
        .confirmationDialog("Make this group private?", isPresented: $confirmPrivate, titleVisibility: .visible) {
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

    private var typeSection: some View {
        Section {
            typeRow("Private Group", selected: !showPublic) { pick(publicType: false) }
            typeRow("Public Group", selected: showPublic) { pick(publicType: true) }
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
                        .foregroundStyle(Color.accentColor)
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
        convListener = Firestore.firestore().collection("conversations").document(cid)
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
            } catch {
                saveError = error.localizedDescription
            }
            saving = false
        }
    }
}

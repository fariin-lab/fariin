import SwiftUI

// "Add to a Group" (from a contact's profile): lists MY existing groups; tap one to add this contact to
// it. Groups the contact already belongs to are shown disabled as "Already a member" (standard).
// This is NOT the create-group flow — it only adds to existing groups. Native inset-grouped list.
struct AddToGroupView: View {
    let contactUid: String
    let contactName: String
    let contactPhoto: String?
    @Environment(\.dismiss) private var dismiss
    private var me: String { AuthService.shared.uid ?? "" }
    @State private var working: String? = nil   // cid currently being added
    @State private var notice: String?
    @State private var noticeIsSuccess = false   // only a success notice should close the sheet on OK
    @State private var pendingGroup: Conversation?   // group awaiting the native "Add New Member" confirm

    // Every group I'm a member of, alphabetical.
    private var myGroups: [Conversation] {
        ConversationsRepository.shared.conversations
            .filter { $0.isGroup && $0.users.contains(me) && !$0.isCleared(me) }
            .sorted { $0.displayName(me).lowercased() < $1.displayName(me).lowercased() }
    }

    var body: some View {
        NavigationStack {
            Group {
                if myGroups.isEmpty {
                    ContentUnavailableView("No Groups", systemImage: "person.2",
                                           description: Text("You're not in any groups yet."))
                } else {
                    List { ForEach(myGroups) { groupRow($0) } }
                        .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Add to a Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)   // don't double-wrap the glass X (the duplicate circle)
                } else {
                    ToolbarItem(placement: .topBarTrailing) { CloseXButton { dismiss() } }
                }
            }
            .alert("Add to a Group", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                // Only close on success — after an error the user should be able to try another group.
                Button("OK") { if noticeIsSuccess { dismiss() } }
            } message: { Text(notice ?? "") }
            // Native bottom action sheet (image-2 look), attached at the top level so it never anchors to a
            // row and adapts into a popover. Replaces the manual UIAlertController that rendered as a bubble.
            .confirmationDialog("Add New Member",
                isPresented: Binding(get: { pendingGroup != nil }, set: { if !$0 { pendingGroup = nil } }),
                titleVisibility: .visible,
                presenting: pendingGroup) { g in
                    Button("Add to Group") { add(to: g) }
                    Button("Cancel", role: .cancel) { }
                } message: { g in
                    Text("Add \"\(contactName)\" to \"\(g.displayName(me))\"?")
                }
        }
    }

    @ViewBuilder private func groupRow(_ g: Conversation) -> some View {
        let already = g.users.contains(contactUid)
        Button {
            guard !already, working == nil else { return }
            pendingGroup = g   // → native .confirmationDialog (bottom action sheet, with Cancel)
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: g.displayName(me), photoUrl: g.displayPhoto(me), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.displayName(me)).foregroundStyle(already ? .secondary : .primary)
                    Text(already ? "Already a member" : g.memberCountLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if working == g.id { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(already || working != nil)
    }

    // Native UIKit action sheet — always a BOTTOM sheet with a Cancel on iPhone (unlike SwiftUI's
    // confirmationDialog, which rendered as a Cancel-less popover inside this sheet).
    private func confirmAdd(_ g: Conversation) {
        // A centered .alert (NOT .actionSheet): an action sheet presented from within a sheet adapts to
        // an iPad-style popover on iPhone — a beak bubble with NO Cancel. An alert is always a centered
        // modal with a guaranteed Cancel on every device (Apple's pattern for a yes/no confirmation).
        let alert = UIAlertController(
            title: "Add New Member",
            message: "Add \"\(contactName)\" to \"\(g.displayName(me))\"?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in add(to: g) })
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(alert, animated: true)
    }

    private func add(to g: Conversation) {
        working = g.id
        Task {
            do {
                let keyless = try await ChatService.addGroupMembers(cid: g.id, add: [contactUid])
                await MainActor.run {
                    working = nil
                    if keyless.isEmpty { dismiss() }
                    else { noticeIsSuccess = true; notice = "\(contactName) hasn't opened Fariin yet — they'll see messages once they do." }
                }
            } catch {
                await MainActor.run { working = nil; noticeIsSuccess = false; notice = error.localizedDescription }
            }
        }
    }
}

import SwiftUI

// "Add to a Group" (from a contact's profile): lists MY existing groups; tap one to add this contact to
// it. Groups the contact already belongs to are shown disabled as "Already a member" (Signal/Telegram).
// This is NOT the create-group flow — it only adds to existing groups. Native inset-grouped list.
struct AddToGroupView: View {
    let contactUid: String
    let contactName: String
    let contactPhoto: String?
    @Environment(\.dismiss) private var dismiss
    private var me: String { AuthService.shared.uid ?? "" }
    @State private var working: String? = nil   // cid currently being added
    @State private var notice: String?

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
                Button("OK") { dismiss() }
            } message: { Text(notice ?? "") }
        }
    }

    @ViewBuilder private func groupRow(_ g: Conversation) -> some View {
        let already = g.users.contains(contactUid)
        Button {
            guard !already, working == nil else { return }
            confirmAdd(g)   // native UIKit action sheet (bottom, with Cancel) — SwiftUI's
                            // confirmationDialog rendered as a Cancel-less popover here.
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
        let sheet = UIAlertController(
            title: "Add New Member",
            message: "Add \"\(contactName)\" to \"\(g.displayName(me))\"?",
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Add to Group", style: .default) { _ in add(to: g) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // Find the top-most presented VC to present from.
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        // iPad popover anchor (harmless on iPhone, where it's a bottom sheet).
        sheet.popoverPresentationController?.sourceView = top?.view
        if let v = top?.view {
            sheet.popoverPresentationController?.sourceRect = CGRect(x: v.bounds.midX, y: v.bounds.maxY - 60, width: 0, height: 0)
        }
        top?.present(sheet, animated: true)
    }

    private func add(to g: Conversation) {
        working = g.id
        Task {
            do {
                let keyless = try await ChatService.addGroupMembers(cid: g.id, add: [contactUid])
                await MainActor.run {
                    working = nil
                    if keyless.isEmpty { dismiss() }
                    else { notice = "\(contactName) hasn't opened Kulan yet — they'll see messages once they do." }
                }
            } catch {
                await MainActor.run { working = nil; notice = error.localizedDescription }
            }
        }
    }
}

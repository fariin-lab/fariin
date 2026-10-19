import SwiftUI

// A new group's first screen (owner 2026-10-19: "when you create a new group ours looks plain white;
// give the user options, our own design"). Until someone writes the first real message, the middle of
// the chat shows the group itself: its photo, name and size, who started it, and the next steps as the
// same labelled tiles the group info page uses. The lock line sits under it, since the plain notice
// only shows in a chat with nothing in it, and a new group already holds its "created the group" line.
struct GroupWelcomeCard: View {
    let conv: Conversation
    let me: String
    var dark: Bool

    @State private var showEdit = false
    @State private var showAdd = false
    @State private var showLink = false

    private var amAdmin: Bool { conv.isAdmin(me) || conv.isOwner(me) }
    private var canEdit: Bool { amAdmin || conv.membersCanEditInfo }
    private var canAdd: Bool { amAdmin || conv.membersCanAdd }

    private var startedLine: String {
        if conv.createdBy == me { return "You started this group" }
        let who = conv.names[conv.createdBy] ?? ""
        return who.isEmpty ? "You were added to this group" : "\(who) started this group"
    }

    private var sizeLine: String {
        conv.users.count == 1 ? "Just you so far" : "\(conv.users.count) members"
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Button { if canEdit { showEdit = true } } label: {
                    AvatarView(name: conv.title, photoUrl: conv.avatarUrl, size: 76)
                        .overlay(alignment: .bottomTrailing) {
                            if canEdit && (conv.avatarUrl ?? "").isEmpty {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.accentColor, in: Circle())
                                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .accessibilityLabel(canEdit ? "Edit Group" : conv.title)

                VStack(spacing: 3) {
                    Text(conv.title).font(.title3.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("\(startedLine) · \(sizeLine)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if canEdit || canAdd {
                HStack(spacing: 8) {
                    if canAdd {
                        GroupActionTile(icon: "ic_add_member", title: "Add Members") { showAdd = true }
                    }
                    if amAdmin {
                        GroupActionTile(icon: "link", title: "Group Link") { showLink = true }
                    }
                    if canEdit {
                        GroupActionTile(icon: "pencil",
                                        title: conv.groupDescription.isEmpty ? "Description" : "Edit") { showEdit = true }
                    }
                }
            }

            Button { if let u = URL(string: "https://fariin.com/safety") { WebLink.open(u) } } label: {
                (Text("\(Image(systemName: "lock.fill")) Only the people in this group can read its messages. ")
                 + Text("Learn more").foregroundStyle(Theme.defaultBubble(dark)))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(.white.opacity(0.06), lineWidth: 0.5))
        .padding(.horizontal, 20)
        .sheet(isPresented: $showEdit) {
            EditGroupView(cid: conv.id, title: conv.title, photoUrl: conv.avatarUrl,
                          description: conv.groupDescription)
        }
        .sheet(isPresented: $showAdd) { AddMembersSheet(cid: conv.id, existing: Set(conv.users)) }
        .sheet(isPresented: $showLink) {
            InviteLinkSheet(cid: conv.id, groupTitle: conv.title, groupPhoto: conv.avatarUrl,
                            initialCode: conv.inviteCode)
        }
    }
}

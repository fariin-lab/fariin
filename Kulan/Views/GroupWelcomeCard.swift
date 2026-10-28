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

    // The admin's own right, not just "is an admin" (2026-10-19 fix round): an admin without
    // Change group info / Invite users saw tiles whose writes were then refused. Members by the
    // group's switch, unless restricted from it, as on the group info page.
    private var now: Double { Date().timeIntervalSince1970 * 1000 }
    private var canEdit: Bool {
        conv.adminCan(me, .changeInfo) || (conv.membersCanEditInfo && !conv.isRestricted(me, .changeInfo, now: now))
    }
    private var canAdd: Bool {
        conv.adminCan(me, .inviteUsers) || (conv.membersCanAdd && !conv.isRestricted(me, .addMembers, now: now))
    }
    private var canLink: Bool { conv.adminCan(me, .inviteUsers) }

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
                    AvatarView(name: conv.title, photoUrl: conv.avatarUrl, size: 92)
                        .overlay(alignment: .bottomTrailing) {
                            if canEdit && (conv.avatarUrl ?? "").isEmpty {
                                // His camera icon on a fixed blue (owner 2026-10-22): the accent is
                                // white in dark mode, so the white glyph vanished into its circle.
                                Image("ic_group_camera").renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 16, height: 16).foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Color(hex: 0x0A84FF), in: Circle())
                                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                            }
                        }
                }
                .buttonStyle(.plain)
                // ⚠️ NOT `.disabled`: a disabled button draws its label dimmed, so every member who
                // cannot edit saw the group photo washed out (owner 2026-10-24). Untappable, not faded.
                .allowsHitTesting(canEdit)
                .accessibilityLabel(canEdit ? "Edit Group" : conv.title)

                VStack(spacing: 3) {
                    Text(conv.title).font(.title3.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("\(startedLine) · \(sizeLine)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            // Round glass circles with their names, the group page's own (owner 2026-10-19: the
            // square tiles read boxy).
            if canEdit || canAdd {
                HStack(spacing: 0) {
                    if canAdd {
                        circle("ic_add_member", "Add Members") { showAdd = true }
                    }
                    if canLink {
                        circle("link", "Group Link") { showLink = true }
                    }
                    if canEdit {
                        circle("pencil", conv.groupDescription.isEmpty ? "Description" : "Edit") { showEdit = true }
                    }
                }
            }

            // Owner 2026-10-28: no "not end-to-end encrypted" line on the group's front; it made people
            // doubt the group (the reference apps with unencrypted groups show none). Nothing claims
            // encryption either; the full explanation stays on the group's info page.
        }
        .padding(.horizontal, 18).padding(.vertical, 24)
        .frame(maxWidth: 340)
        // A rounder card in glass instead of the flat grey box.
        .liquidGlass(RoundedRectangle(cornerRadius: 36, style: .continuous))
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

    private func circle(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PosterActionIcon(icon: icon, diameter: 56, onPhoto: false, label: title)
        }
        .tint(.primary)
        .accessibilityLabel(title)
    }
}

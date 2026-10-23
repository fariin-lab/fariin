import SwiftUI

// GROUP STORIES — owner 2026-10-23 ("group stories go build").
//
// A group story is an ordinary story with `groupId` on it, delivered to the group's members and
// shown to them in a ring of the group's own. Who may post: the owner, and admins while the owner
// leaves "Allow Admins to Add Story" on (`GroupStoryRights`, enforced by firestore.rules
// `groupStoryOK`). Three doors lead in: New Group Story in the + New menu, the + on the group page,
// and the + New menu on Settings > Stories. All of them end on the same camera and editor; only the
// last sheet differs (`ShareStorySheet.groupBody`).

/// The group a story is being made for, as the last sheet shows it.
struct GroupStoryTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let photoUrl: String?
    let memberCount: Int

    @MainActor init(_ c: Conversation) {
        let me = AuthService.shared.uid ?? ""
        id = c.id
        name = c.name(for: me)
        photoUrl = c.photoUrl(for: me)
        memberCount = c.users.count
    }
}

/// The group the camera was opened for, read by the last sheet. Set by `StoryCameraDoor.open`
/// and cleared when the camera closes, the same arrangement as `OfficialStoryCompose`.
@MainActor
enum GroupStoryCompose {
    static private(set) var target: GroupStoryTarget?

    static func open(_ t: GroupStoryTarget) {
        StoryCameraDoor.open(group: t)
    }

    static func setTarget(_ t: GroupStoryTarget?) { target = t }

    static func end() { target = nil }
}

/// NEW GROUP STORY: the groups I may post a story in. From the live chat list; the post itself
/// re-reads the group from the server before it goes (`StoriesService.groupStoryAudience`).
struct GroupStoryPicker: View {
    let onPick: (GroupStoryTarget) -> Void
    let onCancel: () -> Void

    @State private var repo = ConversationsRepository.shared

    private var groups: [Conversation] {
        _ = repo.conversations   // observed, so a promotion or a new group shows up while open
        return GroupStoryRights.eligibleGroups()
            .sorted { $0.name(for: me).localizedCaseInsensitiveCompare($1.name(for: me)) == .orderedAscending }
    }
    private var me: String { AuthService.shared.uid ?? "" }

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    Section {
                        Text("You can post a group story in groups you own, or where you're an admin and the owner allows it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(groups) { c in
                            Button { onPick(GroupStoryTarget(c)) } label: {
                                GroupStoryRow(name: c.name(for: me), photoUrl: c.photoUrl(for: me),
                                              members: c.users.count)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Only the members of the group you pick can see the story.")
                    }
                }
            }
            .navigationTitle("New Group Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onCancel() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// One group, as the picker and the last sheet show it.
struct GroupStoryRow<Trailing: View>: View {
    let name: String
    let photoUrl: String?
    let members: Int
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: name, photoUrl: photoUrl, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).lineLimit(1)
                Text(members == 1 ? "1 member" : "\(members) members")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

extension GroupStoryRow where Trailing == EmptyView {
    init(name: String, photoUrl: String?, members: Int) {
        self.init(name: name, photoUrl: photoUrl, members: members) { EmptyView() }
    }
}

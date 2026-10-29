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
    var isChannel = false

    @MainActor init(_ c: Conversation) {
        let me = AuthService.shared.uid ?? ""
        id = c.id
        // The GROUP's name and photo (displayName/displayPhoto). name(for:)/photoUrl(for:) are the
        // 1:1 helpers: on a group they gave one member's name and face, so every group story went out
        // named after a member (owner 2026-10-23: Juni's stories read "zaki ali").
        name = c.displayName(me)
        photoUrl = c.displayPhoto(me)
        // A channel counts its followers, as its page does (owner 2026-10-29: "2 members").
        memberCount = c.isChannel ? c.subscriberCount : c.users.count
        isChannel = c.isChannel
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
            .sorted { $0.displayName(me).localizedCaseInsensitiveCompare($1.displayName(me)) == .orderedAscending }
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
                                GroupStoryRow(name: c.displayName(me), photoUrl: c.displayPhoto(me),
                                              members: c.isChannel ? c.subscriberCount : c.users.count,
                                              channel: c.isChannel)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Only the members of the group you pick can see the story.")
                    }
                }
            }
            // owner 2026-10-27: the big gap above the card, same spacing as Group Settings.
            .listSectionSpacing(20)
            .contentMargins(.top, 12, for: .scrollContent)
            .navigationTitle("New Group Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onCancel() } label: { Image(systemName: "xmark") }
                }
            }
        }
        // Full height at once (owner 2026-10-23: "this sheet open full").
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// One group, as the picker and the last sheet show it.
struct GroupStoryRow<Trailing: View>: View {
    let name: String
    let photoUrl: String?
    let members: Int
    var channel = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: name, photoUrl: photoUrl, size: 40)
                .avatarSquircle(channel)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).lineLimit(1)
                Text(channel ? (members == 1 ? "1 follower" : "\(members) followers")
                             : (members == 1 ? "1 member" : "\(members) members"))
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

/// The ring that turns round a group's photo while a story to it uploads. A timeline drives the
/// turn (never SwiftUI's repeatForever: the iOS 26 deadlock noted in StickerPlayerView).
struct GroupStoryUploadRing: View {
    let active: Bool
    /// A channel's photo is a squircle (owner 2026-10-29: "uploading story is using a ring circle,
    /// use my design"): the arc runs along that outline instead of turning a circle.
    var squircle = false

    var body: some View {
        if active {
            TimelineView(.animation) { ctx in
                let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                if squircle {
                    // Rotating a squircle would turn its corners, so the trim window travels the
                    // path instead; past the end it wraps as a second piece from the start.
                    let style = StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    let end = turn + 0.28
                    ZStack {
                        SquircleShape().trim(from: turn, to: min(end, 1))
                            .stroke(Color(hex: 0x0A84FF), style: style)
                        if end > 1 {
                            SquircleShape().trim(from: 0, to: end - 1)
                                .stroke(Color(hex: 0x0A84FF), style: style)
                        }
                    }
                    .padding(-7)
                } else {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Color(hex: 0x0A84FF), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                        .padding(-7)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

import SwiftUI
import Observation

// ⛔ THE JOIN PAGE OF A PUBLIC GROUP — 2026-10-19 groups v2. Opened from a global search row or a
// fariin.com/<name> link (GroupDirectory.open), presented by the Chats tab. Photo, name, @name,
// member count, description, and Join (or Request to Join when the group approves each person).
// A member never sees it: the chat opens instead. Laid out like the invite link's join sheet.
//
// ⛔ MESSAGES BEFORE JOINING — owner 2026-10-21, with a screenshot: a public group I am not in opens
// as the REAL chat (ThreadView, `guest`): its messages, photo, name and "N members", with a blue Join
// Group bar where the composer goes (`PublicJoinBar`). Joining turns this same screen into the
// normal chat, no navigation away. The rules decide who gets that: a public group sent in the
// clear (`e2ee == false`), history not hidden from newcomers, not ended, me not banned. So the page
// first asks for one message (`GroupDirectory.canPeek`); refused (an old encrypted group, hidden
// history, rules not yet deployed), it stays this page with photo, name, description and Join.

/// A public group opened by someone not in it, handed to ThreadView by reference (ThreadView sits at
/// the stack limit, so it holds one pointer, never the preview struct). `joined` flips once the join
/// is through and the group is in my chat list; the page then shows the member's chat.
@Observable final class PublicGroupGuest {
    let preview: PublicGroupPreview
    var joined = false
    /// Whether the rules let me read its messages from outside. When they do not (an older, still
    /// encrypted group, or history hidden from new members) the chat still opens, as the reference
    /// app's does, with "join to see the messages" in place of them (owner 2026-10-23).
    let readable: Bool
    init(_ preview: PublicGroupPreview, readable: Bool = true) { self.preview = preview; self.readable = readable }
}

struct PublicGroupSheet: View {
    let target: PublicGroupTarget
    /// Pushed onto the Chats stack: the system back button, no X of its own.
    var pushed = false
    @Environment(\.dismiss) private var dismiss

    @State private var preview: PublicGroupPreview?
    @State private var refusedText: String?
    @State private var failedText: String?
    @State private var joining = false
    @State private var requestSent = false
    @State private var joinError: String?
    @State private var contentHeight: CGFloat = 380
    /// Set when the rules let me read the group's messages: the real chat is shown instead.
    @State private var guest: PublicGroupGuest?

    fileprivate static let blue = Color(hex: 0x2392FE)

    /// When the page appeared: a guest chat that arrives later waits for the push to finish.
    @State private var appearedAt = Date()

    /// ⛔ THE GUEST CHAT IS ON THE FIRST FRAME WHEN WE CAN (owner 2026-10-23, 5th report: a Recent
    /// public group "sometimes" landed on the chat list, blank top buttons, no tab bar). A chat row
    /// pushes its ThreadView at once; this page pushed a blank ground and swapped the ThreadView in
    /// from `.task` IN THE MIDDLE OF THE PUSH, so the chat's own navigation item went in during the
    /// transition, and when that lost the race the stack showed the list. Search rows and Recent rows
    /// are warmed (preview + peek), so the chat is built here, before the push begins.
    init(target: PublicGroupTarget, pushed: Bool = false) {
        self.target = target
        self.pushed = pushed
        let me = AuthService.shared.uid ?? ""
        if let p = GroupDirectory.cachedPreview(name: target.name, cid: target.cid),
           !(p.isMember && ConversationsRepository.shared.conversations
                .contains(where: { $0.id == p.cid && $0.users.contains(me) })),
           let readable = GroupDirectory.cachedPeek(p.cid) {
            _preview = State(initialValue: p)
            _guest = State(initialValue: PublicGroupGuest(p, readable: readable))
        }
    }

    // owner 2026-10-21: the chat itself when the group can be read from outside (see the top note),
    // and once joined the member's chat in the same place. One ZStack so `load` runs once.
    var body: some View {
        ZStack {
            if let g = guest, g.joined {
                ThreadView(cid: g.preview.cid, title: g.preview.title, photoUrl: g.preview.photoUrl)
                    .id("member")
            } else if let g = guest {
                ThreadView(cid: g.preview.cid, title: g.preview.title, photoUrl: g.preview.photoUrl, guest: g)
                    .id("guest")
                    .overlay {
                        if !g.readable {
                            // The reference app's words for a group it cannot show from outside.
                            Text("You need to join this group to view its messages.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal, 40)
                                .allowsHitTesting(false)
                        }
                    }
            } else if refusedText != nil || failedText != nil {
                joinPage
            } else {
                // owner 2026-10-23 ("two different pages"): while the group loads, the chat's own
                // ground, not the info page, so the chat is the only page anybody sees.
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
        .task { appearedAt = Date(); await load() }
    }

    // ⛔ A FULL PAGE, NOT A SHEET (owner 2026-10-20: "open the group page directly, Join at the
    // bottom; once joined, the composer"). The group up top, Join pinned where the composer will
    // be; joining opens the chat itself. Kept for a group the rules do not open to outsiders.
    private var joinPage: some View {
        VStack(spacing: 0) {
            if !pushed { closeBar }
            ScrollView { content.padding(.top, pushed ? 8 : 24) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { joinBar }
    }

    /// The Join button where the composer sits once you are in.
    @ViewBuilder private var joinBar: some View {
        if let p = preview {
            VStack(spacing: 8) {
                statusLine(p)
                capsuleButton(buttonTitle(p), enabled: !joining && !(requestSent || p.requested)) { join(p) }
            }
            .padding(.bottom, 8)
        }
    }

    private var closeBar: some View {
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
    }

    @ViewBuilder private var content: some View {
        if let p = preview {
            groupBody(p)
        } else if let why = refusedText {
            message(symbol: "person.3", why)
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

    @ViewBuilder private func groupBody(_ p: PublicGroupPreview) -> some View {
        VStack(spacing: 0) {
            AvatarView(name: p.title, photoUrl: p.photoUrl, size: 100)
                .padding(.top, 2)
            Text(p.title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            Text(headline(p))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if !p.description.isEmpty {
                Text(p.description)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
            }
        }
    }

    private func headline(_ p: PublicGroupPreview) -> String {
        let count = GroupDirectory.membersLine(p.memberCount)
        return p.username.isEmpty ? count : "@\(p.username) · \(count)"
    }

    @ViewBuilder private func statusLine(_ p: PublicGroupPreview) -> some View {
        if let joinError {
            Text(joinError)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 16)
        } else if requestSent || p.requested {
            Text("Your request is waiting for an admin.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
        }
    }

    private func buttonTitle(_ p: PublicGroupPreview) -> String {
        if requestSent || p.requested { return "Request Sent" }
        if joining { return p.needsApproval ? "Sending…" : "Joining…" }
        return p.needsApproval ? "Request to Join" : "Join Group"
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
        // owner 2026-10-21 (a spinner page after tapping a searched group): what is already known
        // opens at once, the server corrects it behind (see `GroupDirectory.cachedPreview`).
        if preview == nil, let p = GroupDirectory.cachedPreview(name: target.name, cid: target.cid) {
            // A cached "member" is only believed when the chat list agrees: the cache is not
            // cleared on leave, and a redirect here lands while the push is still running.
            let me = AuthService.shared.uid ?? ""
            if p.isMember, ConversationsRepository.shared.conversations
                .contains(where: { $0.id == p.cid && $0.users.contains(me) }) { openChat(p); return }
            if let known = GroupDirectory.cachedPeek(p.cid) { guest = PublicGroupGuest(p, readable: known) }
            preview = p
        }
        // Both questions at once when the group is known by id (a search row); by @name the
        // second needs the first's answer.
        async let answerTask = GroupDirectory.preview(name: target.name, cid: target.cid)
        async let earlyPeek = Self.peek(target.cid)
        let answer = await answerTask
        // Closed while it loaded: nothing opens behind the user's back (audit 2026-10-20).
        guard !Task.isCancelled else { return }
        switch answer {
        case .found(let p):
            if p.isMember { openChat(p); return }
            // owner 2026-10-21: the real chat when the rules let me read it from outside.
            let early = await earlyPeek
            let readable: Bool
            if let early { readable = early } else { readable = await GroupDirectory.canPeek(cid: p.cid) }
            guard !Task.isCancelled else { return }
            // ⛔ THE CHAT, ALWAYS (owner 2026-10-23, the reference app read by five agents): a public
            // group's link pushes its chat with Join at the foot, readable or not. The info page is
            // left for a group that could not be found or loaded. An open guest chat stays as it is.
            // One that arrives now waits for the push to end, so the chat's navigation item is never
            // installed mid-transition (see `init`).
            if guest == nil {
                let left = 0.45 - Date().timeIntervalSince(appearedAt)
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                if guest == nil { guest = PublicGroupGuest(p, readable: readable) }
            }
            preview = p
        case .refused(let why):
            if preview == nil || guest == nil { refusedText = why }
        case .failed(let why):
            if preview == nil { failedText = why }
            // Known from the cache but the server could not be reached (offline): the guest chat with
            // Join at the foot rather than an empty page (review 2026-10-23).
            else if guest == nil, let p = preview {
                guest = PublicGroupGuest(p, readable: GroupDirectory.cachedPeek(p.cid) ?? false)
            }
        }
    }

    private static func peek(_ cid: String?) async -> Bool? {
        guard let cid else { return nil }
        return await GroupDirectory.canPeek(cid: cid)
    }

    private func openChat(_ p: PublicGroupPreview) {
        AppRouter.shared.pendingPublicGroup = nil
        // Pushed on the Chats path, the router swaps THIS page for the chat and keeps the pages under
        // it (audit N3; it used to replace the whole stack, so Back lost the chat you came from).
        // A pop here as well was a second path change in the same moment (owner 2026-10-23).
        if pushed { AppRouter.shared.pendingChatReplaceTop = true }
        GroupDirectory.openChat(p.cid, title: p.title, photo: p.photoUrl)
        if !pushed { dismiss() }
    }

    private func join(_ p: PublicGroupPreview) {
        guard !joining else { return }
        guard NetworkState.shared.isOnline else { joinError = "No internet connection. Try again."; return }
        joining = true
        joinError = nil
        Task {
            do {
                switch try await GroupDirectory.join(cid: p.cid) {
                case .joined, .already: openChat(p)
                case .requested: requestSent = true
                }
            } catch {
                joinError = error.localizedDescription
            }
            joining = false
        }
    }
}

/// ⛔ THE JOIN BAR OF A PUBLIC GROUP SEEN FROM OUTSIDE — owner 2026-10-21. ThreadView puts it where
/// the composer goes (`bottomBarContent`, `guest`). Full-width blue Join Group (Request to Join when
/// admins approve each person), the same join call as the page above. Joined: wait for the group to
/// reach my chat list (a few seconds at most), then `joined` turns the screen into the member's chat.
/// Its own state lives here, not on ThreadView (stack budget).
struct PublicJoinBar: View {
    let guest: PublicGroupGuest
    @State private var joining = false
    @State private var requestSent = false
    @State private var joinError: String?

    private var p: PublicGroupPreview { guest.preview }
    private var waiting: Bool { requestSent || p.requested }

    var body: some View {
        VStack(spacing: 8) {
            if let joinError {
                Text(joinError)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if waiting {
                Text("Your request is waiting for an admin.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            // The reference app's join panel: ONE centred accent glass pill (min 166 wide, 19pt side
            // inset, medium 17), "Join Group" / "Apply to Join Group" (owner 2026-10-23).
            Button(action: join) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(enabled ? Color.white : Color.secondary)
                    .padding(.horizontal, 19)
                    .frame(minWidth: 166)
                    .frame(height: 44)
                    .liquidGlass(Capsule(), interactive: true,
                                 tint: enabled ? PublicGroupSheet.blue : nil)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .frame(maxWidth: .infinity)
        .systemBarChrome()
    }

    private var enabled: Bool { !joining && !waiting }

    private var title: String {
        if waiting { return "Request Sent" }
        if joining { return p.needsApproval ? "Sending…" : "Joining…" }
        return p.needsApproval ? "Apply to Join Group" : "Join Group"
    }

    private func join() {
        guard !joining, !waiting else { return }
        guard NetworkState.shared.isOnline else { joinError = "No internet connection. Try again."; return }
        joining = true
        joinError = nil
        Task {
            do {
                switch try await GroupDirectory.join(cid: p.cid) {
                case .joined, .already:
                    // ⛔ THE MEMBER'S CHAT AT ONCE (owner 2026-10-23: the bar stayed on "Joining…"
                    // after the server had added him in under 2s). It used to wait for the chat list
                    // to bring the group in; the member's chat reads its own group document, so it
                    // does not need the list. `joining` goes back too, in case this bar outlives it.
                    joining = false
                    withAnimation(.easeInOut(duration: 0.25)) { guest.joined = true }
                    return
                case .requested:
                    requestSent = true
                    Haptics.notify(.success)
                }
            } catch {
                joinError = error.localizedDescription
            }
            joining = false
        }
    }
}

/// A public group in global search: photo, name, "@name · N members". Laid out like the stranger
/// row above it (56pt photo, headline and subheadline), so the Global Search section reads as one.
/// A table cell: the table's own selection handles the tap (no Button inside).
struct PublicGroupHitRow: View {
    let hit: PublicGroupHit

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: hit.title, photoUrl: hit.photoUrl, size: 56)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(hit.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

/// THE GROUP'S PAGE FOR SOMEBODY NOT IN IT (owner 2026-10-23: "I can't click the profile before
/// joining"). The reference app opens the group's info page for a non-member too. This one reads
/// only the public preview (the members' group document is theirs alone): photo, name, members,
/// description and the public link. No listeners, no writes.
struct PublicGroupInfoView: View {
    let guest: PublicGroupGuest
    private var p: PublicGroupPreview { guest.preview }
    // ⛔ THE WHOLE PAGE FROM OUTSIDE (owner 2026-10-23, asked many times): a visitor sees what a
    // member sees, the members and the shared media, as the reference app shows a public group.
    // Only sending needs Join, at the chat's foot.
    @State private var media: [Message] = []
    @State private var allMembers = false
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?
    @State private var profile: PublicGroupMember?
    private var me: String { AuthService.shared.uid ?? "" }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AvatarView(name: p.title, photoUrl: p.photoUrl, size: 132)
                    .padding(.top, 12)
                Text(p.title)
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                Text(GroupDirectory.membersLine(p.memberCount))
                    .font(.system(size: 16)).foregroundStyle(Color(hex: 0x8E8E93))
                    .padding(.top, 4)
                if !p.description.isEmpty {
                    Text(GroupInfoView.blueLinks(p.description))
                        .font(.subheadline)
                        .tint(Color(hex: 0x0A84FF))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 10)
                }
                if !p.username.isEmpty {
                    GroupPublicLinkCard(name: p.username, title: p.title,
                                        cardColor: Color(.secondarySystemGroupedBackground),
                                        photo: p.photoUrl, memberCount: p.memberCount)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                }
                if guest.readable, !media.isEmpty {
                    ProfileMediaCard(cid: p.cid, media: media,
                                     onOpen: { m in if m.isVideo { viewerVideo = m } else { viewerImage = m } },
                                     onSeeAll: {})
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                }
                if !p.members.isEmpty { membersCard.padding(.top, 24) }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // No Join here: the reference app's info page has none (its only Join is the chat's foot).
        .task { if guest.readable, let m = await ChatService.sharedMedia(p.cid) { media = m } }
        .fullScreenCover(item: $viewerImage) { msg in
            ImageViewerView(message: msg, cid: p.cid, rectScope: .profile)
        }
        .fullScreenCover(item: $viewerVideo) { msg in
            VideoPlayerScreen(message: msg, cid: p.cid, clipProvider: { nil }, rectScope: .profile)
        }
        .sheet(item: $profile) { m in
            NavigationStack {
                ContactInfoView(cid: [me, m.uid].sorted().joined(separator: "_"), name: m.name,
                                photoUrl: m.photoUrl, source: .story)
            }
        }
    }

    /// The members, owner and admins first, six shown and the rest behind Show All.
    private var membersCard: some View {
        let shown = allMembers ? p.members : Array(p.members.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            Text(GroupDirectory.membersLine(p.memberCount))
                .font(.headline).foregroundStyle(.secondary)
                .padding(.leading, 32)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, m in
                    Button { if m.uid != me { profile = m } } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: m.name, photoUrl: m.photoUrl, size: 40)
                            Text(m.uid == me ? "You" : m.name)
                                .foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            if m.role != "member" {
                                Text(m.role == "owner" ? "owner" : "admin")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < shown.count - 1 { Divider().padding(.leading, 68) }
                }
                if !allMembers, p.members.count > 6 {
                    Divider().padding(.leading, 16)
                    Button { allMembers = true } label: {
                        Text("Show All").foregroundStyle(Color(hex: 0x0A84FF))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).frame(minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}

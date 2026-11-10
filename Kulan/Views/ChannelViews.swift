import SwiftUI

/// Where the composer goes for someone who is not an admin of a channel (2026-10-28). Not following:
/// Follow. Following: Mute / Unmute in the same place (owner 2026-10-31, the reference app's way).
struct ChannelFollowerBar: View {
    let conv: Conversation
    @State private var follows = ChannelFollows.shared
    /// The tap's answer shown at once, before the server's (the reference app's join: the bar is the
    /// joined bar from the tap; a refusal springs it back).
    @State private var optimistic = false
    @State private var problem: String?

    private var following: Bool { follows.follows(conv.id) }
    /// Drawn as followed: the server says so, or my tap is on its way.
    private var joined: Bool { following || optimistic }

    /// Why Follow cannot work here, in the server's words (`followRefusal`), owner 2026-10-29 audit
    /// U4: the bar offered Follow on a private channel and to a banned person, then bounced back.
    private var followBlocked: String? {
        let me = AuthService.shared.uid ?? ""
        if !me.isEmpty, conv.bannedUids.contains(me) { return "You're banned from this channel." }
        // ⛔ NO "PRIVATE" GUESS HERE (owner 2026-10-29: a public channel opened from search showed
        // "This channel is private" in place of Follow after a visit to its profile). This page's
        // copy of the channel cannot be trusted to carry its public name, and a wrong "you can't" is
        // worse than a tap: Follow stays, and a truly private channel answers with the server's
        // own refusal (`problem`), as it did before the audit's U4.
        return nil
    }

    var body: some View {
        VStack(spacing: 8) {
            if let problem {
                Text(problem).font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // Similar channels, right after following (owner 2026-10-31), above the bar, until closed.
            if joined && SimilarChannels.showsAfterFollow(conv.id) {
                SimilarChannelsStrip(cid: conv.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !joined, let blocked = followBlocked {
                Self.noticeCard(blocked)
            } else {
                // ⛔ ONE BAR THAT BECOMES THE OTHER (owner 2026-10-29: "use exactly the join animation
                // the reference app uses"). Read from its ChatChannelSubscriberInputPanelNode: Join
                // swaps to the joined state the moment it is tapped (`isJoining` shows the joined
                // action), no spinner, and the same glass panel morphs on one 0.4 s spring — the blue
                // tint goes, the words cross-fade, the size settles. Ours ends on the official chat's
                // card (`noticeCard`, owner's ask); a refusal springs it back to Follow.
                followMorph
            }
        }
        .frame(maxWidth: .infinity)
        .systemBarChrome()
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: joined)
        // The list now says so: the tap's stand-in is done (so a later unfollow shows Follow again).
        .onChange(of: following) { _, now in if now { optimistic = false } }
    }

    /// ⛔ FOLLOW BECOMES MUTE (owner 2026-10-31, from the reference app: its channel's Join turns
    /// into Mute / Unmute in the same place). One capsule: blue Follow while I do not follow; at the
    /// tap it settles into a light glass Mute. A tap mutes or unmutes; press and hold for the timed
    /// choices, the same ones the channel's page offers (`GroupInfoView.muteMenuItems`).
    private var followMorph: some View {
        Group {
            if joined {
                Menu {
                    if muted {
                        Button("Unmute") { setMute(0) }
                    } else {
                        Section("Mute for…") {
                            Button("1 hour") { setMute(ChatService.muteUntil(1)) }
                            Button("8 hours") { setMute(ChatService.muteUntil(8)) }
                            Button("1 day") { setMute(ChatService.muteUntil(24)) }
                            Button("1 week") { setMute(ChatService.muteUntil(168)) }
                        }
                        Button(role: .destructive) { setMute(ChatService.muteUntil(nil)) } label: {
                            Label("Mute Forever", systemImage: "bell.slash")
                        }
                    }
                } label: {
                    barLabel(icon: muted ? "bell" : "bell.slash", text: muted ? "Unmute" : "Mute", blue: false)
                } primaryAction: {
                    setMute(muted ? 0 : ChatService.muteUntil(nil))
                }
                .accessibilityLabel(muted ? "Unmute channel" : "Mute channel")
            } else {
                Button { follow() } label: { barLabel(icon: nil, text: "Follow", blue: true) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Follow")
            }
        }
        .padding(.horizontal, 16)
    }

    private var muted: Bool { follows.entry(conv.id)?.isMuted ?? false }

    private func setMute(_ until: Double) {
        // No buzz (owner 2026-10-31: "remove the vibrate" on Mute / Unmute).
        Task { _ = await ChatService.setMute(conv.id, until: until) }
    }

    /// The one capsule both states draw, so the spring on `joined` carries one into the other.
    private func barLabel(icon: String?, text: String, blue: Bool) -> some View {
        // ⛔ MUTE ⇄ UNMUTE ROLLS, IT DOES NOT BLINK (owner 2026-10-31): the old words slide up and
        // fade while the new ones come up from below, the way the reference app swaps this title.
        ZStack {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 16, weight: .semibold)) }
                Text(text).font(.system(size: 17, weight: .semibold))
            }
            .id(text)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                    removal: .opacity.combined(with: .offset(y: -10))))
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: text)
        .clipped()
        // ⛔ FOLLOW: BLACK IN LIGHT MODE, WHITE IN DARK (owner 2026-11-08, later the same day as his
        // "liquid glass"): glass tinted with the primary colour, the words in the background colour.
        // Mute stays clear glass with primary words.
        .foregroundStyle(blue ? Color(.systemBackground) : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .liquidGlass(RoundedRectangle(cornerRadius: 25, style: .continuous),
                     interactive: true, tint: blue ? Color.primary : nil)
        .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
    }

    /// The official chat's bottom card, word for word in style (`OfficialChatView.cannotReplyBar`).
    static func noticeCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// Said when Follow only filed a join request (the bar and Find Channels say the same words).
    static let requestSent = "Request sent. An admin will review it."

    private func follow() {
        guard !joined else { return }
        guard NetworkState.shared.isOnline else { problem = "No internet connection. Try again."; return }
        problem = nil
        let cid = conv.id
        Haptics.impact(.light)
        // Joined from the tap, as the reference app's bar is; the server's answer only confirms it.
        optimistic = true
        Task {
            do {
                let status = try await ChannelService.follow(cid: cid)
                // A channel that needs approval only files a request (owner 2026-10-30: the bar faded
                // away for good and nothing said a request went out). No follow will land, so the bar
                // comes back and the toast says what happened.
                if status == "requested" {
                    optimistic = false
                    ToastNotice.show(Self.requestSent)
                }
                // Otherwise the follow list confirms it (`following`); this stays until then so the
                // bar never blinks back to Follow between the answer and the listener.
            } catch {
                problem = error.localizedDescription
                optimistic = false   // springs back to Follow (the bar's .animation on `joined`)
            }
        }
    }
}

/// FIND CHANNELS (2026-10-28): public channels in the server ranking (2026-10-30), this country's first (the
/// reference directory's country filter). A tap opens the channel to look at before following
/// (`GroupDirectory.open`, the public group page's way); Follow follows from the list.
struct DiscoverChannelsView: View {
    /// Opens the channel once the sheets above it are down (the presenter closes them).
    var onOpen: (_ cid: String, _ handle: String?) -> Void = { cid, handle in GroupDirectory.open(cid: cid, name: handle) }
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ChannelService.Discovered] = []
    @State private var loading = true
    @State private var failed = false
    @State private var busy: Set<String> = []
    /// Followed from this list, before the follow list says so; each id goes once the listener has it.
    @State private var justFollowed: Set<String> = []
    /// ⛔ THE CHANNEL OPENS IN HERE (owner 2026-10-31: "open a channel from Find Channels, leave it,
    /// and it takes me to the chat list instead of back where I came from"). A row opened inside this
    /// sheet's own stack, the way the contact page opens a chat inside itself, so Back and Leave come
    /// back to the list. Only when the caller asks for it (`opensInPlace`); otherwise `onOpen` as before.
    @State private var openFollowed: ChatTarget?
    @State private var openVisitor: PublicGroupTarget?
    var opensInPlace = false
    @State private var follows = ChannelFollows.shared

    @State private var query = ""
    /// The loaded channels the search field keeps (name or @handle), in the server's order.
    private var shown: [ChannelService.Discovered] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.handle.localizedCaseInsensitiveContains(q) }
    }

    /// The ids the follow list confirms, so `justFollowed` can let go of them.
    private var confirmedIds: Set<String> {
        Set(justFollowed.filter { follows.follows($0) })
    }

    /// Pushed inside New Message (owner 2026-10-31): no stack or X of its own, the system's Back.
    var embedded = false

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
            List {
                if loading && rows.isEmpty {
                    // Rows shaped like the channels on their way, not a spinner (owner 2026-10-31).
                    ForEach(0..<8, id: \.self) { i in
                        DiscoverRowSkeleton(nameWidth: [130, 100, 160, 115][i % 4])
                            .listRowSeparator(.hidden)
                    }
                } else if failed && rows.isEmpty {
                    Text("Couldn't load channels. Check your connection and try again.")
                        .foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else if rows.isEmpty {
                    Text("No public channels yet. Only public channels show here: to list yours, open it, tap its name, then Channel Settings > Channel Type > Public.")
                        .foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else if shown.isEmpty {
                    Text("No channels match \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}.")
                        .foregroundStyle(.secondary).listRowSeparator(.hidden)
                } else {
                    ForEach(shown) { row($0) }
                }
            }
            // ⛔ DESIGN A (owner 2026-11-10, picked from 4 mockups): a plain list, round photos,
            // name + tick + follower count, a solid Follow pill that turns grey "Following".
            // No card, no descriptions, a search field under the title.
            .listStyle(.plain)
            // The chat list's own search bar: `.searchable` at its defaults (owner 2026-11-10).
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Find Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            // The listener has it now: the stand-in goes, so a later unfollow shows Follow again.
            .onChange(of: confirmedIds) { _, ids in if !ids.isEmpty { justFollowed.subtract(ids) } }
            // Left from inside (its page's Leave): back to the list at once, not a chat I no longer follow.
            .onChange(of: openFollowed.map { isMine($0.id) }) { _, now in
                if now == false { openFollowed = nil }
            }
            .navigationDestination(item: $openFollowed) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo)
            }
            .navigationDestination(item: $openVisitor) { t in
                PublicGroupSheet(target: t, pushed: true)
            }
    }

    /// Find Channels pushed from the chat list's compass (owner 2026-11-10: slides in from the right).
    struct Route: Hashable {}

    private func row(_ c: ChannelService.Discovered) -> some View {
        HStack(spacing: 12) {
            Button {
                if opensInPlace {
                    if isMine(c.cid) {
                        openFollowed = ChatTarget(id: c.cid, name: c.title, photo: c.photoUrl)
                    } else {
                        openVisitor = PublicGroupTarget(cid: c.cid, name: c.handle.isEmpty ? nil : c.handle)
                    }
                } else {
                    onOpen(c.cid, c.handle.isEmpty ? nil : c.handle)
                }
            } label: {
                HStack(spacing: 12) {
                    AvatarView(name: c.title, photoUrl: c.photoUrl, size: 52).avatarSquircle(true)   // channels wear the squircle (owner 2026-11-10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(c.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                .layoutPriority(1)
                            GroupVerifiedMark(on: c.verified, size: 14, label: c.label)
                            // The official channel says so (owner 2026-10-30), in the app's grey. It gives
                            // way first when the row is narrow (owner 2026-10-31: "Fariin N…" was cut off).
                            if c.official {
                                ViewThatFits(in: .horizontal) {
                                    Text("Official").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Color.clear.frame(width: 0, height: 0)
                                }
                            }
                        }
                        // The live count, my own follow from here included (owner 2026-10-30: followed
                        // from this list and it still said 3), the one every channel page uses.
                        Text(GroupDirectory.followersLine(ChannelCountBias.visitorCount(
                            c.cid, memberCount: c.followerCount, followerCount: max(0, c.followerCount - c.admins))))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            followButton(c)
        }
        // Closer rows (owner 2026-11-10: the gap between channels was too big): the list's own row
        // padding replaced by 8 pt above and below, so 52 pt faces sit 16 pt apart.
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        // No lines between rows (owner 2026-11-10).
        .listRowSeparator(.hidden)
    }

    /// Followed, or one of its admins (owner 2026-10-31: tapping his own Fariin News here went to the
    /// visitor page, which handed off to the chat and closed everything onto the chat list). An admin
    /// is a member, not a follower, so "follows" alone was false for the people who run the channel.
    private func isMine(_ cid: String) -> Bool {
        follows.follows(cid)
            || ConversationsRepository.shared.conversations.contains { $0.id == cid && $0.users.contains(AuthService.shared.uid ?? "") }
    }

    @ViewBuilder private func followButton(_ c: ChannelService.Discovered) -> some View {
        let mine = isMine(c.cid) || justFollowed.contains(c.cid)
        Button {
            guard !mine, !busy.contains(c.cid) else { return }
            busy.insert(c.cid)
            // ⛔ FOLLOWING AT THE TAP (owner 2026-10-31: the button shrank to "…" and said nothing).
            // As the in-chat Follow bar does: the answer comes behind, and only a request or a
            // refusal takes it back. Held until the follow list catches up (owner 2026-10-30: it
            // flickered back to Follow between the answer and the listener).
            justFollowed.insert(c.cid)
            Haptics.notify(.success)
            Task {
                do {
                    let status = try await ChannelService.follow(cid: c.cid)
                    if status == "requested" {
                        // Only a request (owner 2026-10-30): said, and the button goes back to Follow.
                        justFollowed.remove(c.cid)
                        ToastNotice.show(ChannelFollowerBar.requestSent)
                    }
                }
                catch {
                    justFollowed.remove(c.cid)
                    ToastNotice.show(error.localizedDescription)
                }
                busy.remove(c.cid)
            }
        } label: {
            Text(mine ? "Following" : "Follow")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(mine ? Color.secondary : Color.onFariinAction)
                .padding(.horizontal, 16).frame(height: 34)
                // Design A: solid action colour to follow, plain grey once following.
                .background(Capsule().fill(mine ? Color(.secondarySystemFill) : Color.fariinAction))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: mine)
        }
        .buttonStyle(.plain)
        .disabled(mine)
    }

    private func load() async {
        loading = true
        if DemoMode.storeShots { rows = DemoMode.storeChannels(); failed = false; loading = false; return }
        do { rows = try await ChannelService.discover(); failed = false }
        catch { failed = true }
        loading = false
    }
}

/// A channel's followers, for its admins (2026-10-28): newest first, 50 at a time, swipe to remove
/// (or remove and keep out). Nobody else sees who follows.
struct ChannelFollowersView: View {
    let cid: String
    /// ⛔ THE COUNT AS THE PAGE OPENED, HELD ONCE (owner 2026-10-30): the parent passes a live value,
    /// so once the server's count landed each Remove / Ban / Add was in it AND in `removed` / `added`,
    /// counted twice. `@State` keeps the first value for the page's life; only this page adjusts it.
    @State private var count: Int

    init(cid: String, count: Int) {
        self.cid = cid
        _count = State(initialValue: count)
    }

    struct Follower: Identifiable, Hashable {
        let uid: String; let name: String; let photoUrl: String?
        /// The @username under the name (owner 2026-11-08); empty when they have none.
        var username: String = ""
        var id: String { uid }
    }

    /// May I remove and ban followers: the owner, or an admin holding `banUsers` (the server's test).
    private var mayRemove: Bool {
        let me = AuthService.shared.uid ?? ""
        return ConversationsRepository.shared.conversations.first { $0.id == cid }?.adminCan(me, .banUsers) == true
    }

    @State private var rows: [Follower] = []
    @State private var more = true
    @State private var loading = false
    @State private var failed = false
    @State private var confirm: (Follower, Bool)?
    /// Ban or plain Remove, copied in as the alert opens so its words hold while it fades.
    @State private var confirmBan = false
    /// Taken off the header's count on each Remove / Ban (owner 2026-10-29 audit U10: `count` is the
    /// number when the page opened, and it did not go down).
    @State private var removed = 0
    /// Added from this page (owner 2026-10-30, Add Followers): on top of `count`, which is the number
    /// when the page opened.
    @State private var added = 0
    @State private var showAdd = false
    @State private var adding = false
    /// People whose own settings refused the add: offered the link instead (`InviteInsteadSheet`).
    @State private var linkInstead: [CallMember] = []
    @State private var shareText: String?
    /// The person whose profile a row tap opens (owner 2026-11-09: tapping a follower did nothing).
    @State private var profileOf: Follower?
    /// May I add people: the owner, or an admin holding "Add users" (the server's own test).
    private var mayInvite: Bool { conv?.adminCan(AuthService.shared.uid ?? "", .inviteUsers) == true }
    /// ⛔ THE ADMINS ARE ON THE LIST AND IN ITS COUNT (owner 2026-10-29: the page said "3 Followers",
    /// the list showed one). The reference app counts a channel's admins among its subscribers and
    /// lists them first, marked; `Conversation.subscriberCount` already counts them the same way.
    private var conv: Conversation? { ConversationsRepository.shared.conversations.first { $0.id == cid } }
    private var admins: [String] {
        guard let c = conv else { return [] }
        return c.users.sorted { a, b in
            if (a == c.createdBy) != (b == c.createdBy) { return a == c.createdBy }
            return (c.names[a] ?? "").lowercased() < (c.names[b] ?? "").lowercased()
        }
    }
    /// The loaded followers who are not admins (the admins are listed above them).
    private var followerRows: [Follower] { rows.filter { !(conv?.users.contains($0.uid) ?? false) } }
    private var shownCount: Int { max(0, count - removed + added) + admins.count }

    var body: some View {
        List {
            // ⛔ ADD FOLLOWERS (owner 2026-10-30: "there's no way to add people, only the link").
            // Public or private: pick people from my chats; anyone whose own "Who can add me" refuses
            // it is offered the channel's link instead. Admins with "Add users" only.
            if mayInvite {
                Section {
                    Button { showAdd = true } label: {
                        Label { Text(adding ? "Adding…" : "Add Followers") } icon: { Image(systemName: "person.badge.plus") }
                    }
                    .disabled(adding)
                    Button { Task { await shareInvite() } } label: {
                        Label { Text("Invite via Link") } icon: { Image(systemName: "link") }
                    }
                }
            }
            Section {
                ForEach(admins, id: \.self) { uid in
                    HStack(spacing: 12) {
                        AvatarView(name: conv?.names[uid] ?? "", photoUrl: conv?.photos[uid], size: 40)
                        Text(uid == AuthService.shared.uid ? "You" : (conv?.names[uid] ?? "")).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(uid == conv?.createdBy ? "Owner" : "Admin")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard uid != AuthService.shared.uid else { return }
                        profileOf = Follower(uid: uid, name: conv?.names[uid] ?? "", photoUrl: conv?.photos[uid])
                    }
                }
                ForEach(followerRows) { f in
                    HStack(spacing: 12) {
                        AvatarView(name: f.name, photoUrl: f.photoUrl, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).lineLimit(1)
                            if !f.username.isEmpty {
                                Text("@" + f.username).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if f.uid != AuthService.shared.uid { profileOf = f } }
                    // Only an admin who may remove people (the server now asks for `banUsers`,
                    // 2026-10-29 review fix); others see the list without the swipe.
                    .swipeActions(edge: .trailing) {
                        if mayRemove {
                            Button("Remove", role: .destructive) { confirmBan = false; confirm = (f, false) }.tint(.red)
                            Button("Ban") { confirmBan = true; confirm = (f, true) }.tint(.orange)
                        }
                    }
                    .onAppear { if f == rows.last, more { Task { await load() } } }
                }
                // ⛔ A SKELETON, NOT A SPINNER, for the first page (owner 2026-10-29): the real row's
                // shape (40pt face, a name line), one per follower up to eight. A spinner stays
                // only for the next page at the foot of a list already on screen.
                if loading && rows.isEmpty {
                    ForEach(0..<max(1, min(count, 8)), id: \.self) { i in
                        HStack(spacing: 12) {
                            SkeletonCircle(size: 40)
                            SkeletonBlock(width: [140, 110, 170, 95][i % 4], height: 13)
                            Spacer(minLength: 0)
                        }
                        .accessibilityHidden(true)
                    }
                } else if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if failed { Text("Couldn't load followers. Pull to try again.").foregroundStyle(.secondary) }
                // Nobody yet: said, not a spinner (owner 2026-10-29: it turned on an empty list).
                // The followers list alone (owner 2026-10-30): `admins` always holds the owner, so
                // testing it too meant this line could never show.
                if followerRows.isEmpty, !loading, !failed, !more {
                    Text("No followers yet. Share the channel to get your first ones.").foregroundStyle(.secondary)
                }
            } header: {
                Text(GroupDirectory.followersLine(shownCount))
            } footer: {
                Text("Only admins can see who follows this channel.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Followers")
        .navigationBarTitleDisplayMode(.inline)
        // The same profile page a group member's row opens (GroupInfoView `profileOf`).
        .navigationDestination(item: $profileOf) { f in
            ContactInfoView(cid: ChatService.convId(AuthService.shared.uid ?? "", f.uid), name: f.name,
                            photoUrl: f.photoUrl, source: .calls)
        }
        .refreshable { rows = []; more = true; await load() }
        .task { if rows.isEmpty { await load() } }
        // The words come from `confirmBan`, set when the alert opens and never cleared (owner
        // 2026-10-30): `confirm` goes nil as the alert closes, and the text flipped during the fade.
        .alert(confirmBan ? "Remove and ban?" : "Remove follower?",
               isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button(confirmBan ? "Ban" : "Remove", role: .destructive) {
                guard let pick = confirm else { return }
                let f = pick.0, ban = pick.1
                Task {
                    do {
                        try await ChannelService.removeFollower(cid: cid, uid: f.uid, ban: ban)
                        rows.removeAll { $0.uid == f.uid }
                        removed += 1
                    } catch { ToastNotice.show(error.localizedDescription) }
                }
            }
        } message: {
            Text(confirmBan ? "They stop following and can't follow again."
                                    : "They stop following. They can follow again if the channel is public.")
        }
        .sheet(isPresented: $showAdd) {
            AddPeopleSheet(alreadyIn: Set(admins + rows.map(\.uid)), actionTitle: "Add") { people in
                Task { await add(people) }
            }
        }
        .sheet(isPresented: Binding(get: { !linkInstead.isEmpty }, set: { if !$0 { linkInstead = [] } })) {
            if let c = conv {
                InviteInsteadSheet(conv: c, people: linkInstead) { linkInstead = [] }
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: Binding(get: { shareText.map { ShareText(id: $0) } }, set: { shareText = $0?.id })) { t in
            SendContactSheet(contactText: t.id)
        }
    }

    static let addsFull = "This channel has added 10 people, the most it can. Others can follow it with its link."

    private func add(_ people: [CallMember]) async {
        guard !people.isEmpty else { return }
        adding = true
        defer { adding = false }
        do {
            let r = try await ChannelService.addFollowers(cid: cid, uids: people.map(\.uid))
            added += r.added.count
            let linkOnly = Set(r.linkOnly)
            let others = r.refused.filter { !linkOnly.contains($0) }.count
            if !r.added.isEmpty {
                Haptics.notify(.success)
                ToastNotice.show(r.added.count == 1 ? "1 follower added" : "\(r.added.count) followers added")
                rows = []; more = true
                await load()
            } else if r.refused.isEmpty && r.capped.isEmpty {
                ToastNotice.show(people.count == 1 ? "Already following" : "They already follow this channel")
            }
            if others > 0 {
                ToastNotice.show(others == 1 ? "1 person couldn't be added" : "\(others) people couldn't be added")
            }
            // Past the ten adds (owner 2026-10-30): said, and they are offered the link like those
            // whose own setting refused the add.
            if !r.capped.isEmpty { ToastNotice.show(Self.addsFull) }
            let viaLink = linkOnly.union(r.capped)
            linkInstead = people.filter { viaLink.contains($0.uid) }
        } catch {
            ToastNotice.show(error.localizedDescription)
        }
    }

    private func shareInvite() async {
        guard let c = conv else { return }
        guard let link = await ChannelService.shareLink(c) else {
            ToastNotice.show("Couldn't get the channel's link. Check your connection and try again.")
            return
        }
        shareText = "Follow \u{201C}\(c.title)\u{201D} on Fariin: " + link
    }

    private func load() async {
        guard !loading, more else { return }
        // ⛔ ALWAYS ASK THE SERVER (owner 2026-10-30): the stored count lags about a minute, so a
        // "0" skip hid the first followers and made pull-to-refresh do nothing.
        loading = true; failed = false
        do {
            let page = try await ChannelService.followers(cid: cid, after: rows.last?.uid)
            let seen = Set(rows.map(\.uid))
            rows += page.rows.filter { !seen.contains($0.uid) }
            more = page.more
        } catch { failed = true }
        loading = false
    }
}

/// People whose own "Who can add me" refused an add to a channel (owner 2026-10-30): they are sent
/// the channel's link in their chat with me instead, each one ticked by default. Our own card, not
/// the reference app's: the people first, one plain sentence, one button.
struct InviteInsteadSheet: View {
    let conv: Conversation
    let people: [CallMember]
    let onDone: () -> Void
    @State private var picked: Set<String>
    @State private var sending = false
    @Environment(\.dismiss) private var dismiss

    init(conv: Conversation, people: [CallMember], onDone: @escaping () -> Void) {
        self.conv = conv
        self.people = people
        self.onDone = onDone
        _picked = State(initialValue: Set(people.map(\.uid)))
    }

    private var names: String {
        let n = people.map { ContactNames.shared.name(for: $0.uid) ?? $0.name }
        return n.count <= 2 ? n.joined(separator: " and ") : "\(n[0]) and \(n.count - 1) others"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(people) { p in
                        Button {
                            if picked.contains(p.uid) { picked.remove(p.uid) } else { picked.insert(p.uid) }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: p.name, photoUrl: p.photoUrl, size: 40)
                                Text(ContactNames.shared.name(for: p.uid) ?? p.name).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: picked.contains(p.uid) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(picked.contains(p.uid) ? Color.fariinAction : Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(names) only \(people.count == 1 ? "lets" : "let") certain people add them to channels. Send the channel's link in your chat instead.")
                        .textCase(nil)
                }
            }
            .navigationTitle("Send the Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { Task { await send() } } label: {
                    Text(sending ? "Sending…" : (picked.count > 1 ? "Send Link to \(picked.count)" : "Send Link"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.onFariinAction)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.fariinAction, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty || sending)
                .opacity(picked.isEmpty ? 0.5 : 1)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    private func send() async {
        sending = true
        let sent = await ChannelService.sendInviteLink(conv, to: Array(picked))
        sending = false
        if sent > 0 {
            Haptics.notify(.success)
            ToastNotice.show(sent == 1 ? "Link sent" : "Link sent to \(sent) people")
            close()
        } else {
            ToastNotice.show("Couldn't send the link. Check your connection and try again.")
        }
    }

    private func close() { onDone(); dismiss() }
}

/// Hold Post > Schedule Post (2026-10-28): when this text goes out. A minute from now at the
/// earliest, a year at the latest (the server holds the same line).
struct SchedulePostSheet: View {
    let text: String
    let onSchedule: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var when = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(text).lineLimit(4).foregroundStyle(.secondary)
                }
                Section {
                    DatePicker("Post on", selection: $when,
                               in: Date().addingTimeInterval(120)...Date().addingTimeInterval(364 * 86_400))
                        .datePickerStyle(.graphical)
                } footer: {
                    Text("Followers get it at that time, the way a post you send now arrives.")
                }
            }
            .navigationTitle("Schedule Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") { onSchedule(when); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// A channel's posts waiting to go out, for its admins (2026-10-28): swipe to cancel.
struct ScheduledPostsView: View {
    let cid: String
    @State private var posts: [ChannelService.ScheduledPost] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        List {
            if loading && posts.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            } else if failed && posts.isEmpty {
                Text("Couldn't load. Pull to try again.").foregroundStyle(.secondary)
            } else if posts.isEmpty {
                Text("Nothing scheduled. Hold Post in the channel to schedule one.").foregroundStyle(.secondary)
            } else {
                ForEach(posts) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.fariinAction)
                        Text(p.text).lineLimit(3)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Cancel", role: .destructive) {
                            Task {
                                do { try await ChannelService.cancelScheduled(id: p.id); posts.removeAll { $0.id == p.id } }
                                catch { ToastNotice.show(error.localizedDescription) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Scheduled Posts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        do { posts = try await ChannelService.scheduled(cid: cid); failed = false } catch { failed = true }
        loading = false
    }
}

/// The sheet a channel admin invite link opens (2026-10-29): the channel, who invited, when it
/// lapses; Accept / Decline for the person invited, Revoke for the channel's admins.
struct AdminInviteSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var info: ChannelAdminInvites.Info?
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 14) {
            if let info {
                AvatarView(name: info.title, photoUrl: info.photoUrl, size: 96).avatarSquircle(true).padding(.top, 28)
                Text(info.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text("Channel admin invite").font(.body).foregroundStyle(.secondary)
                Text(stateLine(info)).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer(minLength: 8)
                if info.state == "open" && info.forMe {
                    Text("Admins post in the channel and can change its name, photo and settings. Followers never see who the admins are.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                    wideButton("Accept", tint: Color.fariinAction) { answer(true) }
                    Button("Decline") { answer(false) }.foregroundStyle(.red).disabled(busy)
                } else if info.canRevoke {
                    wideButton("Revoke", tint: .red) { revoke() }
                }
            } else if let problem {
                Spacer()
                Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                Spacer()
            } else {
                Spacer(); ProgressView(); Spacer()
            }
            if let problem, info != nil {
                Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .task { await load() }
    }

    private func stateLine(_ i: ChannelAdminInvites.Info) -> String {
        switch i.state {
        case "accepted": return "Accepted."
        case "declined": return "Declined."
        case "revoked": return "This invite was revoked."
        case "expired": return "This invite has expired."
        case "gone": return "This channel no longer exists."
        default:
            let from = i.forMe ? "\(i.fromName) invited you. " : ""
            guard let exp = i.expiresAt else { return from }
            let days = max(1, Int(ceil(exp.timeIntervalSinceNow / 86_400)))
            return from + "Expires in \(days) day\(days == 1 ? "" : "s")."
        }
    }

    private func wideButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fontWeight(.semibold).foregroundStyle(tint == .red ? Color.white : Color.onFariinAction)
                .frame(maxWidth: .infinity).frame(height: 50)
                .liquidGlass(Capsule(), interactive: true, tint: tint)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .padding(.horizontal, 20)
    }

    private func load() async {
        do { info = try await ChannelAdminInvites.info(code) }
        catch { problem = error.localizedDescription }
    }

    private func answer(_ accept: Bool) {
        busy = true; problem = nil
        Task {
            do {
                let cid = try await ChannelAdminInvites.answer(code, accept: accept)
                let title = info?.title ?? "Channel"
                dismiss()
                if accept, let cid, !cid.isEmpty {
                    ToastNotice.show("You're now an admin of \(title).")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { GroupDirectory.open(cid: cid, name: nil) }
                }
            } catch { problem = error.localizedDescription; busy = false }
        }
    }

    private func revoke() {
        busy = true
        Task {
            do { try await ChannelAdminInvites.revoke(code); dismiss() }
            catch { problem = error.localizedDescription; busy = false }
        }
    }
}

/// The admin invites still waiting, on a channel's Administrators page (owner 2026-10-29: moved off
/// the channel's info page, with Invite Followers / Invite Admins, which Share and Add Admin cover).
/// Tap one to revoke it.
///
/// ⛔ A PLAIN VALUE, NO STATE (owner 2026-10-29 review fix). This section used to load its own list
/// with `.task` and carry the revoke `.alert`. Inside a List, a Section hands its modifiers to its
/// rows, so with no rows yet the task never ran ("Waiting to Accept" never filled), and with rows
/// there was one alert per row. The page loads the list (`ChannelPendingAdminsLoader` on its List)
/// and passes it in.
struct ChannelPendingAdminsSection: View {
    let pending: [ChannelAdminInvites.Pending]
    let onTap: (ChannelAdminInvites.Pending) -> Void

    var body: some View {
        Section {
            ForEach(pending) { p in
                HStack(spacing: 12) {
                    AvatarView(name: p.name, photoUrl: p.photoUrl, size: 40)
                    Text(p.name).lineLimit(1)
                    Spacer(minLength: 0)
                    // What he was invited to (owner 2026-10-29: "Invited" read as "invited to follow").
                    Text("Invited as admin").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap(p) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Revokes the invite")
            }
        } header: {
            Text("Waiting to Accept")
        }
    }
}

/// Loads the waiting admin invites for `ChannelPendingAdminsSection` and owns its revoke alert. Put
/// on the page's List, not on the Section, so the load runs even while the list is empty.
/// `tick` changes after an invite is sent, to show it at once.
struct ChannelPendingAdminsLoader: ViewModifier {
    let cid: String
    let on: Bool
    let tick: Int
    @Binding var pending: [ChannelAdminInvites.Pending]
    @Binding var revoking: ChannelAdminInvites.Pending?

    func body(content: Content) -> some View {
        content
            .task(id: LoadKey(on: on, tick: tick)) {
                guard on else { return }
                await reload()
            }
            // The name falls back to `shownName`, the last one asked about (owner 2026-10-30):
            // `revoking` goes nil as the alert closes, and the words flipped to "" / "they" mid-fade.
            .alert("Revoke admin invite for \(revoking?.name ?? shownName)?",
                   isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button("Revoke", role: .destructive) { revoke() }
            } message: {
                Text("If you revoke it, \(revoking?.name ?? shownName) can no longer use it to become an admin of this channel.")
            }
            .onChange(of: revoking?.name) { _, name in if let name { shownName = name } }
    }

    @State private var shownName = ""

    private struct LoadKey: Equatable { let on: Bool; let tick: Int }

    private func revoke() {
        guard let p = revoking else { return }
        Task {
            // A refused revoke used to fail without a word (owner 2026-10-29 audit U11).
            do { try await ChannelAdminInvites.revoke(p.code) }
            catch { ToastNotice.show(error.localizedDescription) }
            await reload()
        }
    }

    private func reload() async {
        if let p = try? await ChannelAdminInvites.pending(cid: cid) { pending = p }
    }
}

/// The top of a channel for its owner and admins (owner 2026-10-29): the channel, how many follow
/// it, and the two things that grow it, Share and Edit. Followers never see this card.
struct ChannelAdminCard: View {
    let conv: Conversation
    let me: String

    @State private var showEdit = false
    @State private var shareText: String?

    private var canEdit: Bool { conv.adminCan(me, .changeInfo) }
    private var startedLine: String {
        conv.createdBy == me ? "You created this channel" : "You're an admin of this channel"
    }
    private var followersLine: String {
        // Admins counted, the reference app's subscriber count (`Conversation.subscriberCount`).
        conv.subscriberCount == 1 ? "1 follower" : "\(conv.subscriberCount) followers"
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Button { if canEdit { showEdit = true } } label: {
                    AvatarView(name: conv.title, photoUrl: conv.avatarUrl, size: 92).avatarSquircle(true)
                        .overlay(alignment: .bottomTrailing) {
                            if canEdit && (conv.avatarUrl ?? "").isEmpty {
                                Image("ic_group_camera").renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 16, height: 16).foregroundStyle(.primary)
                                    .frame(width: 32, height: 32)
                                    .liquidGlass(Circle())
                            }
                        }
                }
                .buttonStyle(.plain)
                .allowsHitTesting(canEdit)
                .accessibilityLabel(canEdit ? "Edit Channel" : conv.title)

                VStack(spacing: 3) {
                    Text(conv.title).font(.title3.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("\(startedLine) · \(followersLine)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            // From the same number as the line above (owner 2026-10-30): the raw `followerCount` lags
            // the adjusted one, so a channel showing followers still offered this hint. Only admins.
            if conv.subscriberCount <= conv.users.count {
                Text("Share your channel so people can follow it.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 0) {
                circle("ic_share_up", "Share") { Task { await share() } }
                if canEdit {
                    circle("pencil", conv.groupDescription.isEmpty ? "Description" : "Edit") { showEdit = true }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 24)
        .frame(maxWidth: 340)
        .liquidGlass(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .padding(.horizontal, 20)
        .sheet(isPresented: $showEdit) {
            EditGroupView(cid: conv.id, title: conv.title, photoUrl: conv.avatarUrl,
                          description: conv.groupDescription)
        }
        .sheet(item: Binding(get: { shareText.map { ShareText(id: $0) } }, set: { shareText = $0?.id })) { t in
            SendContactSheet(contactText: t.id)
        }
    }

    private func circle(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PosterActionIcon(icon: icon, diameter: 56, onPhoto: false, label: title)
        }
        .tint(.primary)
        .accessibilityLabel(title)
    }

    /// The public link, else the private channel's invite link.
    private func share() async {
        let link: String
        if conv.isPublic, !conv.publicName.isEmpty {
            link = "https://fariin.com/" + conv.publicName
        } else if !conv.adminCan(me, .inviteUsers) {
            // Said as it is (owner 2026-10-29 audit U16): it used to blame the connection.
            ToastNotice.show("This channel is private. Only admins who can invite followers can share its link.")
            return
        } else if let code = await ChannelInviteLink.code(conv.id) {
            link = KulanApp.groupLink(code: code)
        } else {
            ToastNotice.show("Couldn't get the channel's link. Check your connection and try again.")
            return
        }
        shareText = "Follow \u{201C}\(conv.title)\u{201D} on Fariin: " + link
    }
}

/// The top of a channel for everyone who is not an admin (owner 2026-10-31: a new follower opened
/// Fariin News to a white page and one line). Who the channel is, in one glance: photo, name with
/// its badge, @name, what it is about, and when it began. Nothing to tap; the bar below does that.
struct ChannelFollowerCard: View {
    let conv: Conversation

    private var createdLine: String? {
        guard let d = conv.createdAt else { return nil }
        return "Created " + d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        VStack(spacing: 10) {
            AvatarView(name: conv.title, photoUrl: conv.avatarUrl, size: 92).avatarSquircle(true)
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Text(conv.title).font(.title3.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.center)
                    GroupVerifiedMark(on: conv.showsGroupBadge, size: 18, kind: conv.groupVerifiedType)
                }
                if conv.isPublic, !conv.publicName.isEmpty {
                    Text("@" + conv.publicName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !conv.groupDescription.isEmpty {
                Text(conv.groupDescription)
                    .font(.subheadline).multilineTextAlignment(.center).lineLimit(4)
                    .padding(.top, 2)
            }
            if let createdLine {
                Text(createdLine).font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 24)
        .frame(maxWidth: 340)
        .liquidGlass(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .padding(.horizontal, 20)
    }
}

/// A channel post's reactions (2026-10-29), opened from the row under the post: every emoji with its
/// count, mine ringed. A follower taps one to react (the same one again takes it back); an admin sees
/// the counts. Never who reacted: nobody, not even the admins, is shown that.
struct ChannelReactSheet: View {
    /// What I may pick from: the channel's own six, or the quick set when any emoji goes.
    let offered: [String]
    let counts: [String: Int]
    let mine: String?
    let canReact: Bool
    /// Any emoji allowed: a "More" circle opens the full picker.
    let allowMore: Bool
    let onPick: (String) -> Void
    let onMore: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// The offered ones in their order, then any others already on the post, most first.
    private var shown: [String] {
        let extra = counts.filter { $0.value > 0 && !ChannelEmoji.contains(offered, $0.key) }
            .sorted { $0.value > $1.value }.map(\.key)
        return (canReact ? offered : offered.filter { count(of: $0) > 0 }) + extra
    }
    /// Matched the server's way, with or without the variation selector (audit E3).
    private func count(of e: String) -> Int {
        counts.first { ChannelEmoji.same($0.key, e) }?.value ?? 0
    }
    private func isMine(_ e: String) -> Bool { ChannelEmoji.same(mine, e) }
    private var total: Int { counts.values.reduce(0, +) }

    var body: some View {
        VStack(spacing: 16) {
            Text(total == 0 ? "Be the first to react" : (total == 1 ? "1 reaction" : "\(total) reactions"))
                .font(.headline)
                .padding(.top, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shown, id: \.self) { e in
                        Button {
                            guard canReact else { return }
                            onPick(e)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                ReactionGlyph(emoji: e, size: 30)
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(isMine(e) ? Color.fariinAction.opacity(0.18)
                                                                         : Color(.secondarySystemBackground)))
                                    .overlay(Circle().stroke(isMine(e) ? Color.fariinAction : .clear, lineWidth: 2))
                                Text("\(count(of: e))").font(.footnote.monospacedDigit())
                                    .foregroundStyle(isMine(e) ? Color.fariinAction : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(CustomReaction.spoken(e)), \(count(of: e))")
                    }
                    if canReact && allowMore {
                        Button { dismiss(); onMore() } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(Color(.secondarySystemBackground)))
                                Text("More").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            Text(canReact ? "Only the numbers are shown. Nobody sees who reacted."
                          : "Followers react here. Nobody, admins included, sees who reacted.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(250)])
    }
}

/// Channel Settings > Reactions (2026-10-29): any emoji, only the ones I pick (up to 6), or none.
struct ChannelReactionsSettingsView: View {
    let cid: String
    @State private var mode = "all"
    @State private var list: [String] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var pickAny = false
    /// The save in flight; a newer change cancels it (no greyed-out page while it goes).
    @State private var saveTask: Task<Void, Never>?
    /// The last choice the server took, put back when a save fails (owner 2026-10-29 audit U5: the
    /// page kept the refused choice while Channel Settings showed the saved one).
    @State private var savedMode = "all"
    @State private var savedList: [String] = []
    /// The last non-empty pick list on this page, put back when Selected Emoji is chosen again.
    @State private var lastPicks: [String] = []
    /// The place in the bar being replaced (nil = the "+": a new one at the end).
    @State private var replacing: Int?

    /// What an owner picks from: a wide set, so "only these" can fit any channel.
    /// Any other emoji comes in through the emoji sheet.
    static let palette = ["👍", "❤️", "🔥", "😂", "😮", "😢", "🙏", "👏", "🎉", "💯", "🤔", "😍",
                          "👎", "😡", "🤝", "💪", "✅", "⭐️", "🌙", "☀️", "⚽️", "📌", "💡", "🙌"]
    /// Owner 2026-11-06: up to 12 (was 6). The server's REACT_LIST_MAX matches.
    static let maxPicked = 12
    /// How many a fresh "Selected" starts with, and how many sit on one row of the bar.
    static let perRow = 6
    private let blue = Color.fariinAction

    // Three plain choices and, for Selected, the bar of picks (owner
    // 2026-10-29, made minimal later the same day). Saves run in the background; the page is never
    // disabled while one goes.
    var body: some View {
        Form {
            // ⛔ MINIMAL (owner 2026-10-29: "make this page minimalist"): the three choices, and for
            // Selected one grid whose ticks are the selection. The preview card and the separate
            // "Selected" slot row are gone (they said again what the ticks say).
            // ⛔ ONE SWITCH (owner 2026-11-07): on by default with a default set picked, which he can
            // change below; off = no reactions. "Any Emoji" is gone from the page.
            Section {
                Toggle(isOn: Binding(get: { mode != "off" }, set: { setOn($0) })) {
                    Text("Reactions")
                }
                .tint(.green)
                .disabled(!loaded)
            } footer: {
                Text(mode == "off" ? "Followers can't react to posts." : "Nobody sees who reacted, only how many.")
            }
            if mode != "off" {
                // ⛔ THE PICKS IN ONE BAR (owner 2026-10-31, his drawing): the chosen emoji in a
                // rounded bar, "Tap to replace an emoji" under it, a tap opens the emoji sheet for
                // that one. A "+" fills a free place while fewer than six are chosen.
                Section {
                    reactionBar
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
                } footer: {
                    Text(list.isEmpty ? "Pick at least one, or reactions will be off."
                         : "Tap to choose reactions, up to \(Self.maxPicked)")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .navigationTitle("Reactions")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy(duration: 0.25), value: mode)
        .animation(.snappy(duration: 0.25), value: list)
        // ⛔ MANY AT ONCE, SAVED ONCE (owner 2026-11-06: "one by one is too slow, and the x gets tapped
        // by mistake"). The sheet stays open while emoji are turned on and off in `list` (the bar above
        // follows live); closing it saves once if anything changed.
        .sheet(isPresented: $pickAny, onDismiss: {
            replacing = nil
            if list != savedList || mode != savedMode { save() }
        }) {
            // Low enough that the bar stays in sight above it.
            EmojiMorePicker(title: "Choose Emoji", detents: [.fraction(0.56), .large],
                            // ⛔ EVERY PICK CAN BE UNTICKED (owner 2026-11-08: 😂 and 😮 sat in the
                            // bar and could not be removed). The default set (`palette`) holds emoji
                            // the catalog does not, so they were never in this grid. Picks outside
                            // the catalog now lead it.
                            only: EmojiCatalog.channelOffer(including: list),
                            showsCustom: CustomReaction.canChoose,
                            multi: $list, maxPicks: Self.maxPicked) { _ in }
        }
        .onAppear { loadFromList() }
        // Not in the list yet when the page opened: taken as soon as it arrives.
        .onChange(of: ConversationsRepository.shared.conversations.contains(where: { $0.id == cid })) { _, _ in loadFromList() }
        .onChange(of: list) { _, l in if !l.isEmpty { lastPicks = l } }
    }

    /// The channel's real setting, once. Until then the rows are disabled (`loaded`).
    private func loadFromList() {
        guard !loaded, let c = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) else { return }
        mode = c.reactMode
        // Custom emoji removed in the admin panel leave the editor (the server drops them on save too).
        list = c.reactList.filter { !UploadedEmoji.isRemoved($0) }
        savedMode = c.reactMode
        savedList = c.reactList
        if !c.reactList.isEmpty { lastPicks = c.reactList }
        loaded = true
        // A channel still on the old "any emoji" becomes the switch's ON: the default set, picked and
        // saved, so what the page shows is what followers get.
        if mode == "all" {
            mode = "some"
            if list.isEmpty { list = Array(Self.palette.prefix(Self.perRow)) }
            save()
        }
    }

    /// The switch: on brings back the earlier picks (or the default set), off turns reactions off.
    private func setOn(_ on: Bool) {
        guard loaded, on != (mode != "off") else { return }
        if on {
            mode = "some"
            if list.isEmpty { list = lastPicks.isEmpty ? Array(Self.palette.prefix(Self.perRow)) : lastPicks }
        } else {
            mode = "off"
        }
        Haptics.impact(.light)
        save()
    }

    /// The chosen emoji in one rounded bar; each one opens the emoji sheet to replace it. Six to a
    /// row: with more than six (up to 12, owner 2026-11-06) the bar grows a second row.
    private var reactionBar: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: min(Self.perRow, list.count + (list.count < Self.maxPicked ? 1 : 0))),
                  spacing: 8) {
            // ⛔ NO X ON THE BAR (owner 2026-11-06: tapped by mistake). Any emoji, or the "+", opens the
            // sheet, where a tap turns an emoji on or off (`EmojiMorePicker.multi`).
            ForEach(Array(list.enumerated()), id: \.offset) { _, e in
                Button { pickAny = true } label: {
                    ReactionGlyph(emoji: e, size: 30).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(CustomReaction.spoken(e)). Change reactions")
            }
            if list.count < Self.maxPicked {
                Button { pickAny = true } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add an emoji")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // 30 = half of one row's height, so a single row is still the same capsule as before.
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func choice(_ value: String, _ title: String) -> some View {
        Button {
            guard loaded, mode != value else { return }
            mode = value
            // The earlier picks come back (owner 2026-10-30): after Any / No Reactions the server
            // answers with an empty list, and Selected used to start over from the palette.
            if value == "some" && list.isEmpty {
                list = lastPicks.isEmpty ? Array(Self.palette.prefix(Self.perRow)) : lastPicks
            }
            Haptics.impact(.light)
            save()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if mode == value { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(blue) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // ⛔ NO WRITE BEFORE THE REAL SETTING IS KNOWN (owner 2026-10-30): with the channel not in
        // the list yet the page showed the default "Any Emoji", and one tap overwrote the real one.
        .disabled(!loaded)
        .opacity(loaded ? 1 : 0.4)
    }

    /// The newest state wins: a change cancels the save still waiting, and the server gets the
    /// last one after a short pause, so tapping six emoji is one write, not six.
    private func save() {
        let m = mode, l = list
        problem = nil
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let kept = try await ChannelService.setReactions(cid: cid, mode: m, list: l)
                let km = kept?.mode ?? m, kl = kept?.list ?? l
                savedMode = km
                savedList = kl
                // What the server kept, on screen (audit E2: a refused emoji, or none left = off),
                // unless a newer change is already waiting.
                if !Task.isCancelled, mode == m, list == l { mode = km; list = kl }
            } catch {
                guard !Task.isCancelled else { return }
                problem = error.localizedDescription
                mode = savedMode
                list = savedList
            }
        }
    }
}

/// A private channel's invite link (2026-10-29): the one it has, or a new one made on the spot. It
/// used to send the owner off to Channel Type when the link was missing (the one made at creation
/// can fail on a slow line), where they had to find a switch to turn it on.
enum ChannelInviteLink {
    static func code(_ cid: String) async -> String? {
        if let code = try? await GroupInviteService.shareCode(cid: cid) { return code }
        _ = try? await GroupInviteService.createPrimaryLink(cid: cid)
        return try? await GroupInviteService.shareCode(cid: cid)
    }
}

/// ⛔ A CHANNEL'S ADD ADMIN PICKS FROM ITS FOLLOWERS (owner 2026-10-31: it opened the add-people
/// sheet, every contact, "use the groups' design; nobody who is not a member"). The group's Choose
/// Member page in look: the followers, a search at the foot, an X. A tap asks, then makes them an
/// admin at once (owner 2026-10-31: they follow already, no invite to accept). The server refuses
/// anyone who is not a follower (`makeChannelAdmin`).
struct ChannelAdminPicker: View {
    let cid: String
    let title: String
    let exclude: Set<String>
    var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ChannelFollowersView.Follower] = []
    @State private var more = true
    @State private var loading = false
    @State private var failed = false
    @State private var query = ""
    @State private var asking: ChannelFollowersView.Follower?

    private var shown: [ChannelFollowersView.Follower] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = rows.filter { !exclude.contains($0.uid) }
        return q.isEmpty ? list : list.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.username.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty && loading {
                    ForEach(0..<6, id: \.self) { i in
                        HStack(spacing: 12) {
                            SkeletonCircle(size: 40)
                            SkeletonBlock(width: [140, 110, 170, 95][i % 4], height: 13)
                            Spacer(minLength: 0)
                        }
                        .accessibilityHidden(true)
                    }
                } else if shown.isEmpty && !loading {
                    Text(failed ? "Couldn't load followers. Check your connection and try again."
                         : query.isEmpty ? "No followers yet. Only a follower of the channel can become an admin."
                         : "No follower by that name.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { f in
                    Button { asking = f } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: f.name, photoUrl: f.photoUrl, size: 40)
                            // The @username under the name (owner 2026-11-10), as on the Followers page.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).foregroundStyle(.primary).lineLimit(1)
                                if !f.username.isEmpty {
                                    Text("@\(f.username)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onAppear { if f.uid == rows.last?.uid { Task { await load() } } }
                }
            }
            .navigationTitle("Choose Follower")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            .task { await load() }
            .alert("Make \(asking?.name ?? "") an admin?",
                   isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button("Make Admin") { if let f = asking { send(f) } }
            } message: {
                Text("They can post in the channel. You can change what else they can do from Administrators.")
            }
        }
    }

    private func load() async {
        guard more, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await ChannelService.followers(cid: cid, after: rows.last?.uid)
            let have = Set(rows.map(\.uid))
            rows += page.rows.filter { !have.contains($0.uid) }
            more = page.more
            failed = false
        } catch {
            failed = true
            more = false
        }
    }

    private func send(_ f: ChannelFollowersView.Follower) {
        Task {
            do {
                try await ChannelAdminInvites.makeAdmin(cid: cid, uid: f.uid)
                ToastNotice.show("\(f.name) is now an admin.")
                onSent()
                dismiss()
            } catch {
                ToastNotice.show(error.localizedDescription)
            }
        }
    }
}


// MARK: - Similar channels (owner 2026-10-31)

/// Which channel's "Similar Channels" card shows after following: followed in this run of the app,
/// and not closed with its X (kept per channel). A channel under 1,000 followers gets an empty list
/// from the server, except for app staff, so the card simply never appears there.
@MainActor @Observable
final class SimilarChannels {
    static let shared = SimilarChannels()
    /// Followed in this run (`ChannelService.follow`).
    static var justFollowed: Set<String> {
        get { shared.followed }
        set { shared.followed = newValue }
    }
    private var followed: Set<String> = []
    private var closed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "similarChannels.closed") ?? [])
    /// One fetch per channel per run.
    @ObservationIgnored private var cache: [String: [ChannelService.Discovered]] = [:]

    /// ⛔ HIDDEN EVERYWHERE (owner 2026-11-10: "completely hide this feature because it is not
    /// finished"). Off = no card after following, no section on the channel page, no server call.
    /// Turn back on only on his word.
    static let enabled = false

    static func showsAfterFollow(_ cid: String) -> Bool {
        enabled && shared.followed.contains(cid) && !shared.closed.contains(cid)
    }

    static func close(_ cid: String) {
        shared.closed.insert(cid)
        UserDefaults.standard.set(Array(shared.closed.suffix(500)), forKey: "similarChannels.closed")
    }

    static func load(_ cid: String) async -> [ChannelService.Discovered] {
        guard enabled else { return [] }   // the channel page's section hides itself on an empty list
        if let c = shared.cache[cid] { return c }
        let list = await ChannelService.similar(cid: cid)
        shared.cache[cid] = list
        return list
    }

    /// Opens a channel from a list: the visitor page for a stranger's, the chat for my own.
    static func open(_ c: ChannelService.Discovered) {
        GroupDirectory.open(cid: c.cid, name: c.handle.isEmpty ? nil : c.handle)
    }
}

/// The card after following: "Similar Channels", an X, and up to 10 small channel cards in a row.
/// Our own look: the app's glass panel and squircle photos, the follower count under each name.
struct SimilarChannelsStrip: View {
    let cid: String
    @State private var list: [ChannelService.Discovered] = []
    @State private var loaded = false

    var body: some View {
        // A zero-height stand-in while empty: an empty Group is no view at all, so its `.task`
        // never ran and the list was never asked for (found on the simulator, 2026-10-31).
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Similar Channels").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { SimilarChannels.close(cid) }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Similar Channels")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(list) { c in
                                Button { SimilarChannels.open(c) } label: { card(c) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
                .liquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: list.isEmpty)
        .task(id: cid) {
            guard !loaded else { return }
            loaded = true
            list = await SimilarChannels.load(cid)
        }
    }

    private func card(_ c: ChannelService.Discovered) -> some View {
        VStack(spacing: 4) {
            AvatarView(name: c.title, photoUrl: c.photoUrl, size: 54).avatarSquircle(true)
            HStack(spacing: 2) {
                Text(c.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                GroupVerifiedMark(on: c.verified, size: 10, label: c.label)
            }
            Text(GroupDirectory.followersLine(c.followerCount))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 70)
        .accessibilityElement(children: .combine)
    }
}

/// The channel page's "Similar Channels": the same list as rows, hidden while there are none.
struct SimilarChannelsSection: View {
    let cid: String
    let cardColor: Color
    @State private var list: [ChannelService.Discovered] = []

    var body: some View {
        // A zero-height stand-in while empty: an empty Group is no view at all, so its `.task`
        // never ran and the list was never asked for (found on the simulator, 2026-10-31).
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Similar Channels").font(.headline).foregroundStyle(.secondary)
                        .padding(.leading, 16)
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                            Button { SimilarChannels.open(c) } label: {
                                HStack(spacing: 12) {
                                    AvatarView(name: c.title, photoUrl: c.photoUrl, size: 40).avatarSquircle(true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(c.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                                            GroupVerifiedMark(on: c.verified, size: 13, label: c.label)
                                        }
                                        Text(GroupDirectory.followersLine(c.followerCount))
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if i < list.count - 1 { Divider().padding(.leading, 68) }
                        }
                    }
                    .profileSurface(plain: cardColor)
                }
            }
        }
        .task(id: cid) { list = await SimilarChannels.load(cid) }
    }
}

import SwiftUI

/// Where the composer goes for someone who is not an admin of a channel (2026-10-28). Following:
/// the official chat's card, "You're following this channel" (owner 2026-10-29; mute is the bell).
/// Not following (I unfollowed, or opened it from a link I have not used): Follow.
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

    /// Follow (the full-width blue bar) and "You're following this channel" (the official chat's
    /// card) as ONE glass shape, so the spring carries one into the other instead of swapping views.
    private var followMorph: some View {
        Button { follow() } label: {
            ZStack {
                Text("Follow")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(joined ? 0 : 1)
                // Primary, not secondary (owner 2026-10-29: "this card use Apple liquid glass"): on
                // glass over busy posts the grey words sank into the messages behind them.
                Text("You're following this channel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .opacity(joined ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .frame(height: joined ? 48 : 50)
            .liquidGlass(RoundedRectangle(cornerRadius: joined ? 26 : 25, style: .continuous),
                         interactive: true, tint: joined ? nil : Color(hex: 0x2392FE))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        // Not disabled once joined: the glass answers a touch the way Apple's does (`follow()`
        // already ignores a tap while following).
        // The Follow bar's 16 pt in from the sides; the card sits at the official chat's width.
        .padding(.horizontal, joined ? 0 : 16)
        .accessibilityLabel(joined ? "You're following this channel" : "Follow")
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
                try await ChannelService.follow(cid: cid)
                // The follow list confirms it (`following`); this stays until then so the bar never
                // blinks back to Follow between the answer and the listener.
            } catch {
                problem = error.localizedDescription
                optimistic = false   // springs back to Follow (the bar's .animation on `joined`)
            }
        }
    }
}

/// FIND CHANNELS (2026-10-28): public channels, most followed first, this country's first (the
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
    @State private var follows = ChannelFollows.shared

    var body: some View {
        NavigationStack {
            List {
                if loading && rows.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if failed && rows.isEmpty {
                    Text("Couldn't load channels. Check your connection and try again.")
                        .foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else if rows.isEmpty {
                    Text("No public channels yet. Only public channels show here: to list yours, open it, tap its name, then Channel Settings > Channel Type > Public.")
                        .foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(rows) { row($0) }
                    } footer: {
                        Text("Public channels anyone can follow. Only their admins post.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Find Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func row(_ c: ChannelService.Discovered) -> some View {
        HStack(spacing: 12) {
            Button {
                onOpen(c.cid, c.handle.isEmpty ? nil : c.handle)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(name: c.title, photoUrl: c.photoUrl, size: 48).avatarSquircle(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(c.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            GroupVerifiedMark(on: c.verified, size: 14, label: c.label)
                        }
                        Text(GroupDirectory.followersLine(c.followerCount))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !c.description.isEmpty {
                            Text(c.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            followButton(c)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func followButton(_ c: ChannelService.Discovered) -> some View {
        let mine = follows.follows(c.cid)
            || ConversationsRepository.shared.conversations.contains { $0.id == c.cid && $0.users.contains(AuthService.shared.uid ?? "") }
        Button {
            guard !mine, !busy.contains(c.cid) else { return }
            busy.insert(c.cid)
            Task {
                do { try await ChannelService.follow(cid: c.cid); Haptics.notify(.success) }
                catch { ToastNotice.show(error.localizedDescription) }
                busy.remove(c.cid)
            }
        } label: {
            Text(mine ? "Following" : (busy.contains(c.cid) ? "…" : "Follow"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(mine ? Color.secondary : Color.white)
                .padding(.horizontal, 14).frame(height: 32)
                .liquidGlass(Capsule(), interactive: !mine, tint: mine ? nil : Color(hex: 0x2392FE))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(mine)
    }

    private func load() async {
        loading = true
        do { rows = try await ChannelService.discover(); failed = false }
        catch { failed = true }
        loading = false
    }
}

/// A channel's followers, for its admins (2026-10-28): newest first, 50 at a time, swipe to remove
/// (or remove and keep out). Nobody else sees who follows.
struct ChannelFollowersView: View {
    let cid: String
    let count: Int

    struct Follower: Identifiable, Equatable { let uid: String; let name: String; let photoUrl: String?; var id: String { uid } }

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
    /// Taken off the header's count on each Remove / Ban (owner 2026-10-29 audit U10: `count` is the
    /// number when the page opened, and it did not go down).
    @State private var removed = 0
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
    private var shownCount: Int { max(0, count - removed) + admins.count }

    var body: some View {
        List {
            Section {
                ForEach(admins, id: \.self) { uid in
                    HStack(spacing: 12) {
                        AvatarView(name: conv?.names[uid] ?? "", photoUrl: conv?.photos[uid], size: 40)
                        Text(uid == AuthService.shared.uid ? "You" : (conv?.names[uid] ?? "")).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(uid == conv?.createdBy ? "Owner" : "Admin")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows.filter { !(conv?.users.contains($0.uid) ?? false) }) { f in
                    HStack(spacing: 12) {
                        AvatarView(name: f.name, photoUrl: f.photoUrl, size: 40)
                        Text(f.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    // Only an admin who may remove people (the server now asks for `banUsers`,
                    // 2026-10-29 review fix); others see the list without the swipe.
                    .swipeActions(edge: .trailing) {
                        if mayRemove {
                            Button("Remove", role: .destructive) { confirm = (f, false) }
                            Button("Ban") { confirm = (f, true) }.tint(.orange)
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
                if rows.isEmpty, admins.isEmpty, !loading, !failed, !more {
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
        .refreshable { rows = []; more = true; await load() }
        .task { if rows.isEmpty { await load() } }
        .alert(confirm?.1 == true ? "Remove and ban?" : "Remove follower?",
               isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button(confirm?.1 == true ? "Ban" : "Remove", role: .destructive) {
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
            Text(confirm?.1 == true ? "They stop following and can't follow again."
                                    : "They stop following. They can follow again if the channel is public.")
        }
    }

    private func load() async {
        guard !loading, more else { return }
        // A channel the count says nobody follows: nothing to ask the server for.
        if count == 0, rows.isEmpty { more = false; return }
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
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color(hex: 0x2392FE))
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
                    wideButton("Accept", tint: Color(hex: 0x2392FE)) { answer(true) }
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
            Text(title).fontWeight(.semibold).foregroundStyle(.white)
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
            .alert("Revoke admin invite for \(revoking?.name ?? "")?",
                   isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button("Revoke", role: .destructive) { revoke() }
            } message: {
                Text("If you revoke it, \(revoking?.name ?? "they") can no longer use it to become an admin of this channel.")
            }
    }

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
            if conv.followerCount == 0 {
                Text("Share your channel so people can follow it.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 0) {
                circle("square.and.arrow.up", "Share") { Task { await share() } }
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
                                Text(e).font(.system(size: 30))
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(isMine(e) ? Color(hex: 0x2392FE).opacity(0.18)
                                                                         : Color(.secondarySystemBackground)))
                                    .overlay(Circle().stroke(isMine(e) ? Color(hex: 0x2392FE) : .clear, lineWidth: 2))
                                Text("\(count(of: e))").font(.footnote.monospacedDigit())
                                    .foregroundStyle(isMine(e) ? Color(hex: 0x2392FE) : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(e), \(count(of: e))")
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

    /// What an owner picks from: a wide set, so "only these" can fit any channel.
    /// Any other emoji comes in through the "+" (the full picker) and joins the grid.
    static let palette = ["👍", "❤️", "🔥", "😂", "😮", "😢", "🙏", "👏", "🎉", "💯", "🤔", "😍",
                          "👎", "😡", "🤝", "💪", "✅", "⭐️", "🌙", "☀️", "⚽️", "📌", "💡", "🙌"]
    static let maxPicked = 6
    private let blue = Color(hex: 0x2392FE)

    // Three plain choices and, for Selected, one palette grid with "+" for any emoji (owner
    // 2026-10-29, made minimal later the same day). Saves run in the background; the page is never
    // disabled while one goes.
    var body: some View {
        Form {
            // ⛔ MINIMAL (owner 2026-10-29: "make this page minimalist"): the three choices, and for
            // Selected one grid whose ticks are the selection. The preview card and the separate
            // "Selected" slot row are gone (they said again what the ticks say).
            Section {
                choice("all", "Any Emoji")
                choice("some", "Selected Emoji")
                choice("off", "No Reactions")
            } footer: {
                Text("Nobody sees who reacted, only how many.")
            }
            if mode == "some" {
                Section {
                    grid.padding(.vertical, 6)
                } header: {
                    HStack {
                        Text("Choose up to \(Self.maxPicked)")
                        Spacer()
                        Text("\(list.count)/\(Self.maxPicked)").monospacedDigit()
                    }
                } footer: {
                    if list.isEmpty { Text("Pick at least one, or reactions will be off.") }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .navigationTitle("Reactions")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy(duration: 0.25), value: mode)
        .animation(.snappy(duration: 0.25), value: list)
        .sheet(isPresented: $pickAny) {
            EmojiMorePicker(title: "Choose Emoji") { e in
                pickAny = false
                if !list.contains(e) { toggle(e) }
            }
        }
        .onAppear {
            guard !loaded, let c = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) else { return }
            mode = c.reactMode
            list = c.reactList
            savedMode = c.reactMode
            savedList = c.reactList
            loaded = true
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(Self.palette + list.filter { !Self.palette.contains($0) }, id: \.self) { e in
                let on = list.contains(e)
                let full = list.count >= Self.maxPicked
                Button { toggle(e) } label: {
                    // Up to 46pt, narrower when six columns get less (a 375pt phone gives ~44).
                    Text(e).font(.system(size: 28))
                        .frame(maxWidth: 46).frame(height: 46)
                        .overlay(alignment: .bottomTrailing) {
                            if on {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, blue)
                                    .font(.system(size: 17))
                                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)).padding(-1.5))
                                    .offset(x: 3, y: 3)
                                    .transition(.scale)
                            }
                        }
                }
                .buttonStyle(.plain)
                .opacity(!on && full ? 0.3 : 1)
                .disabled(!on && full)
                .accessibilityLabel(e)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            // Any emoji at all (2026-10-29): the full picker.
            Button { pickAny = true } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: 46).frame(height: 46)
                    .background(Circle().fill(Color(.tertiarySystemFill)))   // a Circle stays round in a narrower frame
            }
            .buttonStyle(.plain)
            .disabled(list.count >= Self.maxPicked)
            .opacity(list.count >= Self.maxPicked ? 0.3 : 1)
            .accessibilityLabel("Choose any emoji")
        }
    }

    private func choice(_ value: String, _ title: String) -> some View {
        Button {
            guard mode != value else { return }
            mode = value
            if value == "some" && list.isEmpty { list = Array(Self.palette.prefix(Self.maxPicked)) }
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
    }

    private func toggle(_ e: String) {
        if let i = list.firstIndex(of: e) { list.remove(at: i) }
        else if list.count < Self.maxPicked { list.append(e) }
        else { return }
        Haptics.impact(.light)
        save()
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

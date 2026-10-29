import SwiftUI

/// Where the composer goes for someone who is not an admin of a channel (2026-10-28). Following:
/// one centred glass pill, Mute / Unmute (the reference app's channel footer). Not following (I
/// unfollowed, or opened it from a link I have not used): Follow, for a public channel.
struct ChannelFollowerBar: View {
    let conv: Conversation
    @State private var follows = ChannelFollows.shared
    @State private var busy = false
    @State private var problem: String?

    private var following: Bool { follows.follows(conv.id) }
    private var muted: Bool { follows.entry(conv.id)?.muted ?? false }

    var body: some View {
        VStack(spacing: 8) {
            if let problem {
                Text(problem).font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if following {
                pill(muted ? "Unmute" : "Mute", icon: muted ? "bell" : "bell.slash", tint: nil) {
                    Haptics.impact(.light)
                    ChannelService.setMuted(cid: conv.id, !muted)
                }
                .accessibilityLabel(muted ? "Unmute channel" : "Mute channel")
            } else {
                // Always Follow (2026-10-29: a public channel opened from an invite card said
                // "private"); the server says no to a private channel without its link, in words.
                pill(busy ? "Following…" : "Follow", icon: nil, tint: Color(hex: 0x2392FE)) { follow() }
            }
        }
        .frame(maxWidth: .infinity)
        .systemBarChrome()
    }

    private func pill(_ title: String, icon: String?, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 16, weight: .medium)) }
                Text(title).font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, 19)
            .frame(minWidth: 166)
            .frame(height: 44)
            .liquidGlass(Capsule(), interactive: true, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func follow() {
        guard !busy else { return }
        guard NetworkState.shared.isOnline else { problem = "No internet connection. Try again."; return }
        busy = true; problem = nil
        Task {
            do { try await ChannelService.follow(cid: conv.id) } catch { problem = error.localizedDescription }
            busy = false
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
                    AvatarView(name: c.title, photoUrl: c.photoUrl, size: 48)
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

    @State private var rows: [Follower] = []
    @State private var more = true
    @State private var loading = false
    @State private var failed = false
    @State private var confirm: (Follower, Bool)?

    var body: some View {
        List {
            Section {
                ForEach(rows) { f in
                    HStack(spacing: 12) {
                        AvatarView(name: f.name, photoUrl: f.photoUrl, size: 40)
                        Text(f.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { confirm = (f, false) }
                        Button("Ban") { confirm = (f, true) }.tint(.orange)
                    }
                    .onAppear { if f == rows.last, more { Task { await load() } } }
                }
                if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                if failed { Text("Couldn't load followers. Pull to try again.").foregroundStyle(.secondary) }
                // Nobody yet: said, not a spinner (owner 2026-10-29: it turned on an empty list).
                if rows.isEmpty, !loading, !failed, !more {
                    Text("No followers yet. Share the channel to get your first ones.").foregroundStyle(.secondary)
                }
            } header: {
                Text(GroupDirectory.followersLine(count))
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
                AvatarView(name: info.title, photoUrl: info.photoUrl, size: 96).padding(.top, 28)
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

/// On a channel's page, for its admins (2026-10-29): invite admins and followers, and the admin
/// invites still waiting (tap one to revoke it).
struct ChannelAdminInviteRows: View {
    let cid: String
    let title: String
    /// What "Invite Followers" sends: the public link, or nil for a private channel.
    let followLink: String?
    let cardColor: Color
    @State private var pending: [ChannelAdminInvites.Pending] = []
    @State private var pickAdmins = false
    @State private var shareText: String?
    @State private var revoking: ChannelAdminInvites.Pending?
    private var mayAddAdmins: Bool {
        let me = AuthService.shared.uid ?? ""
        return ConversationsRepository.shared.conversations.first { $0.id == cid }?.adminCan(me, .addAdmins) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(pending) { p in
                HStack(spacing: 12) {
                    AvatarView(name: p.name, photoUrl: p.photoUrl, size: 40)
                    Text(p.name).lineLimit(1)
                    Spacer(minLength: 0)
                    // What he was invited to (owner 2026-10-29: "Invited" read as "invited to follow").
                    Text("Invited as admin").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture { revoking = p }
                Divider().padding(.leading, 68)
            }
            row("person.badge.plus", "Invite Followers") {
                if let followLink { shareText = "Follow \u{201C}\(title)\u{201D} on Fariin: " + followLink }
                else { Task { await shareInviteLink() } }
            }
            // Only the owner, or an admin the owner let add admins (the server holds to the same).
            if mayAddAdmins {
                Divider().padding(.leading, 56)
                row("plus", "Invite Admins") { pickAdmins = true }
            }
        }
        .background(cardColor, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .task { await reload() }
        .sheet(isPresented: $pickAdmins) {
            AddPeopleSheet(alreadyIn: [], actionTitle: "Invite", linkCap: 16) { people in
                Task {
                    do {
                        let refused = try await ChannelAdminInvites.invite(cid: cid, title: title, people: people)
                        ToastNotice.show(refused.isEmpty ? "Invite sent." : "Invite sent. Not sent to: " + refused.joined(separator: ", "))
                        await reload()
                    } catch { ToastNotice.show(error.localizedDescription) }
                }
            }
        }
        .sheet(item: Binding(get: { shareText.map { ShareText(id: $0) } }, set: { shareText = $0?.id })) { t in
            SendContactSheet(contactText: t.id)
        }
        .alert("Revoke admin invite for \(revoking?.name ?? "")?",
               isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke", role: .destructive) {
                guard let p = revoking else { return }
                Task {
                    try? await ChannelAdminInvites.revoke(p.code)
                    await reload()
                }
            }
        } message: {
            Text("If you revoke it, \(revoking?.name ?? "they") can no longer use it to become an admin of this channel.")
        }
    }

    private func row(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 26)
                Text(text)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reload() async {
        if let p = try? await ChannelAdminInvites.pending(cid: cid) { pending = p }
    }

    /// A private channel: its invite link, from the server.
    private func shareInviteLink() async {
        guard let code = await ChannelInviteLink.code(cid) else {
            ToastNotice.show("Couldn't get the channel's link. Check your connection and try again.")
            return
        }
        shareText = "Follow \u{201C}\(title)\u{201D} on Fariin: " + KulanApp.groupLink(code: code)
    }
}

/// At the top of every channel (owner 2026-10-29, the reference app's privacy notice, in our
/// words): one centred line; a tap opens what the channel can and cannot see about you.
struct ChannelPrivacyNotice: View {
    var body: some View {
        // Straight to the Help Center article (owner 2026-10-29: the sheet in between looked cheap).
        Button {
            if let u = URL(string: "https://help.fariin.com/channels/your-privacy-in-channels") { WebLink.open(u) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 13, weight: .semibold))
                (Text("Your privacy in this channel is protected. ") + Text("Learn more").foregroundColor(Color(hex: 0x2392FE)))   // blue: it is a link (owner 2026-10-29)
                    .multilineTextAlignment(.center)
            }
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(.secondarySystemBackground).opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 40)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
        conv.followerCount == 1 ? "1 follower" : "\(conv.followerCount) followers"
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Button { if canEdit { showEdit = true } } label: {
                    AvatarView(name: conv.title, photoUrl: conv.avatarUrl, size: 92)
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
        let extra = counts.filter { $0.value > 0 && !offered.contains($0.key) }
            .sorted { $0.value > $1.value }.map(\.key)
        return (canReact ? offered : offered.filter { (counts[$0] ?? 0) > 0 }) + extra
    }
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
                                    .background(Circle().fill(mine == e ? Color(hex: 0x2392FE).opacity(0.18)
                                                                         : Color(.secondarySystemBackground)))
                                    .overlay(Circle().stroke(mine == e ? Color(hex: 0x2392FE) : .clear, lineWidth: 2))
                                Text("\(counts[e] ?? 0)").font(.footnote.monospacedDigit())
                                    .foregroundStyle(mine == e ? Color(hex: 0x2392FE) : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(e), \(counts[e] ?? 0)")
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
    @State private var saving = false
    @State private var problem: String?
    @State private var pickAny = false

    /// What an owner picks from: a wide set, so "only these" can fit any channel.
    /// Any other emoji comes in through the "+" (the full picker) and joins the grid.
    static let palette = ["👍", "❤️", "🔥", "😂", "😮", "😢", "🙏", "👏", "🎉", "💯", "🤔", "😍",
                          "👎", "😡", "🤝", "💪", "✅", "⭐️", "🌙", "☀️", "⚽️", "📌", "💡", "🙌"]

    var body: some View {
        Form {
            Section {
                choice("all", "Any emoji", "Followers can react with any emoji.")
                choice("some", "Only these", "Followers can react only with the ones you pick.")
                choice("off", "Off", "No reactions on this channel's posts.")
            } footer: {
                Text("Followers never see who reacted, only how many.")
            }
            if mode == "some" {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.palette + list.filter { !Self.palette.contains($0) }, id: \.self) { e in
                            let on = list.contains(e)
                            Button { toggle(e) } label: {
                                Text(e).font(.system(size: 28))
                                    .frame(width: 46, height: 46)
                                    .background(Circle().fill(on ? Color(hex: 0x2392FE).opacity(0.18) : .clear))
                                    .overlay(Circle().stroke(on ? Color(hex: 0x2392FE) : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .opacity(!on && list.count >= 6 ? 0.35 : 1)
                        }
                        // Any emoji at all (2026-10-29): the full picker.
                        Button { pickAny = true } label: {
                            Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                        .disabled(list.count >= 6)
                        .accessibilityLabel("Choose any emoji")
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Pick up to 6 (\(list.count)/6)")
                } footer: {
                    if list.isEmpty { Text("Pick at least one, or reactions will be off.") }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .navigationTitle("Reactions")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
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
            loaded = true
        }
    }

    private func choice(_ value: String, _ title: String, _ line: String) -> some View {
        Button {
            mode = value
            if value == "some" && list.isEmpty { list = Array(Self.palette.prefix(6)) }
            save()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if mode == value { Image(systemName: "checkmark").foregroundStyle(Color(hex: 0x2392FE)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ e: String) {
        if let i = list.firstIndex(of: e) { list.remove(at: i) }
        else if list.count < 6 { list.append(e) }
        else { return }
        save()
    }

    private func save() {
        let m = mode, l = list
        saving = true; problem = nil
        Task {
            do { try await ChannelService.setReactions(cid: cid, mode: m, list: l) }
            catch { problem = error.localizedDescription }
            saving = false
        }
    }
}

/// DELETE CHANNEL (owner 2026-10-29): a page, not a one-tap alert. What happens, in three lines, and
/// then my password, as Transfer Ownership asks it: someone holding my unlocked phone cannot wipe my
/// channel. An account with no password (signed up another way) types the channel's name instead.
struct DeleteChannelSheet: View {
    let cid: String
    let title: String
    let photoUrl: String?
    let followers: Int
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var typedName = ""
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var hasPassword: Bool { AuthService.shared.passwordAddress != nil }
    private var ready: Bool {
        hasPassword ? !password.isEmpty
            : typedName.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AvatarView(name: title, photoUrl: photoUrl, size: 84)
                        .padding(.top, 8)
                    Text("Delete \u{201C}\(title)\u{201D}?")
                        .font(.title2.bold()).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 16) {
                        point("trash", "Gone for everyone",
                              "Every post, its photos and videos, and its link are deleted from Fariin.")
                        point("person.2.slash", followers == 1 ? "Your follower loses it" : "Your \(followers) followers lose it",
                              "It disappears from their chats.")
                        point("arrow.uturn.backward.circle", "There is no undo",
                              "A deleted channel cannot be brought back.")
                    }
                    .padding(18)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(hasPassword ? "Enter your password to delete it" : "Type the channel's name to delete it")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        Group {
                            if hasPassword {
                                SecureField("Password", text: $password).textContentType(.password)
                            } else {
                                TextField(title, text: $typedName).autocorrectionDisabled().textInputAutocapitalization(.never)
                            }
                        }
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { if ready { delete() } }
                        .padding(.horizontal, 16).frame(height: 52)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        if let problem {
                            Text(problem).font(.footnote).foregroundStyle(.red).padding(.leading, 4)
                        }
                    }

                    Button { delete() } label: {
                        ZStack {
                            Text("Delete Channel").fontWeight(.semibold).opacity(busy ? 0 : 1)
                            if busy { CreatingRing(label: "Deleting channel") }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Capsule().fill(Color.red.opacity(ready ? 1 : 0.4)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready || busy)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                        .disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            focused = true
        }
    }

    private func point(_ icon: String, _ head: String, _ line: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 26).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(head).font(.body.weight(.semibold))
                Text(line).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func delete() {
        guard ready, !busy else { return }
        busy = true; problem = nil
        let typed = password
        password = ""
        let cid = cid
        Task {
            if hasPassword {
                do { try await AuthService.shared.reauthPassword(typed) }
                catch {
                    let words = AuthService.plainMessage(error, credentialHint: "That password is not right.")
                        ?? "Could not check that. Try again."
                    await MainActor.run { busy = false; problem = words }
                    return
                }
            }
            do {
                try await GroupInviteService.deleteGroup(cid: cid)
                await MainActor.run {
                    busy = false
                    LeaveGroupUndo.shared.closeChat(cid)
                    ToastNotice.show("Channel deleted")
                    dismiss()
                    onDeleted()
                }
            } catch {
                let words = error.localizedDescription
                await MainActor.run { busy = false; problem = words }
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

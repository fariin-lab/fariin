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
            } else if conv.isPublic {
                pill(busy ? "Following…" : "Follow", icon: nil, tint: Color(hex: 0x2392FE)) { follow() }
            } else {
                Text("This channel is private. Ask an admin for its invite link.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                    Text("No public channels yet. Create the first one!")
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
                    Text("Invited").foregroundStyle(.secondary)
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
        guard let code = try? await GroupInviteService.shareCode(cid: cid) else {
            ToastNotice.show("This channel has no invite link. Turn one on in Channel Type.")
            return
        }
        shareText = "Follow \u{201C}\(title)\u{201D} on Fariin: " + KulanApp.groupLink(code: code)
    }
}

/// At the top of every channel (owner 2026-10-29, the reference app's privacy notice, in our
/// words): one centred line; a tap opens what the channel can and cannot see about you.
struct ChannelPrivacyNotice: View {
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 13, weight: .semibold))
                Text("Your privacy in this channel is protected. Tap to learn more.")
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
        .sheet(isPresented: $open) { ChannelPrivacySheet() }
    }
}

/// What a channel can and cannot see about a follower. Every line is what the app does.
struct ChannelPrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 54)).foregroundStyle(Color(hex: 0x2392FE))
                .frame(maxWidth: .infinity).padding(.top, 30)
            Text("Your privacy in channels")
                .font(.title2.bold()).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            point("eye.slash", "Other followers can't see you",
                  "Nobody else who follows this channel can see that you follow it, react or vote.")
            point("envelope.badge.shield.half.filled", "Your account stays private",
                  "Fariin has no phone numbers, and a channel's admins never see your email.")
            point("person.crop.circle", "Admins can see your name",
                  "A channel's admins can see your name in its follower list, and your photo if your photo privacy lets them.")
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Text("OK").fontWeight(.semibold).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .liquidGlass(Capsule(), interactive: true, tint: Color(hex: 0x2392FE))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button {
                if let u = URL(string: "https://help.fariin.com/channels/your-privacy-in-channels") { WebLink.open(u) }
            } label: {
                Text("Learn more").frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color(hex: 0x2392FE))
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .presentationDetents([.large])
    }

    private func point(_ icon: String, _ title: String, _ line: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 22)).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(line).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

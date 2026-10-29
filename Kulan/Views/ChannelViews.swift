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

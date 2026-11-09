import SwiftUI
import UIKit

/// The chat list's path value for the Activity page (pushed on the Chats stack like the archive).
enum ActivityRoute: Hashable { case page }

/// Replies and reactions to my comments on channel posts (owner 2026-11-09, design "4 + reactions",
/// contract in fariin-activity/SPEC.md). Opening it reads everything; a tap opens the post's Replies
/// at that comment.
struct ActivityFeedView: View {
    private enum Filter { case all, unread }

    private var store: ActivityStore { .shared }
    @State private var chipFilter: Filter = .all
    /// Items that were unread when the page opened: what the Unread chip shows. Taken once.
    @State private var unreadAtOpen: Set<String> = []
    @State private var tookSnapshot = false

    private var shown: [ActivityItem] {
        let blocks = BlockList.snapshot
        return store.items.filter { item in
            !blocks.contains(item.fromUid) && (chipFilter == .all || unreadAtOpen.contains(item.id))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                chip("All", .all)
                chip("Unread", .unread)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            if store.loaded && shown.isEmpty {
                Spacer()
                Text(chipFilter == .all ? "No activity yet" : "Nothing unread")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.bottom, 80)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { item in
                            Button { store.open(item) } label: { ActivityRowView(item: item) }
                                .buttonStyle(ActivityRowPress())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await store.markAllRead() } } label: {
                        Label("Mark All as Read", systemImage: "envelope.open")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .onAppear { takeSnapshotIfReady() }
        .onChange(of: store.loaded) { _, _ in takeSnapshotIfReady() }
    }

    /// Remembers what was unread, then marks everything read (the chat-list row goes away).
    private func takeSnapshotIfReady() {
        guard !tookSnapshot, store.loaded else { return }
        tookSnapshot = true
        unreadAtOpen = Set(store.items.filter { !$0.read }.map(\.id))
        Task { await store.markAllRead() }
    }

    /// The Replies sheet's Top / Newest chip, at this page's size (the approved mock: 32 pt, 15 pt).
    private func chip(_ title: String, _ f: Filter) -> some View {
        let on = chipFilter == f
        return Button { chipFilter = f } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(on ? Color(.tertiarySystemFill) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The system grey under the finger, as a list row has.
private struct ActivityRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill) : Color.clear)
    }
}

/// One Activity row: the person's face with a badge, three short lines, and the post's picture.
struct ActivityRowView: View {
    let item: ActivityItem

    private var showsPills: Bool { item.kind == .react && item.others > 0 && !item.rx.isEmpty }
    private var hasThumb: Bool { !item.thumb.isEmpty }
    private var channel: String { item.chTitle.isEmpty ? "a channel" : item.chTitle }
    private var name: String { item.fromName.isEmpty ? "Someone" : item.fromName }
    private var mineLabel: String { item.mineIsAnswer ? "Your reply: " : "Your comment: " }

    var body: some View {
        HStack(spacing: 12) {
            face
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    titleLine
                    if item.kind == .reply {
                        Text(item.text.isEmpty ? " " : item.text)
                            .font(.system(size: 15)).foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(mineLabel + item.mineText)
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("In \(channel) · " + mineLabel + item.mineText)
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        if showsPills { pills.padding(.top, 3) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if hasThumb {
                    ActivityThumb(url: item.thumb, video: item.thumbIsVideo)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: showsPills ? 92 : 80)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "Nan in VE3", "Nan reacted", "Nan and 3 others reacted"; the time sits on the right, or in
    /// this line after a dot when the post's picture takes the right edge.
    private var titleLine: some View {
        let who = item.kind == .react && item.others > 0
            ? "\(name) and \(item.others) \(item.others == 1 ? "other" : "others")" : name
        var rest = item.kind == .reply ? " in \(channel)" : " reacted"
        if hasThumb { rest += " · " + ActivityTime.age(item.at) }
        return HStack(spacing: 8) {
            (Text(who).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
             + Text(rest).font(.system(size: 17)).foregroundStyle(.secondary))
                .lineLimit(1)
            if !hasThumb {
                Spacer(minLength: 0)
                Text(ActivityTime.age(item.at))
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var face: some View {
        AvatarView(name: name, photoUrl: item.fromPhoto.isEmpty ? nil : item.fromPhoto, size: 56)
            .frame(width: 56, height: 56)
            .overlay(alignment: .bottomTrailing) { badge }
    }

    /// Reply: the channel's own squircle. React: the latest emoji in a small circle.
    @ViewBuilder private var badge: some View {
        if item.kind == .reply {
            AvatarView(name: channel, photoUrl: item.chPhoto.isEmpty ? nil : item.chPhoto, size: 24)
                .avatarSquircle(true)
                .padding(2)
                .background(Color(.systemBackground), in: SquircleShape())
                .offset(x: 5, y: 5)
        } else {
            Text(item.emoji.isEmpty ? "❤️" : item.emoji)
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
                .background(Color(.systemGray5), in: Circle())
                .padding(2)
                .background(Color(.systemBackground), in: Circle())
                .offset(x: 6, y: 6)
        }
    }

    /// Up to three counts, most used first, in the Replies sheet's reaction-pill look.
    private var pills: some View {
        HStack(spacing: 6) {
            ForEach(Array(item.rx.prefix(3)), id: \ActivityItem.Count.emoji) { r in
                HStack(spacing: 4) {
                    Text(r.emoji).font(.system(size: 14))
                    Text(r.count.formatted()).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }
}

/// The post's picture, 56 pt, rounded 12. Loaded through the app's cached loader (memory, disk,
/// then one shared download), never AsyncImage.
private struct ActivityThumb: View {
    let url: String
    let video: Bool
    @State private var image: UIImage?

    init(url: String, video: Bool) {
        self.url = url
        self.video = video
        _image = State(initialValue: ProfilePhotoLoader.shared.cachedAvatar(url))
    }

    var body: some View {
        ZStack {
            Color(.systemGray5)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
            if video {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: url) {
            guard image == nil else { return }
            image = await ProfilePhotoLoader.shared.avatar(url)
        }
    }
}

enum ActivityTime {
    /// "now", "5m", "3h", "2d", "6w": short ages for the Activity page.
    static func age(_ d: Date) -> String {
        let s = max(0, Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        return "\(Int(s / (7 * 86_400)))w"
    }

    /// The chat list's own time format (ChatRow.timeStr): a clock today, then Yesterday, a weekday,
    /// a date.
    static func listTime(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        if cal.component(.year, from: d) != cal.component(.year, from: Date()) {
            return d.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The chat list's Activity row, drawn like a chat row (`ChatRow`): 56 pt face in an 80 pt row, a
/// bold name, the time, two reserved preview lines and the unread count. Shown only while unread.
struct ActivityChatRow: View {
    let summary: ActivitySummary?
    let dark: Bool

    var body: some View {
        let unread = summary?.unread ?? 0
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AvatarPalette.placeholderFill)
                Image(systemName: "bell.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Activity")
                        .font(.headline.weight(unread > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ActivityTime.listTime(summary?.lastAtMillis ?? 0))
                        .font(.subheadline)
                        .foregroundStyle(unread > 0 ? Theme.accent(dark) : Color.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(alignment: .top, spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        Text(" \n ").font(.subheadline).hidden().accessibilityHidden(true)
                        Text(summary?.preview ?? "")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.footnote.bold()).foregroundColor(Theme.onAccent(dark))
                            .contentTransition(.numericText())
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Theme.accent(dark)).clipShape(Capsule())
                    }
                }
            }
            .padding(.top, 7)
            .padding(.bottom, 9)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import UIKit
import FirebaseFirestore
import Observation

// The group info page's newer pieces (owner 2026-10-18, "upgrade the group info page"): the labelled
// action tiles, the Members · Media · Settings switcher, Member Changes, the chat's storage, the
// QR of the invite link and the Encryption sheet. Fariin's own look throughout: the profile's cards
// (`profileSurface`), Liquid Glass only on the floating switcher, our `ic_*` glyphs.

// MARK: - Action tiles

/// One labelled action under the header: the glyph over a word, on a rounded card. Each tile takes an
/// equal share of the row, so three or four stay even.
struct GroupActionTile: View {
    let icon: String          // an "ic_*" asset of ours, or an SF Symbol name
    let title: String
    var cardColor: Color = Color(uiColor: .secondarySystemGroupedBackground)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if icon.hasPrefix("ic_") {
                        Image(icon).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: icon).font(.system(size: 20, weight: .medium))
                    }
                }
                .frame(height: 26)
                Text(title).font(.footnote.weight(.medium)).lineLimit(1)
            }
            // The page's own ink (the round actions were `.primary` too), not a brand colour.
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .profileSurface(plain: cardColor, radius: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Section switcher

enum GroupInfoSection: Int, CaseIterable, Hashable {
    case members, media, settings
    var label: String {
        switch self {
        case .members: return "Members"
        case .media: return "Media"
        case .settings: return "Settings"
        }
    }
    /// The ScrollViewReader id of the section's anchor (see `GroupSectionAnchor`).
    var anchorId: String { "groupInfo.section.\(rawValue)" }
}

/// Where the switcher's bottom edge and each section's top are, in global points. A reference, and
/// the positions themselves are not observed: the scroll writes them every frame, and only a CHANGE
/// of the section in view redraws anything (the switcher alone, never the page).
@Observable final class GroupInfoScrollMarks {
    private(set) var active: GroupInfoSection = .members
    @ObservationIgnored private var barBottom: CGFloat = 0
    @ObservationIgnored private var tops: [GroupInfoSection: CGFloat] = [:]

    func setBarBottom(_ y: CGFloat) { barBottom = y; recompute() }
    func setTop(_ y: CGFloat, for s: GroupInfoSection) { tops[s] = y; recompute() }

    /// The last section whose top has reached the switcher; Members until anything has.
    private func recompute() {
        let now = GroupInfoSection.allCases.last { s in
            guard let t = tops[s], barBottom > 0 else { return false }
            return t <= barBottom + 2
        } ?? .members
        if now != active { active = now }
    }
}

/// The capsule: three words, the one in view filled. It is the pinned header of the page's lower
/// half, so it rides up with the page and then stays under the bar.
struct GroupSectionSwitcher: View {
    let marks: GroupInfoScrollMarks
    let onPick: (GroupInfoSection) -> Void

    var body: some View {
        let active = marks.active
        HStack(spacing: 4) {
            ForEach(GroupInfoSection.allCases, id: \.self) { s in
                Button { onPick(s) } label: {
                    Text(s.label)
                        .font(.subheadline.weight(s == active ? .semibold : .regular))
                        .foregroundStyle(s == active ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if s == active { Capsule().fill(Color.primary.opacity(0.10)) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .animation(.easeInOut(duration: 0.2), value: active)
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { marks.setBarBottom($0) }
    }
}

/// The spot a section scrolls to: 64pt ABOVE its top (taking no room itself), so the section lands
/// under the pinned switcher instead of behind it. Also reports the section's top for the highlight.
struct GroupSectionAnchor: View {
    let section: GroupInfoSection
    let marks: GroupInfoScrollMarks
    var body: some View {
        Color.clear
            .frame(height: 64)
            .id(section.anchorId)
            .padding(.top, -64)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { marks.setTop($0, for: section) }
            .accessibilityHidden(true)
    }
}

// MARK: - History

/// One line of the group's history, read back from its notice line (`type: "system"`): what
/// happened, who did it (the line's author), when, and which shelf it goes on.
struct GroupHistoryEvent: Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case members, admins, info, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .members: return "Members"
            case .admins: return "Admins"
            case .info: return "Group Info"
            case .settings: return "Settings"
            }
        }
    }
    enum Kind {
        case created, joined, joinedByLink, added, left, removed, ended
        case madeAdmin, adminRemoved, owner, restricted, unrestricted
        case renamed, photo, wallpaper, badge
        case slowMode, disappearing, sending, other

        var category: Category {
            switch self {
            case .created, .joined, .joinedByLink, .added, .left, .removed: return .members
            case .madeAdmin, .adminRemoved, .owner, .restricted, .unrestricted: return .admins
            case .renamed, .photo, .wallpaper, .badge: return .info
            case .slowMode, .disappearing, .sending, .other, .ended: return .settings
            }
        }
        var icon: String {
            switch self {
            case .created: return "sparkles"
            case .joined, .added: return "person.badge.plus"
            case .joinedByLink: return "link"
            case .left: return "rectangle.portrait.and.arrow.right"
            case .removed: return "person.badge.minus"
            case .madeAdmin: return "checkmark.shield"
            case .adminRemoved: return "shield.slash"
            case .owner: return "crown"
            case .restricted: return "hand.raised"
            case .unrestricted: return "hand.thumbsup"
            case .renamed: return "pencil"
            case .photo: return "photo"
            case .wallpaper: return "paintpalette"
            case .badge: return "checkmark.seal"
            case .slowMode: return "timer"
            case .disappearing: return "clock.badge.xmark"
            case .sending: return "bubble.left.and.bubble.right"
            case .other: return "gearshape"
            case .ended: return "xmark.circle"
            }
        }
        var tint: Color {
            switch self {
            case .left, .removed, .adminRemoved, .restricted, .ended: return .red
            case .owner: return .orange
            case .created, .joined, .joinedByLink, .added, .unrestricted: return .green
            default: return .blue
            }
        }
    }
    let id: String
    let kind: Kind
    let text: String
    let at: Date
    let actor: String

    /// The notice texts the app and the server write (ChatService, functions-groups, the moderation
    /// texts in functions-admin), matched on their fixed words, most specific first, so "removed X as
    /// admin" is not read as a removal. Nil for a line that is not a group change (a call row, a
    /// screenshot notice).
    static func kind(of raw: String) -> Kind? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        // "joined the group via invite link" is what functions-groups writes (audit 2026-10-20:
        // the old " joined via invite link" never matched, so link joins were missing here).
        if t.hasSuffix("via invite link") { return .joinedByLink }
        if t.hasSuffix(" joined the group") { return .joined }
        if t.hasSuffix(" created the group") { return .created }
        if t.hasSuffix(" ended the group") { return .ended }
        if t.hasSuffix(" left") || t.hasSuffix(" left the group") { return .left }
        if t.hasSuffix(" as admin") || t.hasSuffix(" as an admin.") { return .adminRemoved }
        if t.hasSuffix(" is now the owner") || t.hasSuffix(" the owner of this group.") { return .owner }
        if t.hasSuffix(" an admin") { return .madeAdmin }
        if l.contains("lifted the restrictions") { return .unrestricted }
        if l.contains(" restricted ") && !l.contains("restricted chat") && !l.contains("restricted group")
            && !l.contains("messaging to admins") { return .restricted }
        if l.contains("renamed the group") { return .renamed }
        if l.contains("wallpaper") { return .wallpaper }
        if l.contains("verified badge") || l.contains(" label") { return .badge }
        if l.contains("group photo") { return .photo }
        if l.contains("slow mode") { return .slowMode }
        if l.contains("disappearing messages") { return .disappearing }
        if l.contains("admins only") || l.contains("everyone to send") || l.contains("restricted chat")
            || l.contains("restricted group") || l.contains("members can") || l.contains("members may") { return .sending }
        if t.hasSuffix(" from the group.") { return .removed }
        if t.contains(" removed ") { return .removed }
        if t.contains(" added ") { return .added }
        return nil
    }
}

/// ⛔ HISTORY (owner 2026-10-20: "rename it History, read how the reference app's works, then make
/// our own"). Every change the group's notice lines record, newest first, on day shelves: who did
/// it (their photo, a small badge for what), the line itself, and the time. A strip of kinds
/// (All, Members, Admins, Group Info, Settings), a "by whom" menu and search narrow it; a long press
/// shows the line in the chat. Admins only (Group Settings shows the row to them alone).
///
/// What it is built from, honestly: the notice lines, which say what changed in words but keep no
/// old/new values, so a change shows as its sentence, not a before and after. They are kept for as
/// long as the group keeps its messages, not a fixed window.
///
/// ⚠️ THE READ IS ONE EQUALITY QUERY on `type`, with no `createdAt` order: an order would need a
/// composite index (type + createdAt) that firestore.indexes.json does not have. The single-field
/// index answers the equality alone, so newest-first is made here, after the read, which is capped.
/// The chat's cached lines are merged in so the page has something offline.
struct GroupHistoryView: View {
    let cid: String
    @Environment(\.dismiss) private var dismiss
    @State private var events: [GroupHistoryEvent] = []
    @State private var loading = true
    @State private var failed = false
    @State private var capped = false
    @State private var shelf: GroupHistoryEvent.Category?
    @State private var actor: String?
    @State private var query = ""
    private static let cap = 1500

    private var conv: Conversation? { ConversationsRepository.shared.conversations.first { $0.id == cid } }
    private var me: String { AuthService.shared.uid ?? "" }

    private func name(_ uid: String) -> String {
        if uid == me { return "You" }
        let n = conv?.names[uid] ?? ""
        return n.isEmpty ? "Someone" : n
    }

    private var shown: [GroupHistoryEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { e in
            (shelf == nil || e.kind.category == shelf)
                && (actor == nil || e.actor == actor)
                && (q.isEmpty || e.text.lowercased().contains(q))
        }
    }

    /// Day shelves, newest day first: "Today", "Yesterday", then the date.
    private var days: [(key: Date, items: [GroupHistoryEvent])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: shown) { cal.startOfDay(for: $0.at) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return d.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide)
                                    : .dateTime.day().month(.wide).year())
    }

    /// The people who did something here, most active first, for the "by whom" menu.
    private var actors: [String] {
        let counts = Dictionary(grouping: events, by: \.actor).mapValues(\.count)
        return counts.keys.filter { !$0.isEmpty }.sorted { (counts[$0] ?? 0, name($1)) > (counts[$1] ?? 0, name($0)) }
    }

    var body: some View {
        List {
            // In the list again (owner 2026-10-21: floated in a top inset they vanished under the
            // bar's own scroll-edge fade). The gap above them is the content margin below.
            Section {
                shelves
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if events.isEmpty {
                Section { emptyState.listRowBackground(Color.clear) }
            } else if shown.isEmpty {
                Section {
                    ContentUnavailableView.search(text: query.isEmpty ? "" : query)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(days, id: \.key) { day in
                    Section {
                        ForEach(day.items) { e in row(e) }
                    } header: {
                        Text(Self.dayTitle(day.key))
                    }
                }
                Section {} footer: {
                    Text(capped || failed
                         ? "Showing what this phone could load. Older changes may be missing."
                         : "Only admins see History.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        // No band above the tabs (owner 2026-10-21): the list starts right under the header.
        .contentMargins(.top, 0, for: .scrollContent)
        .animation(.snappy(duration: 0.25), value: shelf)
        .animation(.snappy(duration: 0.25), value: actor)
        // At the foot, as Members has it (owner 2026-10-20).
        .searchable(text: $query, placement: .toolbar, prompt: "Search history")
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actorMenu }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: Pieces

    /// The kinds as sliding capsules; the picked one filled.
    private var shelves: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", on: shelf == nil) { shelf = nil }
                ForEach(GroupHistoryEvent.Category.allCases) { c in
                    chip(c.title, on: shelf == c) { shelf = (shelf == c ? nil : c) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    /// A liquid glass capsule; the picked one is glass tinted in the text colour (owner 2026-10-21).
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color(uiColor: .systemBackground) : Color.primary)
                .padding(.horizontal, 16).frame(minHeight: 36)
                .liquidGlass(Capsule(), interactive: true, tint: on ? .primary : nil)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "By whom": everyone, or one person's changes only.
    private var actorMenu: some View {
        Menu {
            Button { actor = nil } label: {
                if actor == nil { Label("Everyone", systemImage: "checkmark") } else { Text("Everyone") }
            }
            Divider()
            ForEach(actors, id: \.self) { u in
                Button { actor = u } label: {
                    if actor == u { Label(name(u), systemImage: "checkmark") } else { Text(name(u)) }
                }
            }
        } label: {
            // The owner's filter icon (2026-10-21); blue while one person is picked.
            Image("ic_history_filter").renderingMode(.template)
                .foregroundStyle(actor == nil ? Color.primary : Color(hex: 0x2392FE))
        }
        .accessibilityLabel(actor == nil ? "Show changes by" : "Showing changes by \(name(actor ?? ""))")
    }

    private func row(_ e: GroupHistoryEvent) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(name: name(e.actor), photoUrl: conv?.photos[e.actor], size: 38)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: e.kind.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(e.kind.tint))
                        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            Text(sentence(e))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(e.at.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button {
                NotificationCenter.default.post(name: .goToMessage, object: GoToMessage(cid: cid, messageId: e.id))
            } label: { Label("Show in Chat", systemImage: "bubble.left") }
            Button {
                UIPasteboard.general.string = e.text
            } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }

    /// The line with whoever did it in bold, when the line starts with their name.
    private func sentence(_ e: GroupHistoryEvent) -> AttributedString {
        var out = AttributedString(e.text)
        let who = conv?.names[e.actor] ?? ""
        if !who.isEmpty, e.text.hasPrefix(who), let r = out.range(of: who) {
            out[r].font = .subheadline.weight(.semibold)
        }
        return out
    }

    @ViewBuilder private var emptyState: some View {
        if loading {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        } else if failed {
            ContentUnavailableView("Couldn't load history", systemImage: "wifi.exclamationmark",
                                   description: Text("Check your connection, then pull down to try again."))
        } else {
            ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Changes to members, admins and the group's settings show up here."))
        }
    }

    // MARK: Load

    @MainActor private func load() async {
        var lines: [String: Message] = [:]
        for m in ThreadMessageCache.shared.messages(for: cid) ?? [] where m.isSystem { lines[m.id] = m }
        if events.isEmpty { events = Self.events(from: lines) }
        guard !cid.isEmpty else { loading = false; return }   // an empty id throws an NSException
        do {
            let snap = try await FirestoreHub.db.collection("conversations").document(cid)
                .collection("messages").whereField("type", isEqualTo: "system")
                .limit(to: Self.cap).getDocuments()
            capped = snap.documents.count >= Self.cap
            failed = false
            for d in snap.documents {
                lines[d.documentID] = Message(id: d.documentID, data: d.data(), cid: cid, crypto: Crypto.shared)
            }
        } catch {
            failed = true
        }
        events = Self.events(from: lines)
        loading = false
    }

    private static func events(from lines: [String: Message]) -> [GroupHistoryEvent] {
        lines.values.compactMap { m -> GroupHistoryEvent? in
            guard !m.deleted, let k = GroupHistoryEvent.kind(of: m.text) else { return nil }
            return GroupHistoryEvent(id: m.id, kind: k, text: m.text, at: m.createdAt, actor: m.authorId)
        }
        .sorted { $0.at > $1.at }
    }
}

// MARK: - This chat's storage

/// What this chat's media takes on this phone, from the caches each kind lives in (there is no
/// per-chat ledger, so it is summed from the messages' own urls and ids).
///
/// ⛔ ONLY THE CACHE PART CAN BE CLEARED. Under the mailman model a chat photo, video or voice note
/// on this phone is its ONLY copy once delivered (DiskImageCache `.own`, VideoCache, AudioCache), so
/// deleting it would delete the message's content. Clear takes the `.img` cache copies alone
/// (GIFs, previews, anything that downloads again) and never a message.
enum ChatMediaStorage {
    struct Usage: Equatable { var total = 0; var clearable = 0 }

    /// Every image url this chat's messages point at (photos, album photos, video posters, GIFs).
    private static func imageURLs(_ messages: [Message]) -> Set<String> {
        var out = Set<String>()
        for m in messages {
            if let u = m.imageUrl, !u.isEmpty { out.insert(u) }
            if let u = m.thumbUrl, !u.isEmpty { out.insert(u) }
            for item in m.album where !item.imageUrl.isEmpty { out.insert(item.imageUrl) }
        }
        return out
    }

    static func measure(_ messages: [Message]) -> Usage {
        var u = Usage()
        for url in imageURLs(messages) {
            let b = DiskImageCache.shared.diskBytes(for: url)
            u.total += b.total
            u.clearable += b.cache
        }
        var seen = Set<String>()
        for m in messages where seen.insert(m.id).inserted {
            if m.isVideo { u.total += VideoCache.diskBytes(for: m.id) }
            if m.isAudio { u.total += AudioCache.diskBytes(for: m.id) }
            for (i, item) in m.album.enumerated() where item.isVideo {
                u.total += VideoCache.diskBytes(for: "\(m.id)-\(i)")
            }
        }
        return u
    }

    static func clearCache(_ messages: [Message]) {
        for url in imageURLs(messages) { DiskImageCache.shared.removeCacheCopy(url: url) }
    }
}

// MARK: - Save to Photos (this chat)

extension AutoSaveToPhotos.ChatChoice {
    var label: String {
        switch self {
        case .standard: return AutoSaveToPhotos.isOn ? "Default (On)" : "Default (Off)"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

// The invite link's QR sheet (`GroupLinkQRSheet`) lives in GroupQRCard.swift (2026-10-19).

// MARK: - Encryption

/// How a group's messages are protected, in our own words. Opened from the group page only.
///
/// ⛔ REDRAWN (owner 2026-10-19: "our encryption looks super cheap" beside the reference sheet). A
/// drawn emblem rather than a flat circle, a large title, the promise in full-strength text, and
/// each covered kind with one line saying what that means. The emblem is shapes and system symbols,
/// not a picture: the owner's own illustration can take its place (`hero`).
///
/// ⛔ GROUPS ARE NOT END-TO-END ENCRYPTED (owner 2026-10-19, groups v2): new group messages are kept
/// on our servers, which can read them, like the reference app's cloud groups. This sheet used to
/// promise "no one else can read them, not even Fariin"; that is no longer true for a group, so it
/// now says what does hold: the connection, the server's access rules, the old sealed messages and
/// the one-to-one chats. A group the migration has not reached yet is told the same: saying less
/// than the truth for a moment is the safe direction, claiming encryption that is gone is not.
struct ChatEncryptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// Fixed brand blue: `accentColor` is white in dark mode.
    private static let blue = Color(hex: 0x2C6BED)

    private struct Covered { let icon: String; let title: String; let line: String }
    private let items: [Covered] = [
        .init(icon: "network.badge.shield.half.filled", title: "Protected on the way",
              line: "Messages, photos and files travel over an encrypted connection to our servers."),
        .init(icon: "person.2.fill", title: "Kept for the members",
              line: "On our servers, access rules let only the people in this group read its messages."),
        .init(icon: "clock.arrow.circlepath", title: "Older messages",
              line: "Messages sent before this change stay end-to-end encrypted."),
        .init(icon: "lock.fill", title: "Your one-to-one chats",
              line: "Still end-to-end encrypted. Only you and the other person can read them."),
        // No calls row and no stories row: neither is end-to-end encrypted (2026-10-18/19).
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                hero.padding(.top, 4)

                Text("How this group is protected")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
                Text("Group messages are protected in transit and on our servers, but they are not end-to-end encrypted. That means Fariin's servers can read them.")
                    .font(.system(size: 17))
                    .foregroundStyle(.primary.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.horizontal, 6)

                VStack(alignment: .leading, spacing: 20) {
                    ForEach(items, id: \.title) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: item.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Self.blue)
                                .frame(width: 40, height: 40)
                                .background(Self.blue.opacity(scheme == .dark ? 0.22 : 0.11),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 17, weight: .semibold))
                                Text(item.line).font(.system(size: 15)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 30)
                .padding(.horizontal, 4)

                Button {
                    if let u = URL(string: "https://fariin.com/safety") { WebLink.open(u) }
                } label: {
                    Text("Learn More")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Self.blue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Self.blue.opacity(scheme == .dark ? 0.22 : 0.11), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 34)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .presentationDetents([.large])
    }

    /// A shield on a soft rounded tile (not a lock: this group is not end-to-end encrypted), a ring
    /// around it, and three of the things it covers resting on the ring.
    private var hero: some View {
        ZStack {
            Circle()
                .stroke(Self.blue.opacity(0.16), lineWidth: 1.5)
                .frame(width: 172, height: 172)
            Circle()
                .fill(Self.blue.opacity(scheme == .dark ? 0.12 : 0.06))
                .frame(width: 140, height: 140)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x4A8BFF), Self.blue],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 96, height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: Self.blue.opacity(0.35), radius: 16, y: 8)
                .overlay(
                    Image(systemName: "shield.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                )
            satellite("text.bubble.fill", angle: -140)
            satellite("photo.fill", angle: -35)
            satellite("location.fill", angle: 95)
        }
        .frame(width: 200, height: 190)
        .accessibilityHidden(true)
    }

    private func satellite(_ symbol: String, angle: Double) -> some View {
        let r: CGFloat = 86
        let rad = angle * .pi / 180
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Self.blue)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color(uiColor: .systemBackground)))
            .overlay(Circle().stroke(Self.blue.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            .offset(x: r * cos(rad), y: r * sin(rad))
    }
}

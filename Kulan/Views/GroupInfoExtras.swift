import SwiftUI
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

// MARK: - Member changes

/// One join, leave, removal or admin change, read back from the group's own notice line.
struct GroupMemberEvent: Identifiable {
    enum Kind {
        case created, joined, joinedByLink, added, left, removed, madeAdmin, adminRemoved, owner
        var icon: String {
            switch self {
            case .created: return "sparkles"
            case .joined, .added: return "person.badge.plus"
            case .joinedByLink: return "link"
            case .left: return "rectangle.portrait.and.arrow.right"
            case .removed: return "person.badge.minus"
            case .madeAdmin, .owner: return "star"
            case .adminRemoved: return "star.slash"
            }
        }
        var tint: Color {
            switch self {
            case .left, .removed, .adminRemoved: return .red
            default: return .accentColor
            }
        }
    }
    let id: String
    let kind: Kind
    let text: String
    let at: Date

    /// The notice texts the app and the server write (ChatService, functions-groups, the moderation
    /// texts in functions-admin). Matched on their fixed endings, most specific first, so "removed X
    /// as admin" is not read as a removal and the wallpaper / label notices are not members at all.
    static func kind(of raw: String) -> Kind? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(" joined via invite link") { return .joinedByLink }
        if t.hasSuffix(" joined the group") { return .joined }
        if t.hasSuffix(" created the group") { return .created }
        if t.hasSuffix(" left") { return .left }
        if t.hasSuffix(" as admin") || t.hasSuffix(" as an admin.") { return .adminRemoved }
        if t.hasSuffix(" is now the owner") || t.hasSuffix(" the owner of this group.") { return .owner }
        if t.hasSuffix(" an admin") { return .madeAdmin }
        if t.hasSuffix(" from the group.") { return .removed }
        let notMembers = ["wallpaper", "label", "verified badge", "restrictions"]
        if notMembers.contains(where: { t.contains($0) }) { return nil }
        if t.contains(" removed ") { return .removed }
        if t.contains(" added ") { return .added }
        return nil
    }
}

/// Member Changes: who joined, left, was removed or changed admin, newest first. Read-only, built from
/// the group's notice lines (`type: "system"`), the same lines the chat shows in the middle.
///
/// ⚠️ THE READ IS ONE EQUALITY QUERY on `type`, with no `createdAt` order: an order would need a
/// composite index (type + createdAt) that firestore.indexes.json does not have, and that is a
/// server change. The single-field index answers the equality alone, so the newest-first order is
/// made here, after the read, and the read is capped. The chat's cached lines are merged in so the
/// page has something offline, and the footer says so when the cap was reached.
struct GroupMemberChangesView: View {
    let cid: String
    @State private var events: [GroupMemberEvent] = []
    @State private var loading = true
    @State private var failed = false
    @State private var capped = false
    private static let cap = 1500

    var body: some View {
        List {
            Section {
                ForEach(events) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: e.kind.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(e.kind.tint)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(e.kind.tint.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.text).foregroundStyle(.primary)
                            Text(e.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                if loading && events.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if failed && events.isEmpty {
                    Text("Could not load the changes. Check your connection and try again.")
                } else if events.isEmpty {
                    Text("No member changes yet.")
                } else if capped || failed {
                    Text("Showing the changes this phone could load. Older ones may be missing.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Member Changes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @MainActor private func load() async {
        var lines: [String: Message] = [:]
        for m in ThreadMessageCache.shared.messages(for: cid) ?? [] where m.isSystem { lines[m.id] = m }
        events = Self.events(from: lines)
        guard !cid.isEmpty else { loading = false; return }   // an empty id throws an NSException
        do {
            let snap = try await Firestore.firestore().collection("conversations").document(cid)
                .collection("messages").whereField("type", isEqualTo: "system")
                .limit(to: Self.cap).getDocuments()
            capped = snap.documents.count >= Self.cap
            for d in snap.documents {
                lines[d.documentID] = Message(id: d.documentID, data: d.data(), cid: cid, crypto: Crypto.shared)
            }
        } catch {
            failed = true
        }
        events = Self.events(from: lines)
        loading = false
    }

    private static func events(from lines: [String: Message]) -> [GroupMemberEvent] {
        lines.values.compactMap { m -> GroupMemberEvent? in
            guard !m.deleted, let k = GroupMemberEvent.kind(of: m.text) else { return nil }
            return GroupMemberEvent(id: m.id, kind: k, text: m.text, at: m.createdAt)
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

// MARK: - Invite link QR

/// The invite link as a code, white behind it so any camera reads it in either theme (the invite
/// link page's QR sheet, reached here from the top bar).
struct GroupLinkQRSheet: View {
    let title: String
    let link: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
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
            Text(title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            if let img = qrImage(from: link) {
                Image(uiImage: img)
                    .interpolation(.none).resizable().scaledToFit()
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: 292)
            }
            Text(link).font(.footnote.monospaced()).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Encryption

/// What end-to-end encryption covers in this chat, in our own words.
struct ChatEncryptionSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let items: [(icon: String, text: String)] = [
        ("text.bubble", "Text and voice messages"),
        // No calls row: group calls go through a call server and are not proven end-to-end
        // encrypted, so this sheet does not promise it (2026-10-18). Add it back only once they are.
        ("photo.on.rectangle", "Photos, videos and files"),
        ("location", "Location"),
        ("circle.dashed", "Stories"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
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
                // PLACEHOLDER ART (owner 2026-10-18): an Apple lock in an accent circle holds the spot
                // until the owner sends his own picture for this sheet.
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 104)
                    .background(Circle().fill(Color.accentColor))
                Text("Your messages are private")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Everything in this chat is locked on your phone and opened only on the phones of the people in it. Nobody else can read them, and that includes Fariin.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        if i > 0 { Divider().padding(.leading, 56) }
                        HStack(spacing: 14) {
                            Image(systemName: item.icon).font(.system(size: 17))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 26)
                            Text(item.text)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button {
                    if let u = URL(string: "https://fariin.com/help") { WebLink.open(u) }
                } label: {
                    Text("Learn more").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .presentationDetents([.large])
    }
}

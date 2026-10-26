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
        // 2026-10-23 (owner): members read the group's history, the ones who join later too, as the
        // reference app's cloud groups do. Old sealed messages open once a member who could read
        // them has opened the group; one that nobody left in the group can open stays locked.
        .init(icon: "clock.arrow.circlepath", title: "Group history",
              line: "Members can see messages sent before they joined, unless the admins hid the history. Older encrypted messages open once someone who could read them opens the group."),
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
                Text("Messages in this group are not end-to-end encrypted. They are protected in transit and on our servers, and Fariin's servers can read them.")
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

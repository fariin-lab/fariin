import SwiftUI
import UIKit
import Observation

// ⛔ 2026-10-19: THE PANEL'S LOOK BELOW IS HISTORY. The owner asked for our own design: one glass
// card "Things you can do" with glass circles (GetStartedBanner). The pastel card numbers and tints
// further down describe the old reference-style cards; the store and the logic still apply.
//
// ⛔ GET STARTED + THE FIRST-CHAT TIP — owner 2026-10-18, with screenshots of the reference app on a
// brand-new account: a "Get Started" row of pastel cards at the bottom of the empty chat list, and a
// blue tip under the compose button. "Build completely": same card size, colours, spacing, corner
// radius, fonts, scroll, the X takes one card away, and the logic as theirs.
//
// Ported from the reference app's own source (its GetStartedBannerViewController and the chat list's
// first-conversation cue), numbers unchanged:
//   card 156 x 98, 12 apart, corner 26 on iOS 26, tinted glass; icon 28 x 28 over the label, 4 apart,
//   label footnote semibold up to 3 lines; X at the top-right with 12 around it; title in headline,
//   12 below the top of the panel and 10 above the cards; panel 20 above the tab bar. Tints:
//   light F6EDE0 / DEE5D6 / E5DBE7 / D6E5E5 at 0.6, dark D7BFA9 / 95B373 / CE85DD / 8ACECE at 0.4.
//   Tip: accent fill, corner 9, an 8-high 16-wide tail whose centre sits 20 in from the trailing
//   edge, text padded 11 / 16, 6 in from the screen edge.
//
// Their logic, and the two places this differs on purpose:
//   - an X takes that card away for good (stored per account, like theirs);
//   - Add Photo goes for good once the profile has a photo (theirs: once there is an avatar);
//   - they drop the whole panel at five chats; the owner asked for it to go at the FIRST real chat,
//     so here any conversation with a message that is not the Fariin channel ends it, for good;
//   - the tip shows while the inbox is empty and the account has never had a chat. Tapping it opens
//     compose. Like theirs it is not put away by a tap; it goes once a chat exists.
//   All wording on screen is ours.

/// The four cards, in their order.
enum GetStartedCard: String, CaseIterable, Identifiable {
    case newGroup, inviteFriends, addPhoto, chatColor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newGroup: "New group"
        case .inviteFriends: "Invite friends"
        case .addPhoto: "Add photo"
        case .chatColor: "Chat color"
        }
    }

    /// Filled glyphs in the glass circles, as the group page's circles use.
    var symbol: String {
        switch self {
        case .newGroup: "person.2.fill"
        case .inviteFriends: "envelope.fill"
        case .addPhoto: "person.crop.circle.fill"
        case .chatColor: "paintpalette.fill"
        }
    }

    /// The reference app's tints: one colour for light, one for dark, each see-through.
    var tint: Color {
        let (light, dark): (UInt32, UInt32) = switch self {
        case .newGroup: (0xF6EDE0, 0xD7BFA9)
        case .inviteFriends: (0xDEE5D6, 0x95B373)
        case .addPhoto: (0xE5DBE7, 0xCE85DD)
        case .chatColor: (0xD6E5E5, 0x8ACECE)
        }
        return Color(UIColor { tc in
            tc.userInterfaceStyle == .dark ? Self.ui(dark, alpha: 0.4) : Self.ui(light, alpha: 0.6)
        })
    }

    private static func ui(_ hex: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// What has been put away, per account, in UserDefaults. `version` is the one stored property the
/// views read, so a write redraws them.
@Observable
final class GetStartedStore {
    static let shared = GetStartedStore()
    private init() {}

    private(set) var version = 0
    private let defaults = UserDefaults.standard

    private func key(_ uid: String, _ name: String) -> String { "getStarted.\(uid).\(name)" }

    /// The account has had a real chat: the panel and the tip are over for good.
    func isFinished(_ uid: String) -> Bool {
        _ = version
        return uid.isEmpty || defaults.bool(forKey: key(uid, "finished"))
    }

    func finish(_ uid: String) {
        guard !uid.isEmpty, !defaults.bool(forKey: key(uid, "finished")) else { return }
        defaults.set(true, forKey: key(uid, "finished"))
        version += 1
    }

    /// Undo of the card's X (owner 2026-10-19: one stray tap must not lose it for good).
    func reopen(_ uid: String) {
        guard !uid.isEmpty, defaults.bool(forKey: key(uid, "finished")) else { return }
        defaults.set(false, forKey: key(uid, "finished"))
        version += 1
    }

    /// The first-chat tip, put away once the pen was tapped (owner 2026-10-18: "when I tap the pen,
    /// hide that badge"). Its own flag: the cards stay until the first real chat.
    func isTipDismissed(_ uid: String) -> Bool {
        _ = version
        return uid.isEmpty || defaults.bool(forKey: key(uid, "tipDismissed"))
    }

    func dismissTip(_ uid: String) {
        guard !uid.isEmpty, !defaults.bool(forKey: key(uid, "tipDismissed")) else { return }
        defaults.set(true, forKey: key(uid, "tipDismissed"))
        version += 1
    }

    func isRemoved(_ card: GetStartedCard, _ uid: String) -> Bool {
        _ = version
        return (defaults.stringArray(forKey: key(uid, "removed")) ?? []).contains(card.rawValue)
    }

    func remove(_ card: GetStartedCard, _ uid: String) {
        guard !uid.isEmpty else { return }
        var list = defaults.stringArray(forKey: key(uid, "removed")) ?? []
        guard !list.contains(card.rawValue) else { return }
        list.append(card.rawValue)
        defaults.set(list, forKey: key(uid, "removed"))
        version += 1
    }

    /// The cards still to show, in order.
    func cards(_ uid: String, hasPhoto: Bool, groups: Bool) -> [GetStartedCard] {
        guard !isFinished(uid) else { return [] }
        return GetStartedCard.allCases.filter { c in
            if isRemoved(c, uid) { return false }
            if c == .newGroup && !groups { return false }
            if c == .addPhoto && hasPhoto { return false }
            return true
        }
    }
}

/// ⛔ OUR OWN LOOK (owner 2026-10-19: the pastel cards were the reference's exactly; a checklist read
/// as homework). One glass card, "Things you can do", four glass circles with their names, the
/// group page's own circle. The X hides the whole card (the shell offers Undo); press and hold a
/// circle to hide just that one.
struct GetStartedBanner: View {
    let cards: [GetStartedCard]
    let onTap: (GetStartedCard) -> Void
    let onRemove: (GetStartedCard) -> Void
    let onHideAll: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Things you can do")
                    .font(.headline)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: onHideAll) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide")
            }
            .padding(.horizontal, 6)
            HStack(spacing: 0) {
                ForEach(cards) { card in
                    Button { onTap(card) } label: {
                        PosterActionIcon(icon: card.symbol, diameter: 54, onPhoto: false, label: card.title)
                    }
                    .tint(.primary)
                    .contextMenu {
                        Button(role: .destructive) { onRemove(card) } label: {
                            Label("Hide", systemImage: "eye.slash")
                        }
                    }
                    .accessibilityLabel(card.title)
                    .accessibilityAction(named: "Hide") { onRemove(card) }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 16)
        .liquidGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 40 + 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        // Rows (the Fariin channel) can sit under the panel: a 40-high fade into the page colour,
        // then solid down behind the tab bar, as theirs. Not hit-testable, so the faded strip does
        // not swallow taps on the row behind it.
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
                Color(.systemBackground)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

/// The blue tip under compose. `anchorX` is the compose button's centre in window points; the tail
/// is drawn under it. Without it the tail sits where the reference puts it, 20 in from the edge.
struct FirstChatCue: View {
    let anchorX: CGFloat?
    let onTap: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var minX: CGFloat = 0
    @State private var width: CGFloat = 0

    private var tailX: CGFloat? {
        guard let anchorX, anchorX > 0, width > 0 else { return nil }
        return anchorX - minX
    }

    var body: some View {
        // ⛔ OWNER 2026-10-18 (build 969): shorter words, round ends, Liquid Glass in the app's blue.
        Text("Start your first chat")
            .font(.subheadline.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.top, 9 + CueShape.tailHeight)
            .padding(.bottom, 9)
            .padding(.horizontal, 16)
            .glassEffect(.regular.tint(Theme.defaultBubble(scheme == .dark)).interactive(),
                         in: CueShape(tailX: tailX))
            .contentShape(CueShape(tailX: tailX))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                minX = f.minX; width = f.width
            }
            .onTapGesture(perform: onTap)
            .accessibilityAddTraits(.isButton)
            .padding(.trailing, 6)
            .padding(.leading, 10)
    }
}

private struct CueShape: Shape {
    static let tailHeight: CGFloat = 8
    static let tailWidth: CGFloat = 16
    static let tailMargin: CGFloat = 12
    var tailX: CGFloat?

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let bubble = CGRect(x: rect.minX, y: rect.minY + Self.tailHeight,
                            width: rect.width, height: rect.height - Self.tailHeight)
        p.addRoundedRect(in: bubble, cornerSize: CGSize(width: bubble.height / 2, height: bubble.height / 2),
                         style: .continuous)
        let half = Self.tailWidth / 2
        let fallback = rect.width - Self.tailMargin - half
        let lo = Self.tailMargin + half, hi = rect.width - Self.tailMargin - half
        let x = rect.minX + min(max(tailX ?? fallback, lo), max(lo, hi))
        p.move(to: CGPoint(x: x, y: rect.minY))
        p.addLine(to: CGPoint(x: x - half, y: rect.minY + Self.tailHeight))
        p.addLine(to: CGPoint(x: x + half, y: rect.minY + Self.tailHeight))
        p.closeSubpath()
        return p
    }
}

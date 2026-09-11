import SwiftUI
import Observation
import FirebaseAuth

// Our own in-app message banner, instead of borrowing the iOS one.
//
// A push that lands while the app is OPEN used to be shown by the system: the standard grey
// notification drop-down, which reads as "something outside the app happened" even though you are
// looking at the app. the standard messengers all draw their own, styled like the app, and
// that is what this is: avatar, name, the message, tap to open, swipe up to send it away.
//
// The chat you are currently looking at never banners itself — see PushManager.willPresent.

@Observable
final class InAppBannerCenter {
    static let shared = InAppBannerCenter()
    private init() {}

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let cid: String?
        let title: String
        let body: String
        let photoUrl: String?
    }

    private(set) var item: Item?
    private var hideTask: DispatchWorkItem?
    /// ⛔ 5.0, THEIR NUMBER — owner, 2026-09-11, "make it exactly like [theirs]". Ours was 4.5.
    ///
    /// ⚠️ AND IT IS 5.0 IN EVERY BUILD OF THEIRS, which is worth writing down because their source
    /// looks like it is not: they compute a `timeout` of 6 seconds under DEBUG and then construct
    /// the timer with a hardcoded 5.0, never reading it. Copying the variable rather than the
    /// behaviour would have given us a number their app has never actually used.
    private static let visibleFor: TimeInterval = 5.0

    /// ⛔ POSITION, 0.4s, EASE-IN-EASE-OUT — NOT A SPRING. Theirs animates one property, the layer's
    /// position, over the card's own height with the default timing function; there is no spring
    /// anywhere in that path and no fade. Ours used two different springs for in and out, which is
    /// where the bounce on arrival came from.
    static let slide: Animation = .easeInOut(duration: 0.4)

    @MainActor
    func show(cid: String?, title: String, body: String) {
        // A second message replaces the first and restarts the clock, rather than stacking — which
        // is theirs too: `enqueue` animates the old card out and the new one in at the same moment,
        // and only one item is ever tracked.
        let next = Item(cid: cid, title: title, body: body, photoUrl: cid.flatMap(Self.photo(forCid:)))
        withAnimation(Self.slide) { item = next }
        hideTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    @MainActor
    func dismiss() {
        hideTask?.cancel(); hideTask = nil
        withAnimation(Self.slide) { item = nil }
    }

    /// The sender's photo out of the chat list we already hold: the group's photo for a group, the
    /// other person's for a 1:1. Nothing is fetched here — a miss just falls back to the coloured
    /// initial, the same as every other avatar in the app.
    private static func photo(forCid cid: String) -> String? {
        guard let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        else { return nil }
        if conv.convType == "group" { return conv.avatarUrl }
        let me = Auth.auth().currentUser?.uid ?? ""
        guard let other = conv.users.first(where: { $0 != me }) else { return nil }
        return conv.photos[other]
    }
}

/// THE CARD, REBUILT TO THE REFERENCE APP'S OWN MEASUREMENTS — owner, 2026-09-11: "read their
/// in-app preview design, size, every liquid glass, weight, height, everything, then make it like
/// that. Redesign my notification in-app preview, make it exactly like [theirs] 100%."
///
/// Every number below was read out of their source rather than measured off a screenshot, and each
/// one is named where it sits. Their card is `NotificationItemContainerNode` with a
/// `ChatMessageNotificationItem` inside it; the surface is their glass component.
///
/// ⛔ TWO THINGS THIS REVERSES, BOTH DELIBERATE AND BOTH HIS CALL ON THE DAY.
///
/// 1. THE CARD IS NO LONGER PINNED DARK. It forced `.dark` on its own subtree with white text, and
///    that was a settled decision — it is listed in the accent notes as "not a bug, do not
///    re-report". Theirs is theme-aware: a near-white panel in light, a dark one at night. He was
///    told this is a reversal before approving it, and approved it.
/// 2. THE GRABBER IS GONE. Ours drew a 42x4 capsule as "the one cue that says this thing can be
///    pushed away". Theirs draws none — the card is 64pt of content and nothing else — and "exactly
///    like theirs" cannot keep it. The swipe still works and is now easier to trigger than it was.
struct InAppBannerCard: View {
    let item: InAppBannerCenter.Item
    /// The finger's own translation, rubber-banded downward — see `rubberBanded`.
    @State private var dragY: CGFloat = 0
    /// The pull-down haptic fires ONCE per gesture, at the point their card fires it.
    @State private var feltExpand = false
    @Environment(\.colorScheme) private var scheme

    private var center: InAppBannerCenter { InAppBannerCenter.shared }

    // MARK: - Their numbers

    /// 64, FIXED, and not derived from the content. Two lines of body text do not make their card
    /// taller; the text block is centred in a constant height and truncates instead. Ours grew to
    /// about 83 and moved with the message, which is why a long message used to push the card down
    /// over the screen.
    private static let cardHeight: CGFloat = 64
    private static let corner: CGFloat = 24
    /// 8 each side. Ours was 10.
    private static let sideInset: CGFloat = 8
    /// 40. Ours was 48, which is what made the whole card need more height.
    private static let avatar: CGFloat = 40
    /// The avatar's own leading inset inside the card.
    private static let avatarLeading: CGFloat = 12
    /// Their text column begins at 62 from the card's edge, and the avatar ends at 52 — so the gap
    /// between the two is 10, not the 12 ours used.
    private static let avatarToText: CGFloat = 10
    private static let trailingInset: CGFloat = 10
    /// ONE POINT between the name and the message. Ours used 2. At 15pt type that single point is
    /// what makes the pair read as one block rather than as two rows.
    private static let titleToBody: CGFloat = 1

    /// ⛔ THE TOP INSET IS THE DEVICE'S, NOT A CONSTANT — their `NotificationItemContainerNode`
    /// branches on the status bar's height, and the branch that matters here is the first: a phone
    /// with a Dynamic Island (status bar 39 or taller) gets `statusBarHeight + 6`, so the card
    /// clears the island by six points rather than by a number picked for one handset.
    ///
    /// Ours had NO top padding at all and sat flush under the island. The safe-area top is the same
    /// measurement SwiftUI has on hand, so it is read from there instead of from UIKit.
    private func topInset(safeTop: CGFloat) -> CGFloat {
        if safeTop >= 39 { return safeTop + 6 }     // Dynamic Island
        if safeTop >= 44 { return 42 }              // notch
        return 37                                    // everything older
    }

    var body: some View {
        GeometryReader { geo in
            card(safeTop: geo.safeAreaInsets.top)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        // The reader would otherwise take the whole screen and push the card's own frame with it.
        .frame(height: Self.cardHeight + 80)
        .allowsHitTesting(true)
    }

    @ViewBuilder private func card(safeTop: CGFloat) -> some View {
        HStack(spacing: Self.avatarToText) {
            AvatarView(name: item.title, photoUrl: item.photoUrl, size: Self.avatar)
            VStack(alignment: .leading, spacing: Self.titleToBody) {
                // 15 semibold, one line. Ours was 17.
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                // 15 regular, two lines. Ours was 16. The colour is secondary rather than a
                // dimmed white, because the card is theme-aware now.
                Text(item.body)
                    .font(.system(size: 15))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.avatarLeading)
        .padding(.trailing, Self.trailingInset)
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ⛔ THE APP'S OWN GLASS, WHICH IS THE SAME MATERIAL THEIRS ASKS FOR. Their card is a
        // `UIGlassEffect(style: .regular)` with a tint of 10% white in light and 2.5% in dark, and
        // NO border and NO shadow of its own on iOS 26 — the effect supplies both. `liquidGlass`
        // is this app's wrapper over exactly that effect, so the tint, the rim and the shadow come
        // from the system rather than from three values copied out of their file.
        //
        // ⚠️ WHICH IS WHY THE HAIRLINE AND THE DROP SHADOW ARE GONE. Ours drew a 1pt white 12%
        // stroke and a black 28% shadow at radius 18 because it was a flat material that needed
        // help standing off the screen. Adding them on top of real glass is what makes a card look
        // doubled — their legacy path draws a 0.8pt rim only because it has no glass to draw one.
        .liquidGlass(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .padding(.horizontal, Self.sideInset)
        .padding(.top, topInset(safeTop: safeTop))
        .offset(y: rubberBanded(dragY))
        .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .gesture(dragGesture)
        .onTapGesture { open() }
        // ⛔ POSITION ONLY, 0.4s, EASE-IN-EASE-OUT — and NOT a spring, which is what ours used.
        // Their `animateIn`/`animateOut` move the layer's position by the card's own height with
        // the default timing function and touch nothing else: no scale, no fade. Ours combined a
        // move with an opacity fade on a spring, which is why it arrived with a bounce and a
        // ghost. The move is asymmetric here (in from the top, out to the top) for the same reason
        // theirs is: it always leaves upward, whichever way it was dragged.
        .transition(.move(edge: .top))
    }

    // MARK: - The two gestures

    /// ⛔ DOWN IS RUBBER-BANDED AND CAPPED AT 50, UP IS FREE. Their formula exactly, coefficient
    /// 0.55 and limit 50: a pull downward can never move the card more than 50 points however hard
    /// it is dragged, which is what stops a downward drag reading as "I can put this anywhere".
    /// Upward is linear and unbounded, because upward is a dismissal and the card is leaving.
    private func rubberBanded(_ y: CGFloat) -> CGFloat {
        guard y > 0 else { return y }
        return (1 - (1 / ((y * 0.55 / 50) + 1))) * 50
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                dragY = v.translation.height
                // ⛔ THE HAPTIC PREVIEWS THE PULL-DOWN AT 24 POINTS, which is their number and is
                // deliberately NOT the same as the 20 that commits it: the tap is felt slightly
                // after the point of no return, so the finger learns the gesture has armed.
                if !feltExpand, rubberBanded(v.translation.height) > 24 {
                    feltExpand = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .onEnded { v in
                let travel = v.translation.height
                let velocity = v.predictedEndTranslation.height - travel
                feltExpand = false
                // ⛔ DOWN OPENS THE CHAT — the gesture ours did not have at all. 20 points of
                // rubber-banded travel, or a downward throw, and the banner behaves like a tap.
                if rubberBanded(travel) > 20 || velocity > 300 {
                    dragY = 0
                    open()
                    return
                }
                // ⛔ UP DISMISSES AT FIVE POINTS. Theirs commits on 5pt of travel or 200pt/s, where
                // ours asked for 28 — which is why swiping ours away felt like it needed a shove.
                if travel < -5 || velocity < -200 {
                    dragY = 0
                    center.dismiss()
                    return
                }
                // Neither: home again on their own snap-back, 0.3s and the same curve.
                withAnimation(.easeInOut(duration: 0.3)) { dragY = 0 }
            }
    }

    private func open() {
        if let cid = item.cid { AppRouter.shared.pendingChatId = cid }
        center.dismiss()
    }
}

extension View {
    /// Mount once, at the root, above everything the app normally shows.
    func inAppBanner() -> some View {
        overlay(alignment: .top) {
            if let item = InAppBannerCenter.shared.item {
                InAppBannerCard(item: item)
                    .id(item.id)   // a new message re-runs the slide-in instead of swapping text in place
            }
        }
    }
}

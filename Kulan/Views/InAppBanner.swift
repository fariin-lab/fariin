import SwiftUI
import Observation
import FirebaseAuth
import FirebaseFirestore

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
        /// A call link's nudge (owner 2026-10-23): drawn as the dark capsule with a Join pill.
        var nudge: LinkNudge? = nil
    }

    /// ⛔ UP TO TWO CARDS AT ONCE (owner 2026-10-25, the reference app's 13.1 motion): a second
    /// message sends the first card away on its exit springs WHILE the new one drops in, so for that
    /// moment both are on screen. A leaving card stays mounted until its springs have settled.
    struct Entry: Identifiable, Equatable {
        let item: Item
        var leaving = false
        var id: UUID { item.id }
    }
    private(set) var entries: [Entry] = []
    /// The card on screen and not leaving.
    var item: Item? { entries.last(where: { !$0.leaving })?.item }
    private var hideTask: DispatchWorkItem?
    /// Long enough for the slowest exit spring to settle (response 0.728, damping 0.698 is about
    /// 1.15s to a thousandth); by then the card is above the screen, shrunk and blurred anyway.
    private static let exitSettle: TimeInterval = 1.2
    /// ⛔ 5.0, THEIR NUMBER — owner, 2026-09-11, "make it exactly like [theirs]". Ours was 4.5.
    ///
    /// ⚠️ AND IT IS 5.0 IN EVERY BUILD OF THEIRS, which is worth writing down because their source
    /// looks like it is not: they compute a `timeout` of 6 seconds under DEBUG and then construct
    /// the timer with a hardcoded 5.0, never reading it. Copying the variable rather than the
    /// behaviour would have given us a number their app has never actually used.
    private static let visibleFor: TimeInterval = 5.0

    /// Puts `next` on screen; anything already there leaves at the same moment (their `enqueue`).
    @MainActor private func present(_ next: Item) {
        leaveAll()
        entries.append(Entry(item: next))
    }

    /// Marks every card as leaving (the card runs its exit springs) and unmounts each once settled.
    @MainActor private func leaveAll() {
        for i in entries.indices where !entries[i].leaving {
            entries[i].leaving = true
            let id = entries[i].id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitSettle) { [weak self] in
                self?.entries.removeAll { $0.id == id && $0.leaving }
            }
        }
    }

    @MainActor
    func show(cid: String?, title: String, body: String) {
        // A second message replaces the first and restarts the clock, rather than stacking — which
        // is theirs too: `enqueue` animates the old card out and the new one in at the same moment,
        // and only one item is ever tracked.
        // ⛔ FARIIN'S OWN MESSAGES SPEAK AS FARIIN — owner, 2026-10-17: "Password added" arrived with a
        // grey empty face and the message title where the sender goes. The channel's name and mark,
        // the same as its row in the list; the title moves in front of the words ("Title: body").
        if let cid, OfficialChannel.isOfficial(cid) {
            let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = head.isEmpty || head == OfficialChannel.name ? body : "\(head): \(body)"
            let next = Item(cid: cid, title: OfficialChannel.name, body: words, photoUrl: nil)
            present(next)
            armHide()
            return
        }
        let next = Item(cid: cid, title: title, body: body, photoUrl: cid.flatMap(Self.photo(forCid:)))
        present(next)
        armHide()
    }

    /// ⛔ THE NUDGE (owner 2026-10-23, his screenshot): someone in a call link wants me in. A dark
    /// capsule: their face, "👋 NAME wants to talk", a white "🔊 Join" pill. Join (or a tap anywhere)
    /// opens the call's invitation, not the call itself.
    @MainActor
    func showNudge(_ n: LinkNudge) {
        let next = Item(cid: nil, title: n.callerName, body: "wants to talk", photoUrl: n.photoUrl, nudge: n)
        present(next)
        armHide()
    }

    @MainActor private func armHide() {
        hideTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    /// 2026-09-24 fix-all #223: the clock used to keep running under a finger, so a banner being
    /// dragged could slide away mid-gesture. A drag holds it; a drag that lets it snap back home
    /// starts a fresh clock.
    @MainActor func holdWhileDragging() { hideTask?.cancel(); hideTask = nil }
    @MainActor func releaseAfterDrag() {
        guard item != nil, hideTask == nil else { return }
        armHide()
    }

    @MainActor
    func dismiss() {
        hideTask?.cancel(); hideTask = nil
        leaveAll()
    }

    /// The sender's photo out of the chat list we already hold: the group's photo for a group, the
    /// other person's for a 1:1. Nothing is fetched here — a miss just falls back to the coloured
    /// initial, the same as every other avatar in the app.
    /// ⛔ THE REAL MESSAGE, DECRYPTED ON THIS PHONE — owner, 2026-09-26: the banner only ever said
    /// "New message". The push cannot carry the words (the server never has them), so its body is
    /// that placeholder. The conversation is read FRESH rather than taken from the chat list: the
    /// push can land before the list's listener delivers the new message, and the list would then
    /// hand us the previous one. Nil = keep the push's own body (a marker we do not name, a key not
    /// ready, or no network).
    static func previewBody(cid: String) async -> String? {
        guard let snap = try? await FirestoreHub.db.collection("conversations").document(cid)
                .getDocument(source: .server),
              let d = snap.data(), let raw = d["lastMessage"] as? String, !raw.isEmpty else { return nil }
        if raw.hasPrefix("📷") { return "Photo" }
        if raw.hasPrefix("🎥") || raw.hasPrefix("🎬") { return "Video" }
        if raw.hasPrefix("🎤") { return "Voice message" }
        if raw.hasPrefix("📄") { return "File" }
        let sender = d["lastSender"] as? String ?? ""
        // A 1:1 id is the two uids joined by "_"; a group id is not (the rule `setReaction` uses).
        let text = cid.contains("_")
            ? Crypto.shared.decryptCached(raw, cid: cid)
            : Crypto.shared.decryptGroupCached(raw, cid: cid, authorId: sender)
        guard !text.isEmpty, text != "…", text != "🔒" else { return nil }
        return text
    }

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
    /// Set by the centre when a newer card replaces this one or it is dismissed: the exit springs run.
    var leaving = false
    /// False for the first frame, so the card is drawn at its starting pose and springs in from it.
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    ///
    /// 2026-09-24 fix-all #223: the island test was `>= 39`, which every notch phone (safe top 44
    /// to 50) also passes, so the notch branch below it could never run. Island phones report 54 or
    /// more, notch phones 44 to 50, so the island test is `>= 51` and the notch branch is live.
    ///
    /// ⛔ 2026-09-25 night, owner: "use the position the reference app uses". Re-read from its
    /// `NotificationItemContainerNode.updateLayout`: the numbers hang off the STATUS BAR's height,
    /// not the safe area's (on an island phone the safe area is 5-8pt taller than the status bar,
    /// which is how ours sat low). Island: status bar + 6. Status bar >= 44: 8 + 34 = 42. Status bar
    /// 39-43: 8 + 29 = 37. Shorter (a 20pt bar): 8. `safeTop` is only the fallback when UIKit has no
    /// status bar height to give.
    private func topInset(safeTop: CGFloat) -> CGFloat {
        let bar = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.statusBarManager?.statusBarFrame.height }
            .first(where: { $0 > 0 }) ?? safeTop
        if bar >= 51 { return bar + 6 }     // Dynamic Island
        if bar >= 44 { return 42 }          // notch
        if bar >= 39 { return 37 }
        return 8
    }

    var body: some View {
        GeometryReader { geo in
            card(safeTop: geo.safeAreaInsets.top)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        // The reader would otherwise take the whole screen and push the card's own frame with it.
        .frame(height: Self.cardHeight + 80)
        // ⛔ MEASURED FROM THE SCREEN'S TOP — owner, 2026-09-25 night, screenshot: the card sat a
        // whole bar too low, under the back button instead of over it. The overlay that mounts
        // this starts BELOW the safe area, so `geo.safeAreaInsets.top` read 0, `topInset` took its
        // "older phone" 37, and that 37 was added under the status bar. Ignoring the top edge puts
        // the reader at the screen's top and gives it the real safe area to measure.
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(!leaving)
        .onAppear { arrived = true }
    }

    // MARK: - The 13.1 motion

    /// ⛔ THE REFERENCE APP'S 13.1 BANNER MOTION (owner 2026-10-25: "copy both animations", read from
    /// their `NotificationItemContainerNode`). Replaces the 2026-10-16 slide-and-grow.
    ///
    /// The card drops in from just above the screen while it grows from 19% and comes into focus,
    /// and leaves the same way backwards. Three springs, one per property, each theirs as (damping
    /// ratio, response): scale x (0.69762, 0.728), scale y (0.62275, 0.48669), centre y (0.63333,
    /// 0.62832). SwiftUI's `.spring(response:dampingFraction:)` is the same spring theirs builds
    /// (stiffness (2π/response)², damping 2ζω), and like theirs a spring caught mid-flight carries on
    /// from where it is and how fast it is going, so an exit during the entry has no jump. The blur
    /// is 18 to 0 over 0.3s ease-in-out, theirs.
    ///
    /// Where the centre goes, from their numbers: it STARTS half a card above the screen's top edge
    /// (the card just out of sight), rests at the card's frame, and ENDS a whole card above the top.
    /// The x and y scales settle at different speeds, which is the slight stretch on arrival.
    private enum Phase: Equatable { case start, shown, gone }
    private var phase: Phase { leaving ? .gone : (arrived ? .shown : .start) }

    private func motion<V: View>(_ card: V, top: CGFloat) -> some View {
        let h = Self.cardHeight
        let rest = top + h / 2
        let p = phase
        let scale: CGFloat = p == .shown ? 1 : 0.19
        let centreY: CGFloat = p == .shown ? rest : (p == .start ? -h / 2 : -h)
        func spring(_ zeta: Double, _ response: Double) -> Animation? {
            reduceMotion ? nil : .spring(response: response, dampingFraction: zeta)
        }
        return card
            .scaleEffect(x: scale, y: 1)
            .animation(spring(0.69762, 0.728), value: p)
            .scaleEffect(x: 1, y: scale)
            .animation(spring(0.62275, 0.48669), value: p)
            .offset(y: centreY - rest)
            .animation(spring(0.63333, 0.62832), value: p)
            .blur(radius: p == .shown ? 0 : 18)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: p)
    }

    @ViewBuilder private func card(safeTop: CGFloat) -> some View {
        if let nudge = item.nudge {
            nudgeCard(nudge, safeTop: safeTop)
        } else {
            messageCard(safeTop: safeTop)
        }
    }

    /// The nudge capsule: dark in both themes, as his reference draws it.
    private func nudgeCard(_ n: LinkNudge, safeTop: CGFloat) -> some View {
        let top = topInset(safeTop: safeTop)
        return motion(HStack(spacing: 10) {
            AvatarView(name: n.callerName, photoUrl: n.photoUrl, size: 40)
            Text("👋 \(n.callerName) wants to talk")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button { open() } label: {
                Text("🔊 Join")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Join the call")
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(Color(white: 0.11)))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, Self.sideInset), top: top)
        .padding(.top, top)
        .offset(y: rubberBanded(dragY))
        .contentShape(Capsule())
        .gesture(dragGesture)
        .onTapGesture { open() }
        .accessibilityElement(children: .contain)
    }

    private func messageCard(safeTop: CGFloat) -> some View {
        let top = topInset(safeTop: safeTop)
        return motion(HStack(spacing: Self.avatarToText) {
            if let cid = item.cid, OfficialChannel.isOfficial(cid) {
                OfficialAvatar(size: Self.avatar)
            } else {
                AvatarView(name: item.title, photoUrl: item.photoUrl, size: Self.avatar)
            }
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
        // 2026-10-18 (owner, build 973: "the banner has no liquid glass effects"): INTERACTIVE glass,
        // the system's own touch response, the light that follows the finger and the flex under a
        // press, which the plain regular glass does not draw. Taps and the drag are unchanged.
        .liquidGlass(RoundedRectangle(cornerRadius: Self.corner, style: .continuous), interactive: true)
        .padding(.horizontal, Self.sideInset), top: top)
        .padding(.top, top)
        .offset(y: rubberBanded(dragY))
        .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .gesture(dragGesture)
        .onTapGesture { open() }
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
                center.holdWhileDragging()   // 2026-09-24 fix-all #223
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
                // The card is NOT put back first: like theirs (`freezeGestureBounds`), the exit
                // springs leave from wherever the finger let go, with no jump home.
                if rubberBanded(travel) > 20 || velocity > 300 {
                    open()
                    return
                }
                // ⛔ UP DISMISSES AT FIVE POINTS. Theirs commits on 5pt of travel or 200pt/s, where
                // ours asked for 28 — which is why swiping ours away felt like it needed a shove.
                if travel < -5 || velocity < -200 {
                    center.dismiss()
                    return
                }
                // Neither: home again on their own snap-back, 0.3s and the same curve.
                withAnimation(.easeInOut(duration: 0.3)) { dragY = 0 }
                center.releaseAfterDrag()   // 2026-09-24 fix-all #223
            }
    }

    private func open() {
        if let nudge = item.nudge {
            center.dismiss()
            GroupCallRinging.shared.openNudge(nudge)
            return
        }
        if let cid = item.cid { AppRouter.shared.pendingChatId = cid }
        center.dismiss()
    }
}

extension View {
    /// Mount once, at the root, above everything the app normally shows.
    func inAppBanner() -> some View {
        overlay(alignment: .top) {
            // Every card still on screen, the leaving one under the arriving one. The motion lives in
            // the card (`InAppBannerCard.motion`), so mounting and unmounting are not animated here:
            // a card is mounted at its starting pose and unmounted only once its exit has settled.
            ZStack(alignment: .top) {
                ForEach(InAppBannerCenter.shared.entries) { e in
                    InAppBannerCard(item: e.item, leaving: e.leaving)
                        .transition(.identity)
                }
            }
        }
    }
}

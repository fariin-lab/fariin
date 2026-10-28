import SwiftUI
import UIKit
import Combine

// ⛔ ONE FLOATING CARD SHELL FOR EVERY MINIMIZED CALL — owner 2026-10-28: the group call's small card
// "is full of lag" while the 1:1 card is smooth and can be tucked into the screen edge. The group card
// had its own, simpler drag (no tab, no pinch, no overshoot) on a view that also watched the whole
// group call service, so every publish during a call (speakers, levels, people) re-ran the view that
// was being dragged. This file is the 1:1 card's movement code moved out of `FloatingCallWindow`
// unchanged, so both cards drag, throw, snap to a side, tuck into the edge as a tab, pull back out
// and pinch between sizes the same way. Each card brings only its picture and its tap.
//
// The picture is frozen against the shell (`FrozenCardContent`): the drag's state re-runs the shell
// on every touch, never the picture, and the picture's own observation (CallService, or the group
// call's ObservableObjects inside its own view) redraws only the picture.

/// Where a minimized call's card sits, kept outside the view because the card view is destroyed on
/// every restore and rebuilt on every minimize (owner, 2026-08-23: it must land where it was left).
/// `CallService` holds the 1:1 card's (the properties already had these names); the group card has
/// its own `GroupFloatingCardSpot` (owner 2026-10-28: kept apart from the 1:1 call's for clarity, even
/// though the two kinds of call never run at once). Class-bound so the shell can write through a `let`.
protocol FloatingCardSpot: AnyObject {
    var cardOffset: CGSize { get set }
    var cardBase: CGSize { get set }
    var cardStashed: Bool { get set }
    var cardScale: CGFloat { get set }
}

extension CallService: FloatingCardSpot {}

/// The group call card's place (owner 2026-10-28). Same meaning as CallService's card fields: the
/// settled position from the top-right home, whether it is tucked into the edge as a tab, and the
/// pinch size step. Cleared when the group call ends (`GroupCallService.resetRoomState`), except the
/// size, which lasts for the life of the app as the 1:1 card's does.
@Observable
final class GroupFloatingCardSpot: FloatingCardSpot {
    static let shared = GroupFloatingCardSpot()
    var cardOffset = CGSize.zero
    var cardBase = CGSize.zero
    var cardStashed = false
    var cardScale: CGFloat = 1

    func reset() {
        cardOffset = .zero; cardBase = .zero; cardStashed = false
    }
}

/// The shell's constants. Outside the generic shell because a generic type cannot hold static stored
/// properties.
enum FloatingCardMetrics {
    /// ⛔ PINCH TO RESIZE, AS APPLE'S OWN FLOATING WINDOW DOES — owner, 2026-10-14: keep this card and
    /// its design, make it behave like the system's picture-in-picture window. Three sizes, the
    /// middle one the card he chose (112x199); a pinch scales it live and lets go onto the nearest.
    static let sizeSteps: [CGFloat] = [0.8, 1.0, 1.35]
    static let morphID = "call.card.morph"
    static let keyboardFrames = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillChangeFrameNotification)
}

/// A clear UIView that takes the touch, so nothing underneath (a list's pans) sees it. SwiftUI
/// gestures on it still run: they are recognisers on the hosting view, an ancestor of this one.
private struct TouchShield: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// A view whose parent can never make it re-run: `==` is always true, so SwiftUI skips its body on
/// a parent update and runs it only when something its OWN body read (an @Observable property)
/// changes. For content that must stay still while its container moves under a finger.
private struct FrozenCardContent<Content: View>: View, Equatable {
    let content: () -> Content
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    var body: some View { content() }
}

/// The minimized call's floating card: drag, throw, side snap, tab in the edge, pinch, and the
/// minimize/restore flight's frame. `card` is the finished card (picture, corner, border, shadow);
/// `picture` is the bare picture at card size, which the tab blurs while the card waits off screen.
/// Both read the card size from `spot.cardScale` themselves (112x199 times the step).
struct FloatingCardShell<Spot: FloatingCardSpot, Card: View, Picture: View>: View {
    private let spot: Spot
    private let onTap: () -> Void
    private let card: () -> Card
    private let picture: () -> Picture
    /// The group card's keyboard rule (owner, 2026-10-06): a card the keyboard would cover moves up
    /// above it and goes back when the keyboard leaves. The 1:1 card never had it and is unchanged:
    /// with this off `keyboardTop` stays nil and every limit is the 1:1 card's own.
    private let avoidsKeyboard: Bool

    private var call: CallService { CallService.shared }
    // NOT @State. See CallService.cardOffset: this view dies on every restore, and @State handed the
    // card back to the bottom-right corner each time instead of leaving it where it was dropped.
    private var offset: CGSize {
        get { spot.cardOffset } nonmutating set { spot.cardOffset = newValue }
    }
    private var base: CGSize {
        get { spot.cardBase } nonmutating set { spot.cardBase = newValue }
    }

    private var w: CGFloat { 112 * spot.cardScale }
    private var h: CGFloat { 199 * spot.cardScale }   // 9:16
    /// The live pinch, as a transform (like `dragLive`); folded into `cardScale` when the fingers lift.
    @State private var pinchLive: CGFloat = 1

    // Hiding it to the side.
    private let overshoot: CGFloat = 70   // how far past the edge a drag is allowed to pull it
    private let stashAt: CGFloat = 42     // let go beyond this and it parks as a tab
    /// ⛔ APPLE'S OWN STASH TAB'S SIZE — owner, 2026-10-14: "exactly copy size the native one".
    /// Measured from his two screenshots, same phone: the system tab is 66x264 px, ours (32pt wide)
    /// was 88 px wide, so 2.75 px/pt (a 430pt-wide screen) and the system tab is 24 x 96 pt with
    /// ~12pt inner corners. Was 32 x 120 (then 88 tall for one unshipped commit).
    private let tabW: CGFloat = 24
    private let tabH: CGFloat = 96
    private let pullBack: CGFloat = 22    // pulled at least this far → the card comes back
    private let pullMax: CGFloat = 34     // how far the tab itself moves inward before it goes stiff

    /// Live drag on the tab, as a transform. Transient by design: it is either mid-gesture or zero,
    /// and it must not survive the tab turning back into a card.
    @State private var tabDrag: CGSize = .zero
    /// How far the card has been pulled out of its tab, inward, in points (0 = just the tab).
    @State private var pull: CGFloat = 0

    /// The card's live drag, as a TRANSFORM. Zero except while a finger is down — see the drag's
    /// `onChanged` for why the settled position and the moving one are kept apart.
    @State private var dragLive: CGSize = .zero

    /// The call screen's zoom partner: the screen shrinks into this card and grows back out of it.
    /// Nil is a working configuration (the zoom falls back to a plain presentation).
    @Environment(\.callZoomNamespace) private var zoomNamespace

    @ViewBuilder private func zoomAnchored(_ content: some View) -> some View {
        if let zoomNamespace {
            content.matchedTransitionSource(id: CallZoomSource.card, in: zoomNamespace)
        } else {
            content
        }
    }

    /// Ties the card and the tab together as one shape for the morph.
    @Namespace private var morph
    private static var morphID: String { FloatingCardMetrics.morphID }

    /// The docked keyboard's top edge in screen points, nil while it is down (or `avoidsKeyboard` off).
    @State private var keyboardTop: CGFloat?
    /// Where the card rested before the keyboard pushed it up, so it can go back. nil = not pushed.
    @State private var beforeKeyboard: CGFloat?

    // ⚠️ `base` IS THE ANCHOR AND MUST NOT MOVE MID-DRAG, on the card or the tab. Every gesture
    // update reports the translation from where the finger went DOWN; the live movement is a
    // transform (`dragLive`, `tabDrag`) and `base` is only committed when the finger lifts.

    /// ⛔ CACHED, BECAUSE THIS IS READ FROM `body`. It walks every connected scene and every window
    /// to find the notch, and `body` re-runs on every frame of a drag — sixty scene-graph walks a
    /// second, for a number that cannot change while a call is on screen. Resolved once when the
    /// card appears and read from memory after that.
    @State private var insetsCache: UIEdgeInsets

    private var insets: UIEdgeInsets { insetsCache }

    /// Owner audit 2026-10-06 #43: resolved HERE, before the first layout, not in `onAppear`. Starting
    /// from `.zero` laid the card out once under the notch (y = 8) and only then moved it down, and the
    /// minimize flight, which reads the card's frame 30ms after the cover goes, could land on that
    /// first position and see the real card appear 59pt lower. This view is rebuilt on every
    /// minimize, so that was every minimize, not just the first.
    init(spot: Spot, avoidsKeyboard: Bool = false, onTap: @escaping () -> Void,
         @ViewBuilder card: @escaping () -> Card, @ViewBuilder picture: @escaping () -> Picture) {
        self.spot = spot
        self.avoidsKeyboard = avoidsKeyboard
        self.onTap = onTap
        self.card = card
        self.picture = picture
        _insetsCache = State(initialValue: Self.resolveInsets())
    }

    private static func resolveInsets() -> UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .max(by: { $0.top < $1.top }) ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            if spot.cardStashed {
                // ⛔ APPLE'S OWN PULL-OUT — owner 2026-10-14, seven frames of the system's floating
                // window: "exactly like this animation, make sure 3 times, also wrong blur". The tab is
                // not a separate badge. It is a HANDLE on the edge of the card itself, and the card waits
                // just off screen, its own picture heavily blurred (the old tab painted a zoomed, blurred
                // profile photo instead: the wrong blur). Pulled, the whole card slides out under the
                // finger with the handle leading on its edge; the handle sinks into the card once about a
                // third is out; the blur clears as it comes and is gone where it settles. One view,
                // `stashedCard`, draws every stage, so the tab at rest and the card coming out can never
                // jump between two different looks.
                ZStack(alignment: stashedLeft ? .topLeading : .topTrailing) {
                    stashedCard(pull: pull)
                        .offset(x: (stashedLeft ? pull - w : w - pull) + tabDrag.width, y: tabDrag.height)
                        .allowsHitTesting(false)
                    // What a finger can hold: the handle at rest, the whole card once it is coming out.
                    // Only this is touchable, so the hidden card never covers the list behind it.
                    // ⛔ A REAL UIView UNDER THE FINGER (owner 2026-10-14: on the RIGHT edge the arrow
                    // did not follow, on the left it did). A plain `Color.clear` is not a UIView, so the
                    // touch hit-tested through it to the chat list behind, and the list's own pans got
                    // it too. Pulling the right-hand tab is a drag to the LEFT, which is the list's
                    // swipe-to-reply direction, so the list won and the tab never moved; the left-hand
                    // tab drags right, which nothing behind claims. With a view here the touch belongs
                    // to the tab alone, on both sides.
                    TouchShield()
                        .frame(width: tabW + max(0, pull), height: pull > 0 ? h : tabH)
                        .contentShape(Rectangle())
                        .offset(y: (pull > 0 ? 0 : (h - tabH) / 2) + tabDrag.height)
                        // ⛔ MEASURED ON THE SCREEN, NOT ON THIS VIEW — owner 2026-10-15, second report:
                        // "on the right it does not follow my finger, on the left it does". This view
                        // WIDENS as the card comes out (`tabW + pull`). On the left it grows rightward
                        // and its leading edge, the drag's local origin, stays put; on the right it
                        // grows leftward, so the origin ran away with the finger and each update saw
                        // less movement than the finger made. In global space nothing the drag moves
                        // can move its own reference, on either side.
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { v in
                                    let (_, maxDown) = limits(geo.size)
                                    let y = rubberBand(base.height + v.translation.height, max: maxDown) - base.height
                                    let inward = stashedLeft ? v.translation.width : -v.translation.width
                                    // Inward: the card follows 1:1 the whole way, out of the edge and on
                                    // across the screen (owner 2026-10-14: once it is out he wants to move it
                                    // left and right without lifting the finger first). It stiffens only
                                    // past the far side, where a normal drag stops too.
                                    let across = geo.size.width - 12
                                    pull = inward > 0 ? (inward <= across ? inward : across + rubber(inward - across, 20)) : 0
                                    // Outward has nowhere to go: a little give on the handle, not a second exit.
                                    let give = inward < 0 ? -rubber(-inward, 30) : 0
                                    tabDrag = CGSize(width: stashedLeft ? give : -give, height: y)
                                }
                                .onEnded { v in
                                    let (_, maxDown) = limits(geo.size)
                                    let inward = stashedLeft ? v.translation.width : -v.translation.width
                                    let inwardSpeed = stashedLeft ? v.velocity.width : -v.velocity.width
                                    beforeKeyboard = nil   // moved by hand, as on the card
                                    let y = min(maxDown, max(0, base.height + tabDrag.height))
                                    // Height is committed where the finger left it, without a jump.
                                    var t = Transaction(); t.disablesAnimations = true
                                    withTransaction(t) {
                                        tabDrag = CGSize(width: tabDrag.width, height: base.height + tabDrag.height - y)
                                        base = CGSize(width: base.width, height: y)
                                        offset = base
                                    }
                                    // Carried past where it rests (12pt in): it is a card being dragged now.
                                    // It becomes the real card at exactly that spot and lands like any
                                    // card drag, on the side the throw is heading for, at this height.
                                    if pull > w + 12 {
                                        let (maxLeft, _) = limits(geo.size)
                                        let beyond = pull - (w + 12)
                                        let xNow = stashedLeft ? maxLeft + beyond : -beyond
                                        let thrownX = xNow + v.predictedEndTranslation.width - v.translation.width
                                        let x: CGFloat = thrownX < maxLeft / 2 ? maxLeft : 0
                                        let stretch = tabDrag.height
                                        withTransaction(t) {
                                            base = CGSize(width: xNow, height: y)
                                            offset = base
                                            dragLive = CGSize(width: 0, height: stretch)
                                            pull = 0
                                            tabDrag = .zero
                                            spot.cardStashed = false
                                        }
                                        DispatchQueue.main.async {
                                            withAnimation(landingSpring(from: CGSize(width: xNow, height: y + stretch),
                                                                        to: CGSize(width: x, height: y),
                                                                        velocity: v.velocity)) {
                                                base = CGSize(width: x, height: y)
                                                offset = base
                                                dragLive = .zero
                                            }
                                        }
                                        return
                                    }
                                    guard inward >= w * 0.3 || inwardSpeed > 400 else {
                                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                            pull = 0
                                            tabDrag = .zero
                                        }
                                        return
                                    }
                                    bringOut(geo.size)
                                }
                        )
                        .onTapGesture { bringOut(geo.size) }
                        .accessibilityElement()
                        .accessibilityLabel("Back to the call")
                        .accessibilityAddTraits(.isButton)
                }
                .padding(.top, insets.top + 8 + min(base.height, max(0, limits(geo.size).1)))
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: stashedLeft ? .topLeading : .topTrailing)
            } else {
                // ⛔ THE TRANSFORM SITS ON `window`, INSIDE THE GESTURE, which is where the smooth
                // build had it. Hung on the outside it moves the very view the drag is measured on,
                // so the finger's own reference frame travels with the card.
                // ⛔ THE CARD'S INSIDES ARE NOT REBUILT BY THE DRAG — owner 2026-10-13: "the window
                // follows my finger but feels laggy". `dragLive` is this view's @State, so every touch
                // re-ran this whole body, and `window` with it: the video renderers, the avatars, the
                // palette lookup and `pipFeeds`, 60-120 times a second, to move a transform. The card
                // is wrapped so a parent update never re-runs it (`FrozenCardContent`, always equal);
                // it still redraws on its own when what it reads from `call` changes, because the
                // Observation tracking belongs to the wrapper's own body.
                morphAnchored(zoomAnchored(FrozenCardContent { card() }.equatable()
                    // Where the minimize/restore flight lands and starts (`CallPipMorph`). At rest
                    // `dragLive` is zero, which is the only time a flight reads it.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { call.cardFrame = $0 }
                    .onDisappear { call.cardFrame = .zero }
                    .opacity(call.cardHiddenForMorph ? 0 : 1)
                    .offset(dragLive)
                    // The live pinch grows the card from the corner nearest its edge, as the system's does.
                    .scaleEffect(pinchLive, anchor: onLeft(geo.size) ? .topLeading : .topTrailing)))
                    // Plain gesture, not high-priority: the end button inside the window must still get
                    // its own taps.
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                let (maxLeft, maxDown) = limits(geo.size)
                                // Deliberately allowed PAST the edge by `overshoot`. The card sliding
                                // partly off is the only warning that letting go will hide it — clamped
                                // dead at the edge, hiding would happen out of nowhere.
                                // Past the top or bottom it stretches with resistance instead of
                                // stopping dead, the way the system's window does (2026-10-14).
                                let target = CGSize(
                                    width: min(overshoot, max(maxLeft - overshoot, base.width + v.translation.width)),
                                    height: rubberBand(base.height + v.translation.height, max: maxDown)
                                )
                                // ⛔ THE LIVE DRAG IS A TRANSFORM, NOT LAYOUT, and that is the whole
                                // reason this variable exists (owner, 2026-08-23: "when i drag and
                                // moving the small card it makes shaking, looks something blocks").
                                //
                                // My own regression. Moving the card with PADDING fixed the zoom —
                                // padding is real geometry, so the transition finally knew where the
                                // card was — but padding is also a full LAYOUT PASS, and I was
                                // running one per touch event. Sixty relayouts a second of a view
                                // sitting over the whole screen is the stutter he is feeling.
                                //
                                // Both, then, each where it belongs: the settled position stays
                                // padding, so the frame is honest at rest, which is the ONLY moment a
                                // zoom or a morph ever reads it. The finger moves a transform, which
                                // costs nothing and cannot stutter. On release the transform folds
                                // back into the padding and returns to zero.
                                dragLive = CGSize(width: target.width - base.width,
                                                  height: target.height - base.height)
                            }
                            .onEnded { v in
                                let (maxLeft, maxDown) = limits(geo.size)
                                // Moved by hand: this is its place now, the keyboard has nothing to put
                                // back (group card; always nil on the 1:1 card).
                                beforeKeyboard = nil
                                // ⛔ ONLY THE SIDE SNAPS. Height stays exactly where the finger left
                                // it (owner, 2026-08-23: "only i can drag top left or top right,
                                // bottom left, no middle right or left"). Snapping y as well pinned
                                // the card to four corners, so it could never sit beside the row you
                                // were actually reading — you had to choose between covering the top
                                // of the list or the bottom of it. Apple's own picture-in-picture and
                                // the reference app both do it this way: the edge is decided for you
                                // because a card floating in open space is just in the way; the
                                // height is yours because only you know what is underneath it.
                                // ⛔ WHERE THE THROW WAS GOING, not where the finger stopped. Read
                                // out of the reference implementation's own edge-deceleration: they take
                                // the pan velocity, ignore anything under a threshold so a slow
                                // release is not a throw at all, project where that speed would
                                // carry the view, and land it on the nearest side at whatever height
                                // the projection reached.
                                //
                                // `predictedEndTranslation` is SwiftUI's version of that same
                                // projection, so a flick up-and-left lands top-left and a careful
                                // drop stays exactly where it was let go. Without it the card simply
                                // stopped dead under the finger, which is what makes a floating
                                // window feel stuck to the glass rather than thrown.
                                let thrown = CGSize(
                                    width: base.width + v.predictedEndTranslation.width,
                                    height: base.height + v.predictedEndTranslation.height
                                )
                                // The finger's real last position still decides the STASH, so shoving
                                // it off the side stays a deliberate push rather than something a
                                // fast flick can trigger by accident.
                                let ended = CGSize(width: base.width + dragLive.width,
                                                   height: base.height + dragLive.height)
                                let y = min(maxDown, max(0, thrown.height))
                                // Shoved far enough past a side → park it there as a tab.
                                // 2026-10-14: or THROWN hard off the side it already sits on, as the
                                // system's window parks on a flick. A throw across the screen still
                                // lands on the other side; only a flick outward parks.
                                let startedRight = base.width > maxLeft / 2
                                let flickRight = startedRight && v.velocity.width > 1200 && thrown.width > w * 0.6
                                let flickLeft = !startedRight && v.velocity.width < -1200 && thrown.width < maxLeft - w * 0.6
                                if ended.width > stashAt || ended.width < maxLeft - stashAt || flickRight || flickLeft {
                                    let x: CGFloat = (ended.width > stashAt || flickRight) ? 0 : maxLeft
                                    // ⛔ HIDING IS THE PULL-OUT RUN BACKWARDS (owner 2026-10-14). The card
                                    // becomes the hidden card at exactly the spot it is on screen (its
                                    // visible extent becomes `pull`, its height offset `tabDrag`), with no
                                    // animation, and then slides into its handle, blurring as it goes. The
                                    // drag is a transform, so the layout frame was still at the spot the
                                    // drag started from: morphing from it flew the tab across the screen.
                                    let toLeft = x < 0
                                    let startPull = max(0, toLeft ? geo.size.width - 12 + ended.width : 12 + w - ended.width)
                                    var t = Transaction(); t.disablesAnimations = true
                                    withTransaction(t) {
                                        base = CGSize(width: x, height: y)
                                        offset = base
                                        dragLive = .zero
                                        pull = startPull
                                        tabDrag = CGSize(width: 0, height: ended.height - y)
                                        spot.cardStashed = true
                                    }
                                    DispatchQueue.main.async {
                                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                            pull = 0
                                            tabDrag = .zero
                                        }
                                    }
                                    return
                                }
                                let x: CGFloat = thrown.width < maxLeft / 2 ? maxLeft : 0
                                // 2026-10-14: the landing carries the flick's own speed, as the
                                // system's window does, instead of every landing starting from rest.
                                withAnimation(landingSpring(from: ended, to: CGSize(width: x, height: y), velocity: v.velocity)) {
                                    base = CGSize(width: x, height: y)
                                    offset = base
                                    dragLive = .zero
                                }
                            }
                    )
                    // The card's own tap: back to its call (each card guards a call that is over).
                    .onTapGesture { onTap() }
                    // ⛔ THE PINCH GOES ON AFTER THE DRAG — owner 2026-10-14: "it does not follow my
                    // finger, it only moves there after I lift". Attached before the drag, the pinch
                    // sat closer to the card, and an outer `.gesture` waits for the gestures inside it
                    // to fail. A one-finger pinch never fails until the finger lifts, so the drag got
                    // no `onChanged` at all and only its `onEnded` moved the card. Out here it is
                    // simultaneous with the drag and blocks nothing.
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in pinchLive = rubberScale(v.magnification) }
                            .onEnded { _ in settlePinch(geo.size) }
                    )
                    // ⛔ PADDING, NOT `.offset`, AND THAT IS THE WHOLE POINT (owner, 2026-08-23: he
                    // dragged the card to the bottom-left, reopened the call, and the zoom still flew
                    // to the top-right corner — "we hard code on top only").
                    //
                    // It was not hardcoded, and the card did land back where he left it. `.offset` is
                    // a DRAW-TIME transform: it moves pixels and leaves the view's LAYOUT frame where
                    // it always was, up in the corner. Both transitions read that layout frame —
                    // matchedTransitionSource for the call screen's zoom, matchedGeometryEffect for
                    // the morph into the tab — so both of them animated to a corner the card had not
                    // occupied since the first drag. The card was right and the flight was wrong.
                    //
                    // Expressed as padding the position is real geometry, so the zoom lands on the
                    // card wherever it actually sits. `offset.width` is zero at the right edge and
                    // negative to the left of it, hence the subtraction; it can also go briefly
                    // POSITIVE while a drag pushes the card past the edge, and negative padding is
                    // exactly the right answer there.
                    //
                    // TOP-RIGHT is only the resting HOME (his 2026-08-23 rule: "most land top right,
                    // that's standard"), which is what zero offset means. The self-tile inside the
                    // call screen still lives bottom-right under his 2026-08-12 rule and has not moved.
                    // The finger's transform is on `window` above; only the settled position is here.
                    .padding(.top, insets.top + 8 + base.height)     // the settled position: real layout
                    .padding(.trailing, 12 - base.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: spot.cardStashed)
        // Resolved once. See `insetsCache` for why this is not read live from `body`.
        .onAppear { insetsCache = Self.resolveInsets() }
        // The group card's keyboard rule; returns at once for the 1:1 card (`avoidsKeyboard` off).
        .onReceive(FloatingCardMetrics.keyboardFrames) { note in keyboardMoved(note) }
    }

    // MARK: Keyboard (the group card's, owner 2026-10-06; moved here 2026-10-28)

    /// The lowest `base.height` whose card still ends 8pt above `top`.
    private func lowestRest(above top: CGFloat) -> CGFloat {
        max(0, top - 8 - h - (insets.top + 8))
    }

    /// The reference app's rule: a card the keyboard would cover moves up to sit just above it, and
    /// returns to where it was once the keyboard is out of the way. A card that was never covered
    /// does not move. Screen height, not the GeometryReader's: the shell ignores the safe area and
    /// fills the window, so the two are the same, and the notification arrives outside `geo`.
    private func keyboardMoved(_ note: Notification) {
        guard avoidsKeyboard,
              let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let seconds = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let screenH = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.height }
            .max() ?? end.maxY
        // Down, or not docked to the bottom edge (floating on an iPad): it covers nothing here.
        let docked = end.height > 0 && end.minY < screenH && end.maxY >= screenH - 1
        let top: CGFloat? = docked ? end.minY : nil
        keyboardTop = top
        let wanted = beforeKeyboard ?? base.height
        var target = wanted
        var pushedFrom: CGFloat?
        if let top {
            let lowest = lowestRest(above: top)
            if wanted > lowest {
                target = lowest
                pushedFrom = wanted
            }
        }
        beforeKeyboard = pushedFrom
        guard target != base.height else { return }
        withAnimation(.easeOut(duration: max(0.1, seconds))) {
            base = CGSize(width: base.width, height: target)
            offset = base
        }
    }

    /// Which side it was parked on. `cardBase.width` is 0 at the right edge and negative anywhere
    /// left of it, so the drag has already recorded this and there is no second flag to keep in step.
    private var stashedLeft: Bool { base.width < 0 }

    /// THE HIDDEN CARD AND ITS HANDLE, as one piece, for every stage from tab to card (owner
    /// 2026-10-14, the system window's own frames). `pull` is how far the card is out of the edge, in
    /// points: 0 shows only the handle; `w + 12` is the card at rest, 12pt in from the edge.
    ///
    /// The picture is the card's own (`picture`), blurred hard while it is mostly hidden and
    /// clearing as it comes out. The handle shows the same blurred picture: the picture is stretched
    /// sideways by the handle's width, which cannot be seen under this much blur, and cut to the card
    /// plus the handle. The handle rides the card's edge until about a fifth of the card is out, then
    /// sinks into it, chevron and all.
    private func stashedCard(pull: CGFloat) -> some View {
        let p = max(0, min(1, pull / w))
        let blur = 28 * (1 - p * p)
        let handle = max(0, min(1, 1 - (pull - w * 0.2) / (w * 0.15)))
        let reach = tabW * handle                 // how far the handle sticks out past the card's edge
        let edge: Alignment = stashedLeft ? .trailing : .leading
        let tongue = UnevenRoundedRectangle(
            topLeadingRadius: stashedLeft ? 0 : 12, bottomLeadingRadius: stashedLeft ? 0 : 12,
            bottomTrailingRadius: stashedLeft ? 12 : 0, topTrailingRadius: stashedLeft ? 12 : 0,
            style: .continuous)
        // DARK FROSTED GLASS, not a blur of the picture (owner 2026-10-14: the hidden card showed
        // as a flat WHITE slab). A blur filter on the live call picture does not reach a video layer
        // drawn by UIKit, so what came out was a bright empty shape. A dark material samples whatever
        // is under it, picture or not, and it fades out as the card comes out of the edge.
        return FrozenCardContent { picture() }.equatable()
            .overlay {
                Rectangle().fill(.regularMaterial)
                    .overlay(Color.black.opacity(0.25))
                    .environment(\.colorScheme, .dark)
                    .opacity(blur / 28)
            }
            .scaleEffect(x: (w + reach) / w, y: 1, anchor: stashedLeft ? .leading : .trailing)
            .mask(alignment: edge) {
                ZStack(alignment: edge) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .frame(width: w, height: h)
                    // Starts 20pt inside the card so the join has no gap; sticks out by `reach`.
                    tongue
                        .frame(width: tabW + 20, height: tabH)
                        .offset(x: stashedLeft ? reach : -reach)
                }
            }
            .overlay(alignment: edge) {
                Image(systemName: stashedLeft ? "chevron.compact.right" : "chevron.compact.left")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: tabW, height: tabH)
                    .offset(x: stashedLeft ? reach : -reach)
                    .opacity(handle)
            }
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    /// Out of the edge to where the card rests (12pt in), then the hidden card hands over to the real
    /// one at exactly that spot, so nothing jumps and the blur has already cleared on the way.
    private func bringOut(_ size: CGSize) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            pull = w + 12
            tabDrag = .zero
        } completion: {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                pull = 0
                tabDrag = .zero
                dragLive = .zero
                spot.cardStashed = false
            }
        }
    }

    /// ⛔ ALWAYS ATTACHED. IT IS NOT WHAT SHOOK THE CARD, AND SWITCHING IT OFF MID-DRAG IS WHAT
    /// BROKE IT A THIRD TIME (owner, 2026-08-25: "it won't follow smoothly, something is fighting").
    ///
    /// The blame was reasonable and wrong. `matchedGeometryEffect` re-resolves on every LAYOUT pass,
    /// so it can only argue with a drag that is moving LAYOUT — which this one did while the
    /// position was padding, and has not since the finger was moved onto a transform. In the build
    /// he called smooth this modifier was attached the whole time, over exactly the same stable
    /// layout, and there was nothing to argue with.
    ///
    /// What replaced it cost far more than it saved: `if dragging` is a STRUCTURAL branch, so the
    /// card's whole subtree is torn down and rebuilt at the moment the finger starts moving, and
    /// again when it lifts. A live gesture whose view is replaced under it is the hitch he is
    /// describing. Anything that needs switching off mid-drag has to be switched off WITHOUT
    /// changing the shape of the tree.
    private func morphAnchored(_ content: some View) -> some View {
        content.matchedGeometryEffect(id: Self.morphID, in: morph)
    }

    // How far the card may travel from its top-right home: LEFT as negative x, DOWN as positive y.
    // The bottom stop still allows for the tab pill, so dragging it down parks it above the tabs
    // rather than behind them.
    private func limits(_ size: CGSize) -> (CGFloat, CGFloat) {
        let maxLeft = -(size.width - w - 24)
        var maxDown = max(0, size.height - h - (insets.top + 8) - (insets.bottom + 76))
        // With the keyboard up the card cannot be parked under it (group card only; nil otherwise).
        if let keyboardTop { maxDown = min(maxDown, lowestRest(above: keyboardTop)) }
        return (maxLeft, maxDown)
    }

    // MARK: Native-window feel (owner, 2026-10-14)

    private func onLeft(_ size: CGSize) -> Bool { base.width < limits(size).0 / 2 }

    /// UIScrollView's own rubber-band curve: the further past the stop, the less it gives.
    private func rubber(_ d: CGFloat, _ dim: CGFloat) -> CGFloat { (1 - 1 / (d * 0.55 / dim + 1)) * dim }

    private func rubberBand(_ y: CGFloat, max m: CGFloat) -> CGFloat {
        if y < 0 { return -rubber(-y, 120) }
        if y > m { return m + rubber(y - m, 120) }
        return y
    }

    /// The pinch, held between the smallest and largest step with a little give past either.
    private func rubberScale(_ g: CGFloat) -> CGFloat {
        let lo = FloatingCardMetrics.sizeSteps.first! / spot.cardScale, hi = FloatingCardMetrics.sizeSteps.last! / spot.cardScale
        if g < lo { return lo - rubber(lo - g, 0.15) }
        if g > hi { return hi + rubber(g - hi, 0.15) }
        return g
    }

    /// Fingers up: the nearest size step, kept against the same edge, never pushed past the bottom.
    private func settlePinch(_ size: CGSize) {
        let wanted = spot.cardScale * pinchLive
        let step = FloatingCardMetrics.sizeSteps.min { abs($0 - wanted) < abs($1 - wanted) } ?? 1
        let wasLeft = onLeft(size)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            spot.cardScale = step
            pinchLive = 1
            let (maxLeft, maxDown) = limits(size)   // read at the new size
            base = CGSize(width: wasLeft ? maxLeft : 0, height: min(base.height, maxDown))
            offset = base
        }
    }

    /// A spring that starts at the finger's speed toward where the card is landing.
    private func landingSpring(from: CGSize, to: CGSize, velocity: CGSize) -> Animation {
        let dx = to.width - from.width, dy = to.height - from.height
        let dist2 = dx * dx + dy * dy
        guard dist2 > 1 else { return .spring(response: 0.35, dampingFraction: 0.78) }
        let rel = (velocity.width * dx + velocity.height * dy) / dist2
        return .interpolatingSpring(mass: 1, stiffness: 322, damping: 28, initialVelocity: max(-10, min(10, rel)))
    }
}

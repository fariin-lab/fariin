//
//  SwiftUIView.swift
//
//
//  Created by Tolga İskender on 1.05.2022.
//

import SwiftUI
import AVKit

// Bottom-two-corners rounded rectangle (iOS 14 safe — UnevenRoundedRectangle is iOS 16+).
struct BottomRoundedShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        guard radius > 0 else { return Path(rect) }
        return Path(UIBezierPath(roundedRect: rect,
                                 byRoundingCorners: [.bottomLeft, .bottomRight],
                                 cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

/// Fades the caption out as the viewers sheet is pulled up, 1:1 with the finger.
///
/// WHY IT IS A MODIFIER WITH ITS OWN STATE, and not another `@State` on StoryDetailView beside
/// `chromeHidden`. The host writes the sheet's progress on every display-link tick, so this value
/// changes ~60 times a second; a `@State` up in `StoryDetailView` would re-evaluate that whole body
/// — the picture, the player, the bars — once per frame while the sheet is moving, which is exactly
/// the "the story must never re-render" rule the chrome fades were written around. A ViewModifier is
/// its own node in the view graph: `content` arrives already built by the parent, and a write here
/// re-runs nothing but the opacity.
///
/// The header and the top scrim still flip on a boolean (`storyChromeHidden`) because they leave in
/// one step and nobody has asked for anything else. The caption is the one the owner watched track
/// the drag.
private struct SheetCaptionFade: ViewModifier {
    /// The pull is over well before the sheet is: the card is a third of the way into the slot by
    /// then, and text that keeps drawing while it shrinks is what read as "still there".
    private static let goneAt: CGFloat = 0.32

    @State private var progress: CGFloat = 0
    /// ⚠️ THE FLOOR, and the reason this is not just the fade.
    ///
    /// His report: the caption and its shadow are hidden on a pull "most of the time", and sometimes
    /// they are still there behind the open sheet. A fade driven by a continuous value is only ever
    /// as correct as the last value it was told — and there are several ways for the last value to
    /// be stale. A cancelled drag skips its `.ended`, the spring can be killed mid-flight, and the
    /// sheet can arrive open by a path that never walked progress through the fade window at all.
    /// Every one of those leaves this modifier holding a number from before the pull.
    ///
    /// `storyChromeHidden` is the app's own answer to "is the sheet engaged", already posted for the
    /// header and the progress bars, and it is a BOOLEAN — it cannot be half-told. So the fade still
    /// draws the drag, and this guarantees the end state no matter how the drag got there.
    @State private var chromeHidden = false

    /// AND GONE FOR A FLIGHT TOO (his 2026-08-08: "when i scroll down to close story plz hide
    /// caption").
    ///
    /// The caption is drawn inside the card, so unlike the reply bar it shrinks with it and had no
    /// reason to leave — the card's own chrome staying put is another mainstream messenger's look and it is deliberate.
    /// But a caption is a paragraph of text, and a paragraph rendered at a third of its size over a
    /// picture the size of a row card is a smudge, not a caption. `storyFlightActive` is already
    /// the app's answer to "is the card in the air", posted on the FIRST frame of a pull (an exit
    /// hides the surround at once) and coming back over the last 18% of an arrival — so the caption
    /// now leaves with the reply bar and returns with it, which is one event instead of two.
    ///
    /// ⚠️ SEEDED, NOT ASSUMED FALSE. A page mounted DURING an open has already missed the post that
    /// hid the chrome — see `StoryCardMorph.flightChromeHidden`.
    @State private var flightActive = StoryCardMorph.flightChromeHidden
    /// The dismiss drag's own progress, per frame, so the caption fades on the way DOWN exactly as it
    /// does on the way up. See `opacity`.
    @State private var flightProgress: CGFloat = 0

    /// Linear, straight off the finger — but never visible once the chrome is down.
    ///
    /// ⚠️ THE SHRINK IS THE SOURCE OF TRUTH, NOT THE NOTIFICATION. `StoryCardMorph.sheetFraction` is
    /// written by the one call that actually shrinks the card into the viewers slot, so it describes
    /// what is ON SCREEN. `progress` is a message about what was requested, and the doc above lists
    /// three ways for it to arrive stale — every one of which ends with a caption still drawn over
    /// an open sheet, which is his report, four times now.
    ///
    /// So the fade takes the LARGER of the two. The notification still drives the redraw and still
    /// gives the smooth per-frame curve under a finger; the fraction guarantees the end state by
    /// construction. This is the reference app's `captionAlpha *= (1.0 - contentScaleFraction)` translated
    /// into a view that cannot be handed its alpha directly — same guarantee, same number, same
    /// reason it cannot be told a lie.
    /// ⚠️ `chromeHidden` IS NOT IN HERE ANY MORE, AND THAT IS HIS 2026-08-16 REPORT: "the caption and
    /// bottom shadow disappear too abruptly… make them gradually disappear as the story scrolls up."
    ///
    /// The ramp below was never running for a pull-up. `storyChromeHidden` is posted TRUE at the
    /// moment the swipe engages — `onSwipeUpChanged`'s `if !showViewers` branch, before the finger
    /// has moved a single point — because the header and the top scrim leave in one step and want
    /// telling at once. Reading that boolean here meant the caption was slammed to zero on frame one
    /// and the whole 32% fade underneath it was dead code. There was no gradual anything to see.
    ///
    /// A boolean cannot be half-told, which is exactly why it cannot describe a fade. The end state
    /// is still guaranteed, and by the better of the two sources: `StoryCardMorph.sheetFraction` is
    /// written by the one call that actually shrinks the card, so unlike a message about what was
    /// requested it describes what is ON SCREEN, and it is continuous — every path that ends with the
    /// sheet open ends with the card shrunk, so every one of them ends with this at zero.
    ///
    /// `chromeHidden` still resets the ramp when it goes false; see `onReceive` below.
    /// ⚠️ AND THE FLIGHT IS A FADE NOW, NOT A SWITCH — his 2026-08-18 report: pulling the sheet UP
    /// fades the caption and its shadow away "very well", swiping DOWN to close makes them
    /// "disappear one time". Two gestures that look the same to him, and only one had a continuous
    /// value behind it: the pull posts `storySheetProgress` every frame, while the dismiss posted the
    /// BOOLEAN `storyFlightActive` — and the line here read it and returned 0. One frame, no fade,
    /// which is the whole of what he is describing.
    ///
    /// `StoryCardMorph.flightFraction` is the twin of `sheetFraction`, written by the one call that
    /// moves a flight, so the dismiss fades off the finger through the same 32% window as the pull.
    /// An OPEN runs the same number backwards, 1 → 0, so the caption fades IN as the story arrives
    /// rather than appearing — which is what the note above always meant by "comes back over the last
    /// 18% of an arrival".
    ///
    /// `flightActive` stays as the floor for the one case a fraction cannot cover: a page that mounts
    /// mid-flight and has seen no frame of it yet. The next frame replaces it with a real number.
    private var opacity: Double {
        let flight = max(StoryCardMorph.shared.flightFraction, flightProgress)
        if flightActive, flight == 0 { return 0 }
        let shrink = max(progress, StoryCardMorph.shared.sheetFraction, flight)
        let t = min(1, max(0, shrink / Self.goneAt))
        return Double(1 - t)
    }

    func body(content: Content) -> some View {
        content
            // No `.animation` anywhere near this: the value is already continuous, so an animation
            // on top of a per-frame write only chases it a beat behind, and it stutters when the
            // release spring changes speed.
            .opacity(opacity)
            // A faded caption must stop being a tap target too. The sheet hands touches in the card
            // slot back to SwiftUI once it is open (the carousel band, progress > 0.95), and the
            // caption's expand tap sits in the bottom-left corner of exactly that slot — invisible,
            // and still swallowing taps meant for the card.
            .allowsHitTesting(opacity > 0.01)
            .onReceive(NotificationCenter.default.publisher(for: .init("storySheetProgress"))) { note in
                // NSNumber, because the host's CGFloat goes through NotificationCenter's `id`.
                let raw = (note.object as? NSNumber)?.doubleValue ?? 0
                let p = min(1, max(0, CGFloat(raw)))
                // Past the fade window there is nothing left to change; ignore the rest of the pull
                // rather than invalidating this node on every frame of it.
                guard p < Self.goneAt || progress < Self.goneAt else { return }
                progress = p
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("storyFlightProgress"))) { note in
                let raw = (note.object as? NSNumber)?.doubleValue ?? 0
                let p = min(1, max(0, CGFloat(raw)))
                // Same economy as the pull above: past the fade window there is nothing left to
                // change, so the rest of the flight does not invalidate this node.
                guard p < Self.goneAt || flightProgress < Self.goneAt else { return }
                flightProgress = p
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("storyChromeHidden"))) { note in
                let hidden = (note.object as? Bool) ?? false
                guard chromeHidden != hidden else { return }
                chromeHidden = hidden
                // Coming back means the sheet is down and the story is exposed again. Reset the
                // fade's own number with it, or a leftover progress from the pull that just ended
                // would hold the caption invisible until the next drag happened to overwrite it.
                if !hidden { progress = 0 }
            }
            // The card is in the air: the caption goes with the reply bar. See `flightActive`.
            .onReceive(NotificationCenter.default.publisher(for: .init("storyFlightActive"))) { note in
                let active = (note.object as? Bool) ?? false
                guard flightActive != active else { return }
                flightActive = active
                // Same reset as above, and for the same reason: a drag that was cancelled mid-fade
                // leaves a stale progress behind, and the flight's own end is a reliable moment to
                // clear it. The flight's own number goes too, for the same reason and by the same
                // rule the morph follows in `resetFlight`.
                if !active { progress = 0; flightProgress = 0 }
            }
    }
}

struct StoryDetailView: View {
    // MARK: Public Properties
    @ObservedObject var viewModel: StoryViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State var model: StoryUIModel
    @Binding var isPresented: Bool
    
    @State var timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()   // 20fps for a smooth bar
    @State var timerProgress: CGFloat = 0

    
    let userClosure: UserCompletionHandler?
    var onProfile: ((StoryUIUser) -> Void)?
    var onItemSeen: ((String) -> Void)?
    /// WHICH ITEM IS ON SCREEN — the ungated twin of `onItemSeen`, and NOT a receipt.
    ///
    /// `onItemSeen` means WATCHED, so it is withheld while a story is paused, held, folding,
    /// buffering or behind the keyboard, and for a view-once story it SPENDS the single view. That
    /// makes it the wrong thing to answer "what am I looking at" with, and the host was using it for
    /// exactly that: the "Uploading…" bar and the owner's view count both hang off it. The viewers
    /// sheet pauses the story for its whole life, so the answer could sit a page or more behind the
    /// picture — his 2026-08-10 reports, both of them: an eighteen-hour-old story wearing the
    /// "Uploading…" bar, and the view count arriving late.
    ///
    /// This fires on the item CHANGING and nothing else, which is the same edge the lookahead
    /// already uses (see `startProgress`) and the same separation the reference app draws: `markAsSeen` waits
    /// for real playback, while the reference implementation reports the current item
    /// immediately. Two questions, two answers.
    var onItemChanged: ((String) -> Void)?
    var showMore: Bool = false   // show the header "…" dropdown menu (buttons post notifications to the host)
    /// THE OWNER'S BAR, DRAWN INSIDE MY OWN PAGE — his 2026-08-14 order: "view and trash most be
    /// follow my owner story dont leave".
    ///
    /// It was drawn by the SCREEN, in a stack below the pager, and that is why it could not travel:
    /// the cube turns PAGES, and a sibling of the pager is not one. Swipe from my story to a
    /// friend's and the Views and trash sat flat at the bottom while the story folded away above
    /// them, which is his screenshot. A friend's reply bar never had this problem because it has
    /// always been part of the page — `footerH` below is the room it asks for. This is the same slot,
    /// for the same reason, for my own story.
    ///
    /// ⚠️ IT MUST BE A VIEW THAT WATCHES SOMETHING LIVE. A page is built once and cached, so anything
    /// this closure captured at build time is frozen at build time. The app's bar reads a shared
    /// observable instead, which is what keeps the count and the faces current in a page nobody
    /// rebuilds.
    var ownerBar: ((String) -> AnyView)?
    /// How much room to leave for it. One number from the app, so the card's height and the bar's
    /// height cannot disagree.
    var ownerBarHeight: CGFloat = 0
    var isDismissing: Bool = false   // true while swiping down to close → cube fold off (no skew)
    @State private var lastSeenItem: String = ""
    /// The item `onItemChanged` last reported. Its own latch, not shared with `lastPrefetchItem`
    /// beside it: the two happen to move on the same edge today and they answer different questions,
    /// so tying them together is how one silently changes when the other is tuned.
    @State private var lastChangedItem: String = ""
    /// The item the lookahead was last started from. Separate from `lastSeenItem` on purpose — see
    /// the note at the top of `startProgress`.
    @State private var lastPrefetchItem: String = ""

    // MARK: Private Properties
    @StateObject private var keyboardManager = KeyboardManager()   // own it once (was re-created each re-init)
    // (DELETED: `@State private var state: MediaState`. It mirrored the shared player's readiness so
    //  `playVideo` could ask whether there was anything to play, and its `.onChange` was one of the
    //  four callers that meant nothing and called `play()` anyway. Readiness belongs to the item and
    //  is read off the session.)
    /// ⚠️ THIS PAGE'S VIDEO ITEM — the mode going down, the clock and the end coming back. It
    /// replaces `@State private var player = AVPlayer()`, which was ONE player shared by every item
    /// in this person's bucket and borrowed weakly by one reused view.
    ///
    /// Every story-video bug of the last two months came from that sharing, and none of the guards
    /// it needed exist any more: an item owns its player, so the player can never be holding
    /// somebody else's clip. See `StoryVideoSession` and `StoryItemVideoView`.
    ///
    /// A reference type held in `@State` on purpose, exactly like `hostPause`: the same instance
    /// survives every re-render, and writing to it does not cause one.
    @State private var video = StoryVideoSession()
    @State private var animate = false
    @State private var selectedEmoji = ""
    @State private var startAnimate = false
    @State private var isTimerRunning: Bool = false
    @State private var isAnimationStarted: Bool = false
    @State private var isTapDisabled: Bool = false
    @State private var showEmoji: Bool = true
    @State private var isPaused: Bool = false   // hold-to-pause
    @State private var isHolding: Bool = false  // TRUE only after the long-press engages → drives the
                                                // chrome fade, so a quick tap doesn't flicker the header/bars
    /// A hero open or close is in the air (host posts `storyFlightActive`).
    ///
    /// SEPARATE FROM `chromeHidden` ON PURPOSE, and the difference is the whole point. The bars and
    /// the name live INSIDE the card, so they shrink with it — another mainstream messenger keeps them there for the
    /// whole pull, and it is what makes a story card read as a card rather than a photo sliding
    /// about. The REPLY BAR does not: it is drawn below the card, it does not move, and it carries
    /// its own solid black footer, so it has to leave. One flag for the sheet, one for the flight.
    ///
    /// ⚠️ SEEDED FROM THE FLIGHT RATHER THAN ASSUMED FALSE, AND THAT IS THE OWNER'S 2026-08-16
    /// "the opening does not match the closing". This page is BORN during an open, after the post
    /// that hid the chrome has already gone out to nobody — so it used to come up with its header
    /// and footer at full opacity over a card still flying, and the "show" at 18% changed nothing to
    /// animate. Starting hidden makes the arrival the exact reverse of the departure: same flag,
    /// same 0.15s curve, opposite direction. See `StoryCardMorph.flightChromeHidden`.
    @State private var flightActive = StoryCardMorph.flightChromeHidden
    /// A flight MASK is cutting the card (`StoryCardMorph` posts `storyFlightMask`): the card's own
    /// corner clip stands down so the mask is the only curve on it. The clip shrinks with the card,
    /// so during a drag it renders at a couple of points and capped every corner the flight could
    /// show — the square-cornered scroll-down close in his 2026-08-08 screenshots. The morph raises
    /// this at the moment its mask equals this clip (12pt, full screen) and lowers it in the same
    /// turn its mask leaves, so neither swap can ever be seen.
    @State private var flightMaskOn = false
    @State private var chromeHidden = false     // viewers sheet engaged (host posts storyChromeHidden):
                                                // ONLY the chrome fades; the photo never animates
    @State private var scenePaused = false      // pause came from leaving the foreground, not a hold
    // Host-pause lives in a REFERENCE box: writing it must NOT invalidate/re-render this view.
    // pauseStory posts on the dismiss pan's .began — a plain @State flip there re-rendered the hosted
    // story MID-PAN and iOS cancelled the pan ~20pt in, so a slow swipe-down bounced back every time
    // (fast flicks survived only via the velocity commit). Nothing in `body` reads this flag — only
    // the timer tick and the resume gate do — so a non-invalidating box is safe and kills the bounce.
    private final class HostPauseBox { var paused = false }
    @State private var hostPause = HostPauseBox()  // @State keeps the SAME box across re-renders
    @State private var isAdvancing: Bool = false   // guard the segment-end double-advance
    @State private var isFolding: Bool = false   // true while this page is mid-cube-fold (pause timer)
    /// The video is waiting on bytes MID-CLIP, so the progress bar holds. Mirrored from the session
    /// on the tick — see `startProgress`. It is a mirror rather than the truth because the bar's
    /// gate reads it inside a view body and the session is deliberately not observable.
    ///
    /// (`bufferingURL` is gone with it. It existed because a stall arrived as a broadcast EDGE and
    /// the matching "no longer stalled" could be delivered to a page that had stopped listening,
    /// stranding the hold for the rest of the bucket. A value that is read every tick cannot strand.)
    @State private var isBuffering: Bool = false
    @State private var captionExpanded: Bool = false   // tap the caption to expand past 3 lines
    /// WHERE THE FINGER IS, and the only answer in this file that cannot be missed. See `holdGesture`.
    ///
    /// `.idle` while nothing is touching the story, `.down` from the instant a finger lands, and
    /// `.holding` once the press has lasted long enough to be a hold rather than a tap. Not `.none`:
    /// that name collides with `Optional.none` at every use site and reads worse for it.
    private enum PressPhase: Equatable { case idle, down, holding }
    /// ⚠️ `@GestureState`, NOT `@State`, AND THAT IS THE ENTIRE FIX. SwiftUI resets a gesture state
    /// to its initial value when the gesture ends OR is cancelled, and it guarantees that reset even
    /// when the touch is taken away by another recogniser. That guarantee is the release edge this
    /// file has been trying to manufacture for three attempts.
    @GestureState private var pressPhase: PressPhase = .idle

    /// The index is RIGHT BEFORE THE FIRST FRAME, not corrected after it. `timerProgress` started
    /// at 0 and the jump to the first unseen item lived in `.onAppear` — so the first body
    /// evaluation always rendered item 0, the OLDEST story. For a video that mounts a player: the
    /// old clip's poster (and, warm from cache, the clip itself) painted for a beat before the view
    /// switched to the story actually being opened. That is his "briefly displays a different video
    /// that was already in my Story". The `.onAppear`/`.onChange` corrections stay — they become
    /// no-ops on first paint and still handle bucket changes.
    init(viewModel: StoryViewModel, model: StoryUIModel, isPresented: Binding<Bool>,
         userClosure: UserCompletionHandler?, onProfile: ((StoryUIUser) -> Void)? = nil,
         onItemSeen: ((String) -> Void)? = nil, onItemChanged: ((String) -> Void)? = nil,
         showMore: Bool = false, isDismissing: Bool = false,
         ownerBar: ((String) -> AnyView)? = nil, ownerBarHeight: CGFloat = 0) {
        self.viewModel = viewModel
        _model = State(initialValue: model)
        _isPresented = isPresented
        self.userClosure = userClosure
        self.onProfile = onProfile
        self.onItemSeen = onItemSeen
        self.onItemChanged = onItemChanged
        self.showMore = showMore
        self.isDismissing = isDismissing
        self.ownerBar = ownerBar
        self.ownerBarHeight = ownerBarHeight
        // A page swiped two people away is dismantled and REBUILT when you come back, so the resume
        // has to be answered here as well as in `.onChange` — otherwise going back far enough still
        // restarted the person. Split into named steps rather than a chain of `??`: this file has
        // twice cost a CI round to the type-checker.
        let count = model.stories.count
        let resume = viewModel.lastIndex[model.id]
        let firstUnseen = model.stories.firstIndex(where: { !$0.isSeen })
        let fullyRead = viewModel.startIndexForFullyRead(bucketId: model.id, count: count)
        let start = min(max(0, resume ?? firstUnseen ?? fullyRead), max(0, count - 1))
        _timerProgress = State(initialValue: CGFloat(start))
    }

    private var messageViewPosition: CGFloat {
        return -keyboardManager.currentHeight
    }

    /// Should the picture be dimmed behind the reply keyboard? See the overlay in `body` for the
    /// reference app's numbers this copies.
    ///
    /// `chromeHidden` is the second half, and it is the reference app's too: it clears the dim when the view
    /// list is showing (`if component.hideUI || self.viewListDisplayState != .hidden`). Ours is the
    /// viewers sheet, and the reason is the same — the sheet's own scale and scrim already own the
    /// picture's brightness at that point, and a second dim underneath is a step nobody asked for.
    private var replyDimOn: Bool { keyboardManager.isKeyboardOpen && !chromeHidden }
    
    private var emojiViewPosition: CGFloat {
        // SPEC: the reaction bar sits exactly 12pt above the input bar. The input pill's top is
        // messageViewPosition minus its own height (Constant.MessageView.height) and its 16pt top
        // padding, above the home-indicator inset. The reaction bar is bottom-anchored, so lift it
        // that far plus the 12pt gap. (Was messageViewPosition*1.5 — a huge, uneven gap.)
        return messageViewPosition - Constant.MessageView.height - 16 - 12 - winInsets.bottom
    }

    // Real device safe-area insets (the host no longer applies them — see StoryPageHostVC). Used to
    // place the story card below the notch and the reply bar above the home indicator.
    private var winInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.safeAreaInsets
            ?? UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
    }

    /// THE STORY CARD'S HEIGHT, and this is the reference app's rule read out of its source rather than
    /// guessed from a screenshot. The reference implementation:
    ///
    ///   :3942  itemSize   = (width, ceil(width * 1.77778))    // 9:16, always
    ///   :3955  height     = min(itemSize.height, screenH - safeTop - bottomInset)
    ///   :3973  frame.y    = safeTop                            // it BEGINS below the status bar
    ///   :4031  cornerRadius = 12
    ///
    /// The owner's report was two things and this answers both. Our story ran the full height of the
    /// screen, so a wide photo became a thin band adrift in a lot of black with the progress bars and
    /// the header stranded above it — that is the sizing he circled. And because it started at y=0, a
    /// tall photo could reach up under the clock. A card that begins at the safe-area top and is 9:16
    /// unless the screen is too short for that makes both impossible by construction.
    ///
    /// On a 393x852 phone: 9:16 is 699, available is 852 - 59 - 94 = 699, so the card is exactly 9:16
    /// and the reply bar takes the rest. On a shorter screen the card gives up height rather than
    /// running under the reply bar.
    /// `containerH` is the space THIS page actually has, not the screen. They differ: my own stories
    /// are hosted in a stack that already gave 52pt away to the Views/Delete footer, so measuring
    /// against `UIScreen` would build a card taller than the room it has and run it under that bar.
    private func cardHeight(width: CGFloat, containerH: CGFloat, footerH: CGFloat) -> CGFloat {
        let nineBySixteen = ceil(width * 1.77778)
        let bottomInset = max(footerH, winInsets.bottom + 1)
        let available = containerH - winInsets.top - bottomInset
        return max(1, min(nineBySixteen, available))
    }

    /// ⚠️ ONE NUMBER FOR THE WHOLE CARD, AND IT LIVES IN `Constant` SO THE PHOTO VIEW AND THE CLIP
    /// VIEW READ THE SAME ONE. It was 12 here, 24 on the photo's own bottom corners and 12 again
    /// inside the video view — three numbers for one rectangle, which is his "2 type corners".
    /// Measured off his screenshots; the note on `Constant.cardCornerRadius` holds the measurement.
    private let cardRadius: CGFloat = Constant.cardCornerRadius

    /// Hand the card's rectangle to `StoryCardMorph`, which shrinks the live story into the viewers
    /// sheet and needs to know it is aiming at the card and not at this whole page.
    private func publishCardRect(proxy: GeometryProxy, footerH: CGFloat) {
        // ⚠️ ONE PUBLISHER: THE PAGE THE VIEWER IS ON. See the note at the call site.
        //
        // `setCardMetrics` is a single slot on a singleton with no identity, and a neighbour page
        // that has a reply bar answers a different question by 110pt. This is the same test the
        // jump handler uses to decide whether a notification is meant for this page, deliberately —
        // "am I the page on screen" must have one answer in this file, not two.
        //
        // A fresh open where `currentStoryUser` has not landed yet publishes NOTHING rather than
        // publishing a guess. `contentRect` refuses to answer without metrics and the host keeps its
        // own estimate for those frames, which is what that fallback is for.
        guard viewModel.currentStoryUser == model.id else { return }
        StoryCardMorph.shared.setCardMetrics(
            top: winInsets.top,
            height: cardHeight(width: proxy.size.width, containerH: proxy.size.height, footerH: footerH),
            // The flight's mask lands ON this number at the full-screen end instead of running down
            // to a square corner, so the moment the mask is taken away and this card's own
            // `.clipShape` takes over, the corner does not change. Published from here because this
            // is the one place that knows it.
            radius: cardRadius)
    }

    var body: some View {
        
        GeometryReader { proxy in
            let index = getCurrentIndex()
            ZStack {
                // Empty bucket (all items expired/removed) -> render nothing instead of indexing [-1] (crash).
                if index < model.stories.count {
                    let story = model.stories[index]
                    // EVERY story is a card now, mine and other people's alike. It used to be that
                    // only a friend's story ended above its reply bar and my own ran the full height
                    // of the screen; the difference between the two is just `footerH` below, which is
                    // how much room the bar underneath needs.
                    let isReplyBar = story.config.storyType != .plain()
                    // ⚠️ AND MY OWN BAR ASKS FOR ROOM THE SAME WAY A REPLY BAR DOES. It is the one
                    // line that makes the card shorter by exactly what the bar takes, so the two
                    // cannot overlap and the card the morph is told about is the card that is drawn.
                    let ownFooter: CGFloat = (ownerBar != nil && model.isMine) ? ownerBarHeight : 0
                    let footerH: CGFloat = isReplyBar
                        ? Constant.MessageView.height + 32 + winInsets.bottom
                        : ownFooter
                    // THE CARD. Sized and placed by the reference app's rule (see `cardHeight`), pinned to the
                    // safe-area top by the VStack below rather than centred in the screen.
                    VStack(spacing: 0) {
                        getStoryView(with: index, story: story)
                            .frame(width: proxy.size.width,
                                   height: cardHeight(width: proxy.size.width,
                                                      containerH: proxy.size.height,
                                                      footerH: footerH))
                            // THE STORY STEPS BACK WHILE YOU TYPE. His report, with a reference
                            // screenshot beside ours: opening the reply keyboard left our picture at
                            // full brightness, so the thing you are reading and the thing you are
                            // writing competed, and on a bright photo the reply bar was hard to see
                            // at all.
                            //
                            // The reference app's own numbers, read from the reference implementation:
                            // `contentDimView.backgroundColor = UIColor(white: 0.0, alpha: 0.8)`,
                            // and `dimAlpha` goes to 1 exactly when `inputPanelIsOverlay`, which is
                            // true when and only when the keyboard has height. So: black at 0.8, on
                            // keyboard open, and nothing else turns it on.
                            //
                            // ⚠️ IT DIMS, IT DOES NOT SHRINK, and that is measured rather than
                            // assumed. In the same file the keyboard branch is
                            // `bottomContentInset += 44.0` against `+= inputPanelSize.height` when
                            // the keyboard is down — 44 is LESS than the reply pill's own height, so
                            // their card gets marginally TALLER while you type, never smaller.
                            // Scaling the card here would also put it out of step with the rect
                            // `publishCardRect` hands the flight.
                            //
                            // OVER THE MEDIA, UNDER THE CHROME: this overlay is first, so the
                            // caption, the top scrim, the header and the progress bar all layer
                            // above it and stay readable — which is what their `insertSubview(
                            // captionItemView, aboveSubview: self.contentDimView)` arranges too.
                            .overlay(
                                // ⚠️ A SHAPE WITH A VIEW OPACITY, NOT A COLOUR WITH A COLOUR
                                // OPACITY. `Color` HAS ITS OWN `opacity(_:)` AND IT WINS.
                                //
                                // His report: the dim "appears only after the keyboard is fully
                                // opened… suddenly, all at once", when the intent written here has
                                // always been for it to rise with the keyboard.
                                //
                                // This was `Color.black.opacity(replyDimOn ? 0.8 : 0)`, and that
                                // call does NOT reach `View.opacity`: `Color` declares its own
                                // `opacity(_:) -> Color`, which is more specific, so the expression
                                // built a different COLOUR VALUE rather than applying an animatable
                                // view property. `.animation(value:)` below had nothing of its own
                                // to drive.
                                //
                                // `Rectangle().fill(.black)` is a view, so `.opacity` on it is
                                // unambiguously the view modifier — the animatable one. Writing it
                                // as a shape rather than reordering the chain is deliberate: a
                                // reader can see WHICH opacity this is without knowing the overload
                                // rule that caused the bug.
                                //
                                // ⚠️ REASONED FROM THE SOURCE, NOT MEASURED, and it is the only
                                // candidate reading can reach — everything else on this path (the
                                // duration comes from the notification, `chromeHidden` is the
                                // viewers sheet and is false here, `isKeyboardOpen` is set in
                                // `keyboardWillShow` which fires BEFORE the keyboard moves) is
                                // already correct. If it still pops on a device, the answer is not
                                // in this expression and the next step is to instrument rather than
                                // to re-argue it.
                                // ⛔ 0.4, WHICH IS THE Aa EDITOR'S NUMBER — his 2026-08-18 "when i
                                // click reply bar the image is getting too dark; make it like Aa".
                                //
                                // 0.8 is the reference app's `contentDimView` value and the note
                                // below is right that it was read from their source. He is asking
                                // for the one his own app already uses a few screens away:
                                // `StoryTextToolEditor.dimBackground` is
                                // `UIColor.black.withAlphaComponent(0.4)`. Two dims over the same
                                // photograph, in the same app, twice as dark on one of them, is the
                                // inconsistency he is actually pointing at — and his judgement about
                                // his own app decides which of the two wins.
                                //
                                // ⚠️ THE Aa EDITOR IS NOT TOUCHED, on his instruction. This borrows
                                // its number and its clock; nothing on that screen changes.
                                Rectangle()
                                    .fill(.black)
                                    .opacity(replyDimOn ? 0.4 : 0)
                                    // ⛔ AND THE KEYBOARD'S OWN CURVE, NOT JUST ITS DURATION — the
                                    // "not smooth" half of the same report.
                                    //
                                    // This took the real duration off the notification, which was
                                    // half right, and then ran it on `.easeInOut` — a curve the
                                    // keyboard is not travelling on. So the picture darkened over
                                    // the correct length of time along the wrong path, and drifted
                                    // away from the keys in the middle of the move where the two
                                    // curves are furthest apart. `systemAnimation` is the reference
                                    // app's dispatcher: curve 7 becomes their own
                                    // `bezierPoint(0.23, 1.0, 0.32, 1.0)`, anything else stays
                                    // ease-in-out. Same value the reply bar itself rides, so the
                                    // bar and the dim under it cannot come apart.
                                    .animation(keyboardManager.systemAnimation, value: replyDimOn)
                                    .allowsHitTesting(false)
                            )
                            // THE CARD CARRIES ITS OWN BLACK, inside its own rounded rect.
                            //
                            // The dismiss used to paint the whole moving page black so the story
                            // could never go transparent mid-drag, and then relied on a mask to clip
                            // that black back to the card. When the mask did not bite, the strip of
                            // page ABOVE the 9:16 card shrank into view as a black header sitting on
                            // top of the story. That is the bar he circled.
                            //
                            // Putting the black here instead means there IS no black outside the
                            // card for a clip to fail to remove: the card is opaque by construction,
                            // and everything around it can be transparent at every moment of the
                            // drag. Another mainstream messenger's dismissal looks the way it does for the same reason —
                            // what pulls away is the picture and nothing else.
                            .background(Color.black)
                            // ⚠️ THE REASON THIS WAS ADDED IS GONE, AND IT IS STILL HERE ON PURPOSE.
                            // It was here because a bare `.clipShape` does not clip a
                            // `UIVisualEffectView` — ImageLoader's blur backdrop composited
                            // separately and spilled past the mask, so the card's bottom stayed
                            // square. That backdrop is a `CAGradientLayer` now (`StoryCanvas`) and an
                            // ordinary clip cuts it, so this is no longer load-bearing for corners.
                            // It is kept because it also flattens the card for the flight mask and
                            // the dismiss transform below, and unpicking that belongs to a change to
                            // the story flight, not to a change to the backdrop. Removing it is a
                            // real (small) win — an offscreen pass per frame — for whoever next has
                            // the flight open and a device to check it on.
                            .compositingGroup()
                            // All four corners now, not just the bottom two: the card has a visible top
                            // edge for the first time, because it starts below the status bar.
                            // Radius ZERO while a flight mask is on — the mask owns the corner for the
                            // whole flight (see `flightMaskOn`); the rectangle clip itself stays, it is
                            // what cuts the blur backdrop's spill.
                            .clipShape(RoundedRectangle(cornerRadius: flightMaskOn ? 0 : cardRadius,
                                                        style: .continuous))
                            .overlay(
                                tapStory()
                                    .offset(
                                        y: story.config.storyType != .plain()
                                        ? -Constant.MessageView.height : .zero
                                    )
                            )
                            // Overlay caption: overlaid on the media (never baked into the photo).
                            // It fades with the viewers-sheet pull rather than flipping with the rest
                            // of the chrome — see SheetCaptionFade.
                            // ⚠️ BOTH SCRIMS TAKE THE CARD'S OWN CLIP. They are overlaid AFTER the
                            // card's `.clipShape`, so their square corners OVERHUNG the rounded card
                            // — at rest, no flight involved: his 2026-08-09 screenshot, all four
                            // corners marked, the gradient's square corner sitting proud of the
                            // curve with the chat list behind it. Each scrim strip's far end fades
                            // to clear, so rounding it cuts nothing visible there; its near corners
                            // are the card's corners, which is the point. Radius zero while a
                            // flight mask is on, same rule as the card — the mask owns the corner
                            // and now truly crops these strips with everything else.
                            // LINK AND LOCATION STICKERS. Under the caption and under the header, so
                            // neither can be blocked by one; over the picture, which is where the
                            // sticker it belongs to is already drawn. See `tapAreas`.
                            .overlay(tapAreas(story))
                            .overlay(captionView(story.caption, plain: story.config.storyType == .plain())
                                        .modifier(SheetCaptionFade())
                                        .clipShape(RoundedRectangle(cornerRadius: flightMaskOn ? 0 : cardRadius,
                                                                    style: .continuous)),
                                     alignment: .bottom)
                            // Top dark scrim so the username/avatar/close stay readable on white/bright photos.
                            // Fades with the chrome (it's part of the chrome look) — the PHOTO must stay
                            // pixel-stable when the viewers sheet opens, so the scrim can't linger under
                            // a scrimless morph card (that brightness step read as a flash).
                            .overlay(topScrim.opacity(chromeHidden ? 0 : 1)
                                        .animation(.linear(duration: 0.18), value: chromeHidden)
                                        .clipShape(RoundedRectangle(cornerRadius: flightMaskOn ? 0 : cardRadius,
                                                                    style: .continuous)),
                                     alignment: .top)
                            // THE BARS AND THE HEADER LIVE INSIDE THE CARD, over the picture, which is
                            // where the reference app puts them (`contentInsets.top = 54`). They used to be
                            // overlaid on the SCREEN, so they sat on black above the story and read as
                            // part of the phone rather than part of the story. This is what he circled.
                            .overlay(
                                getUserInfoAndProgressBar(with: index)
                                    // Chrome-only fades: on a real hold, AND while the viewers sheet is
                                    // engaged (host posts storyChromeHidden). ONLY these overlays
                                    // animate — the story image itself must never fade, flash, or
                                    // re-render (user spec).
                                    .opacity((isHolding || chromeHidden) ? 0 : 1)
                                    .animation(.linear(duration: 0.2), value: isHolding)
                                    .animation(.linear(duration: 0.18), value: chromeHidden),
                                alignment: .top
                            )
                        // ⚠️ THE SPACER GOES ABOVE THE BAR, NOT BELOW IT, AND THAT IS THE GAP HE
                        // LOST. The card is capped at 9:16, so on most phones it does not use all
                        // the room this stack has; the leftover used to fall between the card and
                        // the bar, because the bar was pinned to the bottom of the SCREEN and the
                        // page ended above it. Moving the bar into the page put the leftover
                        // UNDERNEATH it instead — the card met the bar with nothing between them
                        // and the black he described as empty was at the very bottom. His words:
                        // "space between story image frame and views count is too small… before is
                        // good… iam feeling buttom empty."
                        //
                        // Pushed to the bottom of the page, the leftover is back where it was and
                        // the geometry is the old one to the point.
                        Spacer(minLength: 0)
                        // MY OWN BAR, IN THE PAGE. It travels with the card through the cube for
                        // the same reason a friend's reply bar always did: both are the page.
                        if let ownerBar, model.isMine, ownerBarHeight > 0 {
                            ownerBar(model.id)
                                .frame(height: ownerBarHeight)
                                // ⚠️ AND IT LEAVES ON THE FLIGHT, EXACTLY LIKE A FRIEND'S REPLY BAR
                                // — his 2026-08-16 report, with the bottom of the screen circled:
                                // "when other people story i scroll down to close the buttom reply
                                // bar disappearing correctly, but… my owner story… views and trash
                                // bar is gone late."
                                //
                                // Moving this bar into the page (2026-08-14) was so it would TRAVEL
                                // with the card through the cube, and it does. But it sits BELOW the
                                // card and does not move with it, which is the reply bar's situation
                                // to the letter — so on a pull-to-close the card flew home and the
                                // Views and trash stayed sitting at the bottom of the chat list
                                // until the whole viewer was torn down. That is the "late".
                                //
                                // Same flag, same curve, same line of code as `messageView`'s, and
                                // deliberately the same line so the two can never drift: one bar
                                // per page, one rule for both. `flightActive` is the hero open and
                                // close only — a cube turn does not raise it, so nothing is taken
                                // away from the swipe this bar was moved here for.
                                // ⚠️ IT FADES AND IT DOES NOT TRAVEL — HIS WORD, 2026-08-17, AFTER
                                // SEEING THE TRAVEL ON A DEVICE: "the bottom now is coming down, i
                                // want my old type… only restore the Reply and Views/Trash bars'
                                // original appearing".
                                //
                                // `871a3fff` had both bars slide up from below the screen on the way
                                // in — the reference app's own `animateIn`, every number read from
                                // their source (0.48s position on cubic bezier
                                // (0.380, 0.700, 0.125, 1.000), a separate 0.28s alpha). It is a
                                // faithful port and he does not want it. His judgement about his own
                                // app decides this, so both bars are back to the plain 0.15s fade
                                // that shipped before it, at both sites, written the same way so the
                                // pair still cannot drift.
                                //
                                // ⚠️ DO NOT RE-PORT IT ON THE STRENGTH OF THE REFERENCE. The
                                // mechanism is recorded in `871a3fff` if it is ever asked for again;
                                // it was not wrong, it was unwanted.
                                .opacity(flightActive ? 0 : 1)
                                .animation(.easeOut(duration: 0.15), value: flightActive)
                        }
                    }
                    .padding(.top, winInsets.top)
                    // Tell the viewers-sheet morph WHERE the card is, because it is no longer the
                    // whole view. Without this it would shrink the black margins into the slot along
                    // with the story and centre on the wrong point.
                    //
                    // ⚠️ "EVERY PAGE COMPUTES THE SAME RECTANGLE, SO WHICHEVER ONE RUNS LAST IS STILL
                    // RIGHT" IS WHAT THIS USED TO SAY, AND IT IS FALSE. That sentence was the bug.
                    //
                    // `footerH` is per PAGE, not per screen: a page with a reply bar gives up
                    // `44 + 32 + safeBottom` = 110pt that a page without one keeps. My own story is
                    // `.plain()` and has no reply bar, a friend's has one — and the pager parents
                    // BOTH neighbours as real child view controllers, so a friend's page appears,
                    // runs this, and overwrites the metrics my page just published. There is no
                    // identity on `setCardMetrics`; it is one slot and the last writer wins.
                    //
                    // On a 393x852 that is 631 written over 699. Nothing shows it at rest, because
                    // each page draws itself from its OWN `cardHeight`. It only bites when the sheet
                    // starts to rise, because the morph then crops the live story to this rectangle
                    // — 68pt shorter than the picture actually is, pinned at the top, so the missing
                    // strip is taken off the BOTTOM. That is the owner's report: the story does not
                    // zoom out, its bottom is cut away, and the text at the foot of his story
                    // disappears the instant the sheet moves.
                    //
                    // The page the viewer is actually ON is the only one whose rectangle is the one
                    // being cropped, so it is the only one allowed to answer. Paging to another
                    // person re-answers through the `currentStoryUser` change below.
                    .onAppear { publishCardRect(proxy: proxy, footerH: footerH) }
                    .onChange(of: proxy.size) { _ in publishCardRect(proxy: proxy, footerH: footerH) }
                    .onChange(of: viewModel.currentStoryUser) { _ in
                        publishCardRect(proxy: proxy, footerH: footerH)
                    }
                    // ⚠️ AND ON THE FOOTER ITSELF, BECAUSE IT IS PER ITEM AND NOT PER PAGE.
                    //
                    // `isReplyBar` is read off `story.config.storyType`, so one bucket can hold an
                    // item with a reply bar and an item without one — `allowsReplies` is per story.
                    // Moving between them changes the card's height by 110pt with no page change and
                    // no size change, so neither of the two triggers above would fire and the crop
                    // would keep the height of the item we just left. Same shape of bug as the one
                    // above, one level down.
                    .onChange(of: footerH) { _ in publishCardRect(proxy: proxy, footerH: footerH) }
                    // (Removed the always-on bottom photo scrim: the reply pill now sits on the solid
                    // black footer BELOW the card, not over the photo, so dimming the photo's bottom
                    // was pointless and just darkened captionless photos.)
                    // Reply bar floats at the bottom OVER the photo (no black background row anymore).
                    VStack(spacing: 0) { Spacer(); messageView(with: index) }
                    getEmojiView(story: story)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // The chrome overlay that used to be HERE, on the whole screen, is on the card now — see
            // the note beside it. Leaving a copy at this level would draw the bars twice, once inside
            // the story and once on the black above it.
            // ⚠️ THE `rotation3DEffect` THAT USED TO BE HERE IS DELETED, AND SO IS `getAngle`.
            //
            // It was a SECOND cube: 45° off `proxy.frame(in: .global).minX`, in SwiftUI, alongside
            // the pager's own fold. It could not work on the path that matters — a GeometryReader
            // re-evaluates on SIZE, not on POSITION, and a finger swipe moves the pages by scroll
            // offset, so nothing re-sampled the angle and the page stayed flat. A tap only worked by
            // accident, because the view model is written first and the arriving page re-renders
            // through the turn.
            //
            // Two things folding the same pages is what produced the shake and the black flash, so
            // it was gated off whenever the real cube was on. That left a fold which could only ever
            // return zero — dead code that reads like a live mechanism. `StoryPager.applyCube` is
            // the only thing that folds a page now, it reads layer positions directly, and it covers
            // the finger and the tap with one mechanism.
            // report how far this page is from centre so the timer can pause mid-fold
            .preference(key: StoryFoldKey.self, value: proxy.frame(in: .global).minX)
        }
        .onPreferenceChange(StoryFoldKey.self) { minX in
            let folding = abs(minX) > 2     // off-centre = mid-fold (or off-screen): freeze the timer
            if folding != isFolding { isFolding = folding }
        }
        // Viewers-sheet chrome control: the host hides ONLY the progress bar / avatar / name /
        // top scrim while the sheet is engaged. The story image stays completely untouched.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyChromeHidden"))) { note in
            let hidden = (note.object as? Bool) ?? false
            if hidden != chromeHidden { chromeHidden = hidden }
            // ⚠️ THIS IS THE COLLAPSED STATE, AND IT IS THE ONLY THING THAT DECIDES WHETHER A STORY
            // RETURNED TO RESUMES OR RESTARTS.
            //
            // The reference app keeps every visible item's view alive while its sheet is collapsed
            // over the story and merely pauses the ones that are not central, so the item you came
            // from keeps its player, its position and its last frame — for free. At full screen it
            // drops every item view but the central one, so a revisit builds a new player and a new
            // player begins at zero.
            //
            // Those are exactly the owner's two rules ("normal viewing restarts, the sheet
            // preserves"), and this line is the whole of the mechanism. See `StoryItemViewStore`.
            StoryItemViewStore.retainDismounted = hidden
            // ⚠️ NOTHING SETS THE WINDOW HERE ANY MORE. The row's own layout pass publishes it, and
            // the row is what comes into existence with the sheet — see `StoryVideoHost.previewWindow`.
            // Closing clears the window as part of dropping retention, which is the flag's `didSet`.
        }
        // A hero open or close is in the air: the reply bar and its black footer step aside, the
        // card's own chrome stays on the card. See `flightActive`.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyFlightActive"))) { note in
            let active = (note.object as? Bool) ?? false
            if active != flightActive { flightActive = active }
        }
        // A flight mask is cutting the card: its own corner clip stands down. See `flightMaskOn`.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyFlightMask"))) { note in
            let on = (note.object as? Bool) ?? false
            if on != flightMaskOn { flightMaskOn = on }
        }
        // ...AND SAY SO, which is the half that was missing. Setting `flightMaskOn` only SCHEDULES
        // the clip change; the mask on the other side was already opening on the assumption that it
        // had happened, and the gap between the two is the black crescent he photographed at the
        // corners in the first fifth of a pull. `StoryCardMorph` holds its hole at the card's own
        // curve until this arrives — see `cardClipIsDown` there.
        //
        // ⚠️ THE `async` HOP IS THE POINT, not clumsiness. `onChange` runs while SwiftUI is
        // processing the new value; a hop lands after that pass has been committed, which is the
        // first moment the zero-radius clip is genuinely on screen. Acknowledging from inside the
        // update would re-state the same assumption one line further down.
        .onChange(of: flightMaskOn) { on in
            guard on else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .init("storyFlightMaskAck"), object: nil)
            }
        }
        // ⚠️ THE `.storyBuffering` AND `.storyVideoFinished` RECEIVERS THAT LIVED HERE ARE GONE, AND
        // SO IS THE WHOLE "WAS THAT ABOUT ME" PROBLEM THEY EXISTED TO SOLVE.
        //
        // Both were broadcasts carrying a clip url in `userInfo`, and both receivers had to compare
        // it against the story they believed was current. Two chances per notification to compare
        // the wrong pair, and two shipped bugs from exactly that — a neighbour page's stall freezing
        // the bar of the story on screen, and a stale clip's end completing somebody else's segment.
        // Being an EDGE made the first one worse: a `false` posted while its page was being swiped
        // away had no listener left, so the hold never came down.
        //
        // Both answers are now READ off this page's own session on the 0.05s tick, in
        // `startProgress`, where a missed edge is impossible and the numbers cannot belong to
        // anybody else.
        .onChange(of: viewModel.currentStoryUser) { newValue in
            // ⚠️ THE `.stopVideo` BROADCAST THAT USED TO OPEN THIS IS GONE, AND NOTHING REPLACES IT.
            // It was posted with `object: nil`, so it reached every mounted page's player and each
            // one had to work out whether it was the one being left. `videoMode`'s first line
            // answers that by construction — a page that is not the current bucket is `.pause` —
            // and `syncVideoMode()` at the bottom of this handler runs on every mounted page, so
            // the page being left stops itself and the page arriving starts itself, from the same
            // line, with no broadcast and nobody to mistake for somebody else.
            // ON THE WAY OUT, BEFORE `resetProgress` WIPES IT. This fires on every mounted page, so
            // the one being left is the one whose id no longer matches — and its `timerProgress`
            // still holds where the finger got to.
            if newValue != model.id { rememberPosition() }
            // ⚠️ THE PAGE BEING LEFT IS STILL VISIBLE, so it keeps its picture through the slide.
            //
            // This onChange fires on EVERY mounted page. On a finger swipe the pager writes
            // `currentStoryUser` in `didFinishAnimating`, after the slide, so a full reset here was
            // invisible. Auto-advance and tap-advance write it FIRST and the slide follows — and the
            // unconditional `timerProgress = 0` re-rendered the departing page onto its first story
            // in the opening frame of that slide. His report: reach person A's last story, the move
            // to B begins, and A flips back to story 1 while still flying off. `keepPosition` clears
            // every latch but leaves the drawn item alone; the full wipe happens in the
            // `newValue == model.id` branch the next time this page takes the screen.
            resetProgress(keepPosition: newValue != model.id)
            // When this bucket becomes current, open where it was left in this session, else at the
            // FIRST UNSEEN item (e.g. a new story D after A/B/C were seen), else at the start.
            // Asking `firstUnseenIndex` here unconditionally is what restarted a fully-watched
            // person at item 1 every single time you swiped back to them.
            // The ITEM is remembered, the position inside it is not: a video returned to restarts
            // from zero (the owner's 2026-08-11 rule, and the reference app's behaviour — a revisited item
            // is a fresh player seeked to 0), so the bar starts the segment exactly where the
            // player will: at its beginning.
            if newValue == model.id {
                let i = resumeIndex()
                timerProgress = CGFloat(i)
                // ⚠️ A CLIP COMES BACK PARKED AT ITS OWN END, AND THAT IS READ AS "IT HAS FINISHED".
                // HIS 2026-08-14 REPORT, WHICH IS VIDEO-ONLY AND IS VIDEO-ONLY FOR A REASON.
                //
                // A photo's bucket ends by ARITHMETIC — `timerProgress` crossing the item count — and
                // that is now clamped on the way out, so a photo page cannot come back claiming to be
                // finished. A video's bucket ends by REPORT, and the bar is capped under the boundary
                // precisely so the player's own word is the only way out of a clip. There is a second
                // path for a clip that reaches its end without saying so (`startProgress`'s inference:
                // loaded, not playing, meant to be playing, clock at the end) — and a retained item
                // view returned to after an auto-advance matches every one of those the instant this
                // page is handed the screen again. So the tick that follows the back swipe's commit
                // advanced straight back to the friend, which is his finger leaving the screen.
                //
                // Rewinding is not a new rule, it is the rule this viewer already has written down: a
                // story returned to restarts at zero, the item is remembered and the position inside
                // it is not. Every other return gets that free by being a NEW player; a retained one
                // has to be told. That is also the exception `restart()`'s own note is about.
                if getStoryOrNil(with: i)?.config.mediaType == .video { video.restart() }
                // The page being handed the screen is not folding, whatever the last geometry
                // snapshot said. `resetProgress` above cleared this too, but a preference delivered
                // mid-transition can arrive AFTER it — see the note in `startProgress`.
                isFolding = false
            }
            syncVideoMode()
        }
        .onAppear {
            // First open of the viewer (onChange(currentStoryUser) doesn't fire for the initial bucket):
            // land on the first unseen item too. `lastIndex` is empty on a fresh viewer, so this is
            // the same answer it always gave.
            if viewModel.currentStoryUser == model.id {
                timerProgress = CGFloat(resumeIndex())
                // A VIEWER THAT HAS JUST OPENED IS NOT FOLDING. The open flight moves this page's
                // container, so the geometry snapshot taken during it reads an off-centre origin and
                // there is no second delivery once it lands — see `startProgress`. This is the first
                // open, where `onChange(of: currentStoryUser)` never fires at all.
                isFolding = false
            }
            // ⚠️ THE FIRST OPEN IS THE ONE PATH `onChange(of: currentStoryUser)` NEVER COVERS, and
            // the mode has to reach the item from somewhere or the first story of a session would
            // sit on its cover. The video content's own `.onAppear` also asks, so this is the belt
            // for the ordering where the page appears before its media view does.
            syncVideoMode()
        }
        .onReceive(timer) { _ in
            startProgress()
        }
        .onChange(of: isAnimationStarted ? isAnimationStarted : false) { state in
            syncVideoMode()
            isTimerRunning = state
        }
        .onChange(of: keyboardManager.isKeyboardOpen) { open in
            syncVideoMode()   // composing a reply pauses; resumes on dismiss
        }
        .onChange(of: scenePhase) { phase in
            setSceneActive(phase == .active)
        }
        // ⚠️ AND THE SAME ANSWER FROM UIKIT, WHICH IS THE ONE THAT ACTUALLY ARRIVES HERE — his
        // 2026-08-16 report: "when I am watching a Story and completely leave the app, the Story
        // continues playing in the background and I can still hear the audio."
        //
        // `scenePhase` is injected by the SwiftUI App into ITS OWN root view, and this view is not
        // under it: every page is a `StoryPageHostVC` — a `UIHostingController` built by hand inside
        // a UIKit pager, inside a UIKit presenter. A hosting controller made that way keeps its own
        // environment, so the value read above can sit at `.active` for the whole life of the
        // viewer. The handler was right and was simply never called, which is why nothing about it
        // looked wrong.
        //
        // These two notifications are posted by UIKit to the whole process and cannot be missed. The
        // app also carries the `audio` background mode for calls and voice notes, so a story left
        // playing does not merely keep running, it keeps SOUNDING — which is what he heard.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            setSceneActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            setSceneActive(true)
        }
        // Host shows/hides a sheet over the viewer (viewers list, share, menu) → freeze/resume.
        .onReceive(NotificationCenter.default.publisher(for: .pauseStory)) { _ in
            // ⚠️ NOTHING IS PHOTOGRAPHED HERE ANY MORE. This used to call `bankCurrentState()`
            // FIRST, because a paused item's video output hands its buffer over exactly once and
            // this was the last instant it could be caught — the sheet coming up over a story was
            // the one moment that decided whether the carousel got a real picture of the clip or
            // fell back to its second-zero poster. Five shipped attempts moved which player was
            // asked, which slot it landed in and which instant it was caught at.
            //
            // The clip's player is still alive and still on that frame now (the store keeps it for
            // as long as the sheet is up), so the card asks for the picture when it wants one and
            // gets it from the file at the second the player is actually paused on. There is no
            // instant to catch, so there is nothing to do here but stop.
            hostPause.paused = true; syncVideoMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeStory)) { _ in
            hostPause.paused = false
            // The host's axis has changed, so the answer is re-taken here as well as after the flag
            // clear below — the `pressPhase` guard can return early, and a mode that is only ever
            // re-derived past a guard is a mode that can be left stale. Re-deriving cannot start a
            // story that should not be running: a finger still down keeps `isHolding` up, and
            // `videoMode` reads it.
            syncVideoMode()
            // ⚠️ THE FLAGS COME DOWN BEFORE THE PLAY, NOT AFTER. `playVideo` now refuses while
            // `isPaused`/`isHolding` stand (see its note), so calling it first — as this line did —
            // would refuse, and then the clear below would leave a story whose bar runs and whose
            // video never restarts. Every other resume path already had this order; this one was
            // the odd one out and only worked because the guard did not exist.
            //
            // AND A HOLD THAT NEVER REPORTED ITS RELEASE. The engage-time pause above closes the
            // common case; this is the belt for a hold whose touch was taken by another recogniser
            // mid-press. `resumeStory` is posted at every moment the story is definitely meant to be
            // running — a viewer appearing, a pull springing back, a sheet closing — and no finger
            // can still be held down across any of them.
            //
            // NOT when the pause is the SCENE's: leaving the app sets `isPaused` too, and clearing
            // it on a resume that arrives while backgrounded would start the story playing behind
            // the app switcher. `scenePhase` owns that one and hands it back itself.
            // ⚠️ AND NOT WHILE A FINGER IS STILL ON THE STORY. The paragraph above assumes no hold
            // can survive a `resumeStory`, and that assumption is wrong in one specific way: a
            // downward pan FAILS the moment the finger moves 8pt on the cross axis
            // (`DirectionalPanGestureRecognizer`), and both pagers post `resumeStory` on failure.
            // So holding a story to pause it and then sliding the thumb a centimetre sideways —
            // without lifting — cleared both flags and started the clip again under the finger. The
            // press was still live, so no further gesture callback was coming, and the eventual
            // release found the flags already clear and did nothing. That is the "it pauses, then
            // it plays by itself" shape, arriving from a completely different direction than the
            // timing race that was fixed earlier.
            //
            // `pressPhase` is the one signal in this file that cannot lie about a finger, so it is
            // what decides. Nothing is stranded by deferring: the gesture's own `.idle` transition
            // resumes on release, which is the same code path a normal hold already ends through.
            // `hostPause` is cleared either way — that is the host's axis, not the finger's.
            guard pressPhase == .idle else { return }
            if !scenePaused, isPaused || isHolding { isPaused = false; isHolding = false }
            if !keyboardManager.isKeyboardOpen { syncVideoMode() }
        }
        // Host's viewers carousel centred a different one of MY stories → jump the (frozen) viewer to
        // that item, so when the sheet collapses the story underneath matches the carousel/morph (no
        // photo-swap flash at the end of the close). Only affects the currently-shown bucket.
        .onReceive(NotificationCenter.default.publisher(for: .init("jumpToStoryItem"))) { note in
            guard viewModel.currentStoryUser == model.id,
                  let id = note.object as? String,
                  let idx = model.stories.firstIndex(where: { $0.id == id }),
                  idx != getCurrentIndex() else { return }
            // ⚠️ THIS IS THE ONE RETURN THAT DOES **NOT** RESTART AT ZERO, AND THE BAR HAS TO AGREE.
            //
            // Every other way back to a story builds a new player, which begins at zero. This one
            // happens while the viewers sheet is collapsed, and while it is collapsed the item views
            // are RETAINED — so swiping the sheet's cards away and back hands the story its own
            // player, still paused exactly where it was. That is the owner's rule ("normal viewing
            // restarts, the sheet preserves") and it is the reference app's collapsed behaviour.
            //
            // The integer part is what SELECTS the item, so it is written plainly here and the
            // fraction is left to `syncBarToPlayer`, which reads the item's own player on the next
            // tick and draws where that clip actually is. Computing the fraction here would be
            // arithmetic on a claim the arriving view has not made yet — the session still names the
            // story being left at this instant — so it could only ever be the wrong number, dressed
            // up as care.
            timerProgress = CGFloat(idx)
            // ⚠️ AND THE HOST IS TOLD IN THE SAME BREATH, WHICH IS THE WHOLE OF THE TAP FIX.
            //
            // The item has changed HERE — `timerProgress`'s integer part is what selects it — but the
            // report that says so lives on the 20fps timer, so the host learned it up to a tick later
            // and on a different runloop turn. The row waits for that report before it moves (it is
            // what `liveStoryId` is built from), so the picture swapped on one clock and the layout
            // sprang on another, which is the tap looking nothing like the swipe.
            //
            // Reporting it from the statement that causes it puts both on one clock. The latch is
            // written too, so the timer does not report the same id a second time a tick later.
            if lastChangedItem != id {
                lastChangedItem = id
                onItemChanged?(id)
            }
            // ⚠️ AND THE WINDOW IS NOT TOUCHED HERE EITHER. It moved with the row, in the row's own
            // layout pass, several frames before this settle — which is their ordering: the pass that
            // lays an item out is the pass that decides it is still valid.
        }
        // Seamless per-item delete (host trash tap). Compute the adjacent index FIRST, then drop the item from
        // THIS bucket in-place and slide to it — the user never sees a blank frame. The host removes it from the
        // database off the back of storyItemDeleted. Only the currently-shown bucket reacts.
        .onReceive(NotificationCenter.default.publisher(for: .deleteCurrentStoryItem)) { _ in
            guard viewModel.currentStoryUser == model.id else { return }
            let idx = getCurrentIndex()
            guard idx >= 0, idx < model.stories.count else { return }
            let deletedId = model.stories[idx].id
            // Case 3 — only one story left: let the host delete + dismiss the whole viewer (no seamless slide).
            if model.stories.count <= 1 {
                NotificationCenter.default.post(name: .storyItemDeleted, object: deletedId)
                return
            }
            // Cases 1 & 2 — compute the target BEFORE mutating: next item if there is one, else the previous.
            let nextIndex = idx < model.stories.count - 1 ? idx : idx - 1
            // Clear the pause/advance latches WITHOUT resetting timerProgress (resetProgress would jump to 0).
            isAdvancing = false; isPaused = false; isTimerRunning = false
            isAnimationStarted = false; isFolding = false; captionExpanded = false
            withAnimation(.easeInOut(duration: 0.18)) {
                model.stories.remove(at: idx)
                timerProgress = CGFloat(max(0, nextIndex))
            }
            NotificationCenter.default.post(name: .storyItemDeleted, object: deletedId)
        }
        // THE DATA CHANGED UNDER AN OPEN VIEWER — swap the items in place, keep the person where
        // they are. Built for an upload finishing in the background (host's 2026-08-09 report: the
        // whole viewer used to be torn down and recreated at that moment, on whatever story you were
        // watching). Same architecture as the delete above: this page's `@State` copy is the truth
        // the screen reads, so it is the thing to update.
        //
        // The watched item is re-found BY ID, and only the index part of the clock moves — the
        // fraction rides so the bar does not blink backwards for an unrelated change. A watched item
        // whose id VANISHED is the placeholder that just became the real story: same slot, so the
        // screen keeps the same picture (its bytes were seeded at post time) and the segment restarts.
        .onReceive(NotificationCenter.default.publisher(for: .storyItemsReconciled)) { note in
            guard let payload = note.object as? StoryItemsReconcile,
                  payload.bucketId == model.id,
                  !payload.stories.isEmpty else { return }
            let oldIndex = getCurrentIndex()
            let watchedId = (oldIndex >= 0 && oldIndex < model.stories.count) ? model.stories[oldIndex].id : nil
            model.stories = payload.stories
            // The pager builds FUTURE pages from the shared list — it must agree with this one.
            if let bi = viewModel.stories.firstIndex(where: { $0.id == model.id }) {
                viewModel.stories[bi].stories = payload.stories
            }
            let frac = timerProgress.isFinite ? timerProgress - CGFloat(Int(timerProgress)) : 0
            if let watchedId, let ni = model.stories.firstIndex(where: { $0.id == watchedId }) {
                if ni != oldIndex { timerProgress = CGFloat(ni) + frac }
            } else {
                timerProgress = CGFloat(min(max(0, oldIndex), model.stories.count - 1))
            }
        }
    }
}

// MARK: Private Configuration
private extension StoryDetailView {
    
    @ViewBuilder
    func getStoryView(with index: Int, story: Story) -> some View {
        switch story.config.mediaType {
        case .image:
            // Round the card in UIKit as well (a SwiftUI clip doesn't clip the blurred backdrop).
            // Applies to reply-bar (friend) cards AND my own story (isMine) — my own card is rounded but
            // uses the library's UIKit dismiss now, so the corners must live here, not in an app-level
            // clip (an app clip pinned the card and broke the smooth dismiss).
            //
            // ⚠️ `cardRadius`, NOT A 24 OF ITS OWN, AND ALL FOUR CORNERS RATHER THAN THE BOTTOM TWO.
            // A photo wearing a hard 24 under the page's soft 12 is exactly the two-corner card he
            // photographed. One number, one shape, and the clip above draws the same curve on top of
            // this one instead of arguing with it.
            ImageView(imageURL: story.mediaURL,
                      previewURL: story.previewURL,
                      // ⚠️ AND THE COVER THAT ARRIVED WITH THE STORY, which this branch never
                      // received. The video branch below has had it since it was written; a photo
                      // with nothing cached had only the grey shimmer to fall back to, and that is
                      // the black card between one item and the next. See `ImageView.blurThumb`.
                      blurThumb: story.blurThumb,
                      cardCornerRadius: (story.config.storyType != .plain() || model.isMine) ? cardRadius : 0,
                      isCaptureProtected: story.isCaptureProtected) {
                start(index: index)
            }
            // ⚠️ NOTHING HAPPENS HERE ANY MORE, AND THAT IS THE POINT. This branch used to carry an
            // `.onAppear` that photographed the outgoing clip's frame and then threw the whole
            // `AVPlayer` away (`rememberPlaybackState()` + `resetAVPlayer()`), because the player
            // belonged to this PAGE and so outlived the view that was using it — a photo arriving
            // meant a live clip was left holding the audio with nobody to stop it.
            //
            // An item owns its player now. A photo replacing a video dismantles the video's view,
            // which releases its player (or hands it to the store, paused, while the sheet is up).
            // There is nothing for this page to clean up and no frame for it to catch in flight.
        case .video:
            // ⚠️ `.id` IS LOAD-BEARING AND IS THE WHOLE CHANGE. Without it SwiftUI reuses the
            // representable's view across items and we are back to one player being handed clip
            // after clip. With it, a different clip is a different view: a new player, born at zero,
            // that has never held anybody else's item.
            StoryVideoContent(
                storyId: story.id,
                storyURL: story.mediaURL,
                posterURL: story.previewURL,
                blurThumb: story.blurThumb,
                session: video,
                isCaptureProtected: story.isCaptureProtected
            )
            // ⚠️ KEYED ON THE STORY'S ID, NOT ITS URL. Four places have to agree about what "this
            // clip" means — this identity, the view store, the session's claim and the carousel
            // card — and while they keyed on the media url they derived it three different ways
            // (the raw string here, `URL(string:)?.absoluteString` inside the view, the model's
            // string again in the progress bar). Any normalisation `URL` performs breaks all of
            // them at once, and two items that somehow shared a url would share one view and one
            // claim: the second would open with the player parked at the end of the first, on a
            // full bar, with the end already consumed and no way forward.
            .id(story.id)
            .onAppear {
                // The item's own duration refines the declared one through the session, read on the
                // tick. Nothing to plumb: `start` only marks the item ready so the bar may move.
                start(index: index)
                syncVideoMode()
            }
        }
    }
    
    @ViewBuilder
    func getEmojiView(story: Story) -> some View {
        let index = getCurrentIndex()
        switch story.config.storyType {
        case .message(_, let emojis, _):
            if let emojis, showEmoji {
                VStack {
                    Spacer()
                    EmojiView(
                        story: getStory(with: index),
                        emojiArray: emojis,
                        startAnimating: $startAnimate,
                        selectedEmoji: $selectedEmoji,
                        userClosure: userClosure
                    )
                    // ⛔ THE KEYBOARD'S OWN CURVE, NOT A SPRING — his "the reply bar is coming late, it
                    // is going under the keyboard". A spring's `response` is its NATURAL PERIOD, not
                    // its arrival time, so a critically damped one handed the keyboard's 0.25 is
                    // still moving well after the keyboard has stopped. The bar never started late;
                    // it was on a curve that runs longer than the thing it travels with, so the keys
                    // overtook it every time. See `KeyboardManager.systemAnimation` for the
                    // reference app's dispatcher and where the bezier comes from.
                    .animation(keyboardManager.systemAnimation, value: messageViewPosition)
                    .offset(y: emojiViewPosition)
                    .opacity(messageViewPosition == 0 ? 0 : 1)
                }
                
                if startAnimate {
                    EmojiReactionView(
                        dissmis: $startAnimate,
                        isAnimationStarted: $isAnimationStarted,
                        emoji: selectedEmoji
                    )
                    // ⚠️ THE LATCH IS RELEASED BY THE VIEW GOING AWAY, NOT ONLY BY THE ANIMATION
                    // FINISHING — and that difference froze the whole page.
                    //
                    // `isAnimationStarted` is raised in this view's `onAppear` and lowered ONLY in
                    // its `didCompletedAnimation`. But it lives inside `if let emojis, showEmoji`,
                    // and `MessageView` sets `showEmoji = text.isEmpty` — so typing one character
                    // into the reply box unmounts it mid-flight and that completion never runs.
                    // The flag then stands for ever, and it drives two things at once:
                    // `isTimerRunning` (the bar stops) and `isTapDisabled` (both tap zones die). Tap
                    // a reaction, type a letter, and the story is completely inert.
                    //
                    // `onDisappear` is the honest end of this view by every route it can leave, and
                    // it is idempotent with the normal completion, which has already set it false.
                    .onDisappear { if isAnimationStarted { isAnimationStarted = false } }
                }
                
            }
        case .plain:
            EmptyView()   // was Divider() — drew a faint hairline across the screen centre on plain stories
        }
    }

    @ViewBuilder
    func getUserInfoAndProgressBar(with index: Int) -> some View {
        let date = getStoryOrNil(with: index)?.date ?? ""
        // PER STORY, read from the item on screen right now — not from the bucket. An author
        // with ten stories up posted them to different audiences, and the header has to follow
        // the one you are looking at as you tap through them.
        let audience = getStoryOrNil(with: index)?.audience
        // PER ITEM, like the audience pill beside it: a tray holds several stories and only some of
        // them can have their viewers changed. See `Story.canEditAudience`.
        let canEditAudience = getStoryOrNil(with: index)?.canEditAudience ?? false
        // Per item too: one tray can hold a public story and a friends-only one. See `Story.isPublicStory`.
        let isPublicStory = getStoryOrNil(with: index)?.isPublicStory ?? false
        let name = model.user.name
        let image = model.user.image
        VStack {
            HStack(spacing: Constant.progressBarSpacing) {
                ForEach(model.stories.indices, id: \.self) { index in
                    ProgressBarView(
                        timerProgress: timerProgress,
                        index: index
                    )
                }
            }
            .padding(.horizontal)
            // 8 FROM THE CARD'S TOP, not from the screen's. This used to add `winInsets.top` because
            // the chrome was overlaid on the whole screen and had to clear the notch itself. The card
            // already begins below the notch, so keeping that here would push the bars 67pt down
            // INSIDE the story. The reference app's sit about 7 below its card's top edge.
            .padding(.top, 8)
            .padding(.bottom, 8)
            UserView(
                image: image,
                name: name,
                isVerified: model.user.isVerified,
                date: date,
                audience: audience,
                onProfile: { onProfile?(model.user) },
                showMore: showMore,
                isMyStory: model.isMine,
                canEditAudience: canEditAudience,
                isPublicStory: isPublicStory,
                isPresented: $isPresented
            )
        }
    }
    
    @ViewBuilder
    func messageView(with index: Int) -> some View {
        let story = getStory(with: index)
        // Reply-bar (friend) stories sit on a SOLID BLACK footer bar, not floating over
        // the photo — the media ends at the top of this bar. Own/plain stories render an empty reply
        // area (they use the app's own black footer), so they get a clear background here.
        // Solid black footer ONLY when the keyboard is CLOSED. When you tap to reply, the bar rises
        // with the keyboard, and a black block riding up between the photo and the keyboard looked
        // bad — so while the keyboard is open the background is clear and the reply pill floats.
        let showBlackFooter = story.config.storyType != .plain() && !keyboardManager.isKeyboardOpen
        return MessageView(
            story: story,
            showEmoji: $showEmoji,
            userClosure: userClosure
        )
        .padding()
        .padding(.bottom, winInsets.bottom)   // keep the reply bar above the home indicator (host no longer insets)
        .background(showBlackFooter ? AnyView(Color.black.ignoresSafeArea(edges: .bottom)) : AnyView(Color.clear))
        // GONE FOR THE WHOLE FLIGHT. It sits below the card and does not move with it, and that black
        // footer would be a bar of black across the bottom of the chat list while the story flew home.
        // Another mainstream messenger does the same: at rest there is a reply bar, and the instant the pull starts it
        // is not there. See `flightActive`.
        // ⚠️ THE FADE ONLY, NO TRAVEL — his 2026-08-17 word. The same line as the owner bar above,
        // deliberately, so one bar can never arrive differently from the other; the long version of
        // why the entry animation went away is at that site.
        .opacity(flightActive ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: flightActive)
        // Ride the keyboard's own timing (critically-damped spring keyed to the keyboard duration):
        // front-loaded like the keyboard, so the reply pill stays just above the keyboard's top edge
        // the whole way up instead of trailing behind it and popping in at the end (user: "bar comes
        // after the keyboard — make it same time").
        // ⛔ THE KEYBOARD'S OWN CURVE, NOT A SPRING — his "the reply bar is coming late, it
                    // is going under the keyboard". A spring's `response` is its NATURAL PERIOD, not
                    // its arrival time, so a critically damped one handed the keyboard's 0.25 is
                    // still moving well after the keyboard has stopped. The bar never started late;
                    // it was on a curve that runs longer than the thing it travels with, so the keys
                    // overtook it every time. See `KeyboardManager.systemAnimation` for the
                    // reference app's dispatcher and where the bezier comes from.
                    .animation(keyboardManager.systemAnimation, value: messageViewPosition)
        .offset(y: messageViewPosition)
    }

    /// ⚠️ A STRAIGHT FADE IS A HEAVY FADE, and that is his 2026-08-09 "caption shadow is too much,
    /// use the shadow the reference app is using".
    ///
    /// Both of ours were `LinearGradient(colors:)`, which puts a stop at each end and interpolates
    /// evenly between them. The reference app's are not straight. It generates EIGHT stops and runs the alpha
    /// through `bezierPoint(0.42, 0.0, 0.58, 1.0, step)` — CSS ease-in-out — so the fade leaves the
    /// picture almost untouched for its first third and does its darkening low down, near the text
    /// that needs it (`StoryContentCaptionComponent`, `StoryItemSetContainerComponent`).
    ///
    /// The difference is not subtle where he drew his line. At a quarter of the way down the band a
    /// straight ramp is already at 25% of peak; theirs is at 4%. Same peak, same height, and one of
    /// them reads as a shadow while the other reads as a grey band across the picture.
    ///
    /// The numbers below ARE theirs, their own easing sampled at their own eight stops and divided
    /// by the peak so one table serves both scrims.
    private static func scrimStops(peak: Double) -> [Gradient.Stop] {
        let eased: [(CGFloat, Double)] = [
            (0.000000, 0.000000), (0.142857, 0.040904), (0.285714, 0.169701),
            (0.428571, 0.378431), (0.571429, 0.621569), (0.714286, 0.830299),
            (0.857143, 0.959096), (1.000000, 1.000000),
        ]
        return eased.map { .init(color: .black.opacity(peak * $0.1), location: $0.0) }
    }

    // Top dark scrim so the header (username, avatar, X) stays readable on white/bright stories.
    // The reference app's numbers: black, 40% at the very top, eased away to nothing 90pt down
    // (`topGradientHeight: CGFloat = 90.0`, and its own gradient asset peaks at 102/255).
    // Ours was 50% over 130pt and straight, so it was heavier in every part of the band at once.
    var topScrim: some View {
        LinearGradient(stops: Self.scrimStops(peak: 0.4), startPoint: .bottom, endPoint: .top)
            .frame(height: 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }

    /// THE STICKERS THAT STILL DO SOMETHING. Invisible rectangles laid over the picture exactly where
    /// the author left them — the drawing is already in the media, so there is nothing to draw here.
    ///
    /// ⚠️ NOTHING IS HIT-TESTABLE EXCEPT THE RECTANGLES THEMSELVES. A full-size transparent layer
    /// over a story is a layer that eats the tap which advances it, and this screen has paid for that
    /// mistake twice already (the caption's expand target, the trim page's wash). The container is
    /// `allowsHitTesting(false)` and each area turns its own touches back on, so a tap anywhere else
    /// on the card reaches the story exactly as before.
    ///
    /// ⚠️ AND NOT WHILE THE CHROME IS DOWN. A hold pauses the story and the viewers sheet drags it
    /// away; a link that fires from either would be a link nobody meant to press.
    @ViewBuilder
    func tapAreas(_ story: Story) -> some View {
        if !story.taps.isEmpty {
            GeometryReader { geo in
                ZStack {
                    ForEach(story.taps) { t in
                        Color.clear
                            .frame(width: max(24, geo.size.width * t.w),
                                   height: max(24, geo.size.height * t.h))
                            .contentShape(Rectangle())
                            .rotationEffect(.radians(t.rotation))
                            .position(x: geo.size.width * t.x, y: geo.size.height * t.y)
                            .allowsHitTesting(true)
                            .onTapGesture { openTapArea(t) }
                    }
                }
            }
            .allowsHitTesting(!isHolding && !chromeHidden && !flightActive)
        }
    }

    /// Opening one. The library has no idea what is at the other end and does not need to: the URL
    /// was already narrowed to http/https on the way in (see the host's `StoryTapTarget.from`), and a
    /// place sticker is a maps URL, which is the same kind of thing.
    private func openTapArea(_ t: StoryTapArea) {
        UIApplication.shared.open(t.url)
    }

    // The caption component: 16pt regular white text with a soft shadow, left-aligned,
    // 16pt side padding, sitting over a 128pt black gradient (0 → 80%). Collapsed to 3 lines; tap to expand.
    @ViewBuilder
    func captionView(_ text: String, plain: Bool = false) -> some View {
        if !text.isEmpty {
            ZStack(alignment: .bottomLeading) {
                // Backs the CAPTION only. It used to be 210 because the reply bar floated over the
                // media and needed darkening too; the bar sits below the card now, so a fade that
                // tall just dimmed a third of the picture for nothing.
                // The reference app's caption scrim exactly: black, 0.8 at the bottom, 128pt tall, and eased
                // rather than straight — see `scrimStops`. The peak and the height were already
                // its; the straight ramp between them is what he photographed.
                LinearGradient(stops: Self.scrimStops(peak: 0.8), startPoint: .top, endPoint: .bottom)
                    .frame(height: 128)
                    .allowsHitTesting(false)
                // Our own design (clean, story-style): bottom-LEFT, no hard line, over the soft fade.
                // LINKS IN A CAPTION ARE REAL LINKS (his 2026-08-09 "caption must be work Link"):
                // detected once per render, tappable in place, opening through the system. The
                // expand/collapse tap below keeps every non-link touch — SwiftUI routes a touch on
                // a link run to the link and everything else to the gesture. @mentions are
                // deliberately NOT styled yet: a highlighted mention that goes nowhere is a fake
                // feature, and the mention system (friends-only notify) is its own build.
                Text(Self.captionWithLinks(text))
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4)
                    .multilineTextAlignment(.leading)
                    .lineLimit(captionExpanded ? 12 : 3)   // cap expansion so a long caption can't overrun the header
                    .padding(.horizontal, 16)
                    // A GAP FROM THE CARD'S BOTTOM EDGE, and nothing else.
                    //
                    // This used to add the whole reply-footer height and the home-indicator inset on
                    // top, because the media ran to the bottom of the SCREEN and the reply pill
                    // floated over it, so the caption had to be lifted clear of a bar that was inside
                    // its own frame. The card ends above the reply bar now — `cardHeight` subtracts
                    // exactly that footer — so the old lift pushed the caption a further ~130pt up
                    // and left it stranded in the middle of the picture, which is what he circled.
                    //
                    // 14 IN BOTH CASES (owner 2026-08-06: "slightly too high… make it like the reference app").
                    // It was 28 on my own story and 16 on a friend's — two numbers for one thing, and
                    // the bigger one is the one he photographed sitting too far up. The reference app puts its
                    // caption the same short distance off the bottom edge whatever the story is, and
                    // the reply bar cannot be the reason for a difference any more: it sits BELOW the
                    // card now, not over the picture.
                    .padding(.bottom, 14)
                    .contentShape(Rectangle())
                    .onTapGesture {   // tap expands/collapses; consumes the tap so it doesn't advance the story
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { captionExpanded.toggle() }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
    }

    /// The caption with every URL made tappable. White and underlined rather than blue: the caption
    /// sits on a photograph behind a dark fade, and blue-on-anything is the one colour combination
    /// that can vanish there; the underline is what says "link" on every backdrop. Bare domains
    /// count (NSDataDetector supplies the scheme), which is how people actually type them.
    static func captionWithLinks(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let full = NSRange(text.startIndex..., in: text)
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in det.matches(in: text, range: full) {
                guard let url = m.url,
                      let sr = Range(m.range, in: text),
                      let ar = Range(sr, in: a) else { continue }
                a[ar].link = url
                a[ar].underlineStyle = .single
                a[ar].foregroundColor = .white
            }
        }
        // @MENTIONS. Semibold and NOT underlined, so the two kinds of tappable text stay tellable
        // apart at a glance — a link goes out of the app, a mention goes to a person inside it.
        //
        // They carry our own scheme rather than a real url: the host resolves the username against
        // the app's username collection and opens that profile (see `StoryMention`). The library has
        // no idea who anybody is, and it must not start knowing.
        //
        // ⚠️ The pattern demands a letter first and allows 2-30 of [A-Za-z0-9_.] after it, which is
        // the app's own username rule. Being STRICTER than the rule would leave real mentions dead;
        // being looser would light up an email's domain half, which the detector above has already
        // claimed as part of a link.
        if let re = try? NSRegularExpression(pattern: "@([A-Za-z][A-Za-z0-9_.]{1,29})") {
            for m in re.matches(in: text, range: full) {
                guard let sr = Range(m.range, in: text),
                      let ar = Range(sr, in: a),
                      a[ar].link == nil,   // already part of a url (an email's tail) — leave it alone
                      let nr = Range(m.range(at: 1), in: text),
                      let url = StoryMention.url(for: String(text[nr]).lowercased())
                else { continue }
                a[ar].link = url
                a[ar].foregroundColor = .white
                a[ar].font = .system(size: 16, weight: .semibold)
            }
        }
        return a
    }

    @ViewBuilder
    func tapStory() -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.black.opacity(0.01))
                    .frame(width: geo.size.width / 3)   // left third = back (smaller back zone)
                    .onTapGesture { tapPreviousStory() }
                Rectangle()
                    .fill(.black.opacity(0.01))
                    .onTapGesture { tapNextStory() }     // right two-thirds = next
            }
            // ⚠️ ONE GESTURE, AND IT STAYS ALIVE UNTIL THE FINGER LEAVES. Read this before moving
            // anything — this area has swung four times now. [[kulan-story-hold-pause-instant]].
            // ⚠️ `.simultaneousGesture`, NEVER `.gesture`, AND THIS COST HIM THE 3D CUBE.
            //
            // `.gesture` CLAIMS the touch. The pager's page turn is a UIScrollView underneath this
            // overlay, and the cube's fold is only computed while that scroll view is actually
            // moving (`StoryPager.applyCube` folds nothing at rest). So a
            // SwiftUI gesture that takes the touch first does not merely compete with the page
            // swipe — it stops the scroll view from ever entering a tracking state, and the fold
            // never runs. His report on the last beta: the 3D cube scroll is not working.
            //
            // [[kulan-scroll-gesture-rules]] says this in as many words, and `StoryCameraView` says
            // it again next to its own swipe: a gesture that claims the touch eats both. The
            // sequenced drag inside `holdGesture` is what made it claim; simultaneous lets the
            // scroll view see the same touches, and the long press still fails at
            // `maximumDistance: 10`, so a real swipe cancels the hold exactly as it should.
            .simultaneousGesture(holdGesture)
            // The pause and the resume both hang off the phase, so there is exactly one place where
            // a finger changes what the story is doing.
            // ⚠️ THE ONE-PARAMETER FORM, because this file is in the StoryUI package and that
            // deploys below iOS 17 — `onChange(of:initial:_:)` is 17+ and the app module's use of it
            // elsewhere does not carry over here. The value handed in is the NEW one.
            .onChange(of: pressPhase) { phase in
                switch phase {
                case .down, .holding:
                    // The keyboard owns the pause while a reply is being composed; a finger on the
                    // story must not take it over. ⚠️ ON THE PAUSE SIDE ONLY — guarding the release
                    // as well would strand a hold whose finger left while the keyboard came up.
                    guard !keyboardManager.isKeyboardOpen else { return }
                    if !isPaused { isPaused = true; syncVideoMode() }
                    // The chrome fade waits for the HOLD, never the touch — his other report ("when
                    // i click story normal story pause": every tap would blink the header). The
                    // pause is instant, the fade is not. Two clocks on purpose.
                    if phase == .holding, !isHolding { isHolding = true }
                case .idle:
                    // The finger has gone, but the APP may have gone too — see the `scenePhase`
                    // handler. A release that resumes while backgrounded plays a story nobody can
                    // see; `.active` owns that resume and hands it back itself. `isHolding` still
                    // comes down, because the hold is genuinely over and it must not cross stories.
                    isHolding = false
                    guard !scenePaused else { return }
                    if isPaused { isPaused = false; syncVideoMode() }
                }
            }
        }
    }

    /// ⚠️ `onLongPressGesture`'s "no longer pressing" IS NOT THE FINGER LIFTING, and everything that
    /// went wrong here came from reading it as if it were.
    ///
    /// A SwiftUI long press ENDS the moment it succeeds. `perform` runs at `minimumDuration` and the
    /// gesture is over — the finger can stay down for another ten seconds and nothing further is
    /// reported. So the old code had a down edge and a confirm and NO release, and every attempt to
    /// work around that made a different half of it wrong:
    ///
    ///  · Pausing at the 0.25s engage strands the pause forever when a UIKit recogniser steals the
    ///    touch (page pan, dismiss pan) — his "paused without reason" reports.
    ///  · Pausing on the down edge is instant, which he asked for, but then nothing trustworthy ever
    ///    says to un-pause.
    ///  · The loan that bridged the two is what he is reporting NOW. It pauses on touch-down and
    ///    starts a 0.35s clock, and a collector on the bar's 0.05s tick cancels the pause if no hold
    ///    has confirmed by then. The hold confirms at 0.25s. **The whole design rested on 100ms of
    ///    margin on the main thread**, which is decoding video and running a 20fps timer — so the
    ///    tick lands late, the collector fires first and resumes, and `perform` arrives a moment
    ///    later and pauses again. Pause, play, pause, with the finger never moving. Exactly his
    ///    words, and the arithmetic was always going to lose that race eventually.
    ///
    /// A press-and-hold needs a gesture that is still running while the finger is down, so this is
    /// the standard shape for one: the long press SEQUENCED before a drag. The drag becomes the
    /// active half only after the press has already succeeded, and it then lives until the touch
    /// ends. `@GestureState` is reset by SwiftUI when a gesture ends or is cancelled, and that reset
    /// is guaranteed — including when another recogniser takes the touch away, which is the case
    /// every previous attempt died on. There is no clock, no loan, no collector and no race.
    ///
    /// ⚠️ THE `minimumDistance: 0` DRAG IS NOT THE ONE [[kulan-scroll-gesture-rules]] FORBIDS. That
    /// rule is about a bare zero-distance drag claiming a touch the scroller needed. This one cannot:
    /// it is unreachable until the long press has already won, and the long press still fails at
    /// `maximumDistance: 10`, so a swipe is arbitrated exactly as it was before.
    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($pressPhase) { value, state, _ in
                switch value {
                case .first(_):     state = .down      // finger is down, not yet a hold
                case .second(_, _): state = .holding   // the press won; the drag holds it open
                }
            }
    }
    
    // DELETED HERE: `getAngle(proxy:)`, the SwiftUI half of the cube. See the note at the
    // `rotation3DEffect` it fed, in `body`. It derived 45° from a GeometryReader's global minX,
    // which cannot follow a finger, and it was gated off whenever the real cube was running — so it
    // was a fold that could only ever return zero. `StoryPager.applyCube` owns the fold.
    
    // DELETED HERE: `resumeFraction(at:)`. It topped the bar up to a REMEMBERED playback position
    // so bar and player could resume together. There is no remembered position any more — a video
    // returned to restarts from zero (the owner's 2026-08-11 rule, the reference app's behaviour) — so its
    // two call sites hand the bar a bare index and the player starts the clip at its beginning.
    // Left as a note because a function that used to exist is a function somebody will reinvent.

    /// `keepPosition` is the DEPARTING page's variant of this reset, and it exists for one reason:
    /// the page being left is still on screen. `UIPageViewController` slides it off over ~0.3s, and
    /// `timerProgress` is what the body DRAWS — zeroing it re-rendered the page onto item 0 in the
    /// first frame of the slide, so a person left on their last story visibly snapped back to their
    /// first while flying off (his 2026-08-10 report). It also made the departing page's `VideoView`
    /// swap to item 0's url and start loading a clip nobody is watching. So the machinery latches
    /// all still clear, and only the picture stays. Safe because the tick's advancing work is gated
    /// on `isCurrent` (`startProgress`), and the position is wiped properly the next time this page
    /// becomes current — the `newValue == model.id` branch runs the full reset and then restores.
    func resetProgress(keepPosition: Bool = false) {
        if !keepPosition {
            timerProgress = 0
        } else if timerProgress >= CGFloat(model.stories.count) {
            // ⚠️ A BUCKET THAT FINISHED MUST NOT BE LEFT SAYING SO. HIS 2026-08-14 REPORT, EXACTLY.
            //
            // "When I am watching my story and the image finishes, it automatically advances to my
            // friend's story. Then when I swipe back toward my own story, I can see my own story
            // during the swipe, but as soon as I release my finger it jumps back to my friend's."
            //
            // `timerProgress` counts items, so reaching `count` IS the sentence "this person is
            // finished" — it is what the tick tests to fire the advance. Keeping the position on the
            // way out is right, and it is what leaves the picture up through the slide, but it also
            // kept THAT. So the page went away still finished, and the moment it was handed the
            // screen again — at the commit of the back swipe, before `onChange` had restored the
            // remembered item one runloop later — the very next 20fps tick read "finished" and fired
            // the advance again. Release the finger, and it is on the friend.
            //
            // ⚠️ THIS IS WHY THE TAP DID NOT DO IT and the auto-advance did, which is the whole of
            // what he narrowed down for me. `tapNextStory` reaches the next person WITHOUT moving
            // `timerProgress` past the last item — it tests `Int(timerProgress) + 1 >= count` and
            // calls `updateStory()` — so a tapped-away page is left mid-item and reads as unfinished.
            // Only the timer's own crossing leaves it at `count`.
            //
            // A hair under, rather than zero: `getCurrentIndex` floors this, so `count - 0.0001` is
            // still the SAME last item and the departing page keeps the exact picture it had. What
            // it loses is only the claim to be finished.
            timerProgress = max(0, CGFloat(model.stories.count) - 0.0001)
        }
        isAdvancing = false
        isPaused = false   // safety: never carry a stuck pause across a user switch (R1 freeze fix)
        scenePaused = false
        // AND THE HOLD LATCH, which was the one missing from this list. It matters more now that
        // `playVideo` refuses while it stands: a hold whose release was eaten by the page pan —
        // the exact case the gesture's guaranteed reset now covers — would carry `isHolding` into
        // the next person and their video would never start, with the bar running over a still
        // picture. Kept as a belt: this costs nothing and the flag has no business crossing stories.
        isHolding = false
        // ⚠️ AND THE BUFFERING LATCH, which was the one that could never come back down.
        //
        // The reference app does not store this at all: `isBuffering` is recomputed as a LOCAL on every
        // progress tick and handed straight to the bar (in the reference implementation's
        // progress update), so it cannot survive anything. Ours is a flag written only
        // by a notification, and the notification had a one-way door in it: the receiver drops any
        // message addressed to a page that is no longer current, while `VideoLoader.setBuffering` is
        // edge-deduped per view and so never sends `false` twice. Swipe away from a stalled video
        // and back, and the bar was frozen for that person for the rest of the session with the
        // video happily playing underneath it.
        //
        // Clearing it on a person switch is the same rule every other latch here already follows,
        // and `VideoLoader.startVideo` now re-arms its own edge so a fresh clip can announce again.
        isBuffering = false
        // Clear every pause latch too, or a new bucket can start permanently frozen (stuck-state bug).
        isTimerRunning = false
        isAnimationStarted = false
        isFolding = false
        captionExpanded = false   // collapse the caption when moving to another story
    }
    
    func getPreviousStory() {
        // Index guard (was `?? 0` then `[index - 1]` → crash if this bucket ever left the array).
        if let bundleIndex = viewModel.stories.firstIndex(where: { model.id == $0.id }), bundleIndex > 0 {
            // ⚠️ NO `withAnimation` HERE, AND PUTTING ONE BACK COSTS HALF A SECOND FOR NOTHING.
            //
            // This used to be wrapped in a bare `withAnimation`, which is SwiftUI's default spring —
            // about a 0.55s response. Nothing it could animate was on screen: the page move belongs
            // to `UIPageViewController`, which reads its own duration and ignores SwiftUI entirely.
            // So the spring drove no visible motion and only held the state change, and everything
            // waiting behind it, in a slow transaction. Measured against the reference app's ~0.3s
            // peer-to-peer move, this was the largest single piece of our ~0.9s.
            viewModel.currentStoryUser = viewModel.stories[bundleIndex - 1].id
        } else {
            let index = getCurrentIndex()
            let story = getStory(with: index)
            if story.config.mediaType == .video {
                // Tapping back past the first story of the first person restarts what is playing.
                // Addressed to THIS page's item instead of broadcast to every mounted player, which
                // is what `.stopAndRestartVideo` did — a bare `seek(to: .zero)` on whichever players
                // happened to be alive.
                video.restart()
            }
            resetProgress()   // restart the current segment (image OR video) — was a no-op for images
        }
        return
    }
    
    func getNextStory() {
        let index = getCurrentIndex()
        let story = getStory(with: index)
        
        if let last = model.stories.last, last.id == story.id {
            if let lastBundle = viewModel.stories.last, lastBundle.id == model.id {
                withAnimation {
                    dissmis()
                }
            } else {
                // ⚠️ `?? 0` USED TO BE HERE AND IT IS THE BUG HE REPORTED AS A BLACK SCREEN.
                //
                // "Not found" was being turned into "you are the first person", so the end of a
                // bucket that is not in `viewModel.stories` navigated to `stories[1]` from wherever
                // you actually were — and the pager, asked to move to a person it could not
                // reconcile with the page on screen, placed nothing at all. `syncIfNeeded` returns
                // early when either of its two index lookups fails, and a return that places nothing
                // is a blank screen. Then the next update repopulated from `currentStoryUser` and
                // his own story came back, which is his report exactly: black for a second, then his
                // own story again, never the next person.
                //
                // ⚠️ AND THE SUBSCRIPT BELOW WAS UNCHECKED. `stories[bundleIndex + 1]` on the last
                // index is a crash, and the guard above it tests `model.id` too — so the one input
                // that could be wrong was gating both branches.
                //
                // Their rule, read from `StoryContainerScreen.navigate(direction:)`: at the end of a
                // peer they ask whether a NEXT SLICE exists, and if it does not they
                // `controller.dismiss()`. There is no branch in which nothing happens. So an
                // unresolvable position dismisses here too — the viewer has run out of people to
                // show, which is the honest reading of "I cannot find where I am".
                guard let bundleIndex = viewModel.stories.firstIndex(where: { model.id == $0.id }),
                      viewModel.stories.indices.contains(bundleIndex + 1) else {
                    withAnimation { dissmis() }
                    return
                }

                // ⚠️ NO `withAnimation` HERE, AND PUTTING ONE BACK COSTS HALF A SECOND FOR NOTHING.
                //
                // This used to be wrapped in a bare `withAnimation`, which is SwiftUI's default spring —
                // about a 0.55s response. Nothing it could animate was on screen: the page move belongs
                // to `UIPageViewController`, which reads its own duration and ignores SwiftUI entirely.
                // So the spring drove no visible motion and only held the state change, and everything
                // waiting behind it, in a slow transaction. Measured against the reference app's ~0.3s
                // peer-to-peer move, this was the largest single piece of our ~0.9s.
                viewModel.currentStoryUser = viewModel.stories[bundleIndex + 1].id
            }
        }
    }
    
    func startProgress() {
        guard !model.stories.isEmpty else { return }   // empty bucket (all expired/deleted) → nothing to index
        // (The loan collector that used to sit here is gone with the loan — see `holdGesture`. It
        // cancelled a touch-down pause that no hold had confirmed within 0.35s, and the hold
        // confirms at 0.25s, so it was racing the main thread over 100ms and losing: it resumed
        // under a finger that had not moved, and the confirm then paused again. The gesture now
        // reports the finger leaving, so there is nothing left for a timer to guess at.)
        // ⚠️ THE LOOKAHEAD IS NOT A SEEN RECEIPT, AND CHAINING IT TO ONE COST EVERY FIRST TAP ONTO A
        // VIDEO ITS FULL DOWNLOAD.
        //
        // The host started the next clips' downloads from `onItemSeen`, and the gate below
        // deliberately withholds that report while the story is paused, held, folded, behind the
        // keyboard — or BUFFERING, which is precisely the state a video is in while it loads. So the
        // clip after this one could not begin downloading until this one had finished downloading
        // and started to play. Tap on, and you are cold again. His "tap left/right to a video and
        // the first time it is a blur or black screen, then in seconds it works": the wait was the
        // download, every time, because the guess that was supposed to have removed it had not been
        // allowed to start.
        //
        // The reference app separates the two outright. `markAsSeen` waits for real playback
        // (the reference implementation), while the preload of the next three items is driven from
        // its own state-change hook — the item CHANGING, nothing else. This is that,
        // on the same list the host used to flatten for us: every story in the viewer in the order
        // they will be watched, across people, so the last item of one warms the first of the next.
        if viewModel.currentStoryUser == model.id {
            let cur = getStory(with: getCurrentIndex())
            // ⚠️ THE MODE IS RE-ASSERTED HERE, AND THAT CLOSES A WHOLE CLASS OF DEAD STORY.
            //
            // `mode` has exactly one writer — `session.setMode` — and for the FIRST video item on a
            // page the only thing that ever calls it is an `.onAppear`. A SwiftUI appearance
            // callback is a single point of failure for "does this story play at all": miss it once,
            // to identity churn or a re-render that reuses the modifier node, and the item mounts
            // with no player, the bar sits frozen, no end ever arrives and nothing recovers. There
            // is no spinner either, because the bytes are loaded.
            //
            // `setMode` → `apply` is fully idempotent (`play()` on a playing player is a no-op), so
            // re-deriving the answer twenty times a second costs nothing and means the mode cannot
            // be lost, only briefly late.
            syncVideoMode()
            // ⚠️ THE BUFFERING HOLD IS READ, NOT RECEIVED, AND THE STALE-HOLD BOOKKEEPING IS GONE.
            //
            // It used to arrive as a `.storyBuffering` notification carrying a url, which the
            // receiver compared against the story it believed was current — and because a report is
            // an EDGE, a `false` posted while its page was being swiped away was dropped by a
            // receiver that no longer recognised the sender, leaving the bar held for good. That is
            // what `bufferingURL` and this stale-hold release existed to repair.
            //
            // The session belongs to the item on screen, so its answer is never somebody else's and
            // never a missed edge: an item with no claim is not buffering, which is the truth.
            let mine = video.claim == cur.id
            let nowBuffering = mine && video.isBuffering
            if nowBuffering != isBuffering { isBuffering = nowBuffering }
            // THE CLIP SAYS IT ENDED; ONLY THEN DOES A VIDEO SEGMENT COMPLETE. The reference app
            // advances a video story from its playback-completed callback alone — ordinary progress
            // updates carry `canSwitch = false` — and this is our half of that, with their
            // `requestedNext` one-shot as `consumeFinished`.
            //
            // ⚠️ AND THE LATCH GOES BACK IF THE ADVANCE IS REFUSED. `updateStory` can decline — a
            // person-turn is animating, or an advance is already in flight — and the end of a clip
            // fires exactly once. Spending the latch on a refused advance meant the player sat at
            // its last frame with nothing left to report, and `syncBarToPlayer` caps the bar at
            // `index + 0.999`, so the arithmetic fallback that used to rescue this can never run
            // either. The story freezes on its final frame under a nearly-full bar, for good.
            // ⚠️ ONE ADVANCE PER TICK, AND THE `else` IS THE WHOLE OF HIS 2026-08-12 BUG.
            //
            // His report: image A hands over to video B correctly, then B ends and the viewer CLOSES
            // instead of going to C. Both tests below read `cur` and `mine`, computed at the TOP of
            // this tick — before an advance moves the story on. So on the very tick the clip's own
            // end report is spent, the second test still sees the departed clip: its claim still
            // matches `cur`, its clock is still parked at its end, and it fires a SECOND advance.
            // Two items in one tick, and on the last-but-one story that second one runs off the end
            // of the bucket, where `updateStory` closes the viewer.
            //
            // They are alternatives, not a sequence: an end that was REPORTED does not also need to
            // be INFERRED. On the next tick `mine` is false — the arriving item has not claimed the
            // session yet — so the inference cannot re-fire on the stale clip either.
            //
            // First: the clip said it ended. ⚠️ The latch goes back if the advance is refused —
            // `updateStory` can decline while a person turn is animating, and a clip reports its end
            // exactly once. Spending it on a refusal left the player at its last frame with nothing
            // to report and the bar capped at `index + 0.999`, so nothing could ever rescue it.
            if !isDismissing, mine, video.consumeFinished() {
                if !advanceFromVideoEnd() { video.rearmFinished() }
            }
            // Second: it reached its end without saying so. Capping the bar under the boundary makes
            // the player's own report the ONLY way out of a video segment, which is the reference
            // app's rule — and it also means a truncated or corrupt clip that plays to its last
            // sample and never emits `AVPlayerItemDidPlayToEndTime` would hold the viewer for ever.
            // The content is here, the item is meant to be playing, the clock has reached the end,
            // and it has stopped moving. Nothing legitimate looks like that.
            else if !isDismissing, mine, video.contentLoaded, !video.isPlaying, videoMode == .play,
                    video.duration > 0, video.timestamp >= video.duration - 0.05 {
                advanceFromVideoEnd()   // a refusal retries on the next tick
            }
            // ⚠️ AND THE HOST IS TOLD WHICH ITEM IS ON SCREEN, HERE, WHERE NOTHING GATES IT.
            //
            // See `onItemChanged`. The host used to learn this from `onItemSeen`, which is the
            // WATCHED receipt below — withheld while paused, held, folding, buffering or behind the
            // keyboard. The viewers sheet pauses the story for its entire life, so anything hanging
            // off that answer (the "Uploading…" bar, the owner's view count) was reading an id that
            // could be pages behind the picture, and stayed there for as long as the sheet was up.
            //
            // This block already exists because the lookahead had the same problem and was moved
            // out of the receipt for the same reason. It runs on the 20fps timer with no pause
            // guard, so the report lands within one tick of the item actually changing.
            if cur.id != lastChangedItem {
                lastChangedItem = cur.id
                onItemChanged?(cur.id)
                // ⚠️ AND EVERY OTHER CLIP GOES QUIET, WHICHEVER WAY THE ITEM CHANGED. The mode above
                // reaches the one view bound to this page's session, which is the right view only
                // while the bind is current — and the one case that matters is exactly when it is
                // not: tapping back from a video to an image, where the video's view has already let
                // go of the session and has nobody left to tell it to stop. This asserts the rule
                // instead of trusting the bind or SwiftUI's teardown timing. See `pauseAllExcept`.
                StoryItemViewStore.pauseAllExcept(cur.id)
                // ⚠️ AND THE EMOJI-ANIMATION PAUSE IS RELEASED WITH THE ITEM. `isAnimationStarted`
                // is raised in the reaction overlay's `onAppear` and lowered in its `onDisappear`,
                // and it is one of `videoMode`'s inputs — so an overlay torn down without its
                // disappear firing would silence every later item of that person, permanently.
                // Nothing in this file is allowed to be able to do that. It was otherwise cleared
                // only by `resetProgress`, which runs on a PERSON change, not an item one.
                if isAnimationStarted { isAnimationStarted = false }
            }
            if cur.id != lastPrefetchItem {
                lastPrefetchItem = cur.id
                // ⚠️ THE ORDER THEY WILL ACTUALLY BE WATCHED, WHICH IS NOT EVERY ITEM OF EVERY
                // PERSON. A flat `flatMap` assumes each person is watched from their item 0, and
                // nobody is: a bucket opens at `resumeIndex()`, normally their first UNSEEN item.
                // So at every person boundary the lookahead warmed items that are about to be
                // skipped and left the one actually landed on cold — paying for data on clips
                // nobody sees AND keeping the wait this feature exists to remove.
                //
                // The bucket being watched keeps every item, because tapping BACK through it is
                // normal and those are already on disk anyway. Later buckets start where they will
                // open. Same rule as `resumeIndex`, minus the per-bucket saved position, which this
                // view cannot see for anybody but itself.
                let all: [Story] = viewModel.stories.flatMap { bucket -> [Story] in
                    guard bucket.id != model.id else { return bucket.stories }
                    let start = bucket.stories.firstIndex(where: { !$0.isSeen }) ?? 0
                    return Array(bucket.stories.dropFirst(start))
                }
                if let i = all.firstIndex(where: { $0.id == cur.id }) {
                    StoryPrefetcher.prefetch(from: i, in: all)
                }
            }
        }
        // Report the ACTUAL current item as seen (per-item, not the whole bucket) — drives accurate
        // view receipts + "Seen by".
        //
        // ⚠️ SEEN MEANS WATCHED, NOT LANDED ON, AND FOR A ONE-TIME STORY THE DIFFERENCE IS THE WHOLE
        // STORY. This fired the moment an item appeared, deliberately ahead of the pause guard. For
        // an ordinary story that is merely generous. For a view-once story it is destructive: the
        // report runs `consumeOneTime`, so auto-advancing INTO one from the previous person's last
        // item, or opening the viewer and immediately swiping down, spends the single view on a
        // story that was never actually watched. It then vanishes and cannot be reopened.
        //
        // The reference app's rule, from the reference implementation: `markAsSeen`
        // is called only once playback reports `.playing` with a real timestamp, and its comment
        // is explicit that a story which never plays is never marked seen. Ours has no player for a
        // photo, so the equivalent is "the clock for this item is actually running": not paused, not
        // held, not frozen behind a sheet or the keyboard, not mid-fold. Every one of those is a
        // moment the person is not watching.
        //
        // This deliberately does NOT wait for a duration — a story looked at for half a second is
        // still watched. It waits only for the state to be watching at all.
        // ⚠️ AND `!isBuffering`, WHICH IS THE DIFFERENCE BETWEEN WATCHED AND MERELY ARRIVED AT.
        //
        // The rule this block argues for is "the clock for this item is actually running". Every
        // flag but one was listed, and the missing one is the flag that says the picture has not
        // appeared yet. So on a slow connection the report fired on the first 50ms tick, over a
        // placeholder, before a single frame existed — and for a VIEW-ONCE story `onItemSeen` runs
        // `consumeOneTime`. The single view was spent on a blank screen and the story could not be
        // opened again. The bar itself already refuses to advance while buffering; this is the same
        // condition applied to the receipt, which is the more expensive of the two to get wrong.
        if viewModel.currentStoryUser == model.id,
           !isPaused, !isHolding, !hostPause.paused, !isFolding,
           !keyboardManager.isKeyboardOpen, !isTimerRunning, !isBuffering {
            let cur = getStory(with: getCurrentIndex())
            if cur.id != lastSeenItem { lastSeenItem = cur.id; onItemSeen?(cur.id) }
        }
        // Pause sources: emoji-fly animation (isTimerRunning), hold-to-pause (isPaused),
        // composing a reply (keyboard open) — and now BUFFERING, because a segment that keeps
        // counting while the video is waiting on bytes will hand the screen to the next story before
        // this one has shown a frame. That is the progress desynchronisation: the bar was measuring
        // time, not playback. It resumes by itself the moment the player reports it is playing.
        //
        // ⚠️ AND `isFolding` CANNOT BE ALLOWED TO STOP THE PAGE THAT IS BEING WATCHED. This is his
        // 2026-08-08 report — "when i open story is opening but is pause sametime… when i watch
        // story A then i go story B is paused first befire dowing any thing… process bar completely
        // stoping" — and the hold was never involved in it.
        //
        // `isFolding` comes from a PREFERENCE carrying `proxy.frame(in: .global).minX`, and it is
        // true whenever the page sits more than 2pt off screen centre. That was sound for the old
        // TabView, where a fold IS a SwiftUI layout and every intermediate position is published.
        // It is not sound now, for one reason: **a GeometryReader re-evaluates on a SIZE change, not
        // on a POSITION change.** `frame(in: .global)` is a snapshot taken whenever the body last
        // ran, so the value is whatever the page's origin happened to be at that moment and there is
        // NO guarantee of another delivery once it settles.
        //
        // Both of his cases are that snapshot landing off-centre:
        //   OPEN — the flight scales and moves the presenter's container above this view, so a body
        //          evaluation during it reads the page at the row card's x, not at 0.
        //   A → B — the page transition moves pages by FRAME; a body evaluation mid-move reads an
        //          off-centre origin, and the page arriving at 0 need not re-run the body at all.
        // Nothing clears it afterwards: `resetProgress` runs BEFORE that snapshot, `onAppear` never
        // touched it, and the preference will not fire again. So the bar stopped dead for the whole
        // visit, which is exactly what he photographed.
        //
        // The fix is to ask the question the app can actually answer. A page that IS the current
        // bucket is the page on screen, whatever some stale geometry says, so the fold gate now only
        // applies to a page that is NOT current — and it is re-evaluated on every 0.05s tick against
        // the live value, so it can never latch again. For a non-current page it changes nothing:
        // the work below is already gated on the same test.
        let isCurrent = viewModel.currentStoryUser == model.id
        guard !isTimerRunning, !isPaused, !hostPause.paused, !(isFolding && !isCurrent), !isDismissing,
              !isBuffering, !keyboardManager.isKeyboardOpen else { return }

        let index = getCurrentIndex()
        let story = getStory(with: index)
        
        if isCurrent {
            if !model.isSeen {
                model.isSeen = true
            }
            if timerProgress < CGFloat(model.stories.count) {
                // TWO KINDS OF SEGMENT, TWO CLOCKS. A photo has no player, so wall time against its
                // declared duration is the only clock there is. A video HAS a clock — the player's —
                // and the bar reads that one, so the two can never disagree.
                //
                // ⚠️ `isReady` NO LONGER GATES A VIDEO, and that gate is half of his 2026-08-12
                // report: "the new story appears immediately, but the progress bar remains on the
                // previous story for a few seconds".
                //
                // It was written to stop a bar counting down over media that had not arrived, which
                // is a real protection FOR A PHOTO — wall time does not care whether there is a
                // picture. A video's bar cannot have that bug by construction: it reads the player's
                // own timestamp, and a player that has not started reports zero. So for a video the
                // flag added nothing except a second thing that had to become true before the
                // segment could move, and it becomes true late — it is written from a media
                // callback, one runloop hop after the fact.
                if story.config.mediaType == .video {
                    syncBarToPlayer(index: index, story: story)
                } else if story.isReady {
                    getProgressBarFrame(duration: story.duration)
                }
            } else if !isAdvancing {
                isAdvancing = true   // fire the user-advance once, not every 0.1s tick
                updateStory()
            }
        }
    }

    /// THE BAR READS THE PLAYER, FOR A VIDEO — the reference app's rule, and the reason its bar cannot
    /// disagree with the picture (the reference implementation: the
    /// bar's fraction is the player's own reported timestamp over its duration, sixty times a
    /// second). Ours accumulated wall time against the declared duration and never asked the player
    /// once, so every seek, stall, slow start and rebuilt player put the two clocks apart for the
    /// rest of the segment — his 2026-08-11 report: come back to a video and it plays from 0:14
    /// under a bar that starts at zero and outlives the clip.
    ///
    /// ⚠️ THE "IS THIS MY CLIP" QUESTION IS GONE. It used to be
    /// `StoryPlaybackClock.story(for: player) == story.mediaURL`, a weak map from a SHARED player to
    /// whichever story last claimed it, because across the load gap that player still held the
    /// previous clip and a bar that read it would draw the old clip's seconds under the new story's
    /// segment. The session is claimed by the item view itself, so its numbers are this item's or
    /// they are nothing — and `claim` is the whole of the check.
    ///
    /// Held still while there is no claim (the beat between an item mounting and its player being
    /// built): a bar that cannot read its own clip does not guess. Capped just under the segment
    /// boundary so a segment can only be COMPLETED by the player's own end-of-clip report — the
    /// reference app's `canSwitch` rule, where ordinary progress updates carry `false` and only its
    /// playback-completed callback carries `true`.
    func syncBarToPlayer(index: Int, story: Story) {
        // ⚠️ AN UNCLAIMED SEGMENT IS PLANTED AT ITS OWN START, NOT LEFT WHERE IT WAS.
        //
        // This used to `return`, which is the other half of his 2026-08-12 report. Returning leaves
        // `timerProgress` holding whatever the last computation put there — and in the beat between
        // an item mounting and its player claiming the session, that value belongs to the story he
        // just left. The bar therefore kept drawing the PREVIOUS story's fraction while the new
        // picture was already on screen, which is exactly "stale progress state from the previous
        // story" in his words.
        //
        // Planting the integer costs nothing when the claim is about to arrive (the segment is meant
        // to start at zero anyway) and guarantees the bar and the picture can never be describing
        // two different items, even for one frame.
        guard video.claim == story.id else {
            let start = CGFloat(index)
            if timerProgress != start { timerProgress = start }
            return
        }
        // An item that can never play again keeps the wall clock, so a broken clip still hands the
        // screen on after its declared duration instead of freezing the story for good.
        if video.failed {
            getProgressBarFrame(duration: story.duration)
            return
        }
        // The player's real duration once it knows it, the declared one until then — the same
        // preference the reference app applies (`effectiveDuration`), so the fraction and the clip
        // end together even when the host's declared length is a little off.
        let duration = video.duration > 0 ? video.duration : story.duration
        guard duration > 0 else { return }
        timerProgress = CGFloat(index) + min(0.999, max(0, CGFloat(video.timestamp / duration)))
    }

    /// The video's own end, arriving as a completed segment: exactly what the tick's integer
    /// crossing used to do by arithmetic, done once, on the player's word. The end of the LAST
    /// item advances to the next person through the same `updateStory` the arithmetic used.
    /// TRUE when the advance was actually taken. The caller puts the end-of-clip latch back when it
    /// was not — see the note at the call site. A refusal here is normal (a person turn is running,
    /// or an advance is already in flight), and it must not cost the clip its only report.
    func advanceFromVideoEnd() -> Bool {
        if !timerProgress.isFinite { timerProgress = 0 }
        if Int(timerProgress) + 1 >= model.stories.count {
            guard !isAdvancing else { return false }
            isAdvancing = true
            let before = viewModel.currentStoryUser
            updateStory()
            // `updateStory` clears `isAdvancing` itself on both of its refusals, so that flag being
            // back down with the person unchanged is exactly what a refusal looks like.
            return !(isAdvancing == false && viewModel.currentStoryUser == before)
        } else {
            timerProgress = CGFloat(Int(timerProgress) + 1)
            return true
        }
    }
    
    func updateStory(direction: StoryDirectionEnum = .next) {
        // ⚠️ ONLY THE PAGE THE VIEWER IS ACTUALLY ON MAY MOVE IT, and this guard is the other half of
        // his 2026-08-12 bounce-back ("it suddenly takes me back to the story I had already left").
        //
        // A person turn keeps the departing page on screen for the length of the slide, and that page
        // still answers taps. `getNextStory` reads `model.id` — ITS OWN person — so a tap that lands
        // on the page being left writes "the person after ME", which by then is the person already
        // being left behind. One late tap therefore drags the viewer backwards, and it looks exactly
        // like a queued tap firing in reverse.
        //
        // The same guard every other host-facing handler in this file already carries (the seen
        // receipt, the item-changed report, the resume). A page that is not current reports nothing
        // and moves nothing.
        //
        // ⚠️ AND BOTH REFUSALS PUT `isAdvancing` BACK. Every caller sets it true immediately before
        // calling here ("an advance is in flight"), and it is otherwise cleared only by a full
        // `resetProgress`. A refusal that left it standing would mean no advance is running AND no
        // further one can start — the last item of a person would stop answering taps for good.
        guard viewModel.currentStoryUser == model.id else { isAdvancing = false; return }
        // ⚠️ ONE TURN AT A TIME, AND A TAP DURING ONE IS DROPPED, NOT QUEUED — his rule in writing:
        // "the navigation must be locked until the current 3D Cube transition finishes… each tap
        // should move forward only once". Queuing is what made a fast series of taps land somewhere
        // he had not asked for. See `StoryPager.personTurnActive`.
        guard !StoryPager.personTurnActive else { isAdvancing = false; return }
        if direction == .previous {
            getPreviousStory()
        } else {
            getNextStory()
        }
    }
    
    func tapNextStory() {
        if keyboardManager.isKeyboardOpen { keyboardManager.dismiss(); return }   // tap closes keyboard, resumes
        // A TAP IS PROOF THE FINGER LEFT. The third belt on the stuck hold: whatever the gesture
        // system did or did not report, a completed tap means nothing is being held right now.
        if isPaused || isHolding { isPaused = false; isHolding = false; syncVideoMode() }
        configureTapScreen()
        guard !isTapDisabled else { return }
        // ⚠️ A TAP ON THE STORY IS PROOF NO HOST OVERLAY IS OVER IT, so the host's own pause comes
        // down here too. It sits BELOW `isTapDisabled`, which is what makes it safe: while the
        // viewers sheet is engaged taps are disabled and never reach this line, so that sheet's
        // pause cannot be cleared out from under it.
        //
        // This is the belt for the "…" dropdown. A `UIButton` menu has no dismissal callback, so the
        // menu releases its pause on two public window notifications and could in principle miss
        // both — and a missed release used to mean the bar advanced on the tap and then froze for
        // good, because nothing but `resumeStory` ever cleared `hostPause`. Now the next tap heals it.
        if hostPause.paused { hostPause.paused = false; syncVideoMode() }
        // A POISONED PROGRESS IS RECOVERED HERE, not trapped on. Same reason as `getCurrentIndex`:
        // `Int(_:)` kills the process on infinity or NaN. Found by auditing the 463 crash rather than
        // by another report — these three sites had the identical hazard and only the layout one had
        // actually fired.
        if !timerProgress.isFinite { timerProgress = 0 }
        if Int(timerProgress) + 1 >= model.stories.count {
            //next user — on the LAST item, advance immediately (was `(p+1) > count` which, when timerProgress
            // sat on an exact integer after a tap, filled all bars instead of advancing until the next tick)
            guard !isAdvancing else { return }   // don't double-advance if the auto-timer is crossing over too
            isAdvancing = true
            updateStory()
        } else {
            //next Story
            timerProgress = CGFloat(Int(timerProgress + 1))
        }
    }
    
    func tapPreviousStory() {
        if keyboardManager.isKeyboardOpen { keyboardManager.dismiss(); return }   // tap closes keyboard, resumes
        if isPaused || isHolding { isPaused = false; isHolding = false; syncVideoMode() }   // see tapNextStory
        configureTapScreen()
        guard !isTapDisabled else { return }
        if hostPause.paused { hostPause.paused = false; syncVideoMode() }   // see tapNextStory
        if !timerProgress.isFinite { timerProgress = 0 }   // see tapNextStory
        if (timerProgress - 1) < 0 {
            guard !isAdvancing else { return }
            isAdvancing = true
            updateStory(direction: .previous)
        } else {
            timerProgress = CGFloat(Int(timerProgress - 1))
        }
    }
    
    func start(index: Int) {
        // ⚠️ THE READY FLAG IS WRITTEN ONE TURN LATER, AND THAT ONE HOP IS THE WHOLE FIX for his
        // 2026-08-09 repro: "first open works, REOPENING the same story sits paused."
        //
        // This is called from the media loaders' completion. On a FIRST open the picture comes from
        // disk or network, the completion is asynchronous, and this write lands. On a REOPEN the
        // picture is already in StoryMemoryCache, the loader answers IN THE SAME TURN — which is
        // inside `updateUIView`, mid view-update — and a `@State` write made during a view update
        // is DISCARDED by SwiftUI. `isReady` then stays false for the whole visit, and
        // `startProgress` draws a bar that never moves over a picture that is plainly there. Not a
        // pause: every pause flag was clear, which is why three pause fixes left this standing.
        //
        // The hop makes the write land after the update pass, wherever the call came from; the
        // 0.05s tick reads it at most one frame later. Bounds re-checked inside the hop — the
        // delete flow can shrink the bucket between the schedule and the landing.
        DispatchQueue.main.async {
            guard model.stories.indices.contains(index), !model.stories[index].isReady else { return }
            model.stories[index].isReady = true
        }
        prefetchNext(after: index)   // warm the next photo so advancing is instant
    }

    // Predictive prefetch: get the next item's picture ready, so tapping or auto-advancing to it
    // shows instantly. One ahead — `StoryPrefetcher` runs the real three-deep window off the tick,
    // and this is the belt for the moment before that window has moved.
    private func prefetchNext(after index: Int) {
        let next = index + 1
        guard next < model.stories.count else { return }
        let story = model.stories[next]
        // ⚠️ THE POSTER, NOT ONLY THE PHOTO, AND FOR A VIDEO TOO. This was `mediaType == .image` and
        // refused to do anything at all for a clip — but a video item's first painted pixel is its
        // COVER, and that cover is a picture like any other. Leaving it out meant a video story
        // reached with nothing decoded put up its black view and waited, which is what he
        // photographed. For a photo story `previewURL` IS `mediaURL`, so this one line covers both.
        guard let poster = story.previewURL, let url = URL(string: poster) else { return }
        // ⚠️ PIXELS, NOT BYTES. Storing into `URLCache` alone — which is all this used to do — leaves
        // the decode to be paid on arrival, and that decode is the black frame. `decodedNow` reads
        // the decoded cache first, so this is what makes the arrival a dictionary lookup.
        //
        // ⚠️ AND OFF THE MAIN THREAD, WHICH IS THE DIFFERENCE BETWEEN THIS AND `decodedNow`. Nobody
        // is looking at this story yet, so there is nothing to be gained by blocking for it and a
        // dropped frame to be lost. That is the same split the reference app draws: synchronous for
        // the item that has just become current, asynchronous for everything it is guessing about.
        if StoryMemoryCache.image(for: url) != nil { return }
        Task.detached(priority: .utility) { await StoryMemoryCache.warm(url) }
        guard URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil else { return }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, let response else { return }
            URLCache.shared.storeCachedResponse(.init(response: response, data: data), for: URLRequest(url: url))
            Task.detached(priority: .utility) { _ = await StoryMemoryCache.prepare(data, for: url) }
        }.resume()
    }
    
    func getProgressBarFrame(duration: Double) {
        let calculatedDuration = viewModel.getVideoProgressBarFrame(duration: duration)
        timerProgress += (0.005 / calculatedDuration)   // halved to match the 0.05s tick (same segment duration)
    }
    
    func dissmis() {
        isPresented = false
        // ⚠️ THE `.replaceCurrentItem` BROADCAST IS GONE AND MUST NOT COME BACK. It was posted with
        // `object: nil`, so it nil'd the player reference inside EVERY mounted page — including
        // pages that were about to be reused — and the resulting chain of no-ops left a story sitting
        // under a loading cover for its whole declared length. The old representable had to
        // re-assert its weak player on every single update purely to survive it.
        //
        // Closing the viewer tears its pages down, and a torn-down page releases its own item's
        // player. Nothing has to be told.
    }
    
    func getCurrentIndex() -> Int {
        // `Int(_:)` on a Double TRAPS for infinity and for NaN — it does not clamp and it does not
        // return zero, it kills the process. `timerProgress` is accumulated by division, so one bad
        // divisor poisons it permanently and every later read of this crashes. Belt and braces with
        // the divisor guard in `getVideoProgressBarFrame`: this is read on every layout pass, and a
        // layout pass is the worst place to find out.
        guard timerProgress.isFinite else { return 0 }
        return max(0, min(Int(timerProgress), model.stories.count - 1))   // never -1 on an empty bucket
    }
    
    func getStory(with index: Int) -> Story {
        return model.stories[index]
    }

    // Safe accessor — returns nil instead of trapping on an empty / out-of-range bucket (crash guard).
    func getStoryOrNil(with index: Int) -> Story? {
        guard index >= 0, index < model.stories.count else { return nil }
        return model.stories[index]
    }

    // DELETED HERE: `firstUnseenIndex()`. It was the viewer's only answer to "where does this
    // person open", and its `?? 0` was the restart-from-the-beginning the owner reported. Every
    // caller now asks `resumeIndex`, which still starts with the first unwatched item and only
    // differs once there isn't one. Left as a note rather than deleted silently, because a function
    // that still exists is a function somebody will call again.

    /// WHERE THIS PERSON OPENS, in the order the answer is looked for:
    ///
    ///   1. where they were left in this viewing session (another mainstream messenger keeps the item on a context it has
    ///      already built — `resetForPresentation`'s `if let currentItemMediaView` branch),
    ///   2. their first unwatched item,
    ///   3. everything watched: their NEWEST if we arrived going backwards, their oldest going
    ///      forwards — see `StoryViewModel.startIndexForFullyRead`.
    ///
    /// See `StoryViewModel.lastIndex` for why the memory lives there and why it is not persisted.
    func resumeIndex() -> Int {
        let count = model.stories.count
        if let saved = viewModel.lastIndex[model.id] {
            return min(max(0, saved), max(0, count - 1))
        }
        if let firstUnseen = model.stories.firstIndex(where: { !$0.isSeen }) { return firstUnseen }
        return viewModel.startIndexForFullyRead(bucketId: model.id, count: count)
    }

    /// Remember where this person was left, on the way out. `timerProgress` counts items with the
    /// progress through the current one as its fraction, so its integer part IS the index; it is
    /// guarded for non-finite because a bad video duration has produced one before (see
    /// `getVideoProgressBarFrame`).
    func rememberPosition() {
        let raw = timerProgress.isFinite ? Int(timerProgress) : 0
        viewModel.lastIndex[model.id] = min(max(0, raw), max(0, model.stories.count - 1))
    }
    
    /// ⚠️ ONE ANSWER TO "IS THIS ITEM PLAYING", DERIVED FROM EVERY FLAG THAT HAS A VOTE.
    ///
    /// This replaces `playVideo()` and `pauseVideo()`, which were two half-answers that could
    /// disagree. `playVideo` carried its own guard list, `pauseVideo` carried none, and between them
    /// six callers meant "resume" while four only happened to arrive while a story was up — which is
    /// the shape of the 2026-08-09 report where a held story started playing again under the finger
    /// about a second later, because `.onChange(of: state)` called `play()` on whatever was loaded.
    ///
    /// A derived mode cannot have that bug: there is no caller that means "play", only callers that
    /// change a flag and then ask for the answer to be re-taken. If a finger is down, the answer is
    /// pause, however it is asked and whoever asks.
    ///
    /// The reference app's equivalent is a per-item mode computed by its container and pushed down;
    /// its non-central items are forced to pause the same way the first line here does.
    var videoMode: StoryProgressMode {
        // A page that is not the one being looked at never plays, whatever its own flags say. This
        // is what stops a story you have swiped away from playing on off-screen.
        guard viewModel.currentStoryUser == model.id else { return .pause }
        guard !model.stories.isEmpty else { return .pause }
        // ⚠️ AND THE ITEM ON SCREEN HAS TO BE A VIDEO, which this never asked.
        //
        // His 2026-08-12 report: an image and a video in one story, open the image, tap right to the
        // video, tap LEFT back to the image — the image appears and the video is still audible. The
        // mode stayed `.play` the whole time, because every input here is about the PAGE and none of
        // them is about which item the page is showing. Nothing was left to tell the clip to stop
        // except SwiftUI tearing its view down, and a story you can hear is proof that did not
        // happen in time.
        let i = getCurrentIndex()
        guard model.stories.indices.contains(i),
              model.stories[i].config.mediaType == .video else { return .pause }
        // The finger, the host (sheet, dismiss drag, hero flight), the scene, the keyboard.
        if isPaused || isHolding || hostPause.paused || scenePaused { return .pause }
        if keyboardManager.isKeyboardOpen { return .pause }
        // An emoji reaction animation pauses the story, which is what `configureProgress` did.
        if isAnimationStarted { return .pause }
        return .play
    }

    // ⚠️ `isFolding` IS DELIBERATELY NOT AN INPUT HERE, AND ADDING IT WOULD REVIVE A FIXED BUG.
    //
    // It comes from a `GeometryReader` position snapshot, and a GeometryReader re-evaluates on SIZE,
    // not on POSITION — so the snapshot can latch true for a page that is perfectly centred and
    // never update. That is the "story opens paused" report, and the fix was to make the fold gate
    // apply only to a page that is NOT current (see `startProgress`). The first line above already
    // pauses every non-current page, so `isFolding` could add nothing except the old bug back.
    //
    // `isDismissing` is out for a milder version of the same reason: it is a plain property fed by
    // the pager, the dismiss path already posts `pauseStory`, and a flag that strands true would
    // mean a story that never plays again. Nothing here should be able to silence a story for good.

    /// Re-take the decision and hand it to the item. Cheap and safe to call from anywhere, and every
    /// former `playVideo()` / `pauseVideo()` call site now calls this instead.
    func syncVideoMode() {
        video.setMode(videoMode)
    }

    /// Leaving the app and coming back, from whichever of the two sources reports it first.
    ///
    /// Pause when the app leaves the foreground; resume on return (the timer also naturally suspends
    /// with the run loop — this coordinates the video too). Only undo a pause WE created: a Control
    /// Centre peek fires inactive→active mid-hold, and blindly clearing `isPaused` resumed the story
    /// under the user's finger.
    ///
    /// ⚠️ THE LEAVING IS RECORDED EVEN WHEN A FINGER ALREADY PAUSED IT. This used to be `if
    /// !isPaused`, so a scene pause arriving DURING a hold was anonymous — nothing remembered that
    /// the app had left the foreground. The gesture's release then cleared `isPaused` and played the
    /// story behind Control Centre, with the 0.05s timer still running, so the bar advanced and you
    /// came back one or two stories further on. And because `scenePaused` was never set, coming back
    /// had nothing to undo. Recording it unconditionally is safe precisely because becoming active
    /// is the only thing that clears it, and the release refuses while it stands.
    ///
    /// Idempotent on purpose: `scenePhase` and UIKit's own notifications both call this, they can
    /// arrive in either order or twice, and the same answer twice must mean the same as once.
    func setSceneActive(_ active: Bool) {
        if active {
            guard scenePaused else { return }
            scenePaused = false
            isPaused = false
        } else {
            guard !scenePaused else { return }
            scenePaused = true
            isPaused = true
        }
        syncVideoMode()
    }
    
    func configureTapScreen() {
        switch (keyboardManager.isKeyboardOpen, isAnimationStarted) {
        case (true, _):
            isTapDisabled = true
        case (false, true):
            isTapDisabled = true
        default:
            isTapDisabled = false
        }
    }
    
    // DELETED HERE: `configureProgress(with:)`. It was the emoji-animation pause, and it was a third
    // place that decided whether a video should be running — with its own media-type test, its own
    // current-page test, and no knowledge of the finger or the sheet. `isAnimationStarted` is one of
    // `videoMode`'s inputs now, so the same event reaches the same single answer as everything else.
}

// reports a page's horizontal offset from centre so the timer can pause mid-fold.
struct StoryFoldKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

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
    /// reason to leave — the card's own chrome staying put is Snapchat's look and it is deliberate.
    /// But a caption is a paragraph of text, and a paragraph rendered at a third of its size over a
    /// picture the size of a row card is a smudge, not a caption. `storyFlightActive` is already
    /// the app's answer to "is the card in the air", posted on the FIRST frame of a pull (an exit
    /// hides the surround at once) and coming back over the last 18% of an arrival — so the caption
    /// now leaves with the reply bar and returns with it, which is one event instead of two.
    @State private var flightActive = false

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
    /// construction. This is Telegram's `captionAlpha *= (1.0 - contentScaleFraction)` translated
    /// into a view that cannot be handed its alpha directly — same guarantee, same number, same
    /// reason it cannot be told a lie.
    private var opacity: Double {
        if chromeHidden || flightActive { return 0 }
        let shrink = max(progress, StoryCardMorph.shared.sheetFraction)
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
                // clear it.
                if !active { progress = 0 }
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
    var showMore: Bool = false   // show the header "…" dropdown menu (buttons post notifications to the host)
    var isDismissing: Bool = false   // true while swiping down to close → cube fold off (no skew)
    @State private var lastSeenItem: String = ""
    /// The item the lookahead was last started from. Separate from `lastSeenItem` on purpose — see
    /// the note at the top of `startProgress`.
    @State private var lastPrefetchItem: String = ""

    // MARK: Private Properties
    @StateObject private var keyboardManager = KeyboardManager()   // own it once (was re-created each re-init)
    @State private var state: MediaState = .notStarted
    @State private var player = AVPlayer()
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
    /// the name live INSIDE the card, so they shrink with it — Snapchat keeps them there for the
    /// whole pull, and it is what makes a story card read as a card rather than a photo sliding
    /// about. The REPLY BAR does not: it is drawn below the card, it does not move, and it carries
    /// its own solid black footer, so it has to leave. One flag for the sheet, one for the flight.
    @State private var flightActive = false
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
    /// The video is waiting on bytes. Holds the progress bar; cleared automatically when the player
    /// reports it is playing again. See `.storyBuffering`.
    @State private var isBuffering: Bool = false
    /// The clip that put the bar on hold. `isBuffering` used to be cleared only by `resetProgress`,
    /// which runs on a PERSON change — so a video that stalled and was then tapped past to a PHOTO in
    /// the same person left the bar frozen for the rest of that bucket, with no auto-advance and no
    /// way back except swiping to somebody else. Knowing whose hold it is means it can be released
    /// the moment that clip stops being the one on screen, and never a moment earlier.
    @State private var bufferingURL: String = ""
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
         onItemSeen: ((String) -> Void)? = nil, showMore: Bool = false, isDismissing: Bool = false) {
        self.viewModel = viewModel
        _model = State(initialValue: model)
        _isPresented = isPresented
        self.userClosure = userClosure
        self.onProfile = onProfile
        self.onItemSeen = onItemSeen
        self.showMore = showMore
        self.isDismissing = isDismissing
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
    /// Telegram numbers this copies.
    ///
    /// `chromeHidden` is the second half, and it is theirs too: they clear the dim when the view
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

    /// THE STORY CARD'S HEIGHT, and this is Telegram's rule read out of their source rather than
    /// guessed from a screenshot. `StoryItemSetContainerComponent.swift`:
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

    /// Telegram's own card radius (`:4031`). Ours was 24 on the bottom corners only, and 0 on top,
    /// because the card used to run off the top of the screen and there was no top corner to round.
    private let cardRadius: CGFloat = 12

    /// Hand the card's rectangle to `StoryCardMorph`, which shrinks the live story into the viewers
    /// sheet and needs to know it is aiming at the card and not at this whole page.
    private func publishCardRect(proxy: GeometryProxy, footerH: CGFloat) {
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
                    let footerH: CGFloat = isReplyBar ? Constant.MessageView.height + 32 + winInsets.bottom : 0
                    // THE CARD. Sized and placed by Telegram's rule (see `cardHeight`), pinned to the
                    // safe-area top by the VStack below rather than centred in the screen.
                    VStack(spacing: 0) {
                        getStoryView(with: index, story: story)
                            .frame(width: proxy.size.width,
                                   height: cardHeight(width: proxy.size.width,
                                                      containerH: proxy.size.height,
                                                      footerH: footerH))
                            // THE STORY STEPS BACK WHILE YOU TYPE. His report, with a Telegram
                            // screenshot beside ours: opening the reply keyboard left our picture at
                            // full brightness, so the thing you are reading and the thing you are
                            // writing competed, and on a bright photo the reply bar was hard to see
                            // at all.
                            //
                            // Telegram's own numbers, read from `StoryItemSetContainerComponent`:
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
                                Color.black
                                    .opacity(replyDimOn ? 0.8 : 0)
                                    // The keyboard's OWN duration and curve, so the picture darkens
                                    // with the keyboard rising rather than lagging behind it.
                                    .animation(.easeInOut(duration: keyboardManager.animationDuration),
                                               value: replyDimOn)
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
                            // drag. Snapchat's dismissal looks the way it does for the same reason —
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
                            // where Telegram puts them (`contentInsets.top = 54`). They used to be
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
                        Spacer(minLength: 0)
                    }
                    .padding(.top, winInsets.top)
                    // Tell the viewers-sheet morph WHERE the card is, because it is no longer the
                    // whole view. Without this it would shrink the black margins into the slot along
                    // with the story and centre on the wrong point. Every page computes the same
                    // rectangle, so whichever one runs last is still right.
                    .onAppear { publishCardRect(proxy: proxy, footerH: footerH) }
                    .onChange(of: proxy.size) { _ in publishCardRect(proxy: proxy, footerH: footerH) }
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
            .rotation3DEffect(
                getAngle(proxy: proxy),
                axis: (x: 0, y: 1, z: 0),
                anchor: proxy.frame(in: .global).minX > 0 ? .leading : .trailing,
                perspective: 2.5
            )
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
        // The player says whether it is waiting on bytes; the progress bar holds while it is. Only
        // the page that is actually current listens, or a neighbour's stall would freeze the story
        // you are watching.
        .onReceive(NotificationCenter.default.publisher(for: .storyBuffering)) { note in
            guard viewModel.currentStoryUser == model.id else { return }
            // ⚠️ AND ABOUT THE CLIP THIS PAGE IS ACTUALLY SHOWING. Being the current PAGE was the
            // only test, so a neighbour page's stall froze the bar of the story on screen. The
            // sender names its url now; a report about anything else is not ours to act on.
            // A post with no url at all is refused rather than trusted — the only writers are
            // `PlayerView`s, and one that cannot say which clip it means is one we cannot place.
            guard let sender = note.userInfo?["url"] as? String,
                  sender == getStory(with: getCurrentIndex()).mediaURL else { return }
            let buffering = (note.object as? Bool) ?? false
            if buffering != isBuffering { isBuffering = buffering }
            bufferingURL = buffering ? sender : ""
        }
        .onChange(of: viewModel.currentStoryUser) { newValue in
            NotificationCenter.default.post(name: .stopVideo, object: nil)
            // ON THE WAY OUT, BEFORE `resetProgress` WIPES IT. This fires on every mounted page, so
            // the one being left is the one whose id no longer matches — and its `timerProgress`
            // still holds where the finger got to.
            if newValue != model.id { rememberPosition() }
            resetProgress()
            // When this bucket becomes current, open where it was left in this session, else at the
            // FIRST UNSEEN item (e.g. a new story D after A/B/C were seen), else at the start.
            // Asking `firstUnseenIndex` here unconditionally is what restarted a fully-watched
            // person at item 1 every single time you swiped back to them.
            // The fraction rides along for a video left mid-play, same as the sheet jump: the item
            // resumed and the position resumed are one memory, not two.
            if newValue == model.id {
                let i = resumeIndex()
                timerProgress = CGFloat(i) + resumeFraction(at: i)
                // The page being handed the screen is not folding, whatever the last geometry
                // snapshot said. `resetProgress` above cleared this too, but a preference delivered
                // mid-transition can arrive AFTER it — see the note in `startProgress`.
                isFolding = false
            }
            playVideo()
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
        }
        .onReceive(timer) { _ in
            startProgress()
        }
        .onChange(of: isAnimationStarted ? isAnimationStarted : false) { state in
            configureProgress(with: state)
            isTimerRunning = state
        }
        .onChange(of: keyboardManager.isKeyboardOpen) { open in
            open ? pauseVideo() : playVideo()   // composing a reply pauses; resumes on dismiss
        }
        .onChange(of: scenePhase) { phase in
            // Pause when the app leaves the foreground; resume on return (the timer also
            // naturally suspends with the run loop, this coordinates video too). Only undo a
            // pause WE created: a Control Center peek fires .inactive→.active mid-hold, and
            // blindly clearing isPaused resumed the story under the user's finger.
            if phase == .active {
                if scenePaused { scenePaused = false; isPaused = false; playVideo() }
            } else {
                // ⚠️ RECORDED EVEN WHEN A FINGER ALREADY PAUSED IT. This was `if !isPaused`, so a
                // scene pause arriving DURING a hold was anonymous — nothing remembered that the app
                // had left the foreground. The gesture's release then cleared `isPaused` and played
                // the story behind Control Centre, with the 0.05s timer still running in `.inactive`,
                // so the bar advanced and you came back one or two stories further on. And because
                // `scenePaused` was never set, returning to `.active` had nothing to undo.
                //
                // Recording it unconditionally is safe precisely because `.active` is the only thing
                // that clears it, and the release now refuses while it stands.
                scenePaused = true
                isPaused = true; pauseVideo()
            }
        }
        // Host shows/hides a sheet over the viewer (viewers list, share, menu) → freeze/resume.
        .onReceive(NotificationCenter.default.publisher(for: .pauseStory)) { _ in
            hostPause.paused = true; pauseVideo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeStory)) { _ in
            hostPause.paused = false
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
            if !keyboardManager.isKeyboardOpen { playVideo() }
        }
        // Host's viewers carousel centred a different one of MY stories → jump the (frozen) viewer to
        // that item, so when the sheet collapses the story underneath matches the carousel/morph (no
        // photo-swap flash at the end of the close). Only affects the currently-shown bucket.
        .onReceive(NotificationCenter.default.publisher(for: .init("jumpToStoryItem"))) { note in
            guard viewModel.currentStoryUser == model.id,
                  let id = note.object as? String,
                  let idx = model.stories.firstIndex(where: { $0.id == id }),
                  idx != getCurrentIndex() else { return }
            // Landing on a video watched earlier this session: the bar starts where the player
            // will (see `resumeFraction`), or the segment counts a full duration over a clip with
            // only its tail left.
            timerProgress = CGFloat(idx) + resumeFraction(at: idx)
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
            // Round the card's bottom corners in UIKit (a SwiftUI clip doesn't clip the blurred backdrop).
            // Applies to reply-bar (friend) cards AND my own story (isMine) — my own card is rounded but
            // uses the library's UIKit dismiss now, so the corners must live here, not in an app-level
            // clip (an app clip pinned the card and broke the smooth dismiss).
            ImageView(imageURL: story.mediaURL,
                      previewURL: story.previewURL,
                      bottomCornerRadius: (story.config.storyType != .plain() || model.isMine) ? 24 : 0) {
                start(index: index)
            }
            .onAppear {
                resetAVPlayer()
            }
        case .video:
            VideoView(
                videoURL: story.mediaURL,
                posterURL: story.previewURL,
                blurThumb: story.blurThumb,
                state: $state,
                player: player
            ) { media, duration in
                // ONLY A REAL LENGTH REPLACES THE ONE WE HAVE. Making `getVideoLength` asynchronous
                // meant this callback now fires at `.ready` with duration still 0, and writing that
                // zero here is what set up the divide-by-zero that killed build 463. The story
                // already carries a sensible length from the host; the player refines it when it
                // knows, and until then the existing one stands.
                //
                // ⚠️ HOPPED for the same reason as `start(index:)`: a CACHED clip's setup can now
                // run synchronously (CacheManager answers a main-thread hit in the same turn), so
                // this closure can fire inside `updateUIView` — where these Binding/@State writes
                // would be silently discarded, the video twin of his reopen-freeze repro.
                DispatchQueue.main.async {
                    if duration.isFinite, duration > 0, model.stories.indices.contains(index) {
                        model.stories[index].duration = duration
                    }
                    start(index: index)
                    state = media
                }
            }
            .onChange(of: state) { _ in
                playVideo()
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
                    .animation(.spring(response: keyboardManager.animationDuration, dampingFraction: 1.0), value: messageViewPosition)
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
            // INSIDE the story. Telegram's sit about 7 below their card's top edge.
            .padding(.top, 8)
            .padding(.bottom, 8)
            UserView(
                image: image,
                name: name,
                date: date,
                audience: audience,
                onProfile: { onProfile?(model.user) },
                showMore: showMore,
                isMyStory: model.isMine,
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
        // Snapchat's does the same: at rest there is a reply bar, and the instant the pull starts it
        // is not there. See `flightActive`.
        .opacity(flightActive ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: flightActive)
        // Ride the keyboard's own timing (critically-damped spring keyed to the keyboard duration):
        // front-loaded like the keyboard, so the reply pill stays just above the keyboard's top edge
        // the whole way up instead of trailing behind it and popping in at the end (user: "bar comes
        // after the keyboard — make it same time").
        .animation(.spring(response: keyboardManager.animationDuration, dampingFraction: 1.0), value: messageViewPosition)
        .offset(y: messageViewPosition)
    }

    /// ⚠️ A STRAIGHT FADE IS A HEAVY FADE, and that is his 2026-08-09 "caption shadow is too much,
    /// use the shadow telegram is using".
    ///
    /// Both of ours were `LinearGradient(colors:)`, which puts a stop at each end and interpolates
    /// evenly between them. Telegram's are not straight. They generate EIGHT stops and run the alpha
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
    // Telegram's numbers: black, 40% at the very top, eased away to nothing 90pt down
    // (`topGradientHeight: CGFloat = 90.0`, and their PanelGradient asset peaks at 102/255).
    // Ours was 50% over 130pt and straight, so it was heavier in every part of the band at once.
    var topScrim: some View {
        LinearGradient(stops: Self.scrimStops(peak: 0.4), startPoint: .bottom, endPoint: .top)
            .frame(height: 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
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
                // Telegram's caption scrim exactly: black, 0.8 at the bottom, 128pt tall, and eased
                // rather than straight — see `scrimStops`. The peak and the height were already
                // theirs; the straight ramp between them is what he photographed.
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
                    // 14 IN BOTH CASES (owner 2026-08-06: "slightly too high… make it like telegram").
                    // It was 28 on my own story and 16 on a friend's — two numbers for one thing, and
                    // the bigger one is the one he photographed sitting too far up. Telegram puts its
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
            // overlay, and the cube's fold angle is only computed while that scroll view is actually
            // tracking (`getAngle` returns flat unless `StoryPager.horizontalScroll` is live). So a
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
                    if !isPaused { isPaused = true; pauseVideo() }
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
                    if isPaused { isPaused = false; playVideo() }
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
    
    func getAngle(proxy: GeometryProxy) -> Angle {
        // Cube is INERT while a swipe-down dismiss moves the card: the fold angle derives from
        // the page's GLOBAL minX, and the dismiss transform shifts it — a fast flick otherwise
        // slams the page into a sudden violent 3D fold (flipped/black frames on close).
        // Both flags mean "the card is being moved by something that is not a page swipe": the
        // library's own dismiss writes the transform itself, the hero close drives it through
        // StoryCardMorph. Either way the page's global minX is no longer evidence of anything.
        if StoryPager.dismissActive || StoryCardMorph.heroDismissActive { return .zero }
        // And the fold may fire ONLY during a live horizontal page swipe. Apple's zoom-dismiss
        // (the native close) moves every page's global minX while it shrinks the cover — the
        // cube folding along with it was the true source of the fast-flick "explosions".
        // NIL MEANS FLAT TOO: the solo host (my own story) never has a horizontal scroll, and the
        // friends pager has none for the first beat after mount — in both cases nothing is being
        // page-swiped, so nothing may fold. The old `if let` fell through on nil and computed an
        // angle, which let the OPEN hero fold the page before the pager had bound its scroll.
        guard let s = StoryPager.horizontalScroll, s.isTracking || s.isDragging || s.isDecelerating else {
            return .zero
        }
        // StoryUI library's cube (tiskender2/StoryUI): angle = 45° × (minX / width). Combined with the
        // pager's horizontal slide + the .leading/.trailing anchor + perspective 2.5, this IS the cube —
        // pure SwiftUI, no UIKit transform feedback (so no shake/black).
        let progress = proxy.frame(in: .global).minX / proxy.size.width
        return Angle(degrees: 45 * progress)
    }
    
    /// How much of a video segment was already watched THIS SESSION, as the bar's fraction.
    ///
    /// `peek`, never `take`: the player is the one that consumes the memory (when it seeks, in
    /// `setupPlayer`), and this runs before that player exists. Measured against the story's
    /// DECLARED duration because that is the clock the bar counts with (`getProgressBarFrame`);
    /// capped just under 1 so a position near the end can never advance the story on the first
    /// tick. Zero for photos, for videos never left mid-play, and for every fresh session — the
    /// door empties the store at close.
    func resumeFraction(at index: Int) -> CGFloat {
        guard index >= 0, index < model.stories.count else { return 0 }
        let s = model.stories[index]
        guard s.config.mediaType == .video, s.duration > 0,
              let u = URL(string: s.mediaURL),
              let t = StoryPlaybackResume.peek(u) else { return 0 }
        return min(0.98, max(0, CGFloat(t / s.duration)))
    }

    func resetProgress() {
        timerProgress = 0
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
        // Telegram does not store this at all: `isBuffering` is recomputed as a LOCAL on every
        // progress tick and handed straight to the bar (StoryItemContentComponent, in
        // `updateVideoPlaybackProgress`), so it cannot survive anything. Ours is a flag written only
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
            // waiting behind it, in a slow transaction. Measured against Telegram's ~0.3s
            // peer-to-peer move, this was the largest single piece of our ~0.9s.
            viewModel.currentStoryUser = viewModel.stories[bundleIndex - 1].id
        } else {
            let index = getCurrentIndex()
            let story = getStory(with: index)
            if story.config.mediaType == .video {
                NotificationCenter.default.post(name: .stopAndRestartVideo, object: nil)
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
                let bundleIndex = viewModel.stories.firstIndex { currentBundle in
                    return model.id == currentBundle.id
                } ?? 0
                
                // ⚠️ NO `withAnimation` HERE, AND PUTTING ONE BACK COSTS HALF A SECOND FOR NOTHING.
                //
                // This used to be wrapped in a bare `withAnimation`, which is SwiftUI's default spring —
                // about a 0.55s response. Nothing it could animate was on screen: the page move belongs
                // to `UIPageViewController`, which reads its own duration and ignores SwiftUI entirely.
                // So the spring drove no visible motion and only held the state change, and everything
                // waiting behind it, in a slow transaction. Measured against Telegram's ~0.3s
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
        // Telegram separates the two outright. `markAsSeen` waits for real playback
        // (`StoryItemContentComponent`), while the preload of the next three items is driven from
        // `StoryContentContextImpl.updateState` — the item CHANGING, nothing else. This is that,
        // on the same list the host used to flatten for us: every story in the viewer in the order
        // they will be watched, across people, so the last item of one warms the first of the next.
        if viewModel.currentStoryUser == model.id {
            let cur = getStory(with: getCurrentIndex())
            // A HOLD BELONGS TO ONE CLIP. See `bufferingURL`: the item has changed, so a hold left
            // by the one we came from is stale and the bar must be released. Matched by url rather
            // than cleared blindly, so a NEW clip that has already reported its own stall keeps it.
            if isBuffering, bufferingURL != cur.mediaURL {
                isBuffering = false
                bufferingURL = ""
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
        // Telegram's rule, from `StoryItemContentComponent.updateVideoPlaybackProgress`: `markAsSeen`
        // is called only once playback reports `.playing` with a real timestamp, and their comment
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
                if story.isReady {
                    getProgressBarFrame(duration: story.duration)
                }
            } else if !isAdvancing {
                isAdvancing = true   // fire the user-advance once, not every 0.1s tick
                updateStory()
            }
        }
    }
    
    func updateStory(direction: StoryDirectionEnum = .next) {
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
        if isPaused || isHolding { isPaused = false; isHolding = false; playVideo() }
        configureTapScreen()
        guard !isTapDisabled else { return }
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
        if isPaused || isHolding { isPaused = false; isHolding = false; playVideo() }   // see tapNextStory
        configureTapScreen()
        guard !isTapDisabled else { return }
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

    // Predictive prefetch: pull the next item's image into URLCache (what ImageLoader reads from),
    // so tapping/auto-advancing to it shows instantly. One ahead — caching handles the rest.
    private func prefetchNext(after index: Int) {
        let next = index + 1
        guard next < model.stories.count,
              model.stories[next].config.mediaType == .image,
              let url = URL(string: model.stories[next].mediaURL),
              URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil else { return }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, let response else { return }
            URLCache.shared.storeCachedResponse(.init(response: response, data: data), for: URLRequest(url: url))
        }.resume()
    }
    
    func getProgressBarFrame(duration: Double) {
        let calculatedDuration = viewModel.getVideoProgressBarFrame(duration: duration)
        timerProgress += (0.005 / calculatedDuration)   // halved to match the 0.05s tick (same segment duration)
    }
    
    func dissmis() {
        isPresented = false
        NotificationCenter.default.post(name: .replaceCurrentItem, object: nil)
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
    ///   1. where they were left in this viewing session (Signal keeps the item on a context it has
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
    
    func resetAVPlayer() {
        // THE OLD PLAYER IS THE ONE TO PAUSE, so the pause happens BEFORE the swap. This was
        // `Task { player.pause() }` ABOVE the swap — but the task body reads `player` when it RUNS,
        // which is after the line below has already replaced it, so it paused the brand-new silent
        // player and the outgoing one was never told to stop. Tapping from a video onto a text or
        // photo story left the old clip's audio running until deallocation got around to it.
        player.pause()
        player = AVPlayer()
    }
    
    func pauseVideo() {
        player.pause()
    }
    
    func playVideo() {
        // Never resume under a sheet or the reply keyboard, and never index an empty bucket.
        guard !model.stories.isEmpty, !hostPause.paused, !keyboardManager.isKeyboardOpen else { return }
        // ⚠️ AND NEVER UNDER A FINGER. THE PAUSE IS THE AUTHORITY; THIS FUNCTION IS NOT.
        //
        // His 2026-08-09 report: hold a story, it pauses, and about a second later it starts playing
        // again with the finger still down. Nothing was unpausing it — `isPaused` and `isHolding`
        // both stayed true and the progress bar stayed frozen, which is why it reads as the video
        // alone disobeying. This function simply never asked.
        //
        // It is called from six places and only two of them mean "the person wants this playing".
        // The other four are events that happen to arrive while a story is up — a keyboard closing,
        // an emoji animation ending, the scene returning, and above all `.onChange(of: state)`,
        // which fires when the PLAYER reports `.started` or when the async duration load lands a
        // beat after opening. That last one is the ~1s in his report: it has nothing to do with the
        // hold, it just calls `play()` on whatever is loaded.
        //
        // Every caller that legitimately resumes already clears these two flags on the line before
        // it calls here (the release branch, the loan collector, the scene's own resume), so this
        // guard costs those nothing and refuses exactly the callers that were never asked for.
        guard !isPaused, !isHolding else { return }
        let index = getCurrentIndex()
        let currentUser = viewModel.currentStoryUser == model.id
        let video = model.stories[index].config.mediaType == .video
        let isReady = state == .ready || state == .started
        
        if isReady, currentUser, video {
            // The `automaticallyWaitsToMinimizeStalling = false` that lived here silently defeated
            // `setupPlayer`'s deliberate `true` on every single play call — the player was told to
            // let AVFoundation wait, and then told the opposite before any clip ever started. With
            // the override gone, a streamed clip holds on its cover until it can play through
            // instead of starting on a stutter, which is what the setting was chosen for.
            // ⚠️ NO `Task` HERE, AND THE HOP WAS A HOLE IN THE GUARD ABOVE.
            //
            // This function is on a plain extension, so a `Task` created in it does NOT inherit the
            // main actor: `player.play()` ran on the global executor at an arbitrary later moment.
            // By then the guard's answer could be stale — press and hold at the instant the player
            // reports ready (every `state` change calls in here) and the pause would take effect,
            // the bar would freeze and the chrome would fade, and then the escaped `play()` would
            // land and the clip would keep moving under the finger. Exactly the report the guard was
            // added for, reduced from certain to intermittent rather than closed.
            //
            // `play()` also has no business being called off the main thread. Calling it inline
            // means the guard three lines up and the play are one indivisible decision.
            player.play()
        }
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
    
    func configureProgress(with state: Bool) {
        guard !model.stories.isEmpty else { return }   // last item deleted mid-animation → don't index [0]
        let index = getCurrentIndex()
        let story = model.stories[index]
        let mediaType = story.config.mediaType
        if state, mediaType == .video {
            pauseVideo()
        } else if !state, mediaType == .video {
            guard viewModel.currentStoryUser == model.id else { return }
            playVideo()
        }
    }
}

// reports a page's horizontal offset from centre so the timer can pause mid-fold.
struct StoryFoldKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

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

    /// Linear, straight off the finger.
    private var opacity: Double {
        let t = min(1, max(0, progress / Self.goneAt))
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
    @State private var captionExpanded: Bool = false   // tap the caption to expand past 3 lines

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
        _timerProgress = State(initialValue: CGFloat(model.stories.firstIndex(where: { !$0.isSeen }) ?? 0))
    }

    private var messageViewPosition: CGFloat {
        return -keyboardManager.currentHeight
    }
    
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
            height: cardHeight(width: proxy.size.width, containerH: proxy.size.height, footerH: footerH))
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
                            // Flatten the card (photo + UIKit blur backdrop) into ONE layer first: a bare
                            // .clipShape does NOT clip the ImageLoader's UIVisualEffectView (its backdrop
                            // composites separately and spills past the mask, so the bottom stayed square).
                            // compositingGroup forces a single layer the round-corner mask can actually cut.
                            .compositingGroup()
                            // All four corners now, not just the bottom two: the card has a visible top
                            // edge for the first time, because it starts below the status bar.
                            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
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
                            .overlay(captionView(story.caption, plain: story.config.storyType == .plain())
                                        .modifier(SheetCaptionFade()),
                                     alignment: .bottom)
                            // Top dark scrim so the username/avatar/close stay readable on white/bright photos.
                            // Fades with the chrome (it's part of the chrome look) — the PHOTO must stay
                            // pixel-stable when the viewers sheet opens, so the scrim can't linger under
                            // a scrimless morph card (that brightness step read as a flash).
                            .overlay(topScrim.opacity(chromeHidden ? 0 : 1)
                                        .animation(.linear(duration: 0.18), value: chromeHidden),
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
        // The player says whether it is waiting on bytes; the progress bar holds while it is. Only
        // the page that is actually current listens, or a neighbour's stall would freeze the story
        // you are watching.
        .onReceive(NotificationCenter.default.publisher(for: .storyBuffering)) { note in
            guard viewModel.currentStoryUser == model.id else { return }
            let buffering = (note.object as? Bool) ?? false
            if buffering != isBuffering { isBuffering = buffering }
        }
        .onChange(of: viewModel.currentStoryUser) { newValue in
            NotificationCenter.default.post(name: .stopVideo, object: nil)
            resetProgress()
            // When this bucket becomes current, open at the FIRST UNSEEN item (e.g. a new
            // story D after A/B/C were seen) instead of always restarting at item 0.
            if newValue == model.id { timerProgress = CGFloat(firstUnseenIndex()) }
            playVideo()
        }
        .onAppear {
            // First open of the viewer (onChange(currentStoryUser) doesn't fire for the initial bucket):
            // land on the first unseen item too.
            if viewModel.currentStoryUser == model.id { timerProgress = CGFloat(firstUnseenIndex()) }
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
                if !isPaused { scenePaused = true }   // remember this pause is ours, not a hold
                isPaused = true; pauseVideo()
            }
        }
        // Host shows/hides a sheet over the viewer (viewers list, share, menu) → freeze/resume.
        .onReceive(NotificationCenter.default.publisher(for: .pauseStory)) { _ in
            hostPause.paused = true; pauseVideo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeStory)) { _ in
            hostPause.paused = false; if !keyboardManager.isKeyboardOpen { playVideo() }
        }
        // Host's viewers carousel centred a different one of MY stories → jump the (frozen) viewer to
        // that item, so when the sheet collapses the story underneath matches the carousel/morph (no
        // photo-swap flash at the end of the close). Only affects the currently-shown bucket.
        .onReceive(NotificationCenter.default.publisher(for: .init("jumpToStoryItem"))) { note in
            guard viewModel.currentStoryUser == model.id,
                  let id = note.object as? String,
                  let idx = model.stories.firstIndex(where: { $0.id == id }),
                  idx != getCurrentIndex() else { return }
            timerProgress = CGFloat(idx)
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
                state: $state,
                player: player
            ) { media, duration in
                // ONLY A REAL LENGTH REPLACES THE ONE WE HAVE. Making `getVideoLength` asynchronous
                // meant this callback now fires at `.ready` with duration still 0, and writing that
                // zero here is what set up the divide-by-zero that killed build 463. The story
                // already carries a sensible length from the host; the player refines it when it
                // knows, and until then the existing one stands.
                if duration.isFinite, duration > 0 { model.stories[index].duration = duration }
                start(index: index)
                state = media
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
                }
                
            }
        case .plain:
            EmptyView()   // was Divider() — drew a faint hairline across the screen centre on plain stories
        }
    }

    @ViewBuilder
    func getUserInfoAndProgressBar(with index: Int) -> some View {
        let date = getStoryOrNil(with: index)?.date ?? ""
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
        // Ride the keyboard's own timing (critically-damped spring keyed to the keyboard duration):
        // front-loaded like the keyboard, so the reply pill stays just above the keyboard's top edge
        // the whole way up instead of trailing behind it and popping in at the end (user: "bar comes
        // after the keyboard — make it same time").
        .animation(.spring(response: keyboardManager.animationDuration, dampingFraction: 1.0), value: messageViewPosition)
        .offset(y: messageViewPosition)
    }

    // Top dark scrim: black (50%) at the very top fading to clear, so the header (username, avatar, X)
    // stays readable on white/bright stories. Mirrors the bottom caption gradient.
    var topScrim: some View {
        LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 130)
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
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
                    .allowsHitTesting(false)
                // Our own design (clean, story-style): bottom-LEFT, no hard line, over the soft fade.
                Text(text)
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
            // Hold to pause. onLongPressGesture's onPressingChanged pauses on press-down
            // and resumes on release; crucially, a horizontal swipe exceeds maximumDistance and
            // CANCELS the press (→ resume) so the TabView can still page between users (R2 fix —
            // a minimumDistance:0 drag stole the touch from the pager).
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 10,
                                perform: { isHolding = true },   // fires only AFTER 0.25s → chrome fades on a real hold
                                onPressingChanged: { pressing in
                if pressing {
                    guard !keyboardManager.isKeyboardOpen else { return }
                    isPaused = true; pauseVideo()
                } else {
                    isPaused = false; isHolding = false; playVideo()
                }
            })
        }
    }
    
    func getAngle(proxy: GeometryProxy) -> Angle {
        // Cube is INERT while a swipe-down dismiss moves the card: the fold angle derives from
        // the page's GLOBAL minX, and the dismiss transform shifts it — a fast flick otherwise
        // slams the page into a sudden violent 3D fold (flipped/black frames on close).
        if StoryPager.dismissActive { return .zero }
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
    
    func resetProgress() {
        timerProgress = 0
        isAdvancing = false
        isPaused = false   // safety: never carry a stuck pause across a user switch (R1 freeze fix)
        scenePaused = false
        // Clear every pause latch too, or a new bucket can start permanently frozen (stuck-state bug).
        isTimerRunning = false
        isAnimationStarted = false
        isFolding = false
        captionExpanded = false   // collapse the caption when moving to another story
    }
    
    func getPreviousStory() {
        // Index guard (was `?? 0` then `[index - 1]` → crash if this bucket ever left the array).
        if let bundleIndex = viewModel.stories.firstIndex(where: { model.id == $0.id }), bundleIndex > 0 {
            withAnimation {
                viewModel.currentStoryUser = viewModel.stories[bundleIndex - 1].id
            }
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
                
                withAnimation {
                    viewModel.currentStoryUser = viewModel.stories[bundleIndex + 1].id
                }
            }
        }
    }
    
    func startProgress() {
        guard !model.stories.isEmpty else { return }   // empty bucket (all expired/deleted) → nothing to index
        // Report the ACTUAL current item as seen (per-item, not the whole bucket) — drives accurate
        // view receipts + "Seen by". Runs before the pause guard so it fires the moment an item shows.
        if viewModel.currentStoryUser == model.id {
            let cur = getStory(with: getCurrentIndex())
            if cur.id != lastSeenItem { lastSeenItem = cur.id; onItemSeen?(cur.id) }
        }
        // Pause sources: emoji-fly animation (isTimerRunning), hold-to-pause (isPaused),
        // composing a reply (keyboard open) — and now BUFFERING, because a segment that keeps
        // counting while the video is waiting on bytes will hand the screen to the next story before
        // this one has shown a frame. That is the progress desynchronisation: the bar was measuring
        // time, not playback. It resumes by itself the moment the player reports it is playing.
        guard !isTimerRunning, !isPaused, !hostPause.paused, !isFolding, !isDismissing,
              !isBuffering, !keyboardManager.isKeyboardOpen else { return }
        
        let index = getCurrentIndex()
        let story = getStory(with: index)
        
        if viewModel.currentStoryUser == model.id {
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
        if !model.stories[index].isReady {
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

    // First UNSEEN item index (open-at-newest). All seen → 0 (replay from the start).
    func firstUnseenIndex() -> Int {
        model.stories.firstIndex(where: { !$0.isSeen }) ?? 0
    }
    
    func resetAVPlayer() {
        Task {
            player.pause()
        }
        player = AVPlayer()
    }
    
    func pauseVideo() {
        player.pause()
    }
    
    func playVideo() {
        // Never resume under a sheet or the reply keyboard, and never index an empty bucket.
        guard !model.stories.isEmpty, !hostPause.paused, !keyboardManager.isKeyboardOpen else { return }
        let index = getCurrentIndex()
        let currentUser = viewModel.currentStoryUser == model.id
        let video = model.stories[index].config.mediaType == .video
        let isReady = state == .ready || state == .started
        
        if isReady, currentUser, video {
            player.automaticallyWaitsToMinimizeStalling = false
            Task {
                player.play()
            }
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

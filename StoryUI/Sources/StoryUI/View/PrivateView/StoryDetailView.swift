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
    @State private var captionExpanded: Bool = false   // Telegram: tap the caption to expand past 3 lines

    private var messageViewPosition: CGFloat {
        return -keyboardManager.currentHeight
    }
    
    private var emojiViewPosition: CGFloat {
        return (messageViewPosition * 1.5)
    }

    // Real device safe-area insets (the host no longer applies them — see StoryPageHostVC). Used to keep the
    // progress bars below the notch and the reply bar above the home indicator while the PHOTO fills under both.
    private var winInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.safeAreaInsets
            ?? UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
    }

    var body: some View {
        
        GeometryReader { proxy in
            let index = getCurrentIndex()
            ZStack {
                // Empty bucket (all items expired/removed) -> render nothing instead of indexing [-1] (crash).
                if index < model.stories.count {
                    let story = model.stories[index]
                    // Friend (reply-bar) stories render as a CARD: the photo ends above the reply-bar
                    // footer with rounded bottom corners (matching my own story), and the black area
                    // below holds the reply bar. Own/plain stories stay full-screen (the app draws
                    // their own rounded card + Views/trash footer on top).
                    let isReplyBar = story.config.storyType != .plain()
                    let footerH: CGFloat = isReplyBar ? Constant.MessageView.height + 32 + winInsets.bottom : 0
                    getStoryView(with: index, story: story)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, footerH)
                        // Flatten the card (photo + UIKit blur backdrop) into ONE layer first: a bare
                        // .clipShape does NOT clip the ImageLoader's UIVisualEffectView (its backdrop
                        // composites separately and spills past the mask, so the bottom stayed square).
                        // compositingGroup forces a single layer the round-corner mask can actually cut.
                        .compositingGroup()
                        .clipShape(BottomRoundedShape(radius: isReplyBar ? 24 : 0))   // match the own-story card (24)
                        .overlay(
                            tapStory()
                                .offset(
                                    y: story.config.storyType != .plain()
                                    ? -Constant.MessageView.height : .zero
                                )
                        )
                        // Telegram-style caption: overlaid on the media (never baked into the photo).
                        .overlay(captionView(story.caption, plain: story.config.storyType == .plain()), alignment: .bottom)
                        // Top dark scrim so the username/avatar/close stay readable on white/bright photos.
                        .overlay(topScrim, alignment: .top)
                    // (Removed the always-on bottom photo scrim: the reply pill now sits on the solid
                    // black footer BELOW the card, not over the photo, so dimming the photo's bottom
                    // was pointless and just darkened captionless photos.)
                    // Reply bar floats at the bottom OVER the photo (no black background row anymore).
                    VStack(spacing: 0) { Spacer(); messageView(with: index) }
                    getEmojiView(story: story)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(
                getUserInfoAndProgressBar(with: index)
                    .opacity(isHolding ? 0 : 1)                      // fade chrome out only on a real hold
                    .animation(.linear(duration: 0.2), value: isHolding)
                ,alignment: .top
            )
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
        .onChange(of: viewModel.currentStoryUser) { newValue in
            NotificationCenter.default.post(name: .stopVideo, object: nil)
            resetProgress()
            // WhatsApp/Instagram: when this bucket becomes current, open at the FIRST UNSEEN item (e.g. a new
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
                      bottomCornerRadius: (story.config.storyType != .plain() || model.isMine) ? 24 : 0) {
                start(index: index)
            }
            .onAppear {
                resetAVPlayer()
            }
        case .video:
            VideoView(
                videoURL: story.mediaURL,
                state: $state,
                player: player
            ) { media, duration in
                model.stories[index].duration = duration
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
                    .animation(.easeOut(duration: keyboardManager.animationDuration), value: messageViewPosition)
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
            .padding(.top, winInsets.top + 8)   // keep the progress bars below the notch (host no longer insets)
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
        // Reply-bar (friend) stories sit on a SOLID BLACK footer bar (Instagram), not floating over
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
        .animation(.easeOut(duration: keyboardManager.animationDuration), value: messageViewPosition)
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

    // Telegram StoryContentCaptionComponent: 16pt regular white text with a soft shadow, left-aligned,
    // 16pt side padding, sitting over a 128pt black gradient (0 → 80%). Collapsed to 3 lines; tap to expand.
    @ViewBuilder
    func captionView(_ text: String, plain: Bool = false) -> some View {
        if !text.isEmpty {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 210)   // backs both the caption AND the floating reply bar
                    .allowsHitTesting(false)
                // Our own design (clean, IG/Telegram-style): bottom-LEFT, no hard line, over the soft fade.
                Text(text)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4)
                    .multilineTextAlignment(.leading)
                    .lineLimit(captionExpanded ? 12 : 3)   // cap expansion so a long caption can't overrun the header
                    .padding(.horizontal, 16)
                    // The caption overlay sits on the FULL-SCREEN padded frame (SwiftUI `.padding`
                    // includes the padding in the view's bounds, so `.bottom` aligns to the SCREEN
                    // bottom, not the card bottom). So lift the caption by the full reply-footer
                    // height + a gap — otherwise it slid behind the reply pill (regression).
                    .padding(.bottom, Constant.MessageView.height + 32 + winInsets.bottom + (plain ? 40 : 16))
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
                    .frame(width: geo.size.width / 3)   // left third = back (IG: smaller back zone)
                    .onTapGesture { tapPreviousStory() }
                Rectangle()
                    .fill(.black.opacity(0.01))
                    .onTapGesture { tapNextStory() }     // right two-thirds = next
            }
            // Hold to pause (IG/Snap). onLongPressGesture's onPressingChanged pauses on press-down
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
        // and composing a reply (keyboard open) — any of them freezes the segment + progress.
        guard !isTimerRunning, !isPaused, !hostPause.paused, !isFolding, !isDismissing, !keyboardManager.isKeyboardOpen else { return }
        
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

    // First UNSEEN item index (WhatsApp/Instagram open-at-newest). All seen → 0 (replay from the start).
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

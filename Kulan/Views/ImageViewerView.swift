import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Photos

// Direction-locked pan gesture recognizer. Kulan-local copy so the
// app target can use it (the StoryUI package has its own). Only begins in the allowed direction.
final class DirectionalPanGestureRecognizer: UIPanGestureRecognizer {
    enum Dir { case up, down, left, right, vertical }   // .vertical = the dismiss config (up AND down engage)
    let dir: Dir
    /// Where this touch started, so the direction test can look at the WHOLE gesture so far.
    private var origin: CGPoint?
    /// How far the finger must travel before the direction is considered known. Below this the vector
    /// is noise — a fingertip rolls a point or two sideways at the start of any swipe.
    private let decisionDistance: CGFloat = 12

    init(direction: Dir, target: AnyObject, action: Selector) {
        self.dir = direction
        super.init(target: target, action: action)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        origin = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        origin = nil
        super.reset()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            guard let touch = touches.first else { return }
            let start = origin ?? touch.previousLocation(in: view)
            let loc = touch.location(in: view)
            // CUMULATIVE from the touch's start, not the delta since the last sample. Per-sample was the
            // bug behind "when I swipe left and right it does scroll down": one noisy frame in the
            // middle of a horizontal swipe reads as vertical, and since `.vertical` deliberately never
            // self-cancels once begun, that single frame handed the whole swipe to the dismiss. Judging
            // the whole vector instead means a sideways swipe stays sideways however the finger wobbles.
            let dx = loc.x - start.x
            let dy = loc.y - start.y
            guard hypot(dx, dy) >= decisionDistance else { return }   // too early to tell — keep waiting
            let ok: Bool = {
                if abs(dy) > abs(dx) {
                    if dir == .vertical { return true }   // any predominantly-vertical move engages
                    if dir == .up, dy < 0 { return true }
                    if dir == .down, dy > 0 { return true }
                } else {
                    if dir == .left, dx < 0 { return true }
                    if dir == .right, dx > 0 { return true }
                }
                return false
            }()
            // FAIL, don't just wait. Staying `.possible` left the dismiss armed for the rest of the
            // touch, so a horizontal swipe that drifted downward halfway through still triggered it —
            // and while it stayed armed it was competing with the pager for the same finger, which is
            // why paging did not track cleanly. Failing releases the touch to the pager for good.
            guard ok else { state = .failed; return }
        }
        super.touchesMoved(touches, with: event)
        if state == .began {
            let v = velocity(in: view)
            switch dir {
            case .left, .right: if abs(v.y) > abs(v.x) { state = .cancelled }
            // NO self-cancel for a vertical dismiss drag. Signal's DirectionalPanGestureRecognizer
            // takes `.vertical` as an OptionSet that matches neither their `.up/.down` nor
            // `.left/.right` case, so it falls through to `default: break` and never cancels. Ours
            // cancelled whenever |vx| > |vy| for one sample — and a cancelled recogniser is DEAD for
            // the rest of the touch, so any slightly diagonal drag did nothing at all. That
            // intermittent dead drag is the "not working very well".
            case .up, .down: if abs(v.x) > abs(v.y) { state = .cancelled }
            case .vertical: break
            }
        }
    }
}

// Full-screen photo viewer. Zoom/pan uses ZoomableMediaView (UIScrollView).
// Drag down at rest dismisses; when opened with a gallery, swipe horizontally to page between photos
// (like the native photo viewer). Chrome follows the current page.
struct ImageViewerView: View {
    let gallery: [Message]              // all images in this context (chat / media grid), oldest→newest
    let cid: String
    // REMOVED: `telegramSourceRect` + `TGOpenState`, a SECOND open animation that lived alongside
    // SignalMediaOpen.fly. Every call site passed nil, so it never ran — but it was a whole parallel
    // pipeline with a different spring (0.38 vs Signal's 0.25), a hardcoded 16pt radius, and
    // `UIScreen.main.bounds` instead of the transition container. Exactly the duplicated-view and
    // frame-mismatch hazard the media transition is supposed to be free of. One pipeline now: the
    // UIKit animator pair in SignalMediaDismiss.swift owns both directions.
    @State private var current: String  // id of the page being shown
    @Environment(\.dismiss) private var dismiss

    // Pen edit → full editor → SEND: wired by the conversation (nil in profile/gallery contexts, where
    // there's no send pipeline — the pen button hides there). (data, caption, viewOnce).
    var onSendEdited: ((Data, String, Bool) -> Void)? = nil
    // Delete-for-me (local hide) wired by the conversation — nil in profile/gallery contexts, where the
    // trash offers only Delete for Everyone (own media). When present, the viewer offers BOTH options
    // like the message bubble's delete.
    var onDeleteForMe: ((Message) -> Void)? = nil
    // The visible viewport of the screen the media came from (window coords) — the drag-close's landing
    // is clipped through it (Signal's clippingAreaInsets). The conversation wires this to the message
    // list's live viewport; profile/gallery leave it nil (no clipping, same as before).
    var clipProvider: () -> CGRect? = { nil }
    // Which screen's tile registry this viewer lands on (chat bubble vs All Media tile vs profile
    // thumb). They share message ids, so the scope is what keeps them apart.
    var rectScope: MediaOpenRects.Scope = .chat
    private struct PenEditWrap: Identifiable { let id = UUID(); let image: UIImage }
    @State private var penEdit: PenEditWrap?

    // Single-image entry (existing call sites): a one-page gallery.
    init(message: Message, cid: String,
         onSendEdited: ((Data, String, Bool) -> Void)? = nil,
         onDeleteForMe: ((Message) -> Void)? = nil,
         clipProvider: @escaping () -> CGRect? = { nil },
         rectScope: MediaOpenRects.Scope = .chat) {
        self.gallery = [message]; self.cid = cid
        self.onSendEdited = onSendEdited
        self.onDeleteForMe = onDeleteForMe
        self.clipProvider = clipProvider
        self.rectScope = rectScope
        _current = State(initialValue: message.id)
    }
    // Gallery entry: swipe between all the images, starting at `message`.
    init(message: Message, in gallery: [Message], cid: String,
         onSendEdited: ((Data, String, Bool) -> Void)? = nil,
         onDeleteForMe: ((Message) -> Void)? = nil,
         clipProvider: @escaping () -> CGRect? = { nil },
         rectScope: MediaOpenRects.Scope = .chat) {
        let list = gallery.isEmpty ? [message] : gallery
        self.gallery = list
        self.cid = cid
        self.onSendEdited = onSendEdited
        self.onDeleteForMe = onDeleteForMe
        self.clipProvider = clipProvider
        self.rectScope = rectScope
        _current = State(initialValue: message.id)
        // Seeded so the FIRST frame renders the opened page, not a window centred on 0.
        _windowIndex = State(initialValue: list.firstIndex { $0.id == message.id } ?? 0)
    }

    @State private var chromeHidden = false     // single-tap toggles header + toolbar (Apple Photos)
    @State private var saved = false
    @State private var saveError = false
    @State private var confirmDelete = false
    @State private var deleteFailed = false     // the server refused — say so, like the bubble delete does
    @State private var shareItems: [Any]?
    @State private var loaded: [String: UIImage] = [:]   // page id -> decrypted image
    @State private var pageZoom: CGFloat = 1              // current page's zoom (1 == fit); gates drag-close
    /// Which page the ±1 render window is centred on. Deliberately BEHIND `current` — it catches up
    /// once a swipe has settled, so no page is built or torn down while a finger is still dragging.
    @State private var windowIndex = 0
    @State private var settleToken = 0                    // debounce: only the newest swipe settles
    @State private var zoomOutToken = 0                  // bump to ask the current page to return to fit
    @State private var closeToken = 0                    // bump → the button close flies home like the drag
    @State private var dismissing = false                 // dismiss in flight → live content hidden ONCE

    private var message: Message { gallery.first { $0.id == current } ?? gallery[0] }
    private var isMine: Bool { message.authorId == (AuthService.shared.uid ?? "") }

    // Header title: "You" for my own photo, else the other person's name.
    private var senderName: String {
        let me = AuthService.shared.uid ?? ""
        if message.authorId == me { return "You" }
        return ConversationsRepository.shared.conversations.first { $0.id == cid }?.displayName(me) ?? ""
    }
    private var dateLine: String { message.createdAt.formatted(date: .numeric, time: .shortened) }
    // NOT gated on `dismissing` any more: during a drag-close the chrome must stay in the tree so the
    // root-alpha scrub can fade it with the finger. Its 0.25s ease here would fight that scrub.
    private var chromeVisible: Bool { !chromeHidden }

    private func closeViewer() {
        // ZOOM OUT FIRST, like Signal — but the close must NEVER be hostage to the zoom-out. The old
        // version re-called itself until the zoom read ≤ 1.02, and with a STALE pageZoom (reported high
        // while the scroll view is actually at fit) zoomOutToFit no-ops, no zoom callback fires, and the
        // retry loop spun forever with the back arrow dead (user report: after a drag, the arrow stopped
        // working; screenshot showed the viewer stuck with chrome up). One zoom-out attempt, then close
        // regardless.
        if pageZoom > 1.02 {
            zoomOutToken += 1
            // Let the zoom settle so the closing state matches the screen — then close no matter what.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { closeToken += 1 }
        } else {
            // ONE exit for every way out (user report: the arrow cut away while the drag flew home).
            // The token routes the button close through SignalDismissHost's fly-home; its no-geometry
            // fallback calls onDismiss, so closing can never be blocked.
            closeToken += 1
        }
    }
    /// The drag-close's exit. The flying copy IS the animation, so the presentation itself must go
    /// without one — SignalDismissHost calls this with its copy still covering the same pixels.
    ///
    /// …which is what this now actually does. It used to be a bare `dismiss()`, so the cover ALSO
    /// played its own slide-out underneath the copy: invisible, because the copy covers those pixels,
    /// but it kept the presentation alive for the length of that animation — and SwiftUI drops a new
    /// cover requested while the old one is still leaving. That is why the photo was back in its bubble
    /// and still not tappable.
    private func instantDismiss() {
        MediaPresentGate.noteDismissed()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { dismiss() }
    }

    var body: some View {
        // Split into pagerLayer/chromeLayer — the inline body blew the type-checker budget.
        ZStack {
            Color.black.ignoresSafeArea()
            // ONLY the media hides when a drag-close begins — the flying copy replaces it 1:1. The
            // black background and the chrome stay LIVE: the coordinator fades the whole presented
            // root with the finger (Signal's fromView.alpha scrub), so chrome melts into the chat
            // with the drag instead of vanishing on its first frame, and fades back if you cancel.
            pagerLayer
                .opacity(dismissing ? 0 : 1)
            chromeLayer
        }
        .overlay {
            // The interactive drag-down close. Unconditional: the system .zoom transition this used to
            // be suppressed for is gone from every chat-media entry point.
            SignalDismissHost(
                canBegin: { pageZoom <= 1.02 },
                media: {
                    // The SAME warm-cache chain the page itself renders from. `loaded` only fills from
                    // the async load, so a page drawn straight from the memory cache could report nil
                    // here — and a nil media means the drag NEVER BEGINS. That was "drag-to-close
                    // sometimes doesn't work" for photos, while video always worked (its closure never
                    // returns nil, it falls back to a snapshot).
                    let m = message
                    guard let img = loaded[current] ?? m.localImageData.flatMap(UIImage.init(data:))
                        ?? m.imageUrl.flatMap({ DiskImageCache.shared.memoryImage($0) }) else { return nil }
                    return (mediaFitRect(img.size, in: UIScreen.main.bounds), img)
                },
                onHideContent: { dismissing = $0 },
                // Land on the thumbnail this photo came from. Reported live by MediaRectReporter,
                // keyed by the CURRENT page's id, so paging to another photo and closing lands on
                // that one's tile rather than the one we opened with.
                targetRect: { MediaOpenRects.rect(MediaOpenRects.key(rectScope, current)) },
                targetId: { MediaOpenRects.key(rectScope, current) },
                clipRect: clipProvider,
                closeToken: closeToken,
                onDismiss: { instantDismiss() })
        }
        // Transparent presentation so the fading backdrop reveals the CONVERSATION behind.
        .presentationBackground(.clear)
        // The cover is gone for real — release a tap that arrived while it was leaving, instead of
        // making it wait out a fixed guess at how long that takes. See MediaPresentGate.
        .onDisappear { MediaPresentGate.noteClosed() }
        .alert("Couldn't save photo", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Check Photos permission and try again.") }
        .alert("Couldn't delete for everyone", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The server refused the delete. The photo is still there for both of you.")
        }
        .alert("Delete this photo?", isPresented: $confirmDelete) {
            // Same options as the message bubble's delete (user report: the photo delete offered only
            // one option). Own photo → Everyone + Me; Delete for Me hides locally via the conversation.
            if isMine {
                Button("Delete for Everyone", role: .destructive) {
                    // deleteMessage routes album pages (synthetic "<parentId>-<i>" ids) to a real
                    // album-item removal — the raw id used to target a nonexistent doc, which the
                    // server refused, so an album photo could never be deleted for everyone.
                    Task {
                        if await ChatService.deleteMessage(cid: cid, messageId: message.id) {
                            await MainActor.run { dismiss() }
                        } else {
                            await MainActor.run { deleteFailed = true }
                        }
                    }
                }
            }
            if let onDeleteForMe {
                Button("Delete for Me", role: .destructive) { onDeleteForMe(message); dismiss() }
            } else if !isMine {
                // Fallback (no repo wired): received photo hides locally.
                Button("Delete for Me", role: .destructive) {
                    HiddenMessages.hide(message.id); dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let items = shareItems { ActivityView(items: items) }
        }
        // Pen flow (user spec): opens straight into DRAW mode; tapping Done there lands in the SAME full
        // image editor used for fresh photos (crop, pen, HD, filters, caption — no new flow), and Send
        // delivers the edited image with everything baked in. X backs out to this viewer.
        .fullScreenCover(item: $penEdit) { wrap in
            // selfDismissOnSend: false — the editor must NOT dismiss itself on Send: that revealed THIS
            // viewer for a few seconds ("a second image preview page") before it closed. dismiss() on the
            // viewer takes the whole stack (viewer + editor) down in one motion instead.
            ChatImageEditor(source: wrap.image,
                            onSend: { data, caption, _, viewOnce in
                                onSendEdited?(data, caption, viewOnce)
                                dismiss()   // back to the conversation, where the edited copy is sending
                            },
                            startDrawing: true,
                            selfDismissOnSend: false)
        }
    }

    // Horizontal paging between photos; each page zooms/dismisses independently. EVERY page is
    // pinned to the exact full screen size (GeometryReader) so a portrait (9:16) and a landscape
    // (16:9) photo page identically — mixed aspect ratios were paging with inconsistent geometry
    // (offset/jank at the page seam). The image aspect-fits + centers WITHIN each uniform page.
    private var pagerLayer: some View {
        GeometryReader { geo in
            // THE WINDOW LAGS THE SELECTION ON PURPOSE — see the note on `.onChange(of: current)`.
            let here = windowIndex
            TabView(selection: $current) {
                ForEach(Array(gallery.enumerated()), id: \.element.id) { pair in
                    pagerPage(pair.element, idx: pair.offset, currentIdx: here)
                        .frame(width: geo.size.width, height: geo.size.height)   // uniform page size
                        .tag(pair.element.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The TabView must ignore the safe area ITSELF, not just live inside a full-bleed
            // GeometryReader: a paging TabView offsets its pages down by the top safe area otherwise.
            // Every letterboxed photo hid that offset inside its own bars; a photo with the screen's
            // exact aspect (a screenshot) has no bars, so the offset showed as a black strip at the
            // top - "the image looks cut at the status bar" (user report).
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        // NOTHING HEAVY ON THE COMMIT FRAME. This is the "swipe only follows my finger halfway, then it
        // finishes by itself" report, and the cause is what used to run right here.
        //
        // A paging TabView flips `current` as you pass the midpoint, WHILE YOUR FINGER IS STILL DOWN.
        // Three things then fired on that single frame: a `pageZoom` state write that invalidated the
        // whole viewer, a prefetch, and — the expensive one — the ±1 page window shifting, which
        // destroys one ZoomImageView and builds another SYNCHRONOUSLY. A UIViewControllerRepresentable
        // being torn down and reconstructed mid-gesture is exactly what breaks an interactive
        // transition: the tracking stops and the system animates the remaining half. Hence "50%".
        //
        // So the work is moved off that frame. `windowIndex` — which decides which pages are real —
        // follows the selection only after the transition has settled, so no page is created or
        // destroyed while you are still dragging. The page you are swiping INTO is already inside the
        // old window, so it is live the whole way.
        .onChange(of: current) { _, _ in
            // Only when it actually differs: paging is gated on being at fit anyway (`canBegin`), so
            // this was almost always writing 1 over 1 and invalidating the body for nothing.
            if pageZoom != 1 { pageZoom = 1 }
            settleToken &+= 1
            let token = settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard token == settleToken else { return }   // superseded by a newer swipe
                windowIndex = currentIndex
                prefetchNeighbors()   // decrypt+decode the new neighbours, now that nothing is moving
            }
        }
        .task {
            windowIndex = currentIndex
            prefetchNeighbors()
        }
    }

    /// Position of every message id, built ONCE per gallery change instead of scanned per page.
    ///
    /// `currentIndex` and `pagerPage` both used to call `gallery.firstIndex { $0.id == ... }`, and a
    /// paging TabView evaluates every page on every body pass — so each pass cost O(pages × gallery)
    /// string comparisons, over the whole chat's photo set. That work landed squarely on the frame the
    /// swipe commits, which is where the stutter was visible.
    private var indexById: [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(gallery.count)
        for (i, m) in gallery.enumerated() { out[m.id] = i }
        return out
    }
    private var currentIndex: Int { indexById[current] ?? 0 }

    @ViewBuilder private func pagerPage(_ m: Message, idx: Int, currentIdx: Int) -> some View {
        // A paging TabView materialises EVERY child up front. In a chat with dozens of photos that
        // meant dozens of ZoomImageViews — each with its own decrypt+decode task — all built before
        // the first frame could appear, which is the rest of the "opens late" delay. Only the current
        // page and its immediate neighbours get a real view; the far pages stay empty until you page
        // near them (they were never on screen anyway).
        if abs(idx - currentIdx) > 1 {
            Color.clear
        } else {
            // PIN THE PAGE TO THE WINDOW, by measurement instead of guesswork. The paging TabView has
            // been placing its page slots below the window origin (the "image is cut at the status
            // bar" and "image jumps down after opening" reports — the fly-open lands the copy centered
            // in the WINDOW, then the real page rendered lower and the photo visibly hopped). Container
            // and TabView both ignore the safe area already and the offset still survived, so stop
            // arguing with the slot: measure where this page actually sits and cancel it. On a
            // correctly placed page the measured offset is zero and this is a no-op.
            GeometryReader { pg in
                realPagerPage(m)
                    .frame(width: pg.size.width, height: pg.size.height)
                    .offset(y: -pg.frame(in: .global).minY)
            }
        }
    }

    @ViewBuilder private func realPagerPage(_ m: Message) -> some View {
        // SYNCHRONOUS warm-cache fallback so the photo is on the FIRST frame. `loaded` starts empty, so
        // this used to render a spinner and only fill in after an async task — even though the bubble
        // you just tapped had already decoded the image into the memory cache. That one-frame-plus gap
        // is what read as "the image opens late".
        if let img = loaded[m.id] ?? m.localImageData.flatMap(UIImage.init(data:))
            ?? m.imageUrl.flatMap({ DiskImageCache.shared.memoryImage($0) }) {
            // Inner UIKit dismiss-pan DISABLED here — the drag-to-close is driven at the CONTAINER level
            // so it can't fight the TabView pager (the 2-day bug). ZoomImageView keeps only pinch-zoom.
            ZoomImageView(image: img,
                          onSingleTap: { withAnimation(.easeInOut(duration: 0.25)) { chromeHidden.toggle() } },
                          onZoom: { pageZoom = $0 },
                          zoomOutToken: zoomOutToken,
                          imageKey: m.id)   // reload on a new PHOTO, never on a new UIImage of the same one
        } else {
            ProgressView().tint(.white)
                .task { await load(m) }
        }
    }

    private var chromeLayer: some View {
        VStack {
            header
            Spacer()
            // Album/group context: thumbnails of EVERY image in the group, current highlighted —
            // tap to jump (reference: centered strip just above the bottom bar).
            if gallery.count > 1 { thumbStrip }
            bottomBar
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
    }

    // Floating Liquid Glass header: back · You/name + date · "…" menu (Go to Chat / Save Image / Delete).
    private var header: some View {
        HStack(alignment: .center) {
            glassButton("chevron.left") { closeViewer() }
            Spacer()
            VStack(spacing: 1) {
                Text(senderName).font(.subheadline.weight(.semibold))
                Text(dateLine).font(.caption2)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .liquidGlass(Capsule(), interactive: false)
            Spacer()
            Menu {
                Button { save() } label: { Label("Save Image", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
            }
        }
        .padding(.horizontal, 12).padding(.top, 4)
    }

    // Thumbnail strip (group context): small rounded thumbs of every image, the current one framed —
    // tap any to jump to it. Centered above the bottom bar (reference screenshot).
    // Split into small pieces (thumbCell / thumbImage) — the inline version blew the type-checker budget.
    private var thumbStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // LAZY, and with no strip-wide animation — both for the swipe's sake. This was an eager
            // HStack over every photo in the chat, each thumb drawing a full-size UIImage through a
            // clipShape + strokeBorder (an offscreen pass apiece), and the `.animation(value: current)`
            // meant all of them ran a 200ms layout animation on the exact frame the page committed.
            // The per-cell animation below still animates the one thumb whose size actually changes.
            LazyHStack(spacing: 5) {
                ForEach(gallery) { m in thumbCell(m) }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)   // few thumbs → centered; many → scrolls
        }
        .frame(height: 44)
        .padding(.bottom, 8)
    }

    private func thumbCell(_ m: Message) -> some View {
        let isCurrent: Bool = m.id == current
        let side: CGFloat = isCurrent ? 38 : 32
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { current = m.id }
        } label: {
            thumbImage(m)
                .frame(width: side, height: side)
                .clipShape(shape)
                .overlay { if isCurrent { shape.strokeBorder(Color.white, lineWidth: 1.5) } }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)   // only the two thumbs that change
    }

    @ViewBuilder private func thumbImage(_ m: Message) -> some View {
        // Same warm-cache fallback as the pages, so the filmstrip isn't a row of grey boxes on open.
        if let img = loaded[m.id] ?? m.imageUrl.flatMap({ DiskImageCache.shared.memoryImage($0) }) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color.white.opacity(0.15)
                .task { await load(m) }   // strip thumbs load lazily like pages
        }
    }

    // Bottom toolbar: 48px real Liquid Glass circle buttons — Share · Pen (draw on it + re-send) ·
    // (Delete own / Save received).
    private var bottomBar: some View {
        HStack {
            barButton("square.and.arrow.up") { share() }
            Spacer()
            // PEN (replaces Reply, user spec): opens the pen editor on THIS image; Done lands in the
            // FULL image editor (crop/pen/HD/…) — the same editor as a fresh photo — and Send delivers
            // the edited copy with every modification baked in. Hidden where no send pipeline exists.
            if onSendEdited != nil {
                barButton("scribble.variable") {
                    // currentImage, not loaded[current] — see the note on currentImage.
                    if let img = currentImage { penEdit = PenEditWrap(image: img) }
                }
            }
            Spacer()
            if isMine {
                barButton("trash", tint: .red) { confirmDelete = true }
            } else {
                barButton("square.and.arrow.down") { save() }   // received photo → Save instead of Delete
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // NATIVE glyph contrast (user spec): .primary adapts to the glass — black glyphs when the material
    // renders light, white when it renders dark (the hardcoded .white vanished on light glass).
    private func barButton(_ icon: String, tint: Color = .primary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func glassButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
        }
    }

    // Pre-load the pages either side of the current one (idempotent — load() no-ops on cache hits).
    private func prefetchNeighbors() {
        guard let idx = gallery.firstIndex(where: { $0.id == current }) else { return }
        for off in [-1, 1] {
            let i = idx + off
            guard gallery.indices.contains(i) else { continue }
            let m = gallery[i]
            if loaded[m.id] == nil { Task { await load(m) } }
        }
    }

    // Load order: optimistic local bytes → cached decrypted → decrypt-on-demand (per page).
    private func load(_ m: Message) async {
        if let data = m.localImageData, let ui = UIImage(data: data) { loaded[m.id] = ui; return }
        guard let u = m.imageUrl else { return }
        if let mem = DiskImageCache.shared.memoryImage(u) { loaded[m.id] = mem; return }
        if let cached = await DiskImageCache.shared.image(for: u) { loaded[m.id] = cached; return }
        // Not cached yet → download the ciphertext + decrypt (same path SecureImageView uses).
        if let url = URL(string: u), let meta = m.enc,
           let (cipher, _) = try? await URLSession.shared.data(from: url),
           let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) {
            loaded[m.id] = UIImage(data: dec)
        }
    }

    /// The photo currently on screen, resolved EXACTLY the way `realPagerPage` resolves it.
    ///
    /// `loaded` is filled only by the async `load(_:)` path, and that path runs only when the page
    /// has nothing to draw. A photo already in the memory cache — the normal case, because the
    /// bubble you just tapped decoded it — renders straight from that cache and never lands in
    /// `loaded`. So Share, Pen and Save all read nil on a photo that is plainly on screen and did
    /// nothing at all (owner report; Delete kept working because it needs no image).
    private var currentImage: UIImage? {
        if let img = loaded[current] { return img }
        guard let m = gallery.first(where: { $0.id == current }) else { return nil }
        return m.localImageData.flatMap(UIImage.init(data:))
            ?? m.imageUrl.flatMap { DiskImageCache.shared.memoryImage($0) }
    }

    private func share() {
        guard let image = currentImage else { return }
        shareItems = [image]
    }

    private func save() {
        Task {
            // Last resort: a page still decrypting has neither, so fetch it before giving up rather
            // than reporting a failure the user can see is wrong.
            var resolved = currentImage
            if resolved == nil, let m = gallery.first(where: { $0.id == current }) {
                await load(m)
                resolved = loaded[current]
            }
            guard let image = resolved else { await MainActor.run { saveError = true }; return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { await MainActor.run { saveError = true }; return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                await MainActor.run {
                    withAnimation { saved = true }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch { await MainActor.run { saveError = true } }
        }
    }
}

// Host VC that drives ZoomableMediaView (pinch/double-tap zoom for one page).
// DELETED HERE: the per-page drag-down-to-dismiss pan (`allowsDismissPan` + `handleDismiss`, a
// YBImageBrowser-derived interaction with its own thresholds and spring). Every caller disabled it —
// the drag-to-close is driven at the CONTAINER level by SignalDismissHost so it can never fight the
// TabView pager — so it was a third, unreachable dismiss implementation with different numbers.
struct ZoomImageView: UIViewControllerRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}
    var onZoom: (CGFloat) -> Void = { _ in }   // reports live zoom scale so the container can gate drag-dismiss
    var cornerRadius: CGFloat = 0       // >0 rounds the IMAGE itself (tall media), scaled to stay visually constant
    // false in the single-image EDITOR: the zoomed photo may overflow its letterboxed canvas and cover
    // the full screen (the chrome floats over it) — the same unclipped growth as the video editor's
    // scaleEffect zoom, so at full zoom there are no top/bottom borders. Viewers keep the default clip.
    var clipsZoomOverflow: Bool = true
    // Bumped by the container to ask this page to zoom back to fit. Signal zooms out BEFORE it starts a
    // dismiss, with the comment "Swapping mediaView for presentationView will be perceptible if we're not
    // zoomed out all the way" - closing a zoomed photo otherwise swaps a zoomed view for an unzoomed
    // transition and the swap is visible as a jump. A counter rather than a Bool so repeated requests
    // still fire, and so the value can never get stuck on.
    var zoomOutToken: Int = 0
    /// Identity of the PHOTO, not of the UIImage object. Given one, a reload happens only when this
    /// changes — see updateUIViewController for why that matters.
    var imageKey: String? = nil

    func makeUIViewController(context: Context) -> ZoomImageController {
        let vc = ZoomImageController()
        vc.image = image
        vc.onSingleTap = onSingleTap
        vc.onZoom = onZoom
        vc.mediaCornerRadius = cornerRadius
        vc.clipsZoomOverflow = clipsZoomOverflow
        context.coordinator.lastZoomOutToken = zoomOutToken
        return vc
    }

    final class Coordinator {
        var lastZoomOutToken = 0
        var lastImageKey: String?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateUIViewController(_ uiViewController: ZoomImageController, context: Context) {
        if zoomOutToken != context.coordinator.lastZoomOutToken {
            context.coordinator.lastZoomOutToken = zoomOutToken
            uiViewController.zoomOutToFit(animated: true)
        }
        // RELOAD ON A NEW PHOTO, NOT ON A NEW OBJECT — this is the flash when arriving at the next
        // image (user 2026-07-29). The test used to be `!==`, pure object identity, and the same photo
        // arrives as a DIFFERENT UIImage all the time: a page rendered from `localImageData` builds one
        // on every body pass, and the settled prefetch drops its own copy into `loaded` a moment after
        // a swipe lands. Each of those looked like a change, so the controller tore the image view down
        // and rebuilt it — on the page you had just swiped to, which is exactly when you see it.
        //
        // The key is the photo's id plus its pixel size, so re-resolving the same picture is free while
        // a genuinely better decode still reloads.
        let key = imageKey.map { "\($0)|\(Int(image.size.width))x\(Int(image.size.height))" }
        let changed = key.map { $0 != context.coordinator.lastImageKey } ?? (uiViewController.image !== image)
        if changed {
            context.coordinator.lastImageKey = key
            uiViewController.image = image
            uiViewController.reloadImage()
        }
        uiViewController.setCornerRadius(cornerRadius)
    }
}

final class ZoomImageController: UIViewController, UIScrollViewDelegate {
    var image: UIImage!
    var onSingleTap: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var clipsZoomOverflow = true   // editor sets false → zoom grows past the canvas like the video editor

    private var scrollView: ZoomableMediaView!
    private var imageView: UIImageView!
    var mediaCornerRadius: CGFloat = 0
    /// Last ratio handed to `onZoom`, so a layout pass that changed nothing writes no SwiftUI state.
    private var lastReportedZoom: CGFloat = 1

    func setCornerRadius(_ r: CGFloat) {
        guard r != mediaCornerRadius else { return }
        mediaCornerRadius = r
        scrollView?.mediaCornerRadius = r
        scrollView?.updateZoomScaleForLayout()
    }

    // Editor swaps the image (filter/crop applied) — refresh in place, keeping the zoom view.
    /// Return this page to fit. Signal zooms out BEFORE dismissing - swapping a zoomed live view for an
    /// unzoomed transition copy is visible as a jump, which their own source calls "perceptible".
    func zoomOutToFit(animated: Bool) {
        guard let sv = scrollView, sv.zoomScale != sv.minimumZoomScale else { return }
        sv.setZoomScale(sv.minimumZoomScale, animated: animated)
    }

    func reloadImage() {
        guard let imageView else { return }
        imageView.image = image
        imageView.sizeToFit()
        scrollView?.updateZoomScaleForLayout()
        // A swapped image starts at FIT. The zoom RANGE is recomputed above, but the old absolute
        // zoomScale survived the swap — when a pen bake had changed the image's pixel size, the stale
        // scale no longer meant "fit", so finishing a crop landed visibly zoomed in (user report).
        // setZoomScale fires scrollViewDidZoom → re-centers + reports onZoom, same as a manual zoom-out.
        if let sv = scrollView, sv.zoomScale != sv.minimumZoomScale {
            sv.setZoomScale(sv.minimumZoomScale, animated: false)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.clipsToBounds = true
        imageView.layer.allowsEdgeAntialiasing = true
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear

        scrollView = ZoomableMediaView(mediaView: imageView, onSingleTap: { [weak self] in self?.onSingleTap?() })
        scrollView.mediaCornerRadius = mediaCornerRadius
        scrollView.clipsToBounds = clipsZoomOverflow   // editor: overflow the canvas while zooming (video parity)
        scrollView.delegate = self
        view.addSubview(scrollView)
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        scrollView.updateZoomScaleForLayout()
        // HEAL STALE ZOOM REPORTS. scrollViewDidZoom only fires on CHANGES, so a ratio computed against
        // a not-yet-final minimumZoomScale can stick — the container then believes the page is zoomed
        // while the screen shows it at fit, which silently blocked BOTH the drag-to-close (canBegin)
        // and the back arrow (its zoom-out-first loop waited for a callback that could never come).
        // Re-report the true ratio after every layout; async so the SwiftUI state write never lands
        // mid-layout.
        //
        // ONLY WHEN IT CHANGED. A same-value write is NOT free: `onZoom` sets SwiftUI @State, and this
        // runs on every layout pass of every live page, so an unconditional write re-invalidated the
        // viewer's body over and over during a swipe — which rebuilt the pager, which laid out again.
        // That loop is what turned the paging animation's one busy frame into sustained stutter.
        let ratio = scrollView.zoomScale / max(scrollView.minimumZoomScale, 0.0001)
        guard abs(ratio - lastReportedZoom) > 0.001 else { return }
        lastReportedZoom = ratio
        DispatchQueue.main.async { [weak self] in self?.onZoom?(ratio) }
    }

    // MARK: UIScrollViewDelegate
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        (scrollView as? ZoomableMediaView)?.updateZoomScaleForLayout()
        view.layoutIfNeeded()
        lastReportedZoom = scrollView.zoomScale / scrollView.minimumZoomScale
        onZoom?(lastReportedZoom)   // 1.0 == fit (not zoomed)
    }

}

// Zoomable media view backed by a UIScrollView. min zoom = fit, max = fit*8, double-tap to 2x at the
// tap point, constraint-based centering, safe-area change resets zoom.
final class ZoomableMediaView: UIScrollView {
    private let mediaView: UIView
    private let singleTapBlock: () -> Void
    private var topC: NSLayoutConstraint!
    private var bottomC: NSLayoutConstraint!
    private var leadingC: NSLayoutConstraint!
    private var trailingC: NSLayoutConstraint!
    private var lastSafeAreaSize: CGSize = .zero
    var mediaCornerRadius: CGFloat = 0   // rounds the mediaView; kept visually constant (divided by minScale)

    init(mediaView: UIView, onSingleTap: @escaping () -> Void = {}) {
        self.mediaView = mediaView
        self.singleTapBlock = onSingleTap
        super.init(frame: .zero)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        leadingC = mediaView.leadingAnchor.constraint(equalTo: leadingAnchor)
        topC = mediaView.topAnchor.constraint(equalTo: topAnchor)
        trailingC = mediaView.trailingAnchor.constraint(equalTo: trailingAnchor)
        bottomC = mediaView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([leadingC, topC, trailingC, bottomC])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    @objc private func handleDoubleTap(_ g: UIGestureRecognizer) {
        guard zoomScale == minimumZoomScale else { zoomOut(animated: true); return }
        let doubleTapZoomScale: CGFloat = 2
        let zoomWidth = bounds.width / doubleTapZoomScale
        let zoomHeight = bounds.height / doubleTapZoomScale
        let tap = g.location(in: self)
        let zoomX = max(0, tap.x - zoomWidth / doubleTapZoomScale)
        let zoomY = max(0, tap.y - zoomHeight / doubleTapZoomScale)
        let rect = CGRect(x: zoomX, y: zoomY, width: zoomWidth, height: zoomHeight)
        zoom(to: mediaView.convert(rect, from: self), animated: true)
    }
    @objc private func handleSingleTap() { singleTapBlock() }

    func updateZoomScaleForLayout() {
        let svSize = bounds.size
        let mediaSize: CGSize
        let intrinsic = mediaView.intrinsicContentSize
        if intrinsic.width > 0, intrinsic.height > 0 {
            mediaSize = intrinsic
        } else if let iv = mediaView as? UIImageView, let img = iv.image, img.size.width > 0, img.size.height > 0 {
            mediaSize = img.size
        } else {
            mediaSize = svSize
        }

        let mvSize = mediaView.frame.size
        let yOffset = max(0, (bounds.height - mvSize.height) / 2)
        let xOffset = max(0, (bounds.width - mvSize.width) / 2)
        topC.constant = yOffset
        bottomC.constant = yOffset
        leadingC.constant = xOffset
        trailingC.constant = -xOffset

        let scaleWidth = svSize.width / mediaSize.width
        let scaleHeight = svSize.height / mediaSize.height
        let minScale = min(scaleWidth, scaleHeight)
        let maxScale = minScale * 8
        minimumZoomScale = minScale
        maximumZoomScale = maxScale
        // Round the media itself. The mediaView is at its FULL pixel size (the scroll view scales it by
        // zoomScale), so to show a constant ~cornerRadius pt at the fitted (min) zoom, the layer radius
        // must be divided by minScale. Corners grow when zoomed in — but they're off-screen by then.
        if mediaCornerRadius > 0, minScale > 0 {
            mediaView.layer.cornerRadius = mediaCornerRadius / minScale
            mediaView.layer.masksToBounds = true
        } else {
            mediaView.layer.cornerRadius = 0
        }
        if zoomScale < minScale { zoomScale = minScale }
        else if zoomScale > maxScale { zoomScale = maxScale }

        let safe = safeAreaLayoutGuide.layoutFrame.size
        if abs(safe.width - lastSafeAreaSize.width) > 0.001 || abs(safe.height - lastSafeAreaSize.height) > 0.001 {
            zoomScale = minimumZoomScale
        }
        lastSafeAreaSize = safe
    }

    func zoomOut(animated: Bool) {
        guard zoomScale != minimumZoomScale else { return }
        setZoomScale(minimumZoomScale, animated: animated)
    }
}

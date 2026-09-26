import SwiftUI
import AVFoundation
import FirebaseStorage
import Photos   // 2026-09-24 decision D16: Save to Photos

// Full-screen player for an E2EE video message — the delivery half of the mailman model:
// play from the device copy if we have one; otherwise download the ciphertext, decrypt,
// KEEP it on this device (VideoCache), and then delete the server object (1:1 chats) so
// our storage never holds delivered videos. Groups skip the delete (other members still
// need it) — the 30-day storage sweep collects those.
//
// The player itself is a custom media-viewer style (not AVKit): a plain AVPlayer layer with a MINIMAL,
// fading chrome — a bottom scrubber + time labels + play/pause, tap the video to toggle the chrome, no
// native transport bar / PiP / AirPlay clutter.
struct VideoPlayerScreen: View {
    let message: Message
    let cid: String
    // The visible viewport of the screen the video came from (window coords) — the drag-close's landing
    // is clipped through it, same as the image viewer. Nil = no clipping (gallery/profile).
    var clipProvider: () -> CGRect? = { nil }
    // Which screen's tile registry to land on — ids are shared across screens, scopes are not.
    var rectScope: MediaOpenRects.Scope = .chat
    // 2026-09-24 decision D16: Share / Save / Forward / Delete, like the photo viewer. Delete-for-me
    // is wired by the conversation (same meaning as ImageViewerView.onDeleteForMe); nil elsewhere,
    // where a received video falls back to the plain local hide, exactly as the photo viewer does.
    var onDeleteForMe: ((Message) -> Void)? = nil
    @State private var shareItems: [Any]?
    @State private var saveError = false
    @State private var confirmDelete = false
    @State private var deleteFailed = false
    @State private var forwarding: Message?
    private var isMine: Bool { message.authorId == AuthService.shared.uid }
    // (A second, SwiftUI open/close animation used to live here alongside the UIKit one. It is gone —
    // see the note in ImageViewerView. One pipeline owns both directions for photo and video alike.)

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var unavailable = false
    @State private var loadFailed = false   // transient (no network / server hiccup), retryable
    @State private var loadAttempt = 0
    /// The shared download's byte fraction while the clip is still arriving (nil = length unknown).
    @State private var dlFraction: Double?
    @State private var isPlaying = true
    @State private var progress: Double = 0        // 0…1 (bound to the scrubber)
    @State private var current: Double = 0         // seconds
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var showChrome = true
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var interruptObserver: NSObjectProtocol?
    @State private var hideWork: DispatchWorkItem?
    @State private var dismissing = false          // dismiss in flight → live content hidden ONCE
    @State private var closeToken = 0              // bump → the button close flies home like the drag
    // Pinch-zoom + pan (video hosted in the same zoomable view as photos).
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var panDrag: CGSize = .zero
    // Scrubbing (see `scrubChanged`).
    @State private var scrubLastX: CGFloat?
    @State private var scrubRate: Double = 1
    @State private var scrubPreview: UIImage?
    @State private var scrubPreviewX: CGFloat = 0
    @State private var frameGrabber: AVAssetImageGenerator?
    // Hold for speed (see `holdForSpeed`).
    @State private var holdStart: CGPoint?
    @State private var fastForward = false
    @State private var fastRate: Float = 2
    @State private var fastWork: DispatchWorkItem?
    @State private var heldAt: Date?

    private var zoomed: Bool { max(1, zoom * pinch) > 1.01 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // ONLY the player content hides when a drag-close begins — the flying poster copy replaces
            // it. Background and chrome stay live so the coordinator's root-alpha scrub (the reference app's
            // fromView.alpha) can melt them into the chat with the finger, and back on cancel.
            playerContent
                .opacity(dismissing ? 0 : 1)
        }
        .overlay(alignment: .top) { if showChrome { topBar } }
        .overlay(alignment: .bottom) { if showChrome, player != nil { scrubberBar } }
        .overlay(alignment: .top) { if fastForward { speedPill } }
        // Both bars and the middle controls together, 0.3s ease-in-out — theirs.
        .animation(.easeInOut(duration: 0.3), value: showChrome)
        .animation(.easeInOut(duration: 0.2), value: fastForward)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
        // Zoomed-in pan (the dismiss drag is now the shared pan below, images + videos identical).
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .updating($panDrag) { v, s, _ in if zoomed { s = v.translation } }
                .onEnded { g in
                    if zoomed { pan.width += g.translation.width; pan.height += g.translation.height }
                }
        )
        // The interactive dismiss — the SAME code path as the image viewer
        // (MediaDismiss.swift): one UIKit vertical pan, lightweight poster copy locked 1:1 to
        // the finger, constant 0.8 scale, root-alpha scrub, 0.25s spring.
        .overlay {
            // Unconditional: the system .zoom this used to be suppressed for is gone from chat media.
            MediaDismissHost(
                canBegin: { !zoomed && !scrubbing },
                media: {
                    // The video's fitted rect from its stored dimensions (fallback: full screen).
                    let bounds = UIScreen.main.bounds
                    var size = bounds.size
                    if let w = message.width, let h = message.height, w > 0, h > 0 {
                        size = CGSize(width: w, height: h)
                    }
                    // Fly the POSTER, not a live-region snapshot. Passing nil took the
                    // resizableSnapshotView branch, which captures whatever chrome has not finished
                    // hiding yet - the reference app always flies a still frame for video, never a layer or a
                    // snapshot of the screen.
                    return (mediaFitRect(size, in: bounds), poster)
                },
                onHideContent: { hidden in
                    if hidden { player?.pause() }   // freeze playback the moment the copy takes over
                    dismissing = hidden
                },
                // Land on the thumbnail this video came from. Without this the default { nil } was used,
                // so video drifted and faded in mid-air while photos flew home to their tile - the single
                // most visible difference between the two media types.
                targetRect: { MediaOpenRects.rect(MediaOpenRects.key(rectScope, message.id)) },
                targetId: { MediaOpenRects.key(rectScope, message.id) },
                clipRect: clipProvider,
                closeToken: closeToken,
                onDismiss: { instantDismiss() })
        }
        .presentationBackground(.clear)   // the fading backdrop reveals the conversation behind
        // Always dark, for the same reason as the photo viewer beside it and in the same breath as
        // his report — see the note in `ImageViewerView`. The two screens share a chrome vocabulary
        // and would look like different apps in light mode if only one were pinned.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .task(id: loadAttempt) { await load() }   // Try Again bumps the id; closing still cancels it
        // noteClosed: the cover is gone for real, so a tap that arrived while it was leaving can run
        // now instead of waiting out a fixed guess. See MediaPresentGate.
        // A flying copy outlives this cover on purpose (it lands on the thumbnail after the viewer
        // is gone). If its landing never completes it is left in the window, drawn over the
        // conversation — see `sweepOrphanedFlights`.
        .onDisappear { cleanup(); MediaPresentGate.noteClosed(); MediaDismissHost.scheduleOrphanSweep() }
        // 2026-09-24 decision D16: the photo viewer's alerts and sheets, video wording.
        .alert("Couldn't save video", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Check Photos permission and try again.") }
        .alert("Couldn't delete for everyone", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The server refused the delete. The video is still there for both of you.")
        }
        .alert("Delete this video?", isPresented: $confirmDelete) {
            if isMine {
                Button("Delete for Everyone", role: .destructive) {
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
                Button("Delete for Me", role: .destructive) { HiddenMessages.hide(message.id); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let items = shareItems { ActivityView(items: items) }
        }
        .sheet(item: $forwarding) { m in ForwardPicker(message: m, sourceCid: cid) }
    }

    // 2026-09-24 decision D16: the decrypted clip on this device (VideoCache, or the sender's own
    // not-yet-uploaded file). Nil while it is still downloading; Share then does nothing and Save
    // says it could not, the same as the photo viewer on a photo that has not loaded.
    private var localVideoURL: URL? {
        VideoCache.url(for: message.id) ?? message.localMediaURL.map { URL(fileURLWithPath: $0) }
    }

    private func share() {
        guard let url = localVideoURL else { return }
        shareItems = [url]
    }

    private func save() {
        Task {
            guard let url = localVideoURL else { await MainActor.run { saveError = true }; return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { await MainActor.run { saveError = true }; return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                await MainActor.run { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            } catch { await MainActor.run { saveError = true } }
        }
    }

    /// The still the transition flies. the reference app flies a poster frame for video too — never a player
    /// layer, never a snapshot of the live region — which is what makes video and photo behave alike.
    private var poster: UIImage? { message.thumbUrl.flatMap { DiskImageCache.shared.memoryImage($0) } }

    // The playing surface + its overlays, split out of `body` so the drag-close can hide EXACTLY this
    // (the copy's pixels) while background and chrome ride the root-alpha scrub.
    // ⛔ THE REFERENCE APP'S VIDEO VIEWER, READ FROM ITS SOURCE — owner, 2026-09-26: "completely
    // redesign video controls, exactly like theirs, logic and physics". What that means here:
    //   · a TAP shows or hides the controls (it no longer plays/pauses); both bars go together, 0.3s
    //   · play/pause is a 92pt glass button in the MIDDLE of the video, with 64pt ±15s buttons 30pt
    //     either side on clips of 30s or more
    //   · the scrubber is an 8pt bar with no knob and a 44pt touch area; the seek lands on RELEASE,
    //     a frame preview follows the finger, and dragging away from the bar slows it (½, ¼, 1/100)
    //   · double-tap the left or right 30% jumps 15s, silently
    //   · hold the right 40% for 0.3s to play at 2×; slide sideways to go 1×–4×
    //   · controls hide after 4s of playback; clips of 30s or less loop, longer ones stop at the end
    @ViewBuilder private var playerContent: some View {
        if let player {
            PlayerLayerView(player: player)
                .scaleEffect(max(1, zoom * pinch))
                .offset(x: pan.width + panDrag.width, y: pan.height + panDrag.height)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { v, s, _ in s = v }
                        .onEnded { v in zoom = min(4, max(1, zoom * v)); if zoom <= 1 { pan = .zero } }
                )
                .onTapGesture(count: 2, coordinateSpace: .global) { loc in
                    let w = UIScreen.main.bounds.width
                    if loc.x < w * 0.3 { skip(-15) } else if loc.x > w * 0.7 { skip(15) }
                }
                .onTapGesture {
                    // A hold for 2× ends with the finger lifting, which is also a tap.
                    if let t = heldAt, Date().timeIntervalSince(t) < 0.3 { return }
                    toggleChrome()
                }
                .simultaneousGesture(holdForSpeed)
            // Shown with the chrome, and always while paused so there is a way back to playing.
            if (showChrome || !isPlaying) && !zoomed {
                centerControls.transition(.opacity)
            }
        } else if unavailable {
            VStack(spacing: 10) {
                Image(systemName: "video.slash").font(.system(size: 34))
                Text("Video no longer available").font(.system(size: 15, weight: .medium))
                Text("It was delivered and removed from the server.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
        } else if loadFailed {
            VStack(spacing: 10) {
                Image(systemName: "wifi.slash").font(.system(size: 34))
                Text("Could not load").font(.system(size: 15, weight: .medium))
                Button("Try Again") { loadFailed = false; loadAttempt += 1 }
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
        } else {
            // Theirs: a 50pt translucent black disc with the ring turning inside it — filled by the
            // real bytes once the download knows its length.
            ZStack {
                Circle().fill(.black.opacity(0.5))
                if let f = dlFraction {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 2.5).padding(8)
                    Circle().trim(from: 0, to: max(0.03, f))
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(8)
                        .animation(.linear(duration: 0.15), value: f)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 50, height: 50)
        }
    }

    // Video closes exactly like a photo: one pipeline, the UIKit animator pair. The button close
    // flies the poster home through MediaDismissHost, same as the drag (its no-geometry fallback
    // dismisses plainly, so closing is never blocked).
    private func closeViewer() { closeToken += 1 }
    /// The drag-close's exit: the flying poster IS the animation, so the presentation goes without one.
    /// The transaction is what makes that true — a bare `dismiss()` still ran the cover's own slide-out
    /// under the copy, which held the presentation open and blocked an immediate re-tap.
    private func instantDismiss() {
        MediaPresentGate.noteDismissed()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { dismiss() }
    }

    // MARK: - Middle controls

    private var centerControls: some View {
        HStack(spacing: 30) {
            if duration >= 30 { seekButton(-15) }
            Button { togglePlay(); showChromeBriefly() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 92, height: 92)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            if duration >= 30 { seekButton(15) }
        }
    }

    private func seekButton(_ seconds: Double) -> some View {
        Button { skip(seconds); showChromeBriefly() } label: {
            Image(systemName: seconds < 0 ? "gobackward.15" : "goforward.15")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds")
    }

    // MARK: - Header: back · name and date · menu

    private var senderName: String {
        let me = AuthService.shared.uid ?? ""
        if message.authorId == me { return "You" }
        return ConversationsRepository.shared.conversations.first { $0.id == cid }?.displayName(me) ?? ""
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button { closeViewer() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer(minLength: 8)
            // Theirs: a round pill 44 tall, at least 150 wide, 14 in from each side; the name at 17
            // semibold over the date at 12, half white.
            VStack(spacing: 2) {
                Text(senderName).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Text(message.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minWidth: 150, minHeight: 44)
            .liquidGlass(Capsule(), interactive: false)
            Spacer(minLength: 8)
            // 2026-09-24 decision D16: the photo viewer's actions, in its header-menu idiom.
            Menu {
                Button { share() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { save() } label: { Label("Save Video", systemImage: "square.and.arrow.down") }
                if message.sendState == nil, !message.deleted, !message.viewOnce {
                    Button { forwarding = message } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
        }
        .padding(.horizontal, 12).padding(.top, 4)
        .transition(.opacity)
    }

    // MARK: - Scrubber

    private var scrubberBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fmt(current))
                Spacer()
                Text(fmt(duration))
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.42))
                    Capsule().fill(.white)
                        .frame(width: max(0, min(1, progress)) * g.size.width)
                }
                .frame(height: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())   // the whole 44pt row takes the finger, not the 8pt bar
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in scrubChanged(v, width: g.size.width) }
                        .onEnded { _ in scrubEnded() }
                )
            }
            .frame(height: 44)
        }
        // 26 = their 8pt row inset + 18 on a phone with a home indicator.
        .padding(.horizontal, 26)
        .padding(.bottom, 4)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) { scrubPreviewView }
        .transition(.opacity)
    }

    /// The frame under the finger, 6pt above the bar: 160 × 90, or 90 × 160 for a portrait clip,
    /// following the finger and kept 10pt inside the screen, with the time under it.
    @ViewBuilder private var scrubPreviewView: some View {
        if scrubbing, let img = scrubPreview {
            let portrait = (message.height ?? 0) > (message.width ?? 0)
            let size = portrait ? CGSize(width: 90, height: 160) : CGSize(width: 160, height: 90)
            let sw = UIScreen.main.bounds.width
            let x = min(max(26 + scrubPreviewX - size.width / 2, 10), sw - size.width - 10)
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottom) {
                    Text(fmt(current)).font(.system(size: 13)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .padding(.bottom, 5)
                }
                .offset(x: x, y: -(size.height + 6))
                .allowsHitTesting(false)
        }
    }

    /// The seek follows the finger's MOVEMENT, not its position, so touching the bar never jumps —
    /// and moving away from the bar slows it: 50, 100 and 150pt give ½, ¼ and 1/100 speed, with a
    /// tick at each step. Nothing seeks until the finger lifts.
    private func scrubChanged(_ v: DragGesture.Value, width: CGFloat) {
        if !scrubbing {
            scrubbing = true
            scrubLastX = v.startLocation.x
            scrubRate = 1
            cancelAutoHide()
        }
        let away = abs(v.translation.height)
        let rate: Double = away >= 150 ? 0.01 : away >= 100 ? 0.25 : away >= 50 ? 0.5 : 1
        if rate != scrubRate {
            scrubRate = rate
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        let dx = v.location.x - (scrubLastX ?? v.location.x)
        scrubLastX = v.location.x
        progress = max(0, min(1, progress + Double(dx / max(1, width)) * rate))
        current = progress * duration
        scrubPreviewX = max(0, min(width, v.location.x))
        requestPreview(at: current)
    }

    private func scrubEnded() {
        seek(to: progress)
        scrubbing = false
        scrubLastX = nil
        scrubPreview = nil
        if isPlaying { scheduleAutoHide() }
    }

    private func requestPreview(at t: Double) {
        guard let g = frameGrabber else { return }
        g.cancelAllCGImageGeneration()
        g.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 600)) { cg, _, _ in
            guard let cg else { return }
            let img = UIImage(cgImage: cg)
            DispatchQueue.main.async { scrubPreview = img }
        }
    }

    // MARK: - Hold for speed

    /// Hold the right 40% for 0.3s: 2×. Slide sideways while holding: 1× to 4× across ±100pt.
    /// Lifting puts the rate back. Only while playing — setting a rate would start a paused clip.
    private var holdForSpeed: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if holdStart == nil {
                    holdStart = v.startLocation
                    guard isPlaying, v.startLocation.x > UIScreen.main.bounds.width * 0.6 else { return }
                    let w = DispatchWorkItem {
                        guard isPlaying else { return }
                        fastForward = true
                        fastRate = 2
                        player?.rate = 2
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    fastWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
                } else if !fastForward, hypot(v.translation.width, v.translation.height) > 10 {
                    fastWork?.cancel()   // a swipe or a drag-to-close, not a hold
                }
                if fastForward {
                    let r = Float(min(4, max(1, 2 + v.translation.width / 100 * 2)))
                    fastRate = r
                    player?.rate = r
                }
            }
            .onEnded { _ in
                fastWork?.cancel(); fastWork = nil
                holdStart = nil
                if fastForward {
                    fastForward = false
                    heldAt = Date()
                    if isPlaying { player?.rate = 1 }
                }
            }
    }

    private var speedPill: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.1f×", fastRate)).font(.system(size: 15, weight: .semibold).monospacedDigit())
            Image(systemName: "forward.fill").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).frame(height: 32)
        .liquidGlass(Capsule(), interactive: false)
        .padding(.top, 60)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Playback control

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false; showChrome = true; cancelAutoHide() }
        else {
            if current >= duration - 0.05 { player.seek(to: .zero); current = 0; progress = 0 }   // replay from end
            player.play(); isPlaying = true; scheduleAutoHide()
        }
    }

    private func seek(to p: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: p * duration, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func toggleChrome() {
        showChrome.toggle()
        if showChrome && isPlaying { scheduleAutoHide() } else { cancelAutoHide() }
    }
    // Ensure the controls are visible right after a tap, then auto-hide again if playing.
    private func showChromeBriefly() {
        showChrome = true
        if isPlaying { scheduleAutoHide() } else { cancelAutoHide() }
    }
    // Jump ±N seconds, clamped to the clip. Silent, as theirs is: the time label says where you are.
    private func skip(_ seconds: Double) {
        guard let player, duration > 0 else { return }
        let t = max(0, min(duration, current + seconds))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = t
        progress = duration > 0 ? t / duration : 0
    }
    private func scheduleAutoHide() {
        cancelAutoHide()
        let w = DispatchWorkItem { if isPlaying && !scrubbing { showChrome = false } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)   // theirs: 4.0s
    }
    private func cancelAutoHide() { hideWork?.cancel(); hideWork = nil }

    // MARK: - Load (mailman: local → download+decrypt+cache → clear server)

    private func load() async {
        if let local = VideoCache.url(for: message.id) { await MainActor.run { startPlayer(local) }; return }
        // ⛔ MY OWN VIDEO PLAYS FROM THE FILE I SENT — owner, 2026-09-26: tapping a video sat on the
        // spinner. The clip I just sent is on this phone at `localMediaURL` (Share already used it,
        // line ~170), but loading skipped it and went to the network: a long wait for a file that
        // was right here, and nothing at all while the upload had not produced a URL yet.
        if let path = message.localMediaURL, FileManager.default.fileExists(atPath: path) {
            await MainActor.run { startPlayer(URL(fileURLWithPath: path)) }
            return
        }
        // Known-gone (mailman: delivered 1:1 videos are deleted server-side; a 404 is PERMANENT).
        // Terminal state — show unavailable instantly, never re-fetch (the unrecoverable-attachment state).
        if DeadMedia.contains(message.id) { await MainActor.run { unavailable = true }; return }
        guard let s = message.videoUrl, !s.isEmpty, message.enc != nil else {
            await MainActor.run { unavailable = true }; return
        }
        // ⛔ THE SHARED JOB, NOT A SECOND DOWNLOAD — 2026-09-26 media pass. This screen used to fetch
        // the whole clip itself, beside whatever the bubble or the chat-open sweep was already
        // fetching, and lost everything it had when it was closed. It joins that one job now: the
        // bytes keep coming after a close, a retry continues from where it stopped, and the mailman
        // delete runs in the job's finisher once the local copy is really on this phone.
        // Through the binding: the observer outlives this call, and a captured copy of the view
        // struct is not a handle on its live storage (the same rule SecureImageView follows).
        let fraction = $dlFraction
        let ok: Bool = await MainActor.run { () -> Task<Bool, Never> in
            let watch = MediaDownloads.shared.observe(s) { state in fraction.wrappedValue = state.fraction }
            return Task { @MainActor in
                defer { MediaDownloads.shared.stopObserving(s, watch) }
                return await MediaDownloads.shared.download(
                    s, priority: .user,
                    finish: MediaFetch.videoFinisher(url: s, enc: message.enc, cid: cid,
                                                     messageId: message.id, authorId: message.authorId))
            }
        }.value
        if Task.isCancelled { return }
        if let local = VideoCache.url(for: message.id) {
            await MainActor.run { startPlayer(local) }
            return
        }
        _ = ok
        let permanent = await MainActor.run { MediaDownloads.shared.state(for: s) == .failed(permanent: true) }
        if permanent { DeadMedia.mark(message.id) }   // object deleted → permanent, never re-fetch
        await MainActor.run { if permanent { unavailable = true } else { loadFailed = true } }
    }

    @MainActor private func startPlayer(_ url: URL) {
        // ⛔ ONE THING PLAYS AT A TIME. This screen sets the category and activates the session
        // directly, with no call check and no handover — and only ONE place in the whole app ever
        // pauses the voice player, which is not this one. So a note playing on the floating bar kept
        // playing underneath a video, both audible at once, and opening a video during a call took
        // the category out from under the call service.
        //
        // The broadcast that used to prevent this was removed on the reasoning that there is only one
        // player now. There are three: this, the gallery and the story player.
        VoiceNotePlayer.shared.pause()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p
        // The scrub preview's frames. Small and loose on purpose: it has to keep up with a finger.
        let grabber = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        grabber.appliesPreferredTrackTransform = true
        grabber.maximumSize = CGSize(width: 320, height: 320)
        grabber.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        grabber.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        frameGrabber = grabber
        duration = message.duration ?? 0
        // Smooth scrubber (a high-frequency observer); don't fight the user while scrubbing.
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            if duration <= 0, let d = p.currentItem?.duration.seconds, d.isFinite { duration = d }
            guard !scrubbing else { return }
            current = time.seconds
            progress = duration > 0 ? min(1, current / duration) : 0
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: p.currentItem, queue: .main) { _ in
            // Theirs: a clip of 30s or less loops; a longer one stops on its last frame and brings
            // the controls back.
            let length = p.currentItem?.duration.seconds ?? 0
            if length.isFinite, length > 0, length <= 30 {
                p.seek(to: .zero); p.play()
            } else {
                isPlaying = false; showChrome = true; cancelAutoHide()
            }
        }
        // A call or another app's audio pauses AVPlayer by itself, but the screen kept showing it as
        // playing with the chrome hidden and no play button (2026-09-24 audit). Show it paused.
        interruptObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                   object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            isPlaying = false; showChrome = true; cancelAutoHide()
        }
        p.play(); isPlaying = true
        scheduleAutoHide()
    }

    private func cleanup() {
        cancelAutoHide()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        if let i = interruptObserver { NotificationCenter.default.removeObserver(i) }
        player?.pause()
    }
}

// Plain AVPlayer layer (aspect-fit), no AVKit transport controls — a custom media-viewer surface.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerUIView { PlayerLayerUIView(player: player) }
    func updateUIView(_ v: PlayerLayerUIView, context: Context) { v.setPlayer(player) }
}

private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    func setPlayer(_ p: AVPlayer) { if playerLayer.player !== p { playerLayer.player = p } }
}

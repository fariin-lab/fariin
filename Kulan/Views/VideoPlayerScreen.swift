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
// The player itself is a custom media-viewer style (not AVKit): a plain AVPlayer layer with the
// reference app's chrome (2026-09-26, its source read with his screenshot beside it): a glass title
// capsule between two round glass buttons at the top; at the bottom a 44pt glass capsule holding
// the elapsed time, a knobless track and the remaining time, and under it three 44pt round glass
// buttons, share / play-pause / forward. A tap on the video shows or hides all of it; nothing hides
// on a timer. A 92pt round play button sits mid-screen only while the clip is paused with the
// chrome away, so there is always a way back to playing.
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
    /// Playback speed (owner 2026-11-13: "add speed"). `defaultRate` makes every later play() keep it.
    @State private var speed: Float = 1
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
    @State private var chromeEntered = false   // the open fade (0.15 s linear)
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var interruptObserver: NSObjectProtocol?
    /// The player layer has drawn its first picture. Until then the poster is what is on screen.
    @State private var firstFrameShown = false
    /// The spinner waits a beat: a clip on this phone has its player well inside it, and a spinner
    /// that flashes for a tenth of a second reads as loading when nothing was.
    @State private var spinnerDue = false
    @State private var lifetime = Lifetime()
    /// Whether this viewer has closed. A reference, so the audio setup that finishes off the main
    /// thread can still ask after the view's own storage is gone.
    private final class Lifetime {
        var closed = false
        /// When the viewer was built, which is the tap (for the VSTREAM# tap-to-first-frame line).
        let openedAt = Date()
        var firstFrameLogged = false
        /// How this clip is being played, for that line: local, stream, full or fallback.
        var mode = "local"
        /// The streaming asset (`ChatVideoStream`), released on close or on fallback.
        var stream: AVURLAsset?
        var streamHeld: Int64 = 0
        /// The stream failed or stalled: this viewer downloads the whole clip instead.
        var noStream = false
        var itemStatus: NSKeyValueObservation?
    }
    /// A plain clip is playing through `ChatVideoStream` and has not drawn its first frame yet.
    @State private var streaming = false
    @State private var dismissing = false          // dismiss in flight → live content hidden ONCE
    @State private var closeToken = 0              // bump → the button close flies home like the drag
    // Pinch-zoom + pan (video hosted in the same zoomable view as photos).
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var panDrag: CGSize = .zero
    /// Scrubbing pauses the clip and puts it back afterwards if it was playing (theirs).
    @State private var wasPlayingBeforeScrub = false

    private var zoomed: Bool { max(1, zoom * pinch) > 1.01 }

    /// ⛔ A ZOOMED VIDEO PANS INSIDE ITS OWN EDGES (owner 2026-11-08: zoomed in, a drag down took the
    /// video off the bottom of the screen). The pan had no limit. Now, like a scroll view and the
    /// reference app's gallery: the clip's edge stops at the screen's edge, a drag past it stretches
    /// (rubber band) and springs back on release.
    private func panLimit(_ scale: CGFloat) -> CGSize {
        let bounds = UIScreen.main.bounds
        var size = bounds.size
        if let w = message.width, let h = message.height, w > 0, h > 0 { size = CGSize(width: w, height: h) }
        let fit = mediaFitRect(size, in: bounds).size
        return CGSize(width: max(0, (fit.width * scale - bounds.width) / 2),
                      height: max(0, (fit.height * scale - bounds.height) / 2))
    }

    private static func clamp(_ v: CGSize, _ lim: CGSize) -> CGSize {
        CGSize(width: min(lim.width, max(-lim.width, v.width)),
               height: min(lim.height, max(-lim.height, v.height)))
    }

    /// Past the edge the content follows the finger less and less (UIScrollView's 0.55 constant).
    private static func rubber(_ v: CGSize, _ lim: CGSize) -> CGSize {
        func one(_ x: CGFloat, _ l: CGFloat) -> CGFloat {
            let over = abs(x) - l
            guard over > 0 else { return x }
            let d: CGFloat = 400
            let r = (1 - 1 / (over * 0.55 / d + 1)) * d
            return x < 0 ? -(l + r) : (l + r)
        }
        return CGSize(width: one(v.width, lim.width), height: one(v.height, lim.height))
    }

    /// Where the clip is drawn: the settled pan plus the live drag, stretched past the edges.
    private var shownPan: CGSize {
        let raw = CGSize(width: pan.width + panDrag.width, height: pan.height + panDrag.height)
        return Self.rubber(raw, panLimit(max(1, zoom * pinch)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // ONLY the player content hides when a drag-close begins — the flying poster copy replaces
            // it. Background and chrome stay live so the coordinator's root-alpha scrub (the reference app's
            // fromView.alpha) can melt them into the chat with the finger, and back on cancel.
            playerContent
                .modifier(RestrictedCapture(cid: cid))
                .opacity(dismissing ? 0 : 1)
        }
        // The bottom panel measures from the screen's bottom EDGE, as theirs does on every phone;
        // the top bar keeps the top safe area.
        .ignoresSafeArea(edges: .bottom)
        // ⛔ FADE IN ON OPEN, NO POP — owner, 2026-10-08. The reference gallery's `animateIn`: both
        // bars start at alpha 0 and fade to 1 over 0.15 s, linear, as the media opens. Ours drew the
        // top bar at full opacity on the first frame and dropped the bottom panel in, unanimated,
        // the moment the player was ready.
        .overlay(alignment: .top) { if showChrome { topBar.opacity(chromeEntered ? 1 : 0) } }
        .overlay(alignment: .bottom) {
            if showChrome, player != nil { bottomPanel.opacity(chromeEntered ? 1 : 0).transition(.opacity) }
        }
        .animation(.linear(duration: 0.15), value: player != nil)
        .onAppear {
            guard !chromeEntered else { return }
            withAnimation(.linear(duration: 0.15)) { chromeEntered = true }
        }
        // Both bars together, 0.3s ease-in-out — theirs.
        .animation(.easeInOut(duration: 0.3), value: showChrome)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
        // Zoomed-in pan (the dismiss drag is now the shared pan below, images + videos identical).
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .updating($panDrag) { v, s, _ in if zoomed { s = v.translation } }
                .onEnded { g in
                    guard zoomed else { return }
                    let raw = CGSize(width: pan.width + g.translation.width, height: pan.height + g.translation.height)
                    pan = Self.rubber(raw, panLimit(zoom))   // where it was drawn, so no jump
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        pan = Self.clamp(raw, panLimit(zoom))
                    }
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
                onDismiss: { instantDismiss() },
                // ⛔ A DRAG THAT SPRINGS BACK PLAYS ON — owner, 2026-09-28: "when I scroll down on a
                // video and back up, the video is frozen". The drag pauses the clip the moment it
                // begins (above), and nothing ever started it again, so it sat on one frame with the
                // pause button still showing. `isPlaying` is still the viewer's own word on whether
                // it was playing, so a clip he had paused himself stays paused.
                onCancel: {
                    guard isPlaying, !lifetime.closed else { return }
                    player?.play()
                })
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
            // The usual cause is Photos access being off: one tap to the switch.
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { Text("Check Photos permission and try again.") }
        .alert("Couldn't delete for everyone", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The server refused the delete. The video is still there for both of you.")
        }
        .alert("Delete this video?", isPresented: $confirmDelete) {
            // Remote limit deleteForEveryoneHours: the bubble's window (ChatService.ownDeleteForEveryoneOpen).
            if isMine && ChatService.ownDeleteForEveryoneOpen(message, cid: cid) {
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
            if ChatService.deletesOnlyForEveryone(cid: cid) {
                // No Delete for Me in a group (owner 2026-10-26).
            } else if let onDeleteForMe {
                Button("Delete for Me", role: .destructive) { onDeleteForMe(message); dismiss() }
            } else if !(isMine && ChatService.ownDeleteForEveryoneOpen(message, cid: cid)) {
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

    /// Disable Sharing (owner, 2026-10-03): No Saving takes Save and Share, No Forwarding takes Forward.
    private var savingLocked: Bool { ChatRestrictions.isOn(.noSaving, cid: cid) }
    private var forwardingLocked: Bool { ChatRestrictions.isOn(.noForwarding, cid: cid) }

    private func share() {
        guard !savingLocked, let url = localVideoURL else { return }
        shareItems = [url]
    }

    private func save() {
        guard !savingLocked else { return }
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
    // ⛔ THE REFERENCE APP'S VIDEO VIEWER, ITS SOURCE READ AGAINST HIS SCREENSHOT — owner,
    // 2026-09-26: "the video controls still do not look like theirs; make it exactly this UI".
    // Yesterday's port took its behaviour from the OTHER messenger he compares against (precision
    // scrubbing with a frame preview, hold for 2×, double-tap skips, loops, a 4s auto-hide); all of
    // that is gone. What is here now, from their source:
    //   · a TAP shows or hides the chrome; both bars go together, 0.3s; no timer hides them
    //   · the bottom panel: a 44pt glass capsule with "00:00", a knobless track and "-00:07", then
    //     24pt below it three 44pt round glass buttons: share, play/pause, forward
    //   · scrubbing seeks live under the finger, pauses the clip and resumes it on release
    //   · the clip stops on its last frame at the end; nothing loops
    //   · a 92pt round play button mid-screen while paused with the chrome away
    @ViewBuilder private var playerContent: some View {
        // ⛔ THE POSTER STAYS UNTIL THE FIRST FRAME — owner, 2026-09-28: "a loading spinner and the
        // screen completely black for a few seconds, every time, even reopening the same video".
        // The still that flew in from the bubble was thrown away the moment the viewer was up, and
        // what replaced it was a black background and a player layer with nothing drawn yet. The
        // reference app keeps its still frame on screen until the player has a picture; so does
        // this now. Hidden once the first frame is drawn, so it never shows behind a zoomed or
        // panned video.
        if !firstFrameShown, !unavailable, !loadFailed, let poster {
            Image(uiImage: poster)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        if let player {
            PlayerLayerView(player: player, onFirstFrame: { firstFrameShown = true; noteFirstFrame() })
                .scaleEffect(max(1, zoom * pinch))
                .offset(x: shownPan.width, y: shownPan.height)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { v, s, _ in s = v }
                        .onEnded { v in
                            zoom = min(4, max(1, zoom * v))
                            // Zooming out pulls the clip back inside its new, smaller edges.
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                                pan = zoom <= 1 ? .zero : Self.clamp(pan, panLimit(zoom))
                            }
                        }
                )
                .onTapGesture { toggleChrome() }
            // His screenshot: chrome up and the clip paused, and nothing mid-screen — the row's own
            // play button is the control. The big one covers the state with no chrome to press.
            if !isPlaying && !showChrome && !zoomed {
                centerPlayButton.transition(.opacity)
            }
            // A streaming clip waits on its first bytes over the poster: say so.
            if streaming && !firstFrameShown {
                ZStack {
                    Circle().fill(.black.opacity(0.5))
                    ProgressView().tint(.white)
                }
                .frame(width: 50, height: 50)
                .allowsHitTesting(false)
            }
        } else if unavailable {
            VStack(spacing: 10) {
                Image(systemName: "video.slash").font(.system(size: 34))
                // Owner 2026-10-23 ("what happened, server?"): the old line said "delivered and removed
                // from the server" for every case, but only a delivered 1:1 clip is removed. A group
                // clip whose key was sealed for the members of the day, without me, was never removed;
                // it cannot be opened here. Each case now says what is true.
                Text(unavailableWords.title).font(.system(size: 15, weight: .medium))
                Text(unavailableWords.detail)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
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
            // A real download (it knows its length) shows at once; anything else waits a beat.
            .opacity(dlFraction != nil || spinnerDue ? 1 : 0)
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                spinnerDue = true
            }
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

    // MARK: - The mid-screen play button

    /// Why a clip cannot be played, in true words (owner 2026-10-23). 1:1 ids are "uidA_uidB".
    private var unavailableWords: (title: String, detail: String) {
        if MediaFetch.sealedWithoutMe(message.enc) {
            return ("Video can't be opened", "It was sent before you joined this group.")
        }
        if message.videoUrl?.isEmpty ?? true || message.enc == nil {
            return ("Video no longer available", "This video's file is missing.")
        }
        if cid.contains("_") {
            return ("Video no longer available", "It was delivered and removed from the server.")
        }
        return ("Video no longer available", "Its file was removed from the server.")
    }

    private var centerPlayButton: some View {
        Button { togglePlay() } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play")
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
            // Theirs: a glass capsule at least 44 tall, 24 in from each side and 4 above and below;
            // the name in subheadline semibold over the date in caption, both in the label colour,
            // the date in the short date and time style ("9/26/26, 7:28 PM").
            VStack(spacing: 2) {
                Text(senderName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(message.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption).foregroundStyle(.primary)
            }
            .lineLimit(1)
            .padding(.horizontal, 24).padding(.vertical, 4)
            .frame(minHeight: 44)
            .liquidGlass(Capsule(), interactive: true)
            Spacer(minLength: 8)
            // Theirs: Save and Delete live in the menu; Share and Forward are the bottom row's buttons.
            // ⛔ ITS OWN EQUATABLE VIEW (owner 2026-11-13, build 1187: "Speed button is not working").
            // The playback clock writes `current`/`progress` about 20 times a second, which re-ran this
            // whole body; an inline Menu was rebuilt on every tick and iOS closed the Speed submenu
            // before a speed could be picked. Built from plain values only, it redraws only when one
            // of them changes.
            PlayerMoreMenu(
                speed: speed,
                canSave: !savingLocked,
                // In a group Delete leads somewhere only when it can go for everyone (no Delete for Me).
                canDelete: !ChatService.deletesOnlyForEveryone(cid: cid)
                    || (isMine && ChatService.ownDeleteForEveryoneOpen(message, cid: cid)),
                actions: PlayerMoreMenu.Actions(setSpeed: { setSpeed($0) }, save: { save() },
                                                delete: { confirmDelete = true })
            )
            .equatable()
        }
        .padding(.horizontal, 12).padding(.top, 4)
        .transition(.opacity)
    }

    // MARK: - The bottom panel: scrubber capsule, then share · play/pause · forward

    /// Theirs: the capsule 44 tall with its labels 16 in; 24 between it and the button row; the row
    /// a fixed distance from the screen's bottom edge (the container ignores the bottom safe area).
    private var bottomPanel: some View {
        VStack(spacing: 24) {
            scrubberCapsule
            HStack {
                panelButton("ic_link_share", label: "Share",
                            enabled: localVideoURL != nil && !savingLocked) { share() }
                Spacer()
                // 10s back / forward beside play in ONE capsule (owner 2026-10-21, with the
                // reference's picture), only on a clip of 20s or more: on a short one a 10s jump
                // is half the video.
                if duration >= 20 {
                    HStack(spacing: 18) {
                        skipButton(-10)
                        playButton
                        skipButton(10)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .liquidGlass(Capsule(), interactive: true)
                } else {
                    playButton
                        .liquidGlass(Circle(), interactive: true)
                }
                Spacer()
                panelButton("arrowshape.turn.up.right", label: "Forward",
                            enabled: localVideoURL != nil && message.sendState == nil
                                     && !message.deleted && !message.viewOnce && !forwardingLocked) {
                    guard !forwardingLocked else { return }
                    forwarding = message
                }
            }
            .padding(.horizontal, 4)   // the buttons' centres 46 from each edge in his screenshot
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .transition(.opacity)
    }

    private var playButton: some View {
        Button { togglePlay() } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func skipButton(_ seconds: Double) -> some View {
        Button { skip(by: seconds) } label: {
            Image(systemName: seconds < 0 ? "gobackward.10" : "goforward.10")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
    }

    private func skip(by seconds: Double) {
        guard duration > 0 else { return }
        let t = min(max(current + seconds, 0), duration)
        current = t
        progress = t / duration
        seek(to: t / duration)
    }

    /// One of the row's round glass buttons: a 24pt-class icon in a 44pt circle, greyed while the
    /// clip is not on this phone yet (theirs disable share and forward until it is).
    private func panelButton(_ symbol: String, label: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(glyph: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    /// Elapsed on the left, the remaining time on the right behind a minus, 13pt monospaced digits;
    /// between them a track with no knob, filled in the label colour over the quaternary one.
    private var scrubberCapsule: some View {
        HStack(spacing: 12) {
            Text(clock(current))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.primary)
                        .frame(width: max(0, min(1, progress)) * g.size.width)
                }
                .frame(height: 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())   // the capsule's whole height takes the finger
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in scrubChanged(v, width: g.size.width) }
                        .onEnded { _ in scrubEnded() }
                )
            }
            Text("-" + clock(max(0, duration - current)))
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .liquidGlass(Capsule(), interactive: true)
    }

    /// Theirs: the finger's position IS the time (a slider), the seek lands on every move, and the
    /// clip is paused for the drag and put back on release if it was playing.
    private func scrubChanged(_ v: DragGesture.Value, width: CGFloat) {
        if !scrubbing {
            scrubbing = true
            wasPlayingBeforeScrub = isPlaying
            player?.pause()
        }
        progress = max(0, min(1, Double(v.location.x / max(1, width))))
        current = progress * duration
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: current, preferredTimescale: 600))
    }

    private func scrubEnded() {
        seek(to: progress)
        scrubbing = false
        if wasPlayingBeforeScrub { player?.play(); isPlaying = true }
        wasPlayingBeforeScrub = false
    }

    /// "00:00" — the minutes padded too, as their formatter pads every unit.
    private func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let t = Int(s.rounded(.down)); return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: - Playback control

    static func speedLabel(_ s: Float) -> String {
        s == 1 ? "Normal" : (s == s.rounded() ? "\(Int(s))×" : "\(s)×")
    }

    /// The new speed now if playing, and for every later play().
    private func setSpeed(_ s: Float) {
        speed = s
        player?.defaultRate = s
        if isPlaying { player?.rate = s }
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else {
            if current >= duration - 0.05 { player.seek(to: .zero); current = 0; progress = 0 }   // replay from end
            player.play(); isPlaying = true
        }
    }

    private func seek(to p: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: p * duration, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Theirs: the tap is the only thing that shows or hides the chrome; no timer does.
    private func toggleChrome() { showChrome.toggle() }

    // MARK: - Load (mailman: local → download+decrypt+cache → clear server)

    private func load() async {
        if let local = VideoCache.url(for: message.id) {
            await MainActor.run { startPlayer(local) }; return
        }
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
        // ⛔ A PLAIN CLIP PLAYS WHILE IT ARRIVES (owner approved 2026-11-11). Channels and groups
        // created since 2026-10-19 store the mp4 itself, so the player reads it through
        // `ChatVideoStream` (range fetches into one partial file) instead of waiting for the whole
        // download. Sealed clips (1:1, old encrypted groups) never stream: one seal covers the whole
        // file. A stream that fails or shows no frame in 8 s falls back to the full download below.
        let streamed: Bool = await MainActor.run {
            guard !lifetime.noStream, ChatVideoStream.canStream(enc: message.enc, cid: cid, url: s) else { return false }
            return startStream(s)
        }
        if streamed { return }
        await MainActor.run { lifetime.mode = lifetime.noStream ? "fallback" : "full" }
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

    /// Start the clip through `ChatVideoStream`. False: download it whole instead.
    @MainActor private func startStream(_ s: String) -> Bool {
        let state = MediaDownloads.shared.state(for: s)
        // A full download well on its way ends sooner than a fresh stream would start.
        if let f = state.fraction, f >= 0.6 { return false }
        guard let made = ChatVideoStream.asset(itemId: message.id, url: s) else { return false }
        // One transfer for these bytes: the stream takes over from a full download still early on.
        if state.isActive { MediaDownloads.shared.cancel(s) }
        let asset = made.asset
        let life = lifetime
        life.stream = asset
        life.streamHeld = made.held
        life.mode = "stream"
        streaming = true
        ChatVideoStream.diag("open id=\(message.id) held=\(made.held)")
        let item = AVPlayerItem(asset: asset)
        life.itemStatus = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in streamFallback("item failed") }
        }
        startPlayer(item: item)
        // The watchdog: a stream that shows nothing in 8 s is not going to beat a plain download.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !life.closed, !life.firstFrameLogged, life.stream === asset else { return }
            streamFallback("no first frame in 8s")
        }
        return true
    }

    /// Give up on the stream and load again as a full download. What arrived stays in the partial.
    @MainActor private func streamFallback(_ why: String) {
        let life = lifetime
        guard !life.closed, let asset = life.stream else { return }
        let ms = Int(Date().timeIntervalSince(life.openedAt) * 1000)
        ChatVideoStream.diag("fallback id=\(message.id) why=\(why) ms=\(ms)")
        life.itemStatus = nil
        life.stream = nil
        life.noStream = true
        life.firstFrameLogged = false
        life.mode = "fallback"
        streaming = false
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        if let i = interruptObserver { NotificationCenter.default.removeObserver(i) }
        timeObserver = nil; endObserver = nil; interruptObserver = nil
        player?.pause()
        player = nil
        firstFrameShown = false
        ChatVideoStream.release(asset)
        loadAttempt += 1   // `load` runs again, and this time downloads the whole clip
    }

    /// The first picture is on screen: one VSTREAM# line with the time since the tap.
    private func noteFirstFrame() {
        let life = lifetime
        guard !life.firstFrameLogged else { return }
        life.firstFrameLogged = true
        streaming = false
        let ms = Int(Date().timeIntervalSince(life.openedAt) * 1000)
        ChatVideoStream.diag("firstframe id=\(message.id) mode=\(life.mode) ms=\(ms) preloaded=\(life.streamHeld)")
    }

    @MainActor private func startPlayer(_ url: URL) {
        startPlayer(item: AVPlayerItem(url: url))
    }

    @MainActor private func startPlayer(item: AVPlayerItem) {
        // ⛔ ONE THING PLAYS AT A TIME. This screen sets the category and activates the session
        // directly, with no call check and no handover — and only ONE place in the whole app ever
        // pauses the voice player, which is not this one. So a note playing on the floating bar kept
        // playing underneath a video, both audible at once, and opening a video during a call took
        // the category out from under the call service.
        //
        // The broadcast that used to prevent this was removed on the reasoning that there is only one
        // player now. There are three: this, the gallery and the story player.
        VoiceNotePlayer.shared.pause()
        // ⛔ THE PLAYER FIRST, THE AUDIO SESSION OFF THE MAIN THREAD — 2026-09-28. The category and
        // `setActive(true)` ran here, on main, BEFORE the player existed: `setActive` renegotiates
        // the audio hardware (100-300ms, the voice player's own note measured it) and nothing could
        // be drawn meanwhile, which is the spinner he photographed. The player is built and on
        // screen at once now, so its first frame decodes while the session comes up, and `play()`
        // waits for the session exactly as the voice player's does.
        let p = AVPlayer(playerItem: item)
        p.defaultRate = speed   // a reload keeps the chosen speed
        player = p
        let life = lifetime
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback { try? session.setCategory(.playback) }
            try? session.setActive(true)
            await MainActor.run {
                // Still open, still this viewer's clip, and nobody paused, started a scrub or began
                // dragging it closed (which pauses it) meanwhile.
                guard !life.closed, player === p, isPlaying, !scrubbing, !dismissing else { return }
                p.play()
            }
        }
        duration = message.duration ?? 0
        // Smooth scrubber (a high-frequency observer); don't fight the user while scrubbing.
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            if duration <= 0, let d = p.currentItem?.duration.seconds, d.isFinite { duration = d }
            guard !scrubbing else { return }
            // Perf audit 2026-11-11 M9: with the controls hidden nothing shows the time, and each
            // write re-ran this whole screen's body 20 times a second. Hidden, it keeps within a
            // second (so the bar is right the moment the controls come back, and the next tick
            // makes it exact); shown, every tick as before.
            guard showChrome || abs(time.seconds - current) >= 1 else { return }
            current = time.seconds
            progress = duration > 0 ? min(1, current / duration) : 0
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: p.currentItem, queue: .main) { _ in
            // Theirs: the clip stops at its end, on its last frame; nothing loops.
            isPlaying = false
            // The hidden-controls ticks may be up to a second behind: the end is the end, so the
            // play button's replay-from-start check sees it.
            if duration > 0 { current = duration; progress = 1 }
        }
        // A call or another app's audio pauses AVPlayer by itself, but the screen kept showing it as
        // playing with the chrome hidden and no play button (2026-09-24 audit). Show it paused.
        interruptObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                   object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            isPlaying = false; showChrome = true
        }
        // The state flips now so the button is right at once; `play()` itself is in the task above.
        isPlaying = true
    }

    private func cleanup() {
        lifetime.closed = true
        lifetime.itemStatus = nil
        if let a = lifetime.stream {
            if !lifetime.firstFrameLogged {
                let ms = Int(Date().timeIntervalSince(lifetime.openedAt) * 1000)
                ChatVideoStream.diag("closed before first frame id=\(message.id) ms=\(ms)")
            }
            lifetime.stream = nil
            ChatVideoStream.release(a)
        }
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        if let i = interruptObserver { NotificationCenter.default.removeObserver(i) }
        player?.pause()
    }
}

// Plain AVPlayer layer (aspect-fit), no AVKit transport controls — a custom media-viewer surface.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// The layer has a picture: the poster underneath can go.
    var onFirstFrame: () -> Void = {}
    func makeUIView(context: Context) -> PlayerLayerUIView {
        PlayerLayerUIView(player: player, onFirstFrame: onFirstFrame)
    }
    func updateUIView(_ v: PlayerLayerUIView, context: Context) { v.setPlayer(player) }
}

private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var frameObservation: NSKeyValueObservation?
    init(player: AVPlayer, onFirstFrame: @escaping () -> Void) {
        super.init(frame: .zero)
        // CLEAR, not black (2026-09-28): the poster under this view is what shows until the first
        // frame, and a black backing covered it with exactly the black screen he reported. The
        // viewer's own background is still black around the picture.
        backgroundColor = .clear
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        // When the first picture is really on screen, the poster underneath goes.
        frameObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in onFirstFrame() }
        }
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    func setPlayer(_ p: AVPlayer) { if playerLayer.player !== p { playerLayer.player = p } }
}

/// The player's ••• menu (Speed, Save Video, Delete). Equatable on its plain values, so the playback
/// clock re-running the screen's body does not rebuild it: an open Speed submenu stays open until a
/// speed is picked (owner 2026-11-13, build 1187).
private struct PlayerMoreMenu: View, Equatable {
    let speed: Float
    let canSave: Bool
    let canDelete: Bool
    let actions: Actions

    /// Closures are not compared: they always do the same thing for one open player.
    struct Actions {
        let setSpeed: (Float) -> Void
        let save: () -> Void
        let delete: () -> Void
    }

    static func == (a: PlayerMoreMenu, b: PlayerMoreMenu) -> Bool {
        a.speed == b.speed && a.canSave == b.canSave && a.canDelete == b.canDelete
    }

    var body: some View {
        Menu {
            // A Picker in .menu style is the system's own submenu with a checkmark on the current
            // choice; it hands the pick straight to the player.
            Picker(selection: Binding(get: { speed }, set: { actions.setSpeed($0) })) {
                ForEach([Float(0.5), 1, 1.25, 1.5, 2], id: \.self) { s in
                    Text(VideoPlayerScreen.speedLabel(s)).tag(s)
                }
            } label: {
                Label("Speed  \(VideoPlayerScreen.speedLabel(speed))", systemImage: "gauge.with.dots.needle.67percent")
            }
            .pickerStyle(.menu)
            if canSave {
                Button { actions.save() } label: { Label("Save Video", systemImage: "square.and.arrow.down") }
            }
            if canDelete {
                Button(role: .destructive) { actions.delete() } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
    }
}

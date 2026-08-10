import SwiftUI
import AVFoundation
import UIKit

// Voice-note chain events (auto-advance): when a note finishes naturally, the chat looks up
// the NEXT voice message and asks its bubble to play — voicemail-style hands-free listening.
extension Notification.Name {
    static let voiceNoteFinished = Notification.Name("voiceNoteFinished")   // object = finished message id
    static let voiceNotePlay = Notification.Name("voiceNotePlay")           // object = message id to start
    static let voiceNoteStopOthers = Notification.Name("voiceNoteStopOthers") // object = the id NOW playing → others pause
}

// Playback ownership (a single shared audio player, minimal form): exactly one voice note owns
// the audio session at a time. Only the OWNER may deactivate the session / touch proximity on teardown —
// this is what stopped every off-screen bubble's onDisappear from nuking the shared session (and the
// auto-advance chain from cutting its own playback). `pendingPlayId` hands auto-advance to a bubble
// that isn't on screen yet (its cell claims the play in onAppear).
// A voice-note waveform scrub is in progress. The conversation's single swipe-to-reply pan reads this
// and yields, so dragging the waveform to seek never also drags the bubble into a reply. (The waveform's
// scrub is a horizontal SwiftUI gesture inside the hosted cell; this flag is how the UIKit pan defers to it.)
enum VoiceScrubState {
    static var active = false
    /// TRUE from the first movement of a touch that LANDED ON A WAVEFORM, regardless of direction.
    ///
    /// This is ownership, not arbitration. Both the scrub and the reply-swipe are simultaneous
    /// gestures, so both run and race; `active` was only raised once the drag proved horizontal, and by
    /// then the reply gesture (18pt) could already have claimed a slightly diagonal drag. This flag is
    /// set at the FIRST onChanged of a 0-distance gesture, which always beats 18pt, and the reply
    /// gesture simply refuses for the rest of that touch. The waveform is a no-reply zone; the rest of
    /// the voice card still swipes normally.
    static var touchOnWaveform = false
}   // set/read on the main thread only (gesture + UI)

enum VoiceAudio {
    static var activeId: String?
    static var pendingPlayId: String?
    // Never touch the audio session while a CALL owns it (1:1 or group) — a scrolled voice bubble must
    // not reroute/deactivate call audio.
    @MainActor static var callActive: Bool {
        CallService.shared.state != .idle || GroupCallService.shared.isActive
    }
}

// Playback bubble for a voice note: downloads the encrypted bytes, decrypts them
// (Crypto.decryptBytes), and plays via AVAudioPlayer. Play/pause + progress.
struct VoiceMessageView: View {
    let message: Message
    let cid: String
    let isMe: Bool
    let dark: Bool
    // Set when the player is rendered OUTSIDE a chat bubble (e.g. the "See All Media" Audio list) — on a
    // plain page background rather than a colored accent bubble. My own notes normally tint with
    // `onAccent` (white in light mode), which is invisible on the white gallery page; on a plain
    // background we use the page-neutral tint instead so my sent notes are visible.
    var plainBackground: Bool = false
    var onScrub: (Bool) -> Void = { _ in }   // forwarded to the bubble so it blocks reply-swipe while scrubbing

    /// ⚠️ THE PLAYER IS NOT IN HERE ANY MORE, AND THAT IS THE WHOLE POINT.
    ///
    /// It used to be `@State private var player: AVAudioPlayer?`, which tied the player's life to this
    /// VIEW's life: leaving the chat tore the view down, released the last reference and killed the
    /// audio mid-sentence, and `onDisappear` called `stop()` on top of that. For users who talk mostly
    /// by voice that reads as the app being broken, so ownership moved to `VoiceNotePlayer.shared`,
    /// which outlives every view. This bubble is now a VIEW OF that engine: it draws what the engine
    /// says and asks it to do things. Nothing about the layout or the gestures changed.
    @ObservedObject private var engine = VoiceNotePlayer.shared

    private var playing: Bool { engine.isPlaying(message.id) }
    private var loading: Bool { engine.isLoading(message.id) }
    private var progress: Double { engine.progress(for: message.id) }
    private var rate: Float { engine.rate(for: cid) }

    private var rateLabel: String { rate == 1 ? "1×" : (rate == 1.5 ? "1.5×" : "2×") }
    private func cycleRate() { engine.cycleRate(cid: cid) }

    private var tint: Color {
        if plainBackground { return dark ? .white : .black }   // on the plain gallery page, never the white onAccent
        return isMe ? Theme.onAccent(dark) : (dark ? .white : .black)
    }
    private var durationText: String {
        let d = Int(message.duration ?? 0)
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            // NOT a Button, for the reason the file bubble already documents (ThreadView "NOT a Button:
            // inside the hosted cell a Button's press gesture claimed the touch"). A 42x42 Button on every
            // voice bubble meant a drag starting on the play disc was swallowed and the chat would not
            // scroll. A plain tap gesture reads identically and claims nothing.
            Group {
                if loading { ProgressView().tint(tint) }
                else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 17))
                        // THE ICON MOVES BETWEEN THE TWO SHAPES INSTEAD OF BEING REPLACED — his
                        // "play fast, play and pause" report, where rapid tapping felt heavy.
                        //
                        // Nothing here was slow: the tap toggles immediately. What was missing is
                        // any motion, so a fast double tap swapped one glyph for another with no
                        // travel and read as a stutter. Signal spends real effort on exactly this
                        // beat — their button is a Lottie scrub between the play and pause states
                        // with a guard so a second tap mid-animation does not restart it
                        // (`AudioMessageView`, "Do nothing if we're already there") — and a
                        // symbol-effect replace is the same idea with none of the machinery.
                        //
                        // `.byLayer` keeps it a bounce rather than a cross-fade, and because the
                        // animation is driven by the VALUE it is interruptible: tap again halfway
                        // and it retargets from where it is instead of queueing.
                        .contentTransition(.symbolEffect(.replace.byLayer))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .background(tint.opacity(0.18), in: Circle())   // big round play button (reference)
            .contentShape(Circle())
            .onTapGesture { toggle() }

            VStack(alignment: .leading, spacing: 4) {
                WaveformBars(bars: displayBars, progress: progress, played: tint,
                             // 0.45, not 0.3. The unplayed half is most of the bar for most of a
                             // note's life, and at 30% of the tint on a saturated bubble it read as
                             // washed rather than as a waveform waiting to be played. Still clearly
                             // quieter than the played side, which is the only job this has.
                             unplayed: tint.opacity(0.45), playing: playing,
                             onSeek: { pct in seek(pct) },
                             // The engine holds the scrub flag now, because the 20Hz tick it has to
                             // stand out of the way of lives there too.
                             onScrub: { s in
                                 engine.setScrubbing(s); VoiceScrubState.active = s; onScrub(s)
                             })
                    .frame(width: 158, height: 26)
                HStack(spacing: 8) {
                    Text(durationText).font(.caption2).foregroundStyle(tint.opacity(0.8))
                    // "Not heard yet" dot (a blue mic indicator, our way) — fades once played.
                    if unheard {
                        Circle().fill(Theme.accent(dark)).frame(width: 7, height: 7)
                            .transition(.opacity)
                    }
                    // Speed toggle (1× / 1.5× / 2×) shown ALWAYS — not gated on `player != nil`.
                    // ROOT CAUSE of "the bubble changes size once played / spacing between notes disappears"
                    // (user clue: "happens when the x1 tab appears"): the cell is PRE-MEASURED by the
                    // collection view while player == nil (no toggle), but the toggle capsule is TALLER than
                    // the plain duration text, so when it appeared on first play the content grew past the
                    // measured cell height and overflowed into the next bubble (the "spacing disappears").
                    // Rendering it unconditionally makes the pre-measure and the played render IDENTICAL, so
                    // nothing shifts. Before load it simply pre-selects the rate cycleRate() applies on play.
                    // Tap gesture, not a Button — same reason as the play disc above.
                    Text(rateLabel).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(tint.opacity(0.16), in: Capsule())
                        .contentShape(Capsule())
                        .onTapGesture { cycleRate() }
                }
                // Pin the meta row to the waveform's fixed width. Height needs NO hard-coding now: the toggle
                // renders unconditionally (above), so the row's tallest element (the 11pt bold capsule) is
                // ALWAYS present → the row height is constant, measure == render, and it stays correct under
                // Dynamic Type (a fixed height would clip large text). The unheard dot is shorter than the
                // text, so its fade in/out never changes the height either.
                .frame(width: 158, alignment: .leading)
            }
        }
        .onAppear {
            // Speed and paused position are the engine's now, so there is nothing to restore here:
            // this bubble reads them live. What is still needed is the auto-advance handoff for a
            // bubble that was OFF-SCREEN when its turn came — the router parks the id and the
            // freshly-realised cell claims it here, because the notification would have been dropped.
            if VoiceAudio.pendingPlayId == message.id {
                VoiceAudio.pendingPlayId = nil
                if !playing { toggle() }
            }
        }
        .onDisappear {
            // ⚠️ NO `stop()` HERE ANY MORE. THIS LINE WAS THE BUG.
            //
            // Leaving the chat, or simply scrolling the note off screen, tore this view down and this
            // handler killed the audio. The engine outlives the view now, so the note keeps playing
            // while you walk around the app, which is the whole feature.
            //
            // Clean only the OPTIMISTIC just-recorded tmp file, and only when this note is NOT the one
            // playing. The DECRYPTED note lives in the persistent AudioCache and must never be deleted
            // here, or every scroll-away would make it download and decrypt again.
            if !playing {
                let fm = FileManager.default
                fm.removeItemIfExists(at: fm.temporaryDirectory.appendingPathComponent("local-\(message.rowId).m4a"))
            }
        }
        // The single-player rule is enforced inside the engine (one player, one owner), so the
        // `.voiceNoteStopOthers` handler that used to pause this bubble is gone with it.
        //
        // Auto-advance stays: the chat posts `.voiceNotePlay` with the NEXT note's id when one
        // finishes, and if it is this bubble and it is not already playing, start it.
        .onReceive(NotificationCenter.default.publisher(for: .voiceNotePlay)) { note in
            guard let id = note.object as? String, id == message.id, !playing else { return }
            toggle()
        }
        // Raise-to-ear also moved into the engine, for the same reason as the player: it was pointless
        // on a view that stops existing the moment you leave the chat.
    }

    // Real captured waveform, or a neutral flat one for older messages that lack it.
    private var displayBars: [Int] {
        message.waveform.isEmpty ? Array(repeating: 35, count: 28) : message.waveform
    }

    // An incoming note this device has never played (optimistic local notes are mine).
    private var unheard: Bool {
        !isMe && message.localAudioData == nil
            && PlayedVoice.shared.isUnplayed(cid: cid, messageId: message.id, createdAt: message.createdAt)
    }

    /// Scrubbing before the first play still works: with no player yet the engine stashes the position
    /// and picks it up when you press play.
    private func seek(_ pct: Double) { engine.seek(pct, id: message.id) }

    private func toggle() { engine.toggle(message: message, cid: cid, isMe: isMe) }

}

extension FileManager {
    // Best-effort delete (voice-note tmp plaintext cleanup) — silent no-op when the file isn't there.
    func removeItemIfExists(at url: URL) {
        guard fileExists(atPath: url.path) else { return }
        try? removeItem(at: url)
    }
}

// Premium waveform (standard style): rounded amplitude bars, the played portion
// tinted, draggable to seek. Drawn in a Canvas (one pass — cheap to redraw on progress).
struct WaveformBars: View {
    /// ⚠️ WHY EVERY BAR USED TO BE THE SAME HEIGHT, AND WHY THE FIX IS HERE AND NOT IN THE RECORDER.
    ///
    /// His 2026-08-10 report, with our bubble beside WhatsApp's and Signal's: ours reads as a fence,
    /// theirs read as a voice. Measured rather than judged, and the cause is the top of the scale.
    ///
    /// `AudioRecorder.perceptualLevel` maps the microphone's dB onto 0…1 with SILENCE at −50 dB and
    /// FULL HEIGHT AT 0 dBFS — the loudest sound the hardware can represent, which is a clipped
    /// scream held to the microphone. Ordinary speech on a phone sits between about −30 and −18 dB,
    /// so every bar of every note landed between roughly 12 and 18 points of the 26 available. Never
    /// the top, never the bottom, and a picket fence is exactly what that arithmetic draws.
    ///
    /// Signal's own numbers (`AudioWaveform.swift`, read from source): silence is also −50, but full
    /// height is **−20 dB**, `clippingThreshold`, and the mapping is a plain clamped `inverseLerp`
    /// between the two. A 30 dB window instead of our 50, with the top set where a person actually
    /// speaks. That is the whole difference. Their loud syllables reach the ceiling and clamp; ours
    /// were still in the middle of the range.
    ///
    /// ⚠️ AND IT IS DELIBERATELY **NOT** PER-CLIP NORMALISATION. Scaling each note to its own
    /// loudest moment would make a whisper draw identically to a shout — Signal's comment is explicit
    /// that a quiet note is meant to render visibly short. An absolute window keeps the real
    /// difference between notes, which is information, not decoration.
    ///
    /// Done at DRAW time, on the stored 0…100, so it re-shapes every voice note ever sent as well as
    /// every new one, with no migration, no re-record and no server change. Exact rather than
    /// approximate: undoing the recorder's `pow(norm, 0.85)` recovers its `norm`, which is
    /// `(dB + 50) / 50`, and multiplying by 50/30 rebases that onto Signal's −50…−20 window.
    static func display(_ stored: Int) -> CGFloat {
        let v = CGFloat(max(0, min(100, stored))) / 100
        guard v > 0 else { return 0 }
        return min(1, pow(v, 1 / 0.85) * (50.0 / 30.0))
    }

    let bars: [Int]          // 0…100
    var progress: Double     // 0…1
    var played: Color
    var unplayed: Color
    var playing: Bool = false
    var onSeek: (Double) -> Void
    var onScrub: (Bool) -> Void = { _ in }   // true while dragging the waveform → parent blocks reply-swipe
    // Scrub state now lives in the UIKit recogniser (WaveformGestureArea), which is the only place that
    // can refuse a vertical touch before it claims one. The old @State drag bookkeeping went with it.

    var body: some View {
        GeometryReader { geo in
            // TimelineView drives a gentle equalizer wobble while playing; paused when idle
            // so there's zero redraw cost when the note isn't playing.
            TimelineView(.animation(minimumInterval: 0.05, paused: !playing)) { tl in
                let phase = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let count = max(bars.count, 1)
                    let slot = size.width / CGFloat(count)
                    let barW = max(2, slot * 0.5)
                    let playedTo = Int(Double(count) * progress)
                    for (i, v) in bars.enumerated() {
                        let norm = Self.display(v)
                        var h = max(2, norm * size.height)
                        // Subtle live wobble on already-played bars during playback.
                        if playing && i <= playedTo {
                            let wob = sin(phase * 6 + Double(i) * 0.5)
                            h = max(3, h * CGFloat(1 + 0.14 * wob))
                        }
                        let x = CGFloat(i) * slot + (slot - barW) / 2
                        let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                                 with: .color(i <= playedTo ? played : unplayed))
                    }
                    // White scrubber line at the current playback position (reference look).
                    let sx = max(1, size.width * CGFloat(max(0, min(1, progress))))
                    var line = Path()
                    line.move(to: CGPoint(x: sx, y: 0))
                    line.addLine(to: CGPoint(x: sx, y: size.height))
                    ctx.stroke(line, with: .color(played), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            // Tap to seek, drag sideways to scrub — in UIKit, because SwiftUI cannot express the one
            // rule that matters here: NEVER take a vertical touch.
            //
            // A SwiftUI DragGesture(minimumDistance: 0) claims the touch on CONTACT and then tracks every
            // axis, so resting a finger on the waveform (which covers most of a voice bubble) BLOCKED chat
            // scrolling. That exact bug was fixed once by deleting such a gesture - 05b9242 kept the bar
            // tap-only and said so in its message - and came straight back when full-waveform scrubbing was
            // re-added in fa060a1. minimumDistance can't fix it either: any SwiftUI drag that eventually
            // claims is a race against the scroll view starting.
            //
            // So the axis is decided BEFORE the gesture is allowed to begin, which only UIKit can do, and
            // which is how the reference app's swipe recogniser works too. Vertical -> we fail instantly and the list
            // scrolls, every time. Horizontal -> we claim, and keep it for the whole gesture in both
            // directions (the the reference app rule the user asked for: "when moving the wave the bubble will never
            // move"). Recognises simultaneously with everything else, so long-press-for-menu still works.
            .overlay {
                WaveformGestureArea(progress: progress, onSeek: onSeek, onScrub: onScrub)
            }
            // DRAGGABLE PLAYHEAD KNOB (the reference app model, user request): you can now drag to move
            // through a voice note. It's a SMALL target on the playhead rather than the whole
            // waveform — that's the entire point. A full-width drag-scrub is what used to block chat
            // scrolling and swallow the reply-swipe, so the bar itself stays tap-only and only this
            // knob claims the pan. While dragging it sets VoiceScrubState, which the message list and
            // the bubble already watch in order to yield their own gestures.
            .overlay(alignment: .leading) {
                let w = max(1, geo.size.width)
                let sx = w * CGFloat(max(0, min(1, progress)))
                // Solid dot in the played colour, like the reference app's. A soft shadow keeps it visible
                // whatever the bubble colour is (white dot on a light custom bubble, etc).
                Circle()
                    .fill(played)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .frame(width: 13, height: 13)
                    .frame(width: 40, height: 40)      // generous touch area around a small dot
                    .offset(x: sx - 20)
                    // VISUAL ONLY. This used to carry its own DragGesture(minimumDistance: 0) behind a
                    // .highPriorityGesture — which pre-empts everything, so a 40x40 patch of every voice
                    // bubble froze chat scrolling outright. The whole waveform scrubs now, so the knob
                    // needs no gesture of its own.
                    .allowsHitTesting(false)
            }
        }
    }
}

// Live recording waveform: scrolling capsules from the most recent mic levels.
struct LiveWaveform: View {
    let levels: [Float]      // 0…1
    var color: Color

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, lvl in
                    Capsule().fill(color)
                        // THE SAME WINDOW THE FINISHED NOTE IS DRAWN IN — see `WaveformBars.display`.
                        // These are the recorder's raw 0…1 levels, so without this the bar you watch
                        // while speaking is flat and the bubble it turns into is not. What you see
                        // recording should be what you get.
                        .frame(width: 2.5,
                               height: max(2, WaveformBars.display(Int(lvl * 100)) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            // Light interpolating spring on top of the recorder's meter ballistics: gives each bar a
            // touch of momentum as it settles, so the waveform reads fluid rather than stepped.
            .animation(.interpolatingSpring(stiffness: 260, damping: 26), value: levels)
        }
    }
}

// MARK: - Waveform gestures (UIKit)

// Tap to seek, horizontal drag to scrub, and a hard guarantee that a VERTICAL touch is never taken so
// the chat always scrolls. See the call site for the full history — the short version is that every
// SwiftUI DragGesture attempt at this eventually claims the touch and locks scrolling, because SwiftUI
// has no way to refuse a gesture based on its direction before it begins. UIKit does.
struct WaveformGestureArea: UIViewRepresentable {
    var progress: Double
    var onSeek: (Double) -> Void
    var onScrub: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pan = AxisLockedScrubRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: WaveformGestureArea
        private var startPct: Double = 0
        init(_ parent: WaveformGestureArea) { self.parent = parent }

        // Co-exist with everything: the bubble's long-press-for-menu lives on an ancestor view and must
        // keep receiving these touches, and the scroll view's pan is vertical-only so it can never fight us.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            let w = max(1, g.view?.bounds.width ?? 1)
            parent.onSeek(max(0, min(1, Double(g.location(in: g.view).x / w))))
        }

        @objc func handlePan(_ g: AxisLockedScrubRecognizer) {
            let w = max(1, g.view?.bounds.width ?? 1)
            switch g.state {
            case .began:
                startPct = max(0, min(1, parent.progress))
                // `touchOnWaveform` is NOT set here any more — it is claimed at touch-down in
                // `AxisLockedScrubRecognizer.touchesBegan` and released in its `reset()`. Setting it
                // at `.began` made it depend on movement, which is the race that let a fast drag
                // reach the reply swipe first. `active` still belongs here: it means "a scrub is
                // really under way", which is a different fact and is what suppresses the reply
                // FIRING at the end.
                VoiceScrubState.active = true
                parent.onScrub(true)
                fallthrough
            case .changed:
                let pct = startPct + Double(g.translation(in: g.view).x / w)
                parent.onSeek(max(0, min(1, pct)))
            case .ended, .cancelled, .failed:
                VoiceScrubState.touchOnWaveform = false
                VoiceScrubState.active = false
                parent.onScrub(false)
            default:
                break
            }
        }
    }
}

// A pan that FAILS the instant it sees a vertical movement, so the enclosing scroll view is left
// completely alone, and otherwise behaves as a normal horizontal pan. The decision is made once per
// gesture and never revisited — that is what makes the horizontal lock a lock, in both directions.
final class AxisLockedScrubRecognizer: UIPanGestureRecognizer {
    private var decided = false
    private var startPoint: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        decided = false
        startPoint = touches.first?.location(in: view) ?? .zero
        // ⚠️ OWNERSHIP IS CLAIMED AT TOUCH-DOWN, NOT AT `.began` — his "when I drag the wave it
        // sometimes goes to reply".
        //
        // The flag used to be raised in the pan's `.began`, and the reply swipe's own comment claims
        // that happens first because a pan begins at ~10pt while the reply gesture waits for 18pt.
        // That is a RACE, not a rule, and it loses two ways. A fast flick can cross both thresholds
        // inside ONE touch event, and nothing orders a UIKit recogniser's callback against SwiftUI's
        // — so the bubble can start sliding before the flag exists. And if this recogniser FAILS on
        // the axis test below, `.began` never arrives at all, so the flag is never set and the reply
        // swipe owns a gesture that started on the waveform.
        //
        // A finger that lands on the waveform is on the waveform. That is knowable at touch-down,
        // with no movement and no threshold, and it is what "the waveform is a no-reply zone" has
        // always meant. Cleared in `reset()`, which UIKit guarantees at the end of every gesture
        // however it finishes, so a failed or cancelled touch cannot leave it stuck on.
        VoiceScrubState.touchOnWaveform = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if !decided, let p = touches.first?.location(in: view) {
            let dx = abs(p.x - startPoint.x), dy = abs(p.y - startPoint.y)
            // ⚠️ 10pt, AND VERTICAL HAS TO WIN CLEARLY — the other half of the same report.
            //
            // Deciding at 3pt meant deciding on the noisiest movement a drag ever produces: the
            // first millimetre of a thumb, which arcs. A bare `dy > dx` then killed the scrub on a
            // 5-vs-4 tie that was a horizontal drag in every sense a person would recognise, and
            // once failed it stays failed for the whole gesture — the finger keeps moving sideways
            // over the waveform and the bubble slides away to reply instead.
            //
            // 10pt is the distance UIKit's own pan uses before it will call itself a pan, and the
            // 1.4 factor means a drag has to be genuinely, visibly downward to be handed to the
            // list. An honest vertical scroll clears both easily and still fails instantly.
            if dx > 10 || dy > 10 {
                decided = true
                if dy > dx * 1.4 { state = .failed; return }   // vertical: not ours, ever
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        decided = false
        // The one place that runs at the end of EVERY gesture — recognised, failed or cancelled —
        // so the no-reply zone can never outlive the finger that claimed it.
        VoiceScrubState.touchOnWaveform = false
    }
}

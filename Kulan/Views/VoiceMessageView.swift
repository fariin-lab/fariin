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
    /// The chat's own time-and-tick row, handed in so it can sit on the SAME line as the duration
    /// instead of on a line of its own below. Nil off the chat screen (the All Media audio list), where
    /// there is no clock to show. `AnyView` rather than a generic parameter on purpose: it is one row of
    /// 10pt text, the cost is nothing, and making the whole view generic would touch every call site.
    var trailingMeta: (() -> AnyView)? = nil

    /// THE BUBBLE'S WIDTH, WORKED OUT FROM THE NOTE ITSELF.
    ///
    /// It used to be a flat 158pt of waveform for every note, so seven seconds and seven minutes drew
    /// the identical bar and a short note was mostly empty space. WhatsApp's grows with the note, and so
    /// does this.
    ///
    /// ⚠️ IT READS `duration` AND NOTHING ELSE, AND THAT IS NOT A STYLE CHOICE. Read the bloom note
    /// above the audio branch in ThreadView: the bubble is pinned to a known width because a child whose
    /// size could be re-resolved made one bubble swell on the first play and eat the gap to its
    /// neighbours. `duration` travels in the message and is the same before, during and after playback,
    /// so the pre-measure and the render can never disagree. A width that consulted the player would
    /// bring that straight back.
    static func waveWidth(for message: Message) -> CGFloat {
        let secs = min(max(message.duration ?? 0, 0), 45)
        return 110 + CGFloat(secs / 45) * 48        // 110 at 0s, up to 158 at 45s and beyond
    }
    /// play button + HStack spacing + waveform. 154 at the short end, 202 at the long end. His
    /// 2026-08-11 report with WhatsApp beside ours: the note reads as a BLOCK. Slimmed to their
    /// scale — button 42→34, row spacing 12→10, wave 26→22, line gap 4→2 — every number here and
    /// nowhere else, so the pre-measure (which calls this) and the render can never disagree.
    static func contentWidth(for message: Message) -> CGFloat {
        34 + 10 + waveWidth(for: message)
    }

    /// ⚠️ THE PLAYER IS NOT IN HERE ANY MORE, AND THAT IS THE WHOLE POINT.
    ///
    /// It used to be `@State private var player: AVAudioPlayer?`, which tied the player's life to this
    /// VIEW's life: leaving the chat tore the view down, released the last reference and killed the
    /// audio mid-sentence, and `onDisappear` called `stop()` on top of that. For users who talk mostly
    /// by voice that reads as the app being broken, so ownership moved to `VoiceNotePlayer.shared`,
    /// which outlives every view. This bubble is now a VIEW OF that engine: it draws what the engine
    /// says and asks it to do things. Nothing about the layout or the gestures changed.
    /// ⚠️ NOT `@ObservedObject`, AND THAT IS A FIX, NOT A STYLE CHOICE. Observing the shared engine
    /// re-rendered EVERY voice bubble on screen twenty times a second while ANY note played — the
    /// engine's 20Hz progress tick invalidates every observer, and his test chats are stacked with
    /// notes. Each bubble now mirrors its own four facts into @State in `sync()`, written only on
    /// change, so a tick re-renders the one bubble whose numbers moved and the rest stay parked.
    private var engine: VoiceNotePlayer { .shared }

    @State private var playing = false
    @State private var loading = false
    @State private var progress: Double = 0
    @State private var rate: Float = 1

    /// Mirror the engine facts this one bubble draws. `objectWillChange` fires BEFORE the values
    /// land (willSet), which is why the subscription below hops through the main queue once — by
    /// the time this runs, the engine's numbers are the new ones.
    private func sync() {
        let p = engine.isPlaying(message.id)
        if playing != p { playing = p }
        let l = engine.isLoading(message.id)
        if loading != l { loading = l }
        let pr = engine.progress(for: message.id)
        if progress != pr { progress = pr }
        let r = engine.rate(for: cid)
        if rate != r { rate = r }
    }

    private var rateLabel: String { rate == 1 ? "1×" : (rate == 1.5 ? "1.5×" : "2×") }

    /// Has the other side played THIS note of mine? Read live off the conversation the chat list is
    /// already listening to, so it lights up the moment their receipt lands, with no listener of its own.
    private var heardByOther: Bool {
        guard isMe else { return false }
        let me = AuthService.shared.uid ?? ""
        guard let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        else { return false }
        return conv.voicePlayedByOther(me, createdAtMillis: message.createdAt.timeIntervalSince1970 * 1000)
    }
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
        // TWO ROWS, NOT A COLUMN BESIDE THE BUTTON — and that is what fixes the alignment he asked
        // about. The play button used to be boxed with the waveform AND the little text row together, so
        // it centred on both and ended up sitting roughly 10pt BELOW the middle of the wave. Nothing in
        // the bubble lined up with anything. Now the button is boxed with the wave alone, so the two are
        // on one line, which is what both references do.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                playButton
                WaveformBars(bars: displayBars, progress: progress, played: tint,
                             // 0.45, not 0.3. The unplayed half is most of the bar for most of a
                             // note's life, and at 30% of the tint on a saturated bubble it read as
                             // washed rather than as a waveform waiting to be played. Still clearly
                             // quieter than the played side, which is the only job this has.
                             unplayed: tint.opacity(0.45),
                             onSeek: { pct in seek(pct) },
                             // The engine holds the scrub flag now, because the 20Hz tick it has to
                             // stand out of the way of lives there too.
                             onScrub: { s in
                                 engine.setScrubbing(s); VoiceScrubState.active = s; onScrub(s)
                             })
                    .frame(width: Self.waveWidth(for: message), height: 22)
            }
            bottomLine
        }
        .frame(width: Self.contentWidth(for: message), alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: unheard)
        .onReceive(VoiceNotePlayer.shared.objectWillChange.receive(on: DispatchQueue.main)) { _ in
            sync()
        }
        // Hosted cells are REUSED: the same view can wake up holding a different message, and the
        // mirrored @State would still describe the old one (a recycled bubble drawing another
        // note's play state). Re-sync the moment the identity changes.
        .onChange(of: message.id) { _, _ in sync() }
        .onAppear {
            sync()   // first render used the @State defaults; read the engine's truth now
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

    /// A SOLID DISC WITH THE TRIANGLE CUT OUT OF IT.
    ///
    /// It used to be a disc at 0.18 of the tint, which on a saturated bubble is barely there — it took
    /// up the room of a button without reading as one, and that washed-out look is what he called ugly.
    /// The green reference does it the other way: a solid disc, high contrast, the one thing you press.
    ///
    /// ⚠️ THE TRIANGLE IS KNOCKED OUT RATHER THAN COLOURED IN, because nothing here knows what colour
    /// the bubble is. `myFill` is a ShapeStyle chosen in ThreadView and can be a gradient, so there is no
    /// colour to hand down. `destinationOut` inside a `compositingGroup` removes the disc where the
    /// glyph is, so whatever the bubble happens to be shows through — right on every chat colour, on the
    /// received grey, and in both light and dark, without passing anything in.
    ///
    /// NOT a Button, for the reason the file bubble already documents (ThreadView "NOT a Button: inside
    /// the hosted cell a Button's press gesture claimed the touch"). A 42x42 Button on every voice
    /// bubble meant a drag starting on the play disc was swallowed and the chat would not scroll. A
    /// plain tap gesture reads identically and claims nothing.
    private var playButton: some View {
        Group {
            if loading {
                ProgressView().tint(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.22), in: Circle())
            } else {
                Circle().fill(tint)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                            // Colour is irrelevant under destinationOut — only the alpha is read, and
                            // this has to be fully opaque to cut a clean hole.
                            .foregroundStyle(.black)
                            // ⚠️ NO transition on the glyph swap. A symbol-effect bounce was tried here
                            // (the icon travelled between play and pause) and he reported it as LAG:
                            // the audio toggles instantly but the button looked like it answered late.
                            // WhatsApp swaps the glyph with no motion at all. Keep it instant.
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
        .onTapGesture { toggle() }
    }

    /// ONE LINE ALONG THE BOTTOM: duration and speed on the left, the chat's clock and ticks on the
    /// right. They used to be on two different lines at two different heights — duration under the
    /// waveform, clock lower down and further right — which is most of why the bubble read as tall and
    /// unarranged. Both references put them on one line.
    ///
    /// ⚠️ THE CLOCK IS AN `.overlay`, NOT A SECOND ITEM IN THE ROW, AND THAT IS DELIBERATE. The bloom
    /// note above the audio branch in ThreadView records what happened last time the timestamp went in
    /// here: an `HStack { Spacer(minLength: 0); metaRow }` gave the row a flexible child, which
    /// re-resolved on the reconfigure that fires at the first play, and that bubble swelled and ate the
    /// gap to its neighbours. That same note points at the shape that is safe — "media bubbles never
    /// bloom because their metaRow is an .overlay, which doesn't affect size". So: no Spacer, no
    /// flexible child, the row is pinned to the known content width and the clock is laid over its
    /// trailing edge.
    private var bottomLine: some View {
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
            Text(rateLabel).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(tint.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { cycleRate() }
            // THEY HEARD IT. On my own notes only, and only in a chat — this is the thing WhatsApp says
            // with a blue microphone, and the one voice signal we sent nothing for at all.
            //
            // ⚠️ IT DIMS, IT DOES NOT TURN BLUE, and that is forced rather than chosen. WhatsApp can use
            // a colour because their bubble is a pale green; ours is whatever chat colour the person
            // picked, and the only ink guaranteed to read on it is `tint`. A blue would vanish on a blue
            // bubble. Faint-to-solid is the one contrast that survives every colour and both appearances.
            //
            // Drawn at BOTH states rather than appearing when they listen, for the reason the speed pill
            // carries above: the row is pre-measured before any of this arrives, and something that
            // shows up later changes the height that was already measured.
            if isMe && !plainBackground {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.opacity(heardByOther ? 1 : 0.35))
            }
        }
        .frame(width: Self.contentWidth(for: message), alignment: .leading)
        .overlay(alignment: .trailing) { trailingMeta?() }
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
        let boosted = pow(v, 1 / 0.85) * (50.0 / 30.0)
        // ⚠️ A SOFT CEILING, NOT `min(1, …)` — his "ours looks boxy" report. The hard clamp cut
        // every loud-ish syllable to the identical full height, and a run of identical full-height
        // bars is a rectangle, not a voice. Below the knee nothing changes; above it the curve
        // compresses toward 1 asymptotically, so loud bars still crest visibly differently while
        // speech keeps owning the top of the range (the whole point of the −20dB window above).
        if boosted <= 0.82 { return boosted }
        return 0.82 + (1 - exp(-(boosted - 0.82) * 2.2)) * 0.18
    }

    let bars: [Int]          // 0…100
    var progress: Double     // 0…1
    var played: Color
    var unplayed: Color
    // `playing` used to live here. It drove the wobble and the TimelineView's pause, and both are gone,
    // so it was a parameter every caller had to pass that changed nothing on screen.
    var onSeek: (Double) -> Void
    var onScrub: (Bool) -> Void = { _ in }   // true while dragging the waveform → parent blocks reply-swipe
    // Scrub state now lives in the UIKit recogniser (WaveformGestureArea), which is the only place that
    // can refuse a vertical touch before it claims one. The old @State drag bookkeeping went with it.

    var body: some View {
        GeometryReader { geo in
            // THE BARS STAND STILL. They used to be pumped up and down by a sine wave — every already
            // played bar breathing ±14% for as long as the note ran — and that is what made the bubble
            // feel busy and heavy. WhatsApp does not move its bars at all. The only thing that travels
            // is the colour boundary and the knob, and that is enough to say where you are.
            //
            // ⚠️ THE `TimelineView` WENT WITH IT, AND THAT WAS THE POINT. Its whole job was to redraw
            // this canvas 20 times a second so the wobble had frames to move in. With the wobble gone it
            // would have been 20 redraws a second to draw the identical picture. The canvas now redraws
            // when `progress` changes, which is the only thing that can change what it looks like.
            Canvas { ctx, size in
                // AIR BETWEEN THE BARS — his "ours looks boxy" report with the reference beside it.
                // All 40 stored bars drawn into a 110pt slim bubble gave a 2.75pt slot: a 2pt bar
                // with a 0.75pt gap, which is a picket fence pressed into a plank. Downsample at
                // DRAW time so a slot is never narrower than 4pt (2pt bar, 2pt of air — the
                // reference's rhythm), taking each bucket's LOUDEST bar so peaks survive the merge.
                // Draw-time like the height remap below, so every old note is re-shaped too.
                let all = bars
                let maxBars = max(8, Int(size.width / 4))
                let step = max(1, Int((Double(all.count) / Double(maxBars)).rounded(.up)))
                var drawn: [Int] = []
                var b = 0
                while b < all.count {
                    drawn.append(all[b..<min(b + step, all.count)].max() ?? 0)
                    b += step
                }
                let count = max(drawn.count, 1)
                let slot = size.width / CGFloat(count)
                let barW = max(2, slot * 0.5)
                let playedTo = Int(Double(count) * progress)
                for (i, v) in drawn.enumerated() {
                    let h = max(2, Self.display(v) * size.height)
                    let x = CGFloat(i) * slot + (slot - barW) / 2
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                             with: .color(i <= playedTo ? played : unplayed))
                }
                // ⚠️ NO SCRUBBER LINE HERE ANY MORE. There were TWO markers sitting on the same spot:
                // this 2pt vertical stroke, and the round knob in the overlay below. One position, two
                // things pointing at it, and on a short note they overlapped into a smudge. WhatsApp
                // marks the spot with a dot and nothing else. The knob is the one that survives, because
                // it is also the thing you can grab.
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

// MARK: - One-time voice pill

// A one-time voice note draws as a PILL, deliberately not as the waveform player — the same idiom
// as the view-once photo above it in ThreadView, and our own look rather than the reference's
// badge-on-a-bubble. No waveform is even sent for these, no scrubbing, no speed: one tap, one
// listen. Pause and resume DURING that listen are allowed for as long as the engine still holds
// the note; the moment it moves off (finished, dismissed, another note started) the pill reads
// "Played" and is inert.
//
// Consumption is device-local (`ViewedOnce`, written by the engine the moment playback starts),
// exactly like the photo. The engine never touches AudioCache for these — the decrypted bytes live
// in a throwaway file it shreds when the listen ends.
struct OneTimeVoicePill: View {
    let message: Message
    let cid: String
    let isMe: Bool
    let dark: Bool
    /// ThreadView's snapshot of ViewedOnce at row build. `consumedLive` below re-reads it on engine
    /// transitions, because the row does NOT reconfigure when the engine marks the note mid-session
    /// — trusting the snapshot alone let a finished note offer itself for a second listen.
    let consumed: Bool
    let tint: Color
    let meta: AnyView

    private var engine: VoiceNotePlayer { .shared }
    @State private var playing = false
    @State private var loading = false
    @State private var active = false        // the engine currently holds THIS note: the one listen
    @State private var consumedLive = false

    /// Sender side only: has the other person spent their listen? Same live read as the voice
    /// bubble's mic receipt — nothing shows if their read receipts are off, and that is the rule.
    private var openedByOther: Bool {
        guard isMe else { return false }
        let me = AuthService.shared.uid ?? ""
        guard let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        else { return false }
        return conv.voicePlayedByOther(me, createdAtMillis: message.createdAt.timeIntervalSince1970 * 1000)
    }

    private var spent: Bool { !isMe && (consumed || consumedLive) && !active }
    private var durationText: String {
        let d = Int(message.duration ?? 0)
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    var body: some View {
        HStack(spacing: 8) {
            if loading {
                ProgressView().tint(tint).frame(width: 18, height: 18)
            } else {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
            }
            Text(label).font(.system(size: 15, weight: .medium)).italic(spent || (isMe && openedByOther))
            meta
        }
        .foregroundStyle(tint.opacity(spent || (isMe && openedByOther) ? 0.6 : 1))
        .contentShape(Capsule())
        .onTapGesture { tap() }
        .onReceive(VoiceNotePlayer.shared.objectWillChange.receive(on: DispatchQueue.main)) { _ in sync() }
        .onChange(of: message.id) { _, _ in consumedLive = ViewedOnce.contains(message.id); sync() }   // hosted cells are reused
        .onAppear { consumedLive = ViewedOnce.contains(message.id); sync() }
    }

    private var icon: String {
        if isMe { return openedByOther ? "circle.slash" : "1.circle" }
        if active { return playing ? "pause.fill" : "play.fill" }
        return spent ? "circle.slash" : "1.circle"
    }
    private var label: String {
        if isMe { return openedByOther ? "Opened" : "Voice message" }
        if spent { return "Played" }
        return "Voice message · " + durationText
    }

    private func tap() {
        guard !isMe else { return }                       // the sender cannot replay a one-time note
        if active { engine.toggle(message: message, cid: cid, isMe: isMe); return }   // pause/resume the one listen
        guard !consumed, !consumedLive, message.sendState == nil else { return }
        engine.toggle(message: message, cid: cid, isMe: isMe)
    }

    private func sync() {
        let a = engine.messageId == message.id && engine.hasNote
        if a != active {
            active = a
            // Transition edges are the only moments consumption can have changed — reading the
            // UserDefaults-backed set on every 20Hz tick would be waste.
            consumedLive = ViewedOnce.contains(message.id)
        }
        let p = engine.isPlaying(message.id)
        if p != playing { playing = p }
        let l = engine.isLoading(message.id)
        if l != loading { loading = l }
    }
}

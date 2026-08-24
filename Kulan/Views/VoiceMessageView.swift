import SwiftUI
import AVFoundation
import UIKit
import FirebaseFunctions

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
    /// the identical bar and a short note was mostly empty space. The reference app's grows with the note, and so
    /// does this.
    ///
    /// ⚠️ IT READS `duration` AND NOTHING ELSE, AND THAT IS NOT A STYLE CHOICE. Read the bloom note
    /// above the audio branch in ThreadView: the bubble is pinned to a known width because a child whose
    /// size could be re-resolved made one bubble swell on the first play and eat the gap to its
    /// neighbours. `duration` travels in the message and is the same before, during and after playback,
    /// so the pre-measure and the render can never disagree. A width that consulted the player would
    /// bring that straight back.
    /// ONE FIXED WIDTH FOR EVERY NOTE — his 2026-08-11 night order, reversing the grow-with-
    /// duration experiment from earlier the same day: "people are adopted to the reference app's note
    /// size". The reference draws every voice bubble the same wide familiar shape regardless of
    /// length, and that sameness is itself the thing people recognise. A constant is trivially
    /// duration-deterministic, so the bloom rule (pre-measure == render, always) holds for free.
    /// The `message` parameter stays: every call site already passes it, and the day this becomes
    /// per-note again the signature will not have to change back.
    /// ⛔ 112, DOWN FROM 170 — owner, 2026-08-24, image 2. The speed pill moved onto this line, and
    /// in his reference the bubble does not get wider to make room for it: the wave gives up the
    /// space instead. 40 + 8 + 104 + 8 + 42 = 202, against the 210 the old disc-plus-wave came to,
    /// so the bubble keeps the width he already signed off.
    static func waveWidth(for message: Message) -> CGFloat { 104 }
    /// COMPACT, 2026-08-13, on his side-by-side ("make it like the second one… ours is bigger and
    /// wider"). Three things were making it bigger and all three come down here:
    ///
    ///   * the play disc was 38 — a filled circle, where the app he is holding up draws a bare
    ///     triangle and spends nothing on a circle at all. 32 keeps our disc (it is the other
    ///     reference's shape, and it is what the scrub gesture aims at) at a size nearer theirs.
    ///   * the waveform was 190 wide and 26 tall for every note, the widest single thing in the
    ///     bubble. 170 × 22.
    ///   * and the gap between the disc and the wave was 10. 8.
    ///
    /// 32 + 8 + 170 = 210, against 238. With the shorter wave and a 2pt row gap the bubble loses
    /// about twelve points of height as well.
    ///
    /// ⚠️ EVERY NUMBER LIVES HERE AND NOWHERE ELSE, so the pre-measure (which calls this) and the
    /// render can never disagree — that equality is what stops the bloom described above.
    /// ⛔ 40, UP FROM 32 — owner, 2026-08-24, image 2, after he asked me to check the disc before
    /// and after the redesign. The honest answer was that the redesign never touched it: it moved
    /// the playhead and the speed pill and left this at 32. Measured off both crops at the same
    /// scale, his reference draws the disc about a third of the bubble's height where ours is a
    /// quarter — roughly 40pt against 32.
    ///
    /// ⚠️ IT IS NOW TALLER THAN THE WAVE (40 against 22), which is the arrangement in his picture:
    /// the disc anchors the row and the wave is the quieter thing beside it. The row centres on the
    /// disc, so nothing else moves, and `contentWidth` picks the change up on its own because it is
    /// stated in terms of this constant.
    static let discSize: CGFloat = 40
    static let waveHeight: CGFloat = 22
    static let discGap: CGFloat = 8
    /// The speed pill's slot on the waveform's line, gap included — see `speedPill`. A STATED width
    /// rather than a measured one, for the reason every number in this block is stated: the
    /// collection view pre-measures the cell through `contentWidth`, and a size that resolves later
    /// than the measurement is exactly the bloom the comments in `bottomLine` describe. "1.5×" is
    /// the widest label at 11pt bold and fits inside this with its capsule padding.
    static let speedSlot: CGFloat = 42
    /// ⛔ THE HEIGHT THE BUBBLE HAD BEFORE THE DISC WAS CENTRED — owner, 2026-08-24: "only adjust
    /// the height, use the previous height value, change nothing else".
    ///
    /// ⚠️ CENTRING THE DISC SHORTENED THE BUBBLE AND I DID NOT SAY SO. The old shape was a VStack of
    /// (disc-and-wave row) over (caption row), so its height was the DISC PLUS the caption line:
    /// 40 + 2 + 13. Putting the disc beside that column instead made the column the only thing with
    /// height, and the column is the wave over the caption, 22 + 2 + 13 = 37 — under the disc's own
    /// 40, so the disc became the tallest thing and the bubble lost about fifteen points.
    ///
    /// A `minHeight` rather than a fixed one: it restores the old number without capping anything,
    /// so a larger Dynamic Type caption can still grow the bubble the way it always could. Stated as
    /// the sum it came from, so it follows the disc if that ever moves again.
    static let contentHeight: CGFloat = discSize + 2 + 13

    /// Everything to the right of the disc: the wave, the pill, and the caption line under them.
    static func columnWidth(for message: Message) -> CGFloat {
        waveWidth(for: message) + discGap + speedSlot
    }
    static func contentWidth(for message: Message) -> CGFloat {
        discSize + discGap + waveWidth(for: message) + discGap + speedSlot
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
        // ⛔ THE DISC IS CENTRED ON BOTH ROWS AND THE WORDS START AT THE WAVE — owner, 2026-08-24,
        // his image 2, two position changes and nothing else.
        //
        // ⚠️ THIS REVERSES THE ARRANGEMENT THE NOTE BELOW DESCRIBES, DELIBERATELY AND ON HIS NEWER
        // WORD. It used to be two full-width rows with the disc boxed against the WAVE alone,
        // because when the disc had been centred on both it sat about 10pt below the middle of the
        // wave and nothing lined up. What made that true was a 32pt disc against a 22pt wave plus a
        // caption line; the disc is 40 now, tall enough to span both rows and read as the anchor of
        // the bubble rather than as a control that missed its line.
        //
        // So: the disc sits beside a COLUMN of (wave + pill) over (duration + clock), centred on it.
        // The duration therefore starts where the wave starts instead of under the disc, which is
        // the second half of what he drew.
        HStack(spacing: Self.discGap) {
            playButton
            // ⛔ 6, UP FROM 2 — owner, 2026-08-24, with his image 1 (now) beside image 2 (wanted):
            // "give space between the waveform and the minutes, and between the 1.5× button and the
            // time".
            //
            // ⚠️ BOTH GAPS HE CIRCLED ARE THIS ONE NUMBER. The wave sits over the duration and the
            // speed pill sits over the clock, but they are not two stacks — they are one row above
            // another row, so the space under the wave and the space under the pill are the same
            // spacing and cannot drift apart. Nothing else moves: the bubble takes the extra height
            // through `contentHeight`'s minHeight, which is a floor rather than a fixed size.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Self.discGap) {
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
                        .frame(width: Self.waveWidth(for: message), height: Self.waveHeight)
                    // ⛔ AT THE END OF THE WAVE, ON ITS OWN LINE — owner, 2026-08-24, image 2. It used to
                // sit in the text row beside the duration; there it competed with the clock for the
                // same line and left the wave stopping short of nothing in particular.
                    speedPill
                }
                bottomLine
            }
        }
        .frame(width: Self.contentWidth(for: message), alignment: .leading)
        // A SECOND frame, because there is no `frame(width:minHeight:)` — the fixed-size signature
        // takes width and height, and mixing a fixed width with a minimum height needs the two
        // stated separately.
        .frame(minHeight: Self.contentHeight, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: unheard)
        // ⚠️ The RAW objectWillChange, with the main-queue hop INSIDE the closure — not
        // `.receive(on:)`. Wrapping the publisher rebuilt it on every body evaluation, and each
        // rebuild tore the old subscription down: an engine event landing in that gap was simply
        // lost, and a bubble whose start-event died there kept drawing "play" under audible sound
        // (his intermittent report). The raw publisher is one stable instance, so the subscription
        // survives re-renders; the async hop still reads the engine AFTER the new values land.
        .onReceive(VoiceNotePlayer.shared.objectWillChange) { _ in
            DispatchQueue.main.async { sync() }
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
                    .frame(width: Self.discSize, height: Self.discSize)
                    .background(tint.opacity(0.22), in: Circle())
            } else {
                Circle().fill(tint)
                    .frame(width: Self.discSize, height: Self.discSize)
                    .overlay {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            // Scaled with the disc: 14 was sized for a 32 circle and read as a
                            // triangle lost inside the larger one. Same ratio as his image 2.
                            .font(.system(size: 17))
                            // Colour is irrelevant under destinationOut — only the alpha is read, and
                            // this has to be fully opaque to cut a clean hole.
                            .foregroundStyle(.black)
                            // ⚠️ NO transition on the glyph swap. A symbol-effect bounce was tried here
                            // (the icon travelled between play and pause) and he reported it as LAG:
                            // the audio toggles instantly but the button looked like it answered late.
                            // The reference app swaps the glyph with no motion at all. Keep it instant.
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        }
        .frame(width: Self.discSize, height: Self.discSize)
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
    /// The speed toggle, on the WAVEFORM's line and hard against its trailing edge (owner
    /// 2026-08-24, image 2). Shown ALWAYS, never gated on the player existing: the cell is
    /// pre-measured before playback and anything that appears later grows the content past the
    /// measured height and eats the gap to the next bubble — the bloom `bottomLine` documents.
    /// Tap gesture, not a Button, same reason as the play disc.
    private var speedPill: some View {
        Text(rateLabel).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { cycleRate() }
            // ⚠️ A FIXED SLOT WITH THE CAPSULE HUGGING INSIDE IT. The label changes width as the
            // rate cycles (1× → 1.5× → 2×), and a capsule that grows would push the whole row past
            // the pre-measured `contentWidth` — the same bloom the notes in `bottomLine` describe,
            // reached by a different door. The slot is stated, the capsule stays snug.
            .frame(width: Self.speedSlot, alignment: .trailing)
    }

    private var bottomLine: some View {
        HStack(spacing: 8) {
            Text(durationText).font(.caption2).foregroundStyle(tint.opacity(0.8))
            // ⛔ THE SPEED PILL IS NOT IN THIS ROW ANY MORE — owner, 2026-08-24, image 2: it sits at
            // the END OF THE WAVEFORM, on the wave's own line, not under the duration. See
            // `waveRow`. It is still rendered unconditionally up there, so the pre-measure and the
            // played render stay identical and the bloom this row's comments describe cannot return.
            // "Not heard yet" dot (a blue mic indicator, our way) — fades once played.
            if unheard {
                Circle().fill(Theme.accent(dark)).frame(width: 7, height: 7)
                    .transition(.opacity)
            }
            // THEY HEARD IT. On my own notes only, and only in a chat — this is the thing the reference app says
            // with a blue microphone, and the one voice signal we sent nothing for at all.
            //
            // ⚠️ IT DIMS, IT DOES NOT TURN BLUE, and that is forced rather than chosen. The reference app can use
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
        // The COLUMN's width, not the bubble's: this row now lives beside the disc rather than
        // under it, so the clock's trailing edge is the column's — which is still the bubble's right
        // edge, because the column is everything the disc is not.
        .frame(width: Self.columnWidth(for: message), alignment: .leading)
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
    /// His 2026-08-10 report, with our bubble beside the reference app's and another mainstream messenger's: ours reads as a fence,
    /// theirs read as a voice. Measured rather than judged, and the cause is the top of the scale.
    ///
    /// `AudioRecorder.perceptualLevel` maps the microphone's dB onto 0…1 with SILENCE at −50 dB and
    /// FULL HEIGHT AT 0 dBFS — the loudest sound the hardware can represent, which is a clipped
    /// scream held to the microphone. Ordinary speech on a phone sits between about −30 and −18 dB,
    /// so every bar of every note landed between roughly 12 and 18 points of the 26 available. Never
    /// the top, never the bottom, and a picket fence is exactly what that arithmetic draws.
    ///
    /// That other messenger's own numbers (the reference implementation, read from source): silence is also −50, but full
    /// height is **−20 dB**, `clippingThreshold`, and the mapping is a plain clamped `inverseLerp`
    /// between the two. A 30 dB window instead of our 50, with the top set where a person actually
    /// speaks. That is the whole difference. Their loud syllables reach the ceiling and clamp; ours
    /// were still in the middle of the range.
    ///
    /// ⚠️ AND IT IS DELIBERATELY **NOT** PER-CLIP NORMALISATION. Scaling each note to its own
    /// loudest moment would make a whisper draw identically to a shout — that other messenger's comment is explicit
    /// that a quiet note is meant to render visibly short. An absolute window keeps the real
    /// difference between notes, which is information, not decoration.
    ///
    /// Done at DRAW time, on the stored 0…100, so it re-shapes every voice note ever sent as well as
    /// every new one, with no migration, no re-record and no server change. Exact rather than
    /// approximate: undoing the recorder's `pow(norm, 0.85)` recovers its `norm`, which is
    /// `(dB + 50) / 50`, and multiplying by 50/30 rebases that onto that other messenger's −50…−20 window.
    static func display(_ stored: Int) -> CGFloat {
        let v = CGFloat(max(0, min(100, stored))) / 100
        guard v > 0 else { return 0 }
        var boosted = pow(v, 1 / 0.85) * (50.0 / 30.0)
        // QUIET IS ALLOWED TO BE SMALL — his side-by-side of the same note in both apps: the
        // reference's silences are DOTS and the speech grows out of them, while ours handed room
        // tone and breath a visible bar, so the whole wave sat "a bit bigger". Below this knee the
        // value drops quadratically toward zero: near-silence lands on the 2pt dot floor the
        // canvas already draws, real speech sits far above the knee and is untouched, and the
        // curve is continuous at the knee so nothing pops between the two.
        let quiet: CGFloat = 0.30
        if boosted < quiet { boosted = boosted * (boosted / quiet) }
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
            // feel busy and heavy. The reference app does not move its bars at all. The only thing that travels
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
                // things pointing at it, and on a short note they overlapped into a smudge. The reference app
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
                // ⛔ A FLAT CAPPED LINE, NOT A ROUND KNOB — owner, 2026-08-24, image 2. The dot sat
                // proud of the bar row and pulled the eye to itself; his reference marks the spot
                // with a thin vertical rule the same height as the tallest bar, so the playhead
                // reads as part of the waveform instead of as a control parked on top of it.
                //
                // ⚠️ The 40pt box stays. It was never the dot's touch area — the knob has had
                // `allowsHitTesting(false)` since the scrubbing moved to the waveform gesture — it
                // is what centres the mark on `sx` via the -20 offset, and the note below explains
                // why the gesture must not come back here.
                Capsule()
                    .fill(played)
                    // The wave's own height, read from the geometry this view was given rather than
                    // from VoiceMessageView's constant: this bars view is also drawn by the recorder
                    // strip and the gallery at other heights, and a playhead taller than its wave
                    // would poke out of both.
                    .frame(width: 2.5, height: geo.size.height)
                    .frame(width: 40, height: 40)
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

// The live recording strip: bars ENTER on the right and TRAVEL LEFT, dying off the far edge —
// the reference's live view, on his order. (This view was deleted for a whole-note compressed
// strip earlier the same day; that version re-bucketed on every tick, so bars shimmered in place
// and he read it as lag. The scroll is the honest motion: sound arrives, sound passes.) Fed by
// the recorder's 10Hz `liveWindow`, not the 30Hz meter — thirty bars a second was a stampede.
// Heights go through WaveformBars.display, so silence enters as the same dots the bubble draws.
// THE SECOND "IT STOPS MOVING" REPORT, and this one was never a freeze (owner 2026-08-13, timed by
// him at 0:05). All the motion came from the array growing — a 4.5pt jump ten times a second — which
// looks like travel only while the wave still has a FRONT crossing empty space. At 45pt a second the
// front reaches the far edge at about five seconds; after that the strip is full, and a packed band
// of same-height bars stepping in place reads as stopped until a loud or quiet patch passes.
//
// The row rides a clock now. Between two samples it slides continuously through exactly one slot, so
// the step and the slide cancel and the strip travels at ONE speed whether it is full or not:
//
//   shift = slot × (1 − f), f = how far we are through the current 0.1s sample
//   f = 0 → the newest bar sits one slot PAST the right edge (clipped, not yet arrived)
//   f = 1 → it has slid exactly into place, and the next sample's step takes it from there
//
// ⚠️ NO spring on the layout any more. The old interpolatingSpring animated the same 4.5pt step this
// offset now cancels, so leaving it in makes the two fight and the strip judders.
struct LiveWaveform: View {
    let levels: [AudioRecorder.LiveBar]   // per-sample PERMANENT ids — see LiveBar's note: identity
    var color: Color                      // by offset froze the strip once the window filled
    var stamp: Date = .distantPast        // when the newest bar landed (AudioRecorder.liveStamp)

    var body: some View {
        GeometryReader { geo in
            let slot: CGFloat = 4.5   // 2.5 bar + 2 gap — must match the HStack below
            // .animation drives the redraw every frame; nothing here is animated by SwiftUI, the
            // position IS the clock. A stale stamp (paused, or not recording) clamps f to 1, which
            // is a shift of zero — exactly where the strip stood before this existed.
            TimelineView(.animation) { ctx in
                // CGFloat spelled out: an implicit Double↔CGFloat conversion here is legal and is
                // also exactly the kind of thing this file's type-checker budget is spent on.
                let f = CGFloat(min(1, max(0, ctx.date.timeIntervalSince(stamp) / AudioRecorder.liveInterval)))
                strip(geo: geo, shift: slot * (1 - f))
            }
        }
        .clipped()   // whatever survives the taper still dies AT the strip's edge, never outside the pill
    }

    // `slot` is gone from here: it existed only to work out each bar's distance from the edge for
    // the taper. The travel still uses it, but that is computed by the caller as `shift`.
    private func strip(geo: GeometryProxy, shift: CGFloat) -> some View {
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.element.id) { i, bar in
                    // ⛔ NO TAPER, NO FADE. A BAR IS WHAT WAS HEARD UNTIL THE EDGE CUTS IT.
                    //
                    // Two attempts to shape the exit are now both reverted, and the third report is
                    // what explains the first two. His words: the small waves "goes right" out, but
                    // where there is a big wave "something bugs back", as if it "acted like some
                    // filtering the big waves".
                    //
                    // That is literally what the taper did, and only because of the 2pt floor beside
                    // it. Height was `max(2, display(level) * h * taper)`. A silence bar is already
                    // AT the floor, so multiplying it by the taper changes nothing and it sails out
                    // whole. A speech bar gets multiplied down to that same floor, so it collapses
                    // from full height to a dot. Same 14pt band, opposite behaviour, decided by how
                    // loud the moment was — so the exit looked like it was sorting the voice.
                    //
                    // Fading instead of shrinking (acec998d) failed for a related reason: a faded
                    // full-height bar loses its thin tips first and reads as shrinking anyway.
                    //
                    // The edge cuts them now, which is what the reference app does — it clips and
                    // shapes nothing. Loud and quiet leave identically because neither is touched.
                    // `.clipped()` on the strip is what performs the exit; do not reintroduce a
                    // per-bar height rule here to "soften" it.
                    Capsule().fill(color)
                        .frame(width: 2.5,
                               height: max(2, WaveformBars.display(Int(bar.level * 100)) * geo.size.height))
                        // A new bar ARRIVES at its true height — .identity kills the insertion
                        // grow-in the implicit animation gave it, which read as bars entering
                        // small and swelling into place ("it depends what wave heard, not fixed").
                        .transition(.identity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            // The travel itself. Every bar's position comes from here and from its index, and both
            // are read fresh each frame, so there is no animation left for anything to interrupt.
            .offset(x: shift)
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

// A one-time voice note draws as a PILL, the same idiom as the view-once photo — and it behaves
// like it too, on his order with the reference open: the tap does not play inline, it opens
// `OneTimeVoicePage` full screen, where the note can be replayed freely, and CLOSING the page is
// what spends the listen (ThreadView's cover marks it on dismiss, exactly the photo's flow).
// After that the pill reads "Played" and is inert. The sender's pill never opens anything and
// flips to "Opened" off the receipts-gated voice-played signal.
struct OneTimeVoicePill: View {
    let message: Message
    let cid: String
    let isMe: Bool
    let dark: Bool
    /// ThreadView's snapshot of ViewedOnce at row build (kept fresh by the viewedOnceTick
    /// reconfigure on page close). `consumedLive` re-reads it on appear and on cell reuse.
    let consumed: Bool
    let tint: Color
    let meta: AnyView
    /// Opens the full-screen page — routed through the bubble's onTapImage so the voice page rides
    /// the exact cover the view-once photo uses, dismissal mark included.
    var onOpen: () -> Void = {}

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

    private var spent: Bool { !isMe && (consumed || consumedLive) }
    private var durationText: String {
        let d = Int(message.duration ?? 0)
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold))
            Text(label).font(.system(size: 15, weight: .medium)).italic(spent || (isMe && openedByOther))
            meta
        }
        .foregroundStyle(tint.opacity(spent || (isMe && openedByOther) ? 0.6 : 1))
        .contentShape(Capsule())
        .onTapGesture {
            guard !isMe, !spent, message.sendState == nil else { return }
            onOpen()
        }
        .onChange(of: message.id) { _, _ in consumedLive = ViewedOnce.contains(message.id) }   // hosted cells are reused
        .onAppear { consumedLive = ViewedOnce.contains(message.id) }
    }

    private var icon: String {
        if isMe { return openedByOther ? "circle.slash" : "1.circle" }
        return spent ? "circle.slash" : "1.circle"
    }
    private var label: String {
        if isMe { return openedByOther ? "Opened" : "Voice message" }
        if spent { return "Played" }
        return "Voice message · " + durationText
    }
}

// MARK: - One-time voice page

// The room where the one listen happens — his order, the reference's model, the view-once photo's
// architecture: while this page is up the note plays and replays as often as wanted; leaving the
// page is what burns it (ThreadView's cover marks consumption on dismiss). The decrypted bytes
// live in one tmp file owned by this page and are shredded on the way out — never AudioCache.
// Playback is a private AVAudioPlayer, not the shared engine: the engine outlives screens by
// design, and a note that must die with its screen is the one thing it must never hold.
struct OneTimeVoicePage: View {
    let message: Message
    let cid: String
    let dark: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVAudioPlayer?
    @State private var tmpURL: URL?
    @State private var playing = false
    @State private var progress: Double = 0
    @State private var failed = false
    @State private var ticker: Timer?

    private var durationText: String {
        let d = Int(player?.duration ?? message.duration ?? 0)
        return String(format: "%d:%02d", d / 60, d % 60)
    }
    private var elapsedText: String {
        let d = Int((player?.duration ?? 0) * progress)
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                VStack(spacing: 22) {
                    Image(systemName: "1.circle")
                        .font(.system(size: 54, weight: .light)).foregroundStyle(.white.opacity(0.9))
                    Text("One-time voice message")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    if failed {
                        Text("Could not load this voice message.")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                    } else if player == nil {
                        ProgressView().tint(.white)
                    } else {
                        Button { toggle() } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 30)).foregroundStyle(.black)
                                .frame(width: 84, height: 84)
                                .background(.white, in: Circle())
                        }
                        .buttonStyle(.plain)
                        // A thin progress line — no waveform exists for a one-time note on purpose
                        // (none is ever sent), so the line is the honest picture.
                        VStack(spacing: 6) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.25))
                                    Capsule().fill(.white)
                                        .frame(width: max(4, geo.size.width * progress))
                                }
                            }
                            .frame(width: 220, height: 4)
                            HStack {
                                Text(elapsedText)
                                Spacer()
                                Text(durationText)
                            }
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 220)
                        }
                    }
                }
                Spacer()
                Text("It's gone when you leave this screen")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 26)
            }
        }
        .task { await load() }
        .onDisappear { teardown() }
    }

    private func toggle() {
        guard let p = player else { return }
        if playing { p.pause(); playing = false; return }
        if progress >= 0.999 { p.currentTime = 0; progress = 0 }   // replay from the top
        p.play(); playing = true
        startTicker()
    }

    private func load() async {
        // The shared engine must not talk over the room.
        VoiceNotePlayer.shared.pause()
        guard let urlStr = message.audioUrl, let url = URL(string: urlStr), let meta = message.enc,
              let (cipher, _) = try? await MediaSession.shared.data(from: url),
              let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
            failed = true
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-once-page-\(message.id).m4a")
        try? data.write(to: tmp)
        tmpURL = tmp
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: tmp)
        guard player != nil else { failed = true; return }
        // The room plays as it opens — nobody opens a one-time note to look at it.
        player?.play()
        playing = true
        startTicker()
        // The sender's "Opened" rides the same receipts-gated voice-played signal every ordinary
        // note sends (the gate lives inside; receipts off means the sender learns nothing).
        ChatService.markVoicePlayedThrottled(cid, createdAtMillis: message.createdAt.timeIntervalSince1970 * 1000)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let p = player else { return }
                if p.isPlaying {
                    progress = p.duration > 0 ? p.currentTime / p.duration : 0
                } else if playing {
                    // Ran to the end: park at the start, ready for a free replay in this room.
                    playing = false
                    progress = 1
                    ticker?.invalidate(); ticker = nil
                }
            }
        }
    }

    private func teardown() {
        // THE SERVER BURN, on the way out — leaving the room is the consumption. Gated on the
        // player having existed: a page that never managed to load must not delete a note nobody
        // heard. Fire-and-forget; the function refuses groups (device-local there, like the
        // photo) and refuses everything that is not a one-time audio message from someone else.
        if player != nil {
            Functions.functions(region: "me-central1").httpsCallable("consumeOnceVoice")
                .call(["cid": cid, "messageId": message.id]) { _, _ in }
        }
        ticker?.invalidate(); ticker = nil
        player?.stop(); player = nil
        if let t = tmpURL { try? FileManager.default.removeItem(at: t) }
        tmpURL = nil
        if !VoiceAudio.callActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}

import UIKit
import SwiftUI

// ⛔ THE COMPOSER IS UIKIT — owner, 2026-08-25: "The Composer input text is currently implemented in
// SwiftUI. Please completely convert it to UIKit." The whole bar he circled: "+", the pill with the
// field, the reply / edit / link banners, the GIF and mic buttons, the send button, the hold-to-record
// row, the locked recording bar with its review, the big mic overlay and the two toasts.
//
// THE SHAPE IS THE REFERENCE APP'S INPUT PANEL: one UIKit view that is handed the WHOLE interface
// state on every change (`ChatComposerView.apply`), diffs it against what it last drew, and animates
// only what changed — their `updateLayout(interfaceState)`. Nothing in the bar is inserted or
// removed for a state change; every control is resident and only its alpha, transform and frame
// move. That is what makes a cross-fade a cross-fade instead of two events that happen to overlap,
// and it is why the mic's hold gesture can never lose the view it is attached to mid-touch.
//
// SwiftUI still owns three things on purpose: the bar's PLACE (the `safeAreaBar` slot, the system
// chrome insets and the keyboard-clock animation of those insets — all recently settled and all
// about where the bar sits, not what it draws), the @-mention popup above it (it draws `AvatarView`
// and `VerifiedMark`, which are SwiftUI and not part of the bar), and the floating pause button,
// which hangs off the chat container so it can overlap the list.

/// Everything the bar draws. Built by `ThreadView` from its own state on every render and pushed in
/// whole; `ChatComposerView` diffs it, so an unchanged state costs one `==`.
struct ChatComposerState: Equatable {
    var text = ""
    /// 2026-09-24 decision D-composer-5: where the caret goes when `text` is pushed in (a UTF-16
    /// offset), for an @mention inserted mid-text. nil keeps UIKit's default, the end.
    var caret: Int? = nil
    var placeholder = "Message"
    /// The keyboard's owner. In → a CHANGE of this flag makes the field take or give up first
    /// responder; out → the delegate reports what actually happened, a turn later. Between a tap
    /// on the field and that report the flag lags the field, and the view knows not to act on the
    /// lag (`ChatComposerView.syncText`).
    var focused = false
    /// The send button is a checkmark while an inline edit is open.
    var editing = false
    /// "+" shows an ellipsis while a photo is going out.
    var attachBusy = false
    /// A MESSAGE REQUEST IS TEXT ONLY — owner's spec, 2026-09-11 §9. While the one message to a
    /// stranger is being written there is no "+", no GIF and no mic, and the pill takes the whole
    /// bar. The rules refuse anything but text on that message; this just does not offer it.
    var textOnly = false
    /// Stickers are off for me in this group: the sticker button is not shown.
    var stickersOff = false
    /// A channel I post in (2026-10-28): my posts go out without sound when true. Nil anywhere
    /// else, and the bell in the field is not shown.
    var channelSilent: Bool? = nil
    /// A channel admin may hold Post to schedule the text for later (2026-10-28).
    var canSchedule = false
    /// A channel I post in: the selection menu offers Format > Bold (owner 2026-11-07).
    var canFormat = false
    /// Reply / edit / link cards stacked above the field, in this order. Empty while recording.
    var banners: [ChatComposerBanner] = []

    // Voice
    var holdStarted = false
    var recordLocked = false
    /// The raw finger translation since touch-down. The view rubber-bands it for display; the
    /// thresholds are ThreadView's, computed from the same rubber-band.
    var recordDrag: CGSize = .zero
    var cancelArmed = false
    var reviewing = false
    var previewPlaying = false
    var previewProgress: Double = 0
    var previewDecibels: [Float] = []
    var voiceOnce = false

    // Toasts
    var holdHint = false
    var voiceOnceToast = false

    // Look
    var dark = false
    /// The chat's own colour, or the default bubble blue — the send button's glass tint.
    var sendTint: UIColor = .systemBlue
    var noticeSurface: Theme.ReceivedSurface = .material
    var onWallpaper = false
    /// Slow mode: when I may send again (nil when I am not waiting) and the group's full wait, for
    /// the ring on the send button and the countdown in the field.
    var slowUntil: Date? = nil
    var slowTotal: Double = 0
    /// The tip above the send button after a send that came too soon; nil hides it.
    var slowTip: String? = nil

    /// Something waits to be sent with no words needed: a quoted channel post (owner 2026-11-06,
    /// "adding text must be optional"). The send button shows as if text were typed.
    var sendsWithoutText = false

    /// "There is something to send": typed words, or an attachment that may go alone.
    var hasText: Bool { sendsWithoutText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A finger is on the mic right now (not yet locked). The big overlay and the hold row.
    var recordingHeld: Bool { holdStarted && !recordLocked }
    /// "The composer is not the composer at the moment" — any recording, held or locked.
    var recordingActive: Bool { holdStarted || recordLocked }
}

/// Bold spans in the composer's field (owner 2026-11-07). The field writes them on every change;
/// the chat reads them at send. Each copy is tied to the exact text it belongs to, so spans never
/// land on other words.
@MainActor enum ComposerFormat {
    private static var text = ""
    private static var bold: [NSRange] = []
    private static var prefill: (text: String, bold: [NSRange])?

    /// The field's text and its bold spans, as they are now.
    static func note(text: String, bold: [NSRange]) {
        self.text = text
        self.bold = bold
    }

    /// Bold spans for `raw` (the untrimmed field text), moved onto its trimmed form.
    static func bold(for raw: String) -> [NSRange] {
        guard raw == text, !bold.isEmpty else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let at = (raw as NSString).range(of: trimmed)
        guard !trimmed.isEmpty, at.location != NSNotFound else { return [] }
        let moved = bold.map { NSRange(location: $0.location - at.location, length: $0.length) }
            .compactMap { r -> NSRange? in
                // Cut off what fell into the trimmed edges.
                let start = max(0, r.location), end = min(at.length, NSMaxRange(r))
                return end > start ? NSRange(location: start, length: end - start) : nil
            }
        return TextFormat.normalized(moved, length: at.length)
    }

    /// The chat is about to put `text` in the field (an edit): give it these bold spans.
    static func setPrefill(_ text: String, bold: [NSRange]) {
        prefill = bold.isEmpty ? nil : (text, bold)
    }

    /// The prefill for `text`, once; nil when it is for other words.
    static func takePrefill(for text: String) -> [NSRange]? {
        guard let p = prefill, p.text == text else { return nil }
        prefill = nil
        return p.bold
    }

    /// Keeps spans when the chat rewrites the field (an @mention picked): spans before the change
    /// stay, spans after it move with the text, spans across it are dropped.
    static func carry(_ rs: [NSRange], from old: String, to new: String) -> [NSRange] {
        guard !rs.isEmpty else { return [] }
        let a = old as NSString, b = new as NSString
        var head = 0
        while head < a.length, head < b.length, a.character(at: head) == b.character(at: head) { head += 1 }
        var tail = 0
        while tail < a.length - head, tail < b.length - head,
              a.character(at: a.length - 1 - tail) == b.character(at: b.length - 1 - tail) { tail += 1 }
        let shift = b.length - a.length
        let out = rs.compactMap { r -> NSRange? in
            if NSMaxRange(r) <= head { return r }
            if r.location >= a.length - tail { return NSRange(location: r.location + shift, length: r.length) }
            return nil
        }
        return TextFormat.normalized(out, length: b.length)
    }
}

/// A mutable timestamp with NO SwiftUI invalidation: written from `hitTest` on every composer
/// touch (a @State write there would re-run the whole conversation tree per keystroke), read by
/// the tap-to-dismiss guard. Held in a @State box so the instance survives re-renders.
final class TouchClock {
    var last = Date.distantPast
}

/// One card above the field: what you are replying to, what you are editing, or the link preview.
struct ChatComposerBanner: Equatable {
    /// `.quote`: a channel post being quoted into this chat (owner 2026-11-06); drawn like a reply.
    enum Style: Equatable { case reply, edit, link, quote }
    enum Thumb: Equatable {
        /// A chat photo or video poster the bubble already put in `DiskImageCache`.
        case cached(url: String)
        /// A GIF: its bytes live in `GifBytesCache`, decoded through `UIImage.animatedGif`.
        case gif(url: String)
        /// Already decoded (the link preview's image).
        case image(UIImage)
        /// 2026-09-24 feature-audit: a spinner, for the link card while its page is still loading.
        case loading
    }
    enum Detail: Equatable {
        case text(String)
        /// A small symbol before the words — "3 Photos", "Voice call", a file name.
        case labelled(symbol: String, text: String)
        /// A voice note: its stored bars and "0:07".
        case voice(bars: [Int], duration: String)
    }
    var id: String
    var style: Style
    var title: String
    var detail: Detail
    var thumb: Thumb?
    /// The link card's third line, the host.
    var footnote: String?
}

/// What the bar can ask of the chat. Plain closures, rebuilt by ThreadView on every render and
/// installed on the view in `updateUIView`, so they always see the current state.
struct ChatComposerActions {
    var textChanged: (String) -> Void = { _ in }
    /// 2026-09-24 decision D-composer-5: the caret moved (UTF-16 offset), so @mentions can follow it.
    var caretChanged: (Int) -> Void = { _ in }
    /// 2026-09-24 decision D-composer-5: pictures pasted into the field → the photo approval flow.
    var pasteImages: ([UIImage]) -> Void = { _ in }
    var focusChanged: (Bool) -> Void = { _ in }
    /// A touch landed anywhere on the bar. The chat's tap-to-dismiss gesture hears taps through
    /// the whole screen — the bar included — and dismisses one runloop turn later so tap-handlers
    /// can cancel it. The SwiftUI bar used to be such a canceller by construction; the UIKit bar
    /// lost that in the move (his report, 2026-08-27: tapping the field for Paste closed the
    /// keyboard). This is the cancel wire back: `hitTest` stamps `TouchClock`, no SwiftUI state
    /// write, and the dismissal checks the stamp.
    var barTouched: () -> Void = {}
    var attach: () -> Void = {}
    var gif: () -> Void = {}
    /// The sticker panel's GIF Search: the same sheet as `gif`, opened on its search field.
    var gifSearch: () -> Void = {}
    /// 2026-10-17 sticker keyboard: a sticker tapped in the panel, and its "Create Sticker" tile.
    /// The panel's GIFs tab still calls `gif` (today's picker).
    var sendSticker: (Sticker) -> Void = { _ in }
    var createSticker: () -> Void = {}
    /// A GIF tapped in the panel's own GIFs tab (2026-10-17).
    var sendGif: (GiphyService.Gif) -> Void = { _ in }
    /// The camera, from its button in the field (owner 2026-10-15: moved here from the attach sheet).
    var camera: () -> Void = {}
    var send: () -> Void = {}
    var dismissBanner: (ChatComposerBanner.Style) -> Void = { _ in }
    var holdBegan: () -> Void = {}
    var holdChanged: (CGSize) -> Void = { _ in }
    var holdEnded: (_ translation: CGSize, _ cancelled: Bool) -> Void = { _, _ in }
    var cancelRecording: () -> Void = {}
    var sendRecording: () -> Void = {}
    var togglePreview: () -> Void = {}
    /// The bar's own pause / keep-recording button (owner 2026-10-28; it floated above the bar).
    var pauseOrResumeRecording: () -> Void = {}
    /// The channel bell in the field: posts with or without sound (2026-10-28).
    var toggleChannelSilent: () -> Void = {}
    /// Hold Post > Schedule Post (a channel admin, with text written).
    var schedulePost: () -> Void = {}
    var seekPreview: (Double) -> Void = { _ in }
    var toggleVoiceOnce: () -> Void = {}
    /// The chat's box for what changes faster than the chat should redraw (perf audit T1/T3/T6).
    /// The bar registers itself on it when the actions are handed over.
    var live: ComposerLive? = nil
}

/// ⛔ WHAT CHANGES PER KEY, PER TOUCH SAMPLE OR PER TICK, KEPT OUT OF THE CHAT'S STATE (perf audit
/// T1/T3/T6, the reference app's way: its input panel holds its own text and owns the record
/// button's drag). The chat screen used to hold these as `@State`, so each key, each finger move on
/// the mic and each 20 Hz review tick re-ran the whole chat screen. Now the chat writes here and the
/// bar is pushed the drag and the review progress directly (`liveDrag`, `liveProgress`); typed text
/// the bar already shows. A plain class: nothing observes it.
final class ComposerLive {
    weak var bar: ChatComposerView?
    /// What is in the field. The chat's `input` reads and writes this.
    var text = ""
    /// The text as it was before the first write not yet reacted to (see `ThreadView.setComposerText`).
    var pendingOld: String?
    var caret: Int?
    var typingIdleStop: DispatchWorkItem?
    var drag: CGSize = .zero
    var progress: Double = 0
}

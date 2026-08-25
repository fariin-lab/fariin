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
    var placeholder = "Message"
    /// The keyboard's owner. In → the field takes or gives up first responder; out → the delegate
    /// reports what actually happened, so the flag can never disagree with the keyboard.
    var focused = false
    /// The send button is a checkmark while an inline edit is open.
    var editing = false
    /// "+" shows an ellipsis while a photo is going out.
    var attachBusy = false
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
    /// The SwiftUI paddings around the bar. The old `.overlay`s (hint, toast, big mic) were placed
    /// against the PADDED box, so the view places them against the same box to keep the geometry.
    var outerInsets = UIEdgeInsets(top: 6, left: 20, bottom: 8, right: 20)

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A finger is on the mic right now (not yet locked). The big overlay and the hold row.
    var recordingHeld: Bool { holdStarted && !recordLocked }
    /// "The composer is not the composer at the moment" — any recording, held or locked.
    var recordingActive: Bool { holdStarted || recordLocked }
}

/// One card above the field: what you are replying to, what you are editing, or the link preview.
struct ChatComposerBanner: Equatable {
    enum Style: Equatable { case reply, edit, link }
    enum Thumb: Equatable {
        /// A chat photo or video poster the bubble already put in `DiskImageCache`.
        case cached(url: String)
        /// A GIF: its bytes live in `GifBytesCache`, decoded through `UIImage.animatedGif`.
        case gif(url: String)
        /// Already decoded (the link preview's image).
        case image(UIImage)
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
    var focusChanged: (Bool) -> Void = { _ in }
    var attach: () -> Void = {}
    var gif: () -> Void = {}
    var send: () -> Void = {}
    var dismissBanner: (ChatComposerBanner.Style) -> Void = { _ in }
    var holdBegan: () -> Void = {}
    var holdChanged: (CGSize) -> Void = { _ in }
    var holdEnded: (_ translation: CGSize, _ cancelled: Bool) -> Void = { _, _ in }
    var cancelRecording: () -> Void = {}
    var sendRecording: () -> Void = {}
    var togglePreview: () -> Void = {}
    /// The floating button above the send: pause while recording, continue while reviewing.
    var pauseRecording: () -> Void = {}
    var resumeRecording: () -> Void = {}
    var seekPreview: (Double) -> Void = { _ in }
    var toggleVoiceOnce: () -> Void = {}
}

import SwiftUI
import Combine   // NotificationCenter.publisher, for the keyboard's own didHide
import PencilKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import PhotosUI
import ImageIO   // CGImageSource: a sticker's first frame, which is the frame that posts
import MapKit    // CLLocationCoordinate2D, carried by a place sticker
import StoryUI   // StoryCanvas: the one sampler + drawer for a story's backdrop

// Photo-story editor — matches the in-chat photo editor (image 212): the picked photo fits on a
// black canvas; X top-left; a caption bar + @ and a crop / draw / adjust / HD tool row at the
// bottom with a green send. Send flattens the edits and opens the audience sheet, which posts the
// story via StoriesService. Every tool is real.
// Publishes the live keyboard height. The editor opts OUT of SwiftUI's automatic keyboard
// avoidance (it was squishing the canvas and desyncing button hit-tests) and instead lifts
// only the bottom bar by this measured height.
final class KeyboardWatcher: ObservableObject {
    @Published var height: CGFloat = 0
    /// WHERE THE KEYBOARD'S TOP EDGE IS ON THE SCREEN, which is the number a view that is not the
    /// screen actually needs.
    ///
    /// ⚠️ `height` IS MEASURED FROM THE BOTTOM OF THE SCREEN, AND SPENDING IT INSIDE A VIEW THAT
    /// DOES NOT REACH THE BOTTOM OF THE SCREEN DOUBLE-COUNTS EVERYTHING IN BETWEEN.
    ///
    /// The story text card is the top half of a VStack whose other half is an 88pt bar, over a home
    /// indicator: its bottom edge is about 122pt up from the screen's. Padding it by `height` lifts
    /// its contents 122pt further than the keyboard ever came, which is the owner's Aa row floating
    /// far above the keys with a gap nobody asked for.
    ///
    /// Signal does not do this arithmetic at all. `PhotoCaptureViewController.handleKeyboardNotification`
    /// converts the end frame into the composer's OWN space
    /// (`textStoryComposerView.convert(endFrame, from: nil)`) and insets by the difference against
    /// its own bounds, so the amount it moves cannot depend on what is underneath it.
    ///
    /// A view can subtract this from its own `maxY` and get exactly the overlap it has to clear.
    /// `.infinity` while the keyboard is down means "nothing overlaps", with no special case.
    @Published var topOnScreen: CGFloat = .infinity

    /// THE KEYBOARD'S OWN CLOCK, TAKEN OFF THE NOTIFICATION RATHER THAN GUESSED AT.
    ///
    /// The reference app reads exactly these two keys in its `keyboardWillChangeFrame` handler and
    /// builds one transition out of them, which every frame it moves is then set inside:
    ///
    ///     var duration = userInfo[keyboardAnimationDurationUserInfoKey] ?? 0.0
    ///     if duration > .ulpOfOne { if #available(iOS 26.0, *) {} else { duration = 0.5 } }
    ///     let curve = userInfo[keyboardAnimationCurveUserInfoKey] ?? 7
    ///     transitionCurve = (curve == 7) ? .spring : .easeInOut
    ///
    /// ⚠️ Note what the version check says: below iOS 26 they THROW THE REPORTED DURATION AWAY and use
    /// 0.5; on 26 they keep it. We are 26-only, so the reported number is the one to use.
    @Published private(set) var animationDuration: Double = 0.25
    /// UIKit's curve constant. 7 is the keyboard's own private curve and is what it reports in
    /// practice; theirs maps 7 to a spring and everything else to ease-in-out.
    @Published private(set) var animationCurve: UInt = 7

    /// The notification's clock as something SwiftUI can animate with.
    ///
    /// ⚠️ 0.23, 1.0, 0.32, 1.0 IS THEIR OWN BEZIER FOR CURVE 7, not a shape picked to look right.
    /// `springAnimationSolver` in `ListViewAnimation.swift` samples `kCAMediaTimingFunctionSpring`
    /// where it can and falls back to `bezierPoint(0.23, 1.0, 0.32, 1.0, t)` where it cannot — and
    /// `UIView.AnimationOptions(rawValue: 7 << 16)` is how they hand the same curve to UIKit. SwiftUI
    /// has no door to `7 << 16`, so their own written-out form of it is the closest honest thing.
    var systemAnimation: Animation {
        let d = animationDuration > .ulpOfOne ? animationDuration : 0.25
        return animationCurve == 7 ? .timingCurve(0.23, 1.0, 0.32, 1.0, duration: d)
                                   : .easeInOut(duration: d)
    }

    private var tokens: [NSObjectProtocol] = []
    init() {
        // ⚠️ `queue: nil`, WHICH IS THEIRS, AND `.main` IS NOT THE SAME THING. With a queue handed
        // in, the block is ENQUEUED — even `.main` runs it in a later runloop turn than the post. The
        // keyboard is already moving by then, so anything driven off this was a turn behind it every
        // single time. `nil` runs the block synchronously on the posting thread, which is the main
        // thread, which is where the keyboard posts from.
        tokens.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil) { [weak self] n in
                guard let self else { return }
                self.readClock(from: n)
                guard let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
                self.height = max(0, UIScreen.main.bounds.height - f.origin.y)
                self.topOnScreen = f.origin.y
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: nil) { [weak self] n in
                guard let self else { return }
                self.readClock(from: n)
                self.height = 0
                self.topOnScreen = .infinity
        })
    }

    private func readClock(from n: Notification) {
        if let d = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue {
            animationDuration = d
        }
        if let c = (n.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue {
            animationCurve = c
        }
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

struct StoryEditorView: View {
    let source: UIImage
    var onPosted: () -> Void = {}
    /// A WHOLE POST ARRIVING FROM THE VIDEO EDITOR. When a picture joins a video-first post, that
    /// screen cannot hold it (its model is a list of clips, each of which IS a video), so it hands
    /// everything here — each clip with its trim, mute, drawing and text, then the new picture.
    /// Empty means the normal single-photo start via `source`.
    var seedItems: [DraftItem] = []
    var seedCaption: String = ""
    /// ⚠️ VIDEOS THAT ARRIVE WITH THE HAND-OFF BUT ARE NOT RESOLVED YET, and this is what stopped
    /// the video editor showing twice.
    ///
    /// Packing a clip means loading its duration and generating a poster, which is seconds for
    /// several large files. The video editor used to do that work BEFORE it handed over — while the
    /// picker had already dismissed itself — so the old, unchanged video editor sat there as the
    /// frontmost screen for the whole wait and this composer then slid up on top of it. Two editors,
    /// which is exactly what he photographed.
    ///
    /// They come across raw now and resolve HERE, on the screen that is already up, through the same
    /// `appendPicked(video:)` the + button has always used. The strip fills in as each one lands,
    /// which is the behaviour the photo path already had.
    var seedVideos: [(url: URL, assetID: String?)] = []
    /// The library asset `source` came from, if it came from one. It makes the first item count
    /// against the story's five and show as a tick when the + reopens the picker — see
    /// `DraftItem.assetID`. Nil for a camera capture, which is counted but cannot be ticked.
    var sourceAssetID: String? = nil
    /// ⚠️ THE POST STARTS ON A VIDEO, AND THIS IS WHAT ENDS THE TWO-EDITOR BUG.
    ///
    /// A video used to open a screen of its own whose model is a list of CLIPS, so the moment a
    /// picture joined the post it could not hold it and handed the whole thing to this composer —
    /// presented on top of itself, and never dismissed, because nothing told it to be. Two real
    /// screens, which is what he photographed three times. Timing fixes could only ever change how
    /// long the first one was visible for.
    ///
    /// So there is no hand-off any more: a video-first post opens HERE, where a clip and a picture
    /// are both just a `DraftItem`, and the second screen never exists to be seen.
    ///
    /// ⚠️ IT IS SEEDED SYNCHRONOUSLY AND FILLED IN AFTERWARDS. `appendPicked(video:)` awaits the
    /// duration before it appends, which is right for a clip joining a post already on screen and
    /// wrong for the FIRST item: every part of this view reads `items[index]`, so an empty `items`
    /// for the length of that load is a composer drawn on nothing. See `resolveSourceVideo`.
    var sourceVideo: SourceVideo? = nil

    /// The clip a video-first post opens on. A struct rather than a tuple so it can be `Equatable`
    /// and carried in a `@State`-driven presentation without the compiler having to infer it.
    struct SourceVideo: Equatable {
        let url: URL
        let assetID: String?
        init(url: URL, assetID: String? = nil) { self.url = url; self.assetID = assetID }
    }

    /// Open the composer on a video. The `source` picture is the placeholder every clip wears until
    /// its own frame decodes — it is never shown as an item, because `onAppear` seeds the clip
    /// instead of building a photo from it.
    static func forVideo(url: URL, assetID: String? = nil,
                         onPosted: @escaping () -> Void = {}) -> StoryEditorView {
        StoryEditorView(source: blackPoster, onPosted: onPosted,
                        sourceVideo: SourceVideo(url: url, assetID: assetID))
    }
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var drawing = PKDrawing()
    /// ⛔ WHICH LAYER IS ON TOP, AND IT IS WHICHEVER WAS TOUCHED LAST (owner, 2026-08-21: "when i use
    /// pen then i try to use Aa the text are entering UNDER pen … always the one is the last one
    /// become up").
    ///
    /// The drawing was permanently above the text and the stickers, because it is declared after
    /// them in the ZStack and a ZStack draws in declaration order. So a caption written after a
    /// scribble went under the scribble, every time, with no way to bring it forward.
    ///
    /// ⚠️ IT IS ONE FLAG AND NOT A z PER ITEM, and that is the architecture rather than a shortcut.
    /// Every stroke lives in ONE `PKDrawing` on ONE canvas — there is no such thing as putting a
    /// caption between two strokes, because the strokes are not separable layers. So the honest
    /// question is the only one that can be answered: was the last thing you did a stroke, or a
    /// thing you placed. His sentence is exactly that question.
    @State private var drawingOnTop = true
    @State private var isDrawing = false
    /// The strokes as they were when the pen was opened, so its ✕ can put them back. Nil whenever
    /// the pen is shut — see `closePen`.
    @State private var drawingAtPenOpen: PKDrawing?
    /// The pen's Discard / Keep question, raised only when this session actually drew something.
    @State private var confirmDiscardDrawing = false
    @State private var filterIndex = 0
    @State private var croppedSource: UIImage?   // result of the interactive crop (nil = uncropped)
    @State private var showCrop = false
    /// The crop screen's picture has left the card, so this card may stand down. See the note beside
    /// the canvas's own `.opacity` and `ChatCropView.onFlightStart`. Reset on close, or the next crop
    /// would open with the card already hidden and show the held frame all over again.
    @State private var cropFlying = false
    /// The story card's rectangle on screen, so Crop can open as a resize of the picture already
    /// there instead of as a second picture fading in over it. See `cropOverlay`.
    @State private var cardRect: CGRect = .zero
    // Trim's working state for the video item on screen, mirrored back into the item on Done. It
    // lives here rather than in a pushed screen because trimming is a mode of this editor, the same
    // call he made on the video editor.
    @State private var showTrim = false
    /// Which tab the trim page is showing. Always `.video` on open — his rule, and the reason the
    /// page is entered at all is nearly always the trim.
    private enum TrimTab { case video, adjust }
    @State private var trimTab: TrimTab = .video
    /// The one composition the dial drives, and the live exposure inside it. Built on the first
    /// touch of the dial and dropped with the player — see `applyPreviewBrightness`.
    @State private var brightnessLive: StoryVideoBrightness.LiveExposure?
    /// Which way the next still-frame nudge steps — see `nudgePreviewFrame`.
    /// The link badge currently wearing "Tap for more", or nil. See `showLinkHint`.
    @State private var linkHintStickerID: UUID?
    /// How far above the badge's top edge the hint floats.
    private static let linkHintGap: CGFloat = 14
    /// How long it stays. The owner's number, from his own reference picture — there is nothing to
    /// copy here: the app this badge is modelled on shows no such hint at all, which was checked in
    /// the three files that build and manage it before this was written.
    private static let linkHintSeconds: TimeInterval = 5

    @State private var nudgeForward = false
    /// True while a still-frame redraw is being seeked. The dial keeps writing the exposure through
    /// it; only the redraw is dropped. See `nudgePreviewFrame`.
    @State private var nudgeInFlight = false
    /// A redraw asked for while one was already running. Redeemed by the in-flight seek's completion
    /// so the last position of a drag always gets a frame.
    @State private var nudgePending = false
    /// Builds that one composition — see `applyPreviewBrightness`.
    @State private var brightnessTask: Task<Void, Never>?
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var trimOpenedStart: Double = 0   // what X puts back
    @State private var trimOpenedEnd: Double = 0
    @State private var trimThumbs: [UIImage] = []
    /// Which clip the strip above belongs to. The strip is the WHOLE clip with handles over it, so it
    /// does not change when the handles do — only when the item does. Keeping it is what stops a
    /// second trim of the same video decoding the same ten frames again; see `loadTrimThumbs`.
    @State private var trimThumbsItem: UUID?
    // THE COMPOSER HAD NO PLAYER AT ALL, which is why the play mark did nothing and why trim was a
    // filmstrip you dragged blind. A video item drew its poster and a decorative `play.fill`.
    //
    // One AVPlayer, built when a clip needs previewing and torn down when you leave it. It is not
    // built up front: most posts are photos, and an idle AVPlayer per composer session is a decoder
    // held open for nothing.
    @State private var previewPlayer: AVPlayer?
    @State private var previewPlaying = false
    /// The end-of-clip registration. `NotificationCenter.addObserver(forName:object:queue:using:)`
    /// hands back a token that lives until it is removed BY HAND, and the block it registers captures
    /// the AVPlayer and this view. Throwing the token away leaked one of each per clip previewed, for
    /// the whole life of the app. `stopPreview()` removes it.
    @State private var previewEndObserver: NSObjectProtocol?
    /// The playback clock behind the trim strip's white line. Removed from the PLAYER in
    /// `stopPreview()`, which is why it is held rather than discarded — see `ensurePreviewPlayer`.
    @State private var trimTimeObserver: Any?
    /// ⛔ THE PLAYHEAD IS NOT THIS SCREEN'S `@State` ANY MORE, AND THAT IS THE VIDEO FREEZE.
    ///
    /// His report, and the repro he worked out himself, which is the whole diagnosis: it only happens
    /// when the clip is PLAYING as he changes page. Pause first, trim, play in trim, pause, Done —
    /// any number of times — and it never happens.
    ///
    /// The playhead is written by a periodic time observer at 20Hz, and a periodic observer only
    /// fires while time is actually moving. That is exactly "only while it is playing". As a plain
    /// `@State` on this view, each of those twenty writes a second INVALIDATED THE WHOLE EDITOR BODY:
    /// the canvas, the overlays, the caption layer, the tool row, the trim page and, through
    /// `ZoomableImageView.updateUIView`, a fresh `transform` write onto the very `UIView` whose layer
    /// is the `AVPlayerLayer` showing the clip. Twenty times a second, on the main thread, on top of
    /// a 0.28s page animation.
    ///
    /// The picture is what starves under that and the sound is not, which is precisely what he sees
    /// and is not a coincidence: audio runs on its own real-time thread, while video frames reach an
    /// `AVPlayerLayer` through the main run loop and CoreAnimation's commit. Starve the main thread
    /// and the sound plays on over a still picture until it catches up — his "after minutes it works".
    ///
    /// A class in `@State` rather than a `@StateObject`, and the difference IS the fix: `@StateObject`
    /// subscribes the owning view to `objectWillChange`, which would put the whole body straight back
    /// on the 20Hz clock. `@State` holds the reference and nothing else, so the only view that
    /// re-renders is the one that observes the box — `TrimStripHost`, which is 56 points tall.
    @State private var trimPlayhead = TrimPlayheadBox()
    /// The photo's live transform, for the pen layer that rides above it. A class in `@State` for the
    /// same reason `trimPlayhead` is one: the reference is held and NOTHING re-renders when it
    /// changes. See `PhotoTransformRelay`.
    @State private var photoTransform = PhotoTransformRelay()
    @State private var trimScrub: Double?
    @State private var trimDragging = false
    /// ⛔ THE SEEK SERIALISER, AND IT IS WHY THE CLIP FROZE AFTER A SECOND TRIM.
    ///
    /// Every scrub of the trim strip fired `seek(toleranceBefore: .zero, toleranceAfter: .zero)`
    /// STRAIGHT AT THE PLAYER, one per drag frame. A zero-tolerance seek is the expensive kind: it
    /// cannot answer with a nearby keyframe, so the renderer flushes and decodes forward from the
    /// previous sync sample every single time. Issued faster than they complete, they queue, and the
    /// VIDEO renderer never settles long enough to put a frame on screen — while the audio, already
    /// buffered and running on its own clock, plays straight through. That is his report word for
    /// word: sound continues, frames stop, and it "suddenly starts playing again" the moment the
    /// backlog drains.
    ///
    /// It is worse on the second trim because nothing clears between them: the storm from the first
    /// scrub is still unwinding when the second `openTrim` adds another precise seek on top of it.
    ///
    /// Apple's own answer to this is QA1820 — never have more than one seek in flight, remember only
    /// the LATEST target, and issue it when the current one finishes. That is exactly what these two
    /// hold, and `seekPreview` is the only door to the player's seek now.
    @State private var seekInFlight = false
    @State private var pendingSeek: (time: CMTime, precise: Bool)?
    /// Where the finger last asked for, so lifting it can land one exact seek. See `seekPreview`.
    @State private var lastScrubSeconds: Double?
    @State private var cropRect: CGRect? = nil   // live crop as a rectangle — see DraftItem.cropRect
    // Our own pen palette, the same three controls ChatImageEditor drives PencilKit with. Defaults
    // match it too, so a pen is a pen wherever you pick one up in this app.
    @State private var penHue = 0.01             // 0 = white end of the track; 0.01 = red
    @State private var penWidth: CGFloat = 6
    @State private var isHighlighter = false
    /// A stroke is under the finger right now. Everything on top of the photo gets out of the way
    /// while it is true (owner 2026-08-03: "when i start to use pen all buttons hide, when i remove
    /// my finger show again") — you cannot draw across a corner your own toolbar is sitting on.
    @State private var strokeInFlight = false
    /// Clear All asked before it throws every stroke away — see `penTopBar`.
    @State private var showClearAll = false
    @State private var editedCache: UIImage?         // filtered+cropped; recomputed only on tool change
    /// The reference app's two canvas colours for the picture as it stands. Held rather than derived on each
    /// layout pass, and rewritten by `recomputeEdited` — a filter changes the picture, so it changes
    /// the canvas made from it.
    @State private var canvasCache: (top: UIColor, bottom: UIColor)?
    @State private var canvasSize: CGSize = .zero
    // Pinch-zoom + pan the photo directly on the canvas (baked WYSIWYG into the post). Driven by UIKit
    // recognizers (PinchPanGestureView) using the standard accumulate-and-reset pattern — see below.
    @State private var photoZoom: CGFloat = 1
    @State private var photoOffset: CGSize = .zero
    // Real device safe-area top from the window (the editor's GeometryReader under-reports it because the
    // status bar is hidden). Used to place the close button 12pt below the Dynamic Island / notch.
    private var windowSafeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 47
    }
    @State private var posting = false
    @State private var postError = false
    /// The X asked about, when there is something behind it worth asking about. See `closeEditor()`.
    @State private var showDiscard = false
    /// The black band under the card where the tool capsule and NEXT live. A CONSTANT, not a
    /// measured height: the card's frame used to be inset by the bottom bar's measured size, and
    /// anything that changed the bar (focusing the caption, opening Aa — both raise the keyboard)
    /// re-measured the canvas and visibly shrank the photo. His rule: the preview NEVER resizes.
    /// Geometry that cannot move is geometry derived from nothing that moves.
    static let toolZoneHeight: CGFloat = 58

    /// THE CARD, BY THE VIEWER'S OWN RULE. `StoryDetailView.cardHeight` is `min(9:16, the room
    /// there is)`, and this must be the same shape or the composer is framing a picture for a
    /// rectangle that does not exist.
    ///
    /// It was `available` on its own, which on his phone is 430 x 782 — aspect 1.8196 against the
    /// story card's 1.7778, so a picture pinched to exactly fill the composer arrived at the story
    /// 2.4% too tall. Proved from his own post: the uploaded file is 2638x4800, aspect 1.8196, the
    /// composer's shape to three decimals, and 1.8196 in a 1.778 card leaves the 1.15%-a-side band
    /// he drew lines down.
    ///
    /// `ceil` and 1.77778 are copied from the viewer deliberately. Two rectangles that have to agree
    /// to the pixel must be the same arithmetic, not arithmetic that happens to match.
    /// ⛔ THE CROP TOOL IS OFF, AND THE CODE BEHIND IT IS DELIBERATELY UNTOUCHED (owner, 2026-08-20:
    /// "disable the Crop Image feature inside Stories for now… we will use this feature again
    /// later"). This hides the ONE door: the button in the photo tool row. Everything it opened is
    /// still here and still compiles — `showCrop`, the `ChatCropView` sheet, `applyCropToDrawing`,
    /// `croppedSource`, `cropRect` and the refinement path — so turning it back on is this one
    /// constant and nothing else.
    ///
    /// Not `#if`, not a deletion, and not a disabled-looking button: a tool that is present and
    /// greyed asks to be tapped and answers nothing.
    static let cropEnabled = false

    /// ⛔ THE PEN'S OWN CANVAS, WHICH IS NOT ALWAYS THE CARD.
    ///
    /// The pen layer wears the photo's transform, so a stroke stays on the part of the picture it was
    /// drawn on when you pinch. That is right, and zooming OUT exposed the other half of it: at a
    /// zoom below 1 the canvas shrinks with the photo, so it stops covering the card and the blurred
    /// surround has no canvas under it at all. The owner's report — the pen simply does not draw
    /// there.
    ///
    /// Dividing by the zoom gives the canvas back exactly the size it needs to STILL cover the card
    /// once the transform has shrunk it. Above 1 there is nothing to fix: a zoomed-in canvas already
    /// more than covers the card, and enlarging it further would only waste raster.
    ///
    /// ⚠️ EVERY PLACE THE DRAWING IS RENDERED HAS TO ASK THIS, not `card` — the live canvas, the
    /// still that replaces it after Done, `flatten`, and the video burn-in. They share one
    /// coordinate space or the strokes land somewhere other than where they were drawn.
    static func penCanvasSize(card: CGSize, zoom: CGFloat) -> CGSize {
        let z = min(1, max(0.01, zoom))
        return CGSize(width: card.width / z, height: card.height / z)
    }

    static func cardSize(in space: CGSize, top: CGFloat) -> CGSize {
        let available = max(1, space.height - top - toolZoneHeight)
        return CGSize(width: space.width, height: min(ceil(space.width * 1.77778), available))
    }
    /// How far the card's bottom edge sits above the bottom of this screen. `toolZoneHeight` when the
    /// 9:16 card fits in the room available, more when it does not — and the caption pill hangs off
    /// THIS rather than off the constant, or it drops through the floor of a shortened card.
    @State private var cardBottomGap: CGFloat = StoryEditorView.toolZoneHeight
    @State private var pendingShare: StoryShareData?
    @State private var pendingExtras: [StoryExtra] = []
    @FocusState private var captionFocused: Bool
    /// ⚠️ FOR THE KEYBOARD'S CLOCK, NOT FOR ITS HEIGHT. Nothing on this screen computes a keyboard
    /// height and that rule stands — the bottom bar is a sibling of the canvas and SwiftUI's own
    /// avoidance lifts it, which is the system moving it on the system's curve.
    ///
    /// What was missing is that the caption's OWN change — the pill dropping from the card's bottom
    /// edge to just above the keys, about 70pt — was being animated at `.easeOut(0.25)` beside it.
    /// Two motions of one bar on two curves is his "not smooth". The watcher now carries the
    /// notification's duration and curve so the second motion can be run on the first one's clock.
    @StateObject private var keyboard = KeyboardWatcher()
    // Adaptive control contrast: dark icons over a light photo region, light over dark (so buttons are
    // never invisible on a white background). Sampled per-region (top = X, bottom = tools).
    @State private var topIconDark = false
    @State private var bottomIconDark = false
    /// THE EDITOR'S CONTROLS ARRIVE, THE PICTURE IS ALREADY THERE.
    ///
    /// The other half of the camera handover (see `AddStorySheet`, and `handingOver` in
    /// StoryCameraView). The cover no longer slides, so without this the whole screen — photo and
    /// every button at once — would simply appear in one frame, which is a cut rather than a
    /// transition. The picture appearing instantly is right: it is the same picture the camera was
    /// already showing, in the same place, so there is nothing for it to animate FROM. Only the
    /// controls are new, so only the controls fade.
    ///
    /// It fades in on EVERY entry, not only from the camera. The library path still arrives on a
    /// sliding cover, where a quarter-second fade on the controls is at worst unnoticed — and one
    /// behaviour that is always true beats a flag threaded through four call sites to make two
    /// screens differ by 0.28s.
    @State private var chromeIn = false

    // Text-on-photo overlays
    @State private var overlays: [TextOverlay] = []
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    /// ⚠️ THE Aa EDITOR'S KEYBOARD IS NOT THE CAPTION BAR'S, AND THE CAPTION BAR WAS RIDING IT.
    ///
    /// His report: "Aa feature is working good but only one bug — when i close keyboard caption bar is
    /// doing movement". The caption bar is not part of the Aa editor and is not even visible while it
    /// is up (`captionLayer`'s opacity is 0 for `editingID != nil`) — but it is a sibling that respects
    /// the keyboard on purpose, so SwiftUI's avoidance lifted it a few hundred points along with
    /// everything else the Aa keyboard pushed. Done then made it visible again while it was still up
    /// there, and it rode the keyboard back down in front of him. Nothing was mispositioned at either
    /// end; it was travelling a distance it had no business travelling at all.
    ///
    /// So the caption layer ignores the keyboard for as long as the Aa editor owns one. It cannot be
    /// keyed on `editingID` directly: that clears when Done is pressed, which is the START of the
    /// keyboard's dismissal, so the bar would snap down (or up) mid-flight — the same bug wearing a
    /// different sign. This is raised when the editor opens and lowered on `keyboardDidHide`, by which
    /// time the inset is already zero and the flip costs no movement at all.
    ///
    /// ⚠️ THE CAPTION'S OWN FOCUS IS UNTOUCHED BY THIS. When the caption field is the first responder
    /// there is no Aa editor, so this is false and the bar rides its own keyboard exactly as it did —
    /// including the animated padding below it, which is a separate fix and still needed.
    @State private var textToolKeyboardUp = false
    /// ⚠️ THE BOTTOM OF THE SCREEN MUST NEVER BE BARE, AND IT WAS, FOR AS LONG AS THE KEYBOARD TAKES.
    ///
    /// His 2026-08-18 report: "when i click text before keyboard opening bottom button is going to
    /// disappear". Tapping a text block set `editingID`, and both bottom layers read that directly, so
    /// the tools capsule and NEXT blinked out in the SAME FRAME as the tap while the keyboard — and
    /// the Aa bar it carries as its accessory — was still a quarter of a second from arriving. For
    /// that quarter second the picture had no controls at all, which is the hole he is pointing at.
    ///
    /// So the bars are not hidden by the tap any more. They are hidden once the keyboard is UP, at
    /// which point the keyboard is already standing over them and the flip cannot be seen: the same
    /// far-side trick `textToolKeyboardUp` uses on the way out, for the same reason. Between the tap
    /// and that moment they simply sit under the editor's own dim and are covered by the rising keys,
    /// which is what every iOS screen does with the controls a keyboard lands on.
    ///
    /// ⚠️ NOT A TIMER. `keyboardDidShow` fires for a hardware keyboard's accessory bar too, so a
    /// phone with no on-screen keys still lowers them rather than leaving them lit under the dim.
    @State private var textToolBarsDown = false
    @State private var draggingID: UUID?
    @State private var trashHot = false
    @State private var guideV = false
    @State private var guideH = false

    // Stickers. Their own list rather than a case inside `overlays`, because the two are edited by
    // different tools and only ever meet at the bake — see `StickerOverlay`.
    @State private var stickers: [StickerOverlay] = []
    @State private var showStickers = false

    private static let ciContext = CIContext()
    private static let filters: [(name: String, ci: String?)] = [
        ("Original", nil), ("Vivid", "CIPhotoEffectChrome"), ("Mono", "CIPhotoEffectMono"),
        ("Fade", "CIPhotoEffectFade"), ("Noir", "CIPhotoEffectNoir"),
    ]
    // MARK: - More than one item

    /// One thing queued for this post. A video carries its file; its `image` is the poster, which is
    /// what the thumbnail strip and the canvas show — a video's own bytes decode to nothing as an
    /// image, and every strip in this app already learned that the hard way.
    struct DraftItem: Identifiable {
        let id = UUID()
        /// The ORIGINAL, never overwritten. Every edit is re-applied to this, which is what makes
        /// them undoable — baking them in was the old model and it made a crop permanent the moment
        /// you looked at another item.
        var image: UIImage
        var videoURL: URL? = nil
        var duration: Double = 0
        /// THE LIBRARY ASSET THIS CAME FROM, which is how the picker and this post stay in step.
        ///
        /// The five-item ceiling belongs to the post, so the + has to reopen the picker with what is
        /// already here ticked (his 2026-08-11 spec). A `UIImage` cannot be recognised again once it
        /// has been decoded and edited; the asset's local identifier can. Nil for anything with no
        /// asset behind it — a camera capture, or a clip handed over from the video editor — which
        /// still counts towards the five but cannot be shown as a tick.
        var assetID: String? = nil
        var isVideo: Bool { videoURL != nil }

        // The edits, held BESIDE the picture rather than burnt into it, so switching away and back
        // returns you to exactly what you had, still adjustable (owner 2026-08-04).
        var cropped: UIImage? = nil       // the interactive crop's result, re-derivable from `image`
        /// THE SAME CROP, AS A RECTANGLE (normalised 0-1). A photo can carry its crop as a cropped
        /// picture; a video has no picture to crop, so it needs the rectangle and applies it during
        /// the export. Both are kept because both are needed: the poster in the strip is the image,
        /// the frames that get uploaded are the rectangle.
        var cropRect: CGRect? = nil
        var filterIndex = 0
        var drawing = PKDrawing()
        var overlays: [TextOverlay] = []
        /// Held on the ITEM like everything else the tools own, so switching to another picture and
        /// back finds the stickers where they were left. Same stash-move-restore as the rest.
        var stickers: [StickerOverlay] = []
        /// ⚠️ THE CAPTION IS THE ITEM'S, NOT THE SCREEN'S — his 2026-08-17 report: "I can't give each
        /// one their own caption… only one story I can give a caption, and if I select another one it
        /// still shows the old caption."
        ///
        /// It was one `@State` on the editor, so every picture in a post shared the field: typing on
        /// item one wrote item two's caption as well, switching thumbnails did not change what the
        /// pill said, and at post time only the FIRST item's story carried it — the rest went up with
        /// `caption: ""` on the reasoning that "it belongs to the post". It does not; each picture is
        /// its own story in the viewer, and this is the one thing the tools own that was not stashed
        /// beside the item like the crop, the drawing, the stickers and the zoom already are.
        var caption: String = ""
        /// ⚠️ ZERO MEANS "NOBODY HAS CHOSEN ONE YET", NOT "no zoom". The default depends on the shape
        /// of the picture AND on the size of the card, which the model cannot know — so the value is
        /// left unset here and resolved the first time this item is put on the tools
        /// (`restoreCurrent` → `defaultZoom`). Any number in here, 1 included, is the OWNER's: it was
        /// either pinched or it was the default he accepted, and neither may be recomputed
        /// underneath him. That is his rule in as many words: "if user use manual zoom out or crop
        /// or other things dont change after upload".
        var zoom: CGFloat = 0
        var offset: CGSize = .zero

        // VIDEO-ONLY, and they are the whole of the owner's report that a video thumbnail brought up
        // the photo tools. A clip has two things a picture does not: a soundtrack you may not want,
        // and a length you may want less of. `StoryVideoPayload` has carried both since the video
        // editor was built; this screen simply never offered them or filled them in.
        //
        // `trimEnd == 0` means "not trimmed" rather than "zero length", so an untouched clip needs no
        // knowledge of its own duration to be correct.
        var muted = false
        /// ⛔ THE TRIM PAGE'S SECOND TAB, -1…1 with 0 untouched (owner, 2026-08-20). Per ITEM, like
        /// the mute and the trim beside it: a post can hold five clips and they were not all shot in
        /// the same light.
        var brightness: Double = 0
        var trimStart: Double = 0
        var trimEnd: Double = 0
        var isTrimmed: Bool { trimStart > 0.05 || (trimEnd > 0 && trimEnd < duration - 0.05) }
        /// The range to keep, in seconds, or nil for the whole clip — the shape the payload wants.
        var trimRange: ClosedRange<Double>? {
            guard isTrimmed else { return nil }
            let end = trimEnd > 0 ? trimEnd : duration
            guard end > trimStart else { return nil }
            return trimStart...end
        }
    }

    /// Everything in this post, in order, with `index` pointing at the one on the canvas.
    ///
    /// SWITCHING BAKES. The item you are leaving keeps its crop, filter, drawing and text by having
    /// them flattened into its image, and the tools reset for the one you arrive at. Per-item live
    /// edit state would mean five parallel copies of every tool's state on a screen that is already
    /// device-verified, and the risk of that is not worth being able to un-crop something you left.
    @State private var items: [DraftItem] = []
    @State private var index = 0
    @State private var showAddPicker = false

    /// Everything a pick from OUR library grid needs to become an item. The same work the old
    /// PhotosPicker handler did, minus the transferable dance — the grid resolves the asset itself
    /// and hands over a UIImage or a file URL.
    /// ⚠️ `restoreCurrent()`, NOT `recomputeEdited()`. This is what made a picked photo look like
    /// nothing had happened.
    ///
    /// The tools are held OUTSIDE the item — croppedSource, cropRect, filterIndex, drawing,
    /// overlays, photoZoom, photoOffset — and `select(_:)` has always been stash, move, restore.
    /// These two append paths did stash, move, and then `recomputeEdited`, which is the last line of
    /// restore without the restore. So the new picture arrived wearing the PREVIOUS one's tools, and
    /// `recomputeEdited` reads `croppedSource ?? current` — meaning if the item before it had been
    /// cropped, the editor recomputed from that old cropped bitmap and drew the OLD PHOTO on the new
    /// item. He picked a second image and the screen did not change.
    @MainActor private func appendPicked(image ui: UIImage, assetID: String? = nil) {
        stashCurrent()
        items.append(DraftItem(image: ui, assetID: assetID))
        index = max(0, items.count - 1)
        restoreCurrent()   // a fresh item has clean tools; this ends in recomputeEdited()
    }

    /// ⚠️ THE ITEM ARRIVES FIRST AND ITS THUMBNAIL CATCHES UP — half of his 2026-08-12 report.
    ///
    /// A picked IMAGE is already decoded, so it lands the instant it is chosen. A picked VIDEO used
    /// to wait here for a 1200px `AVAssetImageGenerator` decode before it joined `items` at all, and
    /// a hand-off from the video editor runs this in a loop over the whole batch. So the composer
    /// appeared holding only the pictures, and the clips filled in one by one over several seconds —
    /// which is what he described as a second editor opening on top with the media in it.
    ///
    /// Duration still resolves before the append, because `DraftItem` carries it and the export and
    /// the trim both read it. Only the bitmap is deferred, and it is only ever the strip's thumbnail.
    private func appendPicked(video url: URL, assetID: String? = nil) async {
        let dur = await Self.duration(of: url)
        await MainActor.run {
            stashCurrent()
            items.append(DraftItem(image: Self.blackPoster, videoURL: url, duration: dur, assetID: assetID))
            index = max(0, items.count - 1)
            restoreCurrent()   // same fix as the image path above — see its note
        }
        await decodePoster(url, duration: dur)
    }

    /// How long a clip is. Split out because the batch path loads every clip's duration at once and
    /// then appends them together — see `applyPickerChange`.
    private static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    /// The strip's thumbnail for a clip, decoded and patched in.
    ///
    /// ⚠️ SEPARATE FROM THE APPEND ON PURPOSE, AND THE BATCH PATH DEPENDS ON IT BEING SEPARATE. This
    /// is a 1200px `AVAssetImageGenerator` decode and it is the slow part of adding a clip by a wide
    /// margin. While it sat inside `appendPicked(video:)`, a caller adding several items in a loop
    /// awaited each decode before the NEXT item could join — see the note there.
    private func decodePoster(_ url: URL, duration dur: Double) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1200, height: 1200)
        let t = CMTime(seconds: min(0.1, max(0.01, dur / 2)), preferredTimescale: 600)
        // A poster that cannot be decoded must NOT drop the video on the floor — a `guard return`
        // here made a picked clip silently never appear ("i chose video, is not working"). The item
        // keeps its black poster instead; the clip itself is fine and the export never reads this
        // bitmap.
        guard let cg = try? await gen.image(at: t).image else { return }
        let poster = UIImage(cgImage: cg)
        await MainActor.run {
            // BY FILE, NOT BY INDEX — the strip can be reordered or thinned while this is in flight.
            guard let i = items.firstIndex(where: { $0.videoURL == url }) else { return }
            items[i].image = poster
            // The canvas draws from the edited copy of the CURRENT item, so a poster landing on the
            // one being looked at has to re-run that or the black placeholder stays on screen until
            // the next edit touches it.
            if i == index { recomputeEdited() }
        }
    }

    /// FILL IN THE CLIP THE COMPOSER OPENED ON — see `sourceVideo`.
    ///
    /// Deliberately not `appendPicked(video:)`: that one appends, and this item is already there. It
    /// has to be, because the whole screen reads `items[index]` and a composer with an empty `items`
    /// for the length of an `AVAsset` load is the blank first frame this fix exists to avoid. So the
    /// item is seeded with a black poster and a zero duration, and both are patched here.
    ///
    /// BY FILE, NOT BY INDEX, like every other patch on this screen: the strip can be reordered or
    /// thinned while these two loads are in flight, and a position would paint one clip's frame onto
    /// another.
    private func resolveSourceVideo(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        await MainActor.run {
            guard let i = items.firstIndex(where: { $0.videoURL == url }) else { return }
            items[i].duration = dur
            // ⚠️ NOT `trimEnd = dur`. Zero means "untrimmed" on a DraftItem (see its note), and
            // writing the full length in would make every clip look trimmed to `isTrimmed`, which
            // decides whether the export re-encodes and whether closing asks about discarding work.
            //
            // ⚠️ IT DOES NOT PLAY ITSELF ANY MORE — his 2026-08-14 instruction: "first time i chose
            // video, video is playing, please make pause default. If user want to play just click
            // play, if again click pause."
            //
            // This used to build the player and start it for the item the post opened on, because
            // that is what the old video-only editor did. But this is an EDITING screen: you arrive
            // to crop, write on it and trim it, and a clip that starts talking the moment it opens
            // is one you have to silence before you can work. Every other clip in the post already
            // waited to be asked; now they all do.
            //
            // The player is still not built here either. `ensurePreviewPlayer` is the one place
            // that does it, on first need, so nothing decodes for a clip nobody has asked to watch.
            _ = i
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1200, height: 1200)
        let t = CMTime(seconds: min(0.1, max(0.01, dur / 2)), preferredTimescale: 600)
        // A poster that will not decode keeps the black placeholder, same as the append path: the
        // clip itself is fine and the export never reads this bitmap.
        guard let cg = try? await gen.image(at: t).image else { return }
        let poster = UIImage(cgImage: cg)
        await MainActor.run {
            guard let i = items.firstIndex(where: { $0.videoURL == url }) else { return }
            items[i].image = poster
            if i == index { recomputeEdited() }
        }
    }

    /// The placeholder every picked clip wears until its own frame is decoded, and the fallback for
    /// one that will not decode at all. Built once: it is the same black rectangle every time.
    private static let blackPoster: UIImage = {
        let side = CGSize(width: 1080, height: 1920)
        return UIGraphicsImageRenderer(size: side).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: side))
        }
    }()

    /// THE PICKER'S SELECTION IS THIS POST'S SELECTION — his 2026-08-11 spec, applied as one move.
    ///
    /// What came off the ticks leaves; what went on arrives. Removals run FIRST so the ceiling is
    /// honoured in the order he did the work in: taking one off to make room for another has to free
    /// the slot before the new item claims it.
    ///
    /// ⚠️ A POST CANNOT BE EMPTIED. `remove(_:)` has always refused the last item, and the same rule
    /// applies here: if the ticks were all cleared and nothing is arriving, the post keeps what it
    /// has. The picker cannot reach that state through Add — the bar hides with no ticks — so this
    /// is the belt, not the mechanism.
    /// ⚠️ THE WHOLE BATCH LANDS AT ONCE. IT USED TO ARRIVE ONE ITEM AT A TIME OVER SEVERAL SECONDS,
    /// AND THAT IS HIS "TWO STORY VIDEO EDITORS STACKED ON TOP OF EACH OTHER".
    ///
    /// Nothing was ever presented twice. This was a loop that `await`ed `appendPicked(video:)` per
    /// pick, and that function did not return until it had decoded a 1200px poster — so the next
    /// pick could not join until the previous clip's decode finished. Every arrival also ran
    /// `stashCurrent` → `index = last` → `restoreCurrent`, which moves the editor onto the item that
    /// has just landed. So the screen changed under him two or three times, seconds apart, each time
    /// showing a different set of media. That reads exactly like a second editor opening over the
    /// first, and his own description of the two states is the proof of the mechanism: the videos
    /// arrived first (they were ticked first and each one blocked the queue) and the images, ticked
    /// after them, could not appear until every clip ahead of them had been decoded.
    ///
    /// The image-only flow never showed it, which is why it "works": `store.fullImage` has already
    /// decoded those in the picker, so every image pick lands in the same run-loop turn and the
    /// batch looks instantaneous. This gives the video path the same property rather than a
    /// different one.
    ///
    /// Three steps, and the order of them is the fix:
    ///
    /// 1. **Durations first, all at once.** `DraftItem` carries the duration and both the export and
    ///    the trim read it, so it must be right at append time — it cannot be patched in later the
    ///    way a thumbnail can. These are concurrent because they are independent, and a duration load
    ///    off a local file is quick; the batch waits for the slowest one, not for the sum.
    /// 2. **One append, one transaction.** `stashCurrent` once, every item in tap order, `index` to
    ///    the last of them, `restoreCurrent` once. The editor moves exactly once, to the last thing
    ///    he ticked, and everything he ticked is already there when it does.
    /// 3. **Posters afterwards, concurrently.** The slow decode no longer gates anything, and each
    ///    one patches its own clip BY FILE, so they may finish in any order.
    private func applyPickerChange(removed: [String], added: [StoryPick]) async {
        await MainActor.run { dropItems(withAssetIDs: removed, expectingMore: !added.isEmpty) }
        guard !added.isEmpty else { return }

        // STEP 1 — every clip's length, concurrently, keyed by its own file.
        var durations: [URL: Double] = [:]
        let urls = added.compactMap { pick -> URL? in
            if case .video(let u) = pick.kind { return u }
            return nil
        }
        if !urls.isEmpty {
            await withTaskGroup(of: (URL, Double).self) { group in
                for u in urls {
                    group.addTask {
                        let d = await Self.duration(of: u)
                        return (u, d)
                    }
                }
                for await (u, d) in group { durations[u] = d }
            }
        }

        // STEP 2 — the whole batch, in tap order, in one transaction.
        await MainActor.run {
            stashCurrent()
            for pick in added {
                switch pick.kind {
                case .image(let ui):
                    items.append(DraftItem(image: ui, assetID: pick.assetID))
                case .video(let url):
                    items.append(DraftItem(image: Self.blackPoster, videoURL: url,
                                           duration: durations[url] ?? 0, assetID: pick.assetID))
                }
            }
            index = max(0, items.count - 1)
            // A fresh item has clean tools, and this ends in `recomputeEdited()`. Same reason as the
            // single-pick paths above: stash, move, RESTORE — never stash, move, recompute.
            restoreCurrent()
        }

        // STEP 3 — thumbnails fill in behind the finished batch.
        //
        // Plainly sequential, and that is not a compromise: every item is already on screen by the
        // time this starts, so what is left is a black strip thumbnail becoming a picture. Nothing
        // waits on it and nothing moves when it lands. (A task group here would have to capture
        // `self` — a SwiftUI `View` struct — which is the kind of thing that costs a 40-minute CI
        // round trip to discover. `Self.duration` in step 1 is static, so that group captures
        // nothing.)
        for u in urls { await decodePoster(u, duration: durations[u] ?? 0) }
    }

    @MainActor private func dropItems(withAssetIDs removed: [String], expectingMore: Bool) {
        let ids = Set(removed)
        guard !ids.isEmpty else { return }
        stopPreview()
        // The item on screen keeps its edits whether or not it survives: stash BEFORE the array
        // moves, then follow it by identity rather than by index.
        stashCurrent()
        let onScreen = items.indices.contains(index) ? items[index].id : nil
        let kept = items.filter { !($0.assetID.map(ids.contains) ?? false) }
        guard !kept.isEmpty || expectingMore else { return }
        items = kept
        if let onScreen, let i = items.firstIndex(where: { $0.id == onScreen }) { index = i }
        else { index = max(0, min(index, items.count - 1)) }
        restoreCurrent()   // ends in recomputeEdited(); a no-op while items is empty
    }

    private var current: UIImage { items.indices.contains(index) ? items[index].image : source }
    private var currentIsVideo: Bool { items.indices.contains(index) && items[index].isVideo }

    /// What the post holds, for the picker's ceiling — see `StoryLibraryPicker.preselected`.
    /// `items` is empty until `onAppear` builds it, and `source` is a real item that whole time, so
    /// the empty case answers for it rather than reporting an empty post.
    private var postAssetIDs: [String] {
        items.isEmpty ? [sourceAssetID].compactMap { $0 } : items.compactMap(\.assetID)
    }
    private var postReservedCount: Int {
        items.isEmpty ? (sourceAssetID == nil ? 1 : 0) : items.filter { $0.assetID == nil }.count
    }

    private var edited: UIImage { editedCache ?? current }
    private func recomputeEdited() {
        // Filter applies on top of the (interactively) cropped source.
        editedCache = Self.apply(Self.filters[filterIndex].ci, to: croppedSource ?? current)
        updateIconContrast()   // re-sample brightness so the controls stay readable on this photo
        // ...and re-read the canvas, because a filter changes the colours the canvas is made of.
        // It is sampled HERE rather than derived in `cardContent` because that runs on every layout
        // pass and this reads pixels. Same reason, same shape, as the video editor's `canvasBackdrop`.
        canvasCache = StoryCanvas.colours(of: edited)
    }
    /// The canvas colours for the picture as it stands, through the one sampler the post and the
    /// story viewer also read. Falls back to the untouched source for the instant before
    /// `recomputeEdited` first runs, so the card never draws a frame of the wrong backdrop.
    private var canvasColours: (top: UIColor, bottom: UIColor) {
        canvasCache ?? StoryCanvas.colours(of: current)
    }

    // The photo's aspect-fit size inside the frame ("always-cover" clamp basis).
    private func fittedSize(in frame: CGSize) -> CGSize {
        let s = edited.size
        guard s.width > 0, s.height > 0 else { return frame }
        let scale = min(frame.width / s.width, frame.height / s.height)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
    // Clamp the pan so the photo edge can reach the frame edge but never past it (no gaps / floating).
    // offset ∈ ±(scaledSize − frameSize)/2  — the standard image-transform normalize math.
    private func clampedOffset(_ off: CGSize, zoom: CGFloat, in frame: CGSize) -> CGSize {
        let fit = fittedSize(in: frame)
        let maxX = max(0, (fit.width * zoom - frame.width) / 2)
        let maxY = max(0, (fit.height * zoom - frame.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, off.width)),
                      height: min(maxY, max(-maxY, off.height)))
    }

    var body: some View {
        // TWO LAYERS, AND THE SPLIT IS THE POINT. The canvas ignores the keyboard so it can never be
        // squished or re-measured (the pen bakes strokes against `geo`, so a canvas that moves puts
        // the line somewhere other than the finger). The bottom bar is a SIBLING of it, outside that
        // ignore, so SwiftUI's own keyboard avoidance lifts it — on the system's exact curve, on the
        // system's exact frame, because it is the system doing it.
        //
        // It used to be one layer with `.ignoresSafeArea(.keyboard)` over everything and a hand-
        // computed `.padding(.bottom, ...)` from a KeyboardWatcher. That is the jump the owner
        // reported, and it was TWO jumps: focusing the field tore the thumbnail strip and the tool
        // row out of the stack, which dropped the bar DOWN, and then the keyboard notification
        // arrived and shoved it UP. Two state changes, two moments, neither animated with the
        // keyboard. Nothing here computes a keyboard height any more.
        ZStack {
            Color.black.ignoresSafeArea()
            canvasLayer
                // THE CARD'S FRAME IS FIXED (owner: "the Story preview must never shrink, resize,
                // or change its scale"). It was inset by the bottom bar's MEASURED height, and the
                // keyboard reached the canvas through that wrapper — focusing the caption or
                // opening Aa visibly shrank the photo. The card is `Self.cardSize` now — screen
                // geometry and a constant, nothing measured and nothing that moves — and the canvas
                // ignores the keyboard outright. Fixed still means fixed; it just is not the same
                // number it was, because it is the STORY's rectangle now (see cardSize).
                //
                // TRIM ZOOMS THE MEDIA OUT, exactly as the single-video editor does — same 0.9,
                // same top anchor, same 10pt nudge, same 0.3 curve.
                //
                // ⚠️ AND CROP DOES *NOT*, ANY MORE — TWO COPIES OF ONE PHOTOGRAPH AT TWO SIZES IS HIS
                // "when i click crop my image are overlapping other image i can see".
                //
                // The crop screen fades its own black ground in over the same 0.3s (see the note in
                // `ChatCropView.body`, which says in as many words that the frames before it are meant
                // to show "the editor's own card — the same picture in the same place"). That was true
                // when the crop screen replaced the picture in one step. It stopped being true the
                // moment the crop screen's picture started TRAVELLING from the card: the canvas was
                // stepping back to 0.9 and down 10pt at the same time, so for the whole flight there
                // were two renderings of the same photo behind a half-transparent black, at different
                // sizes, sliding across each other. That is the overlap he circled, and the top-left
                // chrome showing through it is the same window.
                //
                // The step-back was written when the crop entry did not move, as the thing that made
                // it feel like a zoom. `06236258` gave the picture itself the whole journey — the
                // reference app's `animateTransitionIn` moving one picture's frame from the rect it
                // was handed — and their review screen underneath never moves a pixel while it
                // happens. So this now holds still for a crop, which makes that note's claim true
                // instead of nearly true, and there is one photograph on screen at every moment.
                //
                // ⚠️ TRIM KEEPS IT, and the difference is not an inconsistency. The trim page has no
                // travelling copy of the picture: its filmstrip arrives over a canvas that has to get
                // out of the way, which is the motion he signed off ("user never feel new page… just
                // zoom out then trim appearing").
                .scaleEffect(showTrim ? 0.9 : 1, anchor: .top)
                .offset(y: showTrim ? 10 : 0)
                .animation(.easeInOut(duration: 0.3), value: showTrim)
                .animation(.easeInOut(duration: 0.3), value: showCrop)
                // ⚠️ ONE PHOTOGRAPH ON SCREEN FOR THE WHOLE CROP FLIGHT, AND THIS IS THE HALF OF
                // THEIR MECHANISM THAT WAS MISSING.
                //
                // His screenshot: the editor's card at full size behind, the crop screen's picture
                // smaller and sharper on top of it, both visible at once through a black that is
                // still fading in. Holding the canvas still (`720df49a`) stopped the two SLIDING
                // across each other; it did not stop there being two.
                //
                // Theirs never has two. `TGPhotoEditorTabController` gives the flight the REAL view
                // when it can — `if (_transitionView == nil) { _transitionView = referenceView; }` —
                // and `TGPhotoCropView.animateTransitionIn` sets `_scrollView.hidden = true` for the
                // whole flight so the crop screen's own copy is not drawn until
                // `transitionInFinishedAnimated:` reveals it. One picture travels; nothing else of
                // that picture exists anywhere on screen.
                //
                // SwiftUI cannot reparent this card into the crop screen, so the equivalent is to
                // stand it down for exactly as long as the crop screen is drawing it: the crop
                // picture starts at this card's rect wearing this card's corner, so the hand-over is
                // invisible and what travels is the only copy there is.
                //
                // ⚠️ INSTANT, AND OUTSIDE BOTH ANIMATIONS ABOVE ON PURPOSE. Faded, this would be a
                // cross-dissolve between two renderings of one photograph — which is the thing being
                // removed, spelled differently.
                // ⛔ AND IT STANDS DOWN WHEN THE FLIGHT LEAVES, NOT WHEN THE DOOR OPENS. FOURTH
                // REPORT ON THIS TRANSITION; the note above is right about WHY this hide exists and
                // was wrong about WHEN.
                //
                // The crop screen cannot start its flight until the canvas has stopped moving (its
                // `armEntry` re-arms on every geometry report), and this hid the card the instant
                // `showCrop` went true. So for the whole settle the only thing on screen was the crop
                // screen's picture parked at progress 0 — the card's rect, at the card's size, chrome
                // still down. Correct geometry, held still. That is his "it will be full screen, after
                // that start zoom out".
                //
                // `cropFlying` is the crop screen telling us its picture is away, in the same turn as
                // its first moving frame. Until then this card is what he is looking at, exactly as
                // theirs keeps its review screen until `animateTransitionIn` runs.
                .opacity(showCrop && cropFlying ? 0 : 1)
                // ⛔ BOTH FLAGS, AND DROPPING ONE OF THEM IS WHAT PUT A BLACK SCREEN AFTER DONE.
                //
                // This line used to read `.animation(nil, value: showCrop)` and the note above says
                // exactly why: instant, outside both animations, because a fade here is a
                // cross-dissolve between two renderings of one photograph. Adding `cropFlying` to the
                // opacity and moving the nil-animation onto it ALONE left `showCrop` governed by the
                // `.animation(.easeInOut(0.3), value: showCrop)` further up — so closing crop faded
                // this card in from zero over 0.3s while the crop screen was already gone.
                //
                // That is his "after zoom in finished screen is going black in secends after that is
                // jumping frame up": three tenths of a second of nothing, then the card arriving.
                //
                // ⚠️ A `value:` OVERLOAD ONLY SPEAKS FOR THE VALUE IT NAMES. Two flags drive this
                // opacity now, so it takes two lines; there is no version of this with one.
                .animation(nil, value: showCrop)
                .animation(nil, value: cropFlying)
            // Bottom chrome. While DRAWING, our pen bar takes the bottom instead; it stays pinned
            // because a drawing screen has no keyboard and the canvas must not move under a stroke.
            if isDrawing {
                // The pen's own top bar, on the same terms as its bottom one: opacity rather than an
                // `if`, so nothing about the canvas's layout changes mid-stroke.
                //
                // ⛔ AND AT THE EDITOR'S OWN TOP-ROW HEIGHT, not at the top of the screen (his
                // 2026-08-21: "check story editor page X button position then like that position
                // use"). It was `.padding(.top, 8)` on a VStack in a ZStack that ignores the safe
                // area, so undo and Clear All sat up level with the status bar and read as a system
                // header rather than as this screen's controls. `max(windowSafeTop - 22, 10)` is
                // copied from the editor's own top controls, character for character, so the two
                // rows cannot drift apart — press ✕ and press undo and your thumb is in one place.
                VStack { penTopBar; Spacer() }
                    .padding(.top, max(windowSafeTop - 22, 10))
                    .opacity(strokeInFlight ? 0 : 1)
                VStack { Spacer(); penBar.padding(.bottom, 8) }
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    // OPACITY, not an `if`: removing the bar from the tree mid-stroke would relayout
                    // the screen the canvas is measured against, and the canvas has to stay exactly
                    // where it is or the line lands somewhere other than the finger.
                    .opacity(strokeInFlight ? 0 : 1)
            } else if !showTrim, !showCrop {
                // TWO SEPARATE LAYERS, because they answer to different masters. The tool row is
                // pinned to the screen bottom and never moves for the keyboard; the caption pill
                // sits ON the card (the reference layout) and rides the keyboard when focused.
                // GONE DURING A TRIM, not merely faded — the filmstrip lands where they were.
                //
                // ⚠️ AND GONE DURING A CROP FOR THE SAME REASON, WHICH IS HIS "the bottom buttons
                // change to crop buttons". The crop screen's black now fades in over 0.3s rather
                // than 0.15, so leaving these underneath it meant the editor's tools and the crop
                // bar were both half-visible for a fifth of a second — two sets of buttons at once,
                // which is the thing this screen already refuses to do while a stroke is in flight.
                // The other app does not fade its old toolbar out either: the tab swaps and the new
                // buttons fade in on their own.
                toolRowLayer.opacity(chromeIn ? 1 : 0)
                captionLayer.opacity(chromeIn ? 1 : 0)
            }
            // Aa's editor is a SIBLING of the canvas, not an overlay inside it: it needs the
            // keyboard avoidance the canvas must never have. Its own dim backdrop covers the
            // screen; the card underneath does not move a pixel.
            if let id = editingID, let idx = overlays.firstIndex(where: { $0.id == id }) {
                // ⚠️ THE WHOLE EDITOR IS UIKit NOW, AND EVERY REASON IS IN
                // `StoryTextToolEditor.swift`'s header. The short version: the bar is the keyboard's
                // own `inputAccessoryView`, the editing area is bounded by `keyboardLayoutGuide`, and
                // Done is `resignFirstResponder`. None of those three has a SwiftUI equivalent that
                // behaves the same way, which is why the SwiftUI editor kept losing its controls and
                // moving its words.
                StoryTextToolEditor(
                    overlay: overlays[idx],
                    // What `TextOverlayView` offers `storyStyledText` on the canvas. The editor lays
                    // the words out at this width so the line breaks — and therefore the block's whole
                    // shape — are already the canvas's before Done is pressed.
                    wrapWidth: canvasSize.width * 0.9
                ) { edited, screenCenter in
                    guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
                    var o = edited
                    // ⚠️ THE CONTINUITY LINE, AND IT IS WHY THERE IS NO ANIMATION HERE.
                    //
                    // His report: tap Done and the words move down toward the centre, then correct
                    // themselves. A brand-new text is created at the canvas's centre, the editor draws
                    // it above the keyboard, and the canvas then draws it at the centre it was created
                    // with — so the hand-over shows two different places and reads as a jump.
                    //
                    // Theirs does not animate that gap, it removes it: `applyTextEdits` takes the text
                    // view's centre AS IT APPEARS IN THE EDITOR, turns it into a canvas unit and
                    // writes it onto the item. The canvas then draws it exactly where the editor was
                    // drawing it and there is nothing left to travel.
                    //
                    // Only for a text that has never been placed, which is their `isNewItem`: one he
                    // has already dragged somewhere has a position he chose.
                    if newOverlayID == id, let c = canvasCenter(fromScreen: screenCenter) {
                        o.center = c
                    }
                    overlays[i] = o
                    trimEmpty(id)
                    newOverlayID = nil
                    // Theirs fades its editing layer out over 0.2s and un-hides the canvas copy in the
                    // same breath. Same shape here: the canvas draws the words immediately, at the
                    // place the editor left them, while the editor fades off the top of them.
                    withAnimation(.easeInOut(duration: 0.2)) { editingID = nil }
                }
                // NOTHING MOVES THIS SCREEN FOR THE KEYBOARD. The editor is bounded by the keyboard
                // from the inside, by their own layout guide; SwiftUI shrinking the host as well would
                // count the keyboard twice, which is the squeezed-into-a-band screenshot from 08-16.
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(30)
            }
            // Above the bars, and keyboard-proof: neither cropping nor trimming has a keyboard, and
            // both must cover everything under them.
            cropOverlay
                .ignoresSafeArea(.keyboard)
            trimOverlay
                .ignoresSafeArea(.keyboard)
        }
        // THE CONTROLS ARRIVE A BEAT AFTER THE PICTURE — see `chromeIn`. The delay is not decoration:
        // it is the gap the camera's own fade-out leaves, so the two screens read as one handover
        // rather than as a cross-fade where both sets of buttons are half-visible at once.
        .onAppear {
            withAnimation(.easeOut(duration: 0.28).delay(0.04)) { chromeIn = true }
        }
        // ⚠️ RAISED WHEN THE Aa EDITOR OPENS AND LOWERED ONLY WHEN ITS KEYBOARD HAS GONE. Both halves
        // matter; see `textToolKeyboardUp`, which is where the reason is written down.
        .onChange(of: editingID) { _, id in
            if id != nil { textToolKeyboardUp = true }
            // AND THE BARS COME BACK THE MOMENT EDITING ENDS, over the same 0.2s the editor takes to
            // fade off them. Only this direction is driven by `editingID`: going the other way is the
            // keyboard's business, not the tap's. See `textToolBarsDown`.
            if id == nil { withAnimation(.easeInOut(duration: 0.2)) { textToolBarsDown = false } }
        }
        // The far side of the keyboard's arrival, where lowering them is invisible because the keys
        // are already standing on top of them. `editingID` is checked for the same reason the hide
        // notification below checks it: the caption field has a keyboard of its own and this is not
        // about that one.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            // Animated, though on his phone nothing is left to see: the keys pass the tool row about
            // 50ms into their rise and the caption pill about 170ms, both before this fires. The fade
            // is for the screens where they do not — a short one, so anything the keyboard failed to
            // reach leaves quietly instead of popping.
            if editingID != nil { withAnimation(.easeInOut(duration: 0.15)) { textToolBarsDown = true } }
        }
        // `keyboardDidHide`, not `willHide`: this must flip on the far side of the animation, when the
        // safe-area inset is already back to nothing, so the flip itself moves the caption bar by
        // exactly zero points. `editingID` is re-checked because a second Aa session can begin inside
        // the dismissal of the first (tap another text block), and that one still owns the keyboard.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            if editingID == nil { textToolKeyboardUp = false }
        }
        // A CALL THAT ARRIVES WHILE THE CLIP IS RUNNING STOPS IT, and until now nothing said so.
        // The system pauses the player itself and posts this; `previewPlaying` stayed true, so the
        // play mark — which hangs off that flag — stayed hidden over a clip that was not moving, and
        // the next tap read as "pause" and did nothing. Following the interruption puts the mark back,
        // and the tap after it goes through `playPreview`, which by then knows there is a call.
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            previewPlaying = false
        }
        // Closing the composer must not leave a decoder and an audio session running behind it.
        .onDisappear { stopPreview() }
        // ONE PLACE DECIDES WHETHER THE CLIP IS RUNNING, the same rule the video editor follows.
        // `previewPlaying` is not this screen's own flag alone: it is handed to `VideoTrimStrip` as
        // its `playing` binding, and the strip sets it FALSE the moment a handle or the playhead is
        // grabbed. Nothing was listening, so that instruction reached the flag and never reached the
        // player. Following the flag here means every writer of it stops the clip, not just
        // `togglePreview`.
        .onChange(of: previewPlaying) { _, on in
            if on, let p = previewPlayer { playPreview(p) } else { previewPlayer?.pause() }
        }
        // ALWAYS DARK, whatever the phone is set to (owner: "all story buttons always use dark mode
        // no light mode"). A story is white text and glass over somebody's photo; in light mode the
        // materials go pale and the controls wash out, which he photographed on the pen screen.
        //
        // NOT `.preferredColorScheme(.dark)`: KulanApp sets preferredColorScheme OUTSIDE RootView,
        // and an outer one always wins, so a pin inside a screen is dead code — five of them in the
        // auth flow never did anything. See [[kulan-preferredcolorscheme-trap]].
        //
        // `storyAlwaysDark` is BOTH halves: the environment value the materials read, and the UIKit
        // trait everything else reads. The environment on its own left this screen's alerts and any
        // system sheet it raises resolving light on a light-mode phone — the same split he
        // photographed on the picker. See the note on `DarkPresentation`.
        // THE STICKER TRAY. One sheet, and Link and Location are PUSHES INSIDE IT rather than sheets
        // of their own — see the note at the top of `StoryStickerSheet`. 0.8 is his number, and the
        // keyboard grows the tray to full because the two pushed screens type and 80% of a phone
        // with a keyboard over it is not a screen you can type on.
        // ⚠️ OUR OWN TRAY, NOT A SYSTEM SHEET, AND THE ONLY REASON IS THE GAP DOWN EACH SIDE.
        //
        // His 2026-08-17, three times: "no space left and right". On iOS 26 a sheet at a partial
        // detent is presented as a FLOATING PANEL inset from the screen edges, drawn by the
        // presentation controller — so no background, corner radius or content of ours can reach it.
        // `.presentationSizing(.page)` is the documented way to ask for the full-width presentation
        // instead; it shipped, and the gap survived. He then named the fallback himself: "you can
        // Make custom sheet but same ui like now".
        //
        // ⚠️ THE TRAY ITSELF IS UNTOUCHED — same view, same search field, same pills, same grid,
        // same glass tab row, same black, same 80%. `StoryTraySheet` replaces the PRESENTATION and
        // nothing else, and it carries the detent, the drag indicator, the background, the dim, the
        // tap-outside and the drag-to-dismiss across one for one. See its header.
        .storyTray(isPresented: $showStickers, heightFraction: 0.8) {
            StoryStickerSheet(
                onSticker: { g in Task { await addSticker(g) } },
                onLink: { url, name in addLinkSticker(url, name: name) },
                onPlace: { name, coord in addPlaceSticker(name, coord) },
                onTime: { addTimeSticker() },
                // The tray has no system sheet to dismiss itself out of any more, so the close is
                // handed in. Same slide-down whichever way it is asked for.
                onClose: { StoryTrayPresenter.dismiss() })
            // ⚠️ THE BLACK GROUND IS THE PANEL'S NOW, NOT `.presentationBackground` — the modifier
            // only ever spoke to a system sheet and there is none here. It is still BLACK, and that
            // reverses his 2026-08-16 "make it real liquid glass" on purpose: on 2026-08-17, having
            // seen the real thing over a photograph, he asked for "sticker sheet make black". The
            // glass was doing its job — the picture read straight through it, and every sticker in
            // the grid (a cut-out with no ground of its own) was competing with the story behind.
            // Both instructions are real, they are about different things, and this one is later.
            // ⚠️ DO NOT "RESTORE" THE GLASS ON THE STRENGTH OF THE OLDER NOTE. See
            // `StoryTrayContainerVC.panel`, which is where the colour lives.
        }
        .storyAlwaysDark()
    }

    private var canvasLayer: some View {
        GeometryReader { geo in
            // THE CARD IS THE STORY FRAME (owner: "use the real Story frame… the editor accurately
            // matches the final Story layout"). Full width, from just under the status bar down to
            // the tool band — a CONSTANT of screen geometry, so nothing that appears or disappears
            // around it (keyboard, bars, Aa) can ever resize the preview. Everything WYSIWYG —
            // the photo, the pen, the text, the flatten — lives in the CARD's coordinate space
            // now, not the whole screen's, which is what makes the posted frame the seen frame.
            let cardTop: CGFloat = 8
            let card = Self.cardSize(in: geo.size, top: cardTop)
            let cardH = card.height
            ZStack {
                Color.black.ignoresSafeArea()
                cardContent(card: card)
                    .frame(width: card.width, height: card.height)
                    // The card ALWAYS has the rounded story shape (reference). Display-only:
                    // the flatten renders the same space unrounded, and the viewer rounds its
                    // own card exactly like this.
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                    // WHERE THE PICTURE IS ON SCREEN, for the crop screen to open out of. Their
                    // presenter sets `initialContentInsets` before presenting for exactly this; see
                    // `ChatCropView.initialContentRect`. Read in global coordinates because the crop
                    // canvas sits under a bar whose height it is not told.
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { cardRect = $0 }

                // Top controls — stay put when the keyboard opens (don't ride up with it).
                VStack {
                    HStack {
                        Button { closeEditor() } label: {
                            // 40pt, his call (2026-08-06), matching the video editor's. The glyph
                            // comes down with the circle so the proportion inside it is unchanged.
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)   // always white; glass + shadow carry contrast
                                .shadow(color: .black.opacity(0.35), radius: 2)
                                .frame(width: 40, height: 40).contentShape(Circle()).liquidGlass(Circle())
                        }
                        Spacer()
                        // (The "Done" that used to sit here while drawing is GONE. The pen carries
                        // its own ✕ and ✓ at the two ends of its bar now — his 2026-08-14 design —
                        // and a second Done up here would be the same decision offered twice.)
                        //
                        // SOUND LIVES UP HERE NOW, opposite the ✕ and built the same way — his
                        // 2026-08-14 instruction, in his words: "remove [it from the] bottom, then
                        // put [it] top line around X button right side, also make same size [as the]
                        // x button."
                        //
                        // It reads better here than it did in the tool capsule: everything else in
                        // that capsule OPENS something — a keyboard, a crop screen, a pen — and this
                        // one silently flips a state. A switch belongs with the screen's other
                        // switch-like control, not among its doors.
                        if currentIsVideo {
                            Button {
                                items[index].muted.toggle()
                                // ⚠️ AND THE PLAYER HEARS IT. THIS IS THE WHOLE OF "MUTE IS NOT
                                // WORKING". The flag only ever reached the EXPORT — the posted file
                                // came out silent, correctly — and nothing ever told the preview,
                                // so the clip he was listening to kept talking and the button
                                // looked dead. It was doing its job somewhere he could not hear.
                                previewPlayer?.isMuted = items[index].muted
                            } label: {
                                Image(systemName: items[index].muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .shadow(color: .black.opacity(0.35), radius: 2)
                                    .frame(width: 40, height: 40).contentShape(Circle()).liquidGlass(Circle())
                            }
                        }
                    }
                    // HIG: inside the safe area, 16pt leading, 12pt below the Dynamic Island / notch.
                    // Higher up, into the top-left corner (clear of the centred Dynamic Island) per request.
                    .padding(.horizontal, 16).padding(.top, max(windowSafeTop - 22, 10))
                    Spacer()
                }
                // …and out of the way while a stroke is under the finger, same as the pen bar below.
                // The X is in a top corner, which is exactly where a drawing runs off.
                // AND DURING TRIM: the trim overlay carries its own X/✓ in the same corners, and
                // the composer's X kept drawing UNDER it — his screenshot showed the two close
                // buttons stacked on top of each other.
                // AND WHILE THE PEN IS OPEN, for the same reason one step further on: the pen's bar
                // now has its own ✕, and this one closes the WHOLE editor. Two ✕ on one screen
                // meaning two different things is worse than one extra tap to get out.
                // AND DURING A CROP, WHICH IS THE OTHER HALF OF HIS OVERLAP REPORT. The crop screen
                // carries its own ✕ at the bottom-left and its black ground fades in over 0.3s, so
                // this button sat in the top-left corner of the picture for the whole entry — his
                // screenshot, circled, half-cut by the card's corner. `showTrim` is here for exactly
                // the same reason and the crop screen was simply missed when it grew a bar of its own.
                .opacity(draggingID == nil && editingID == nil && !strokeInFlight && !showTrim && !showCrop && !isDrawing ? 1 : 0)
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // The bottom bars and the crop overlay are siblings of the canvas, in `body`,
                // which is what lets the keyboard move one without touching the other.
            }
            .onAppear {
                canvasSize = card
                cardBottomGap = max(Self.toolZoneHeight, geo.size.height - cardTop - card.height)
                if items.isEmpty {
                    if let v = sourceVideo, seedItems.isEmpty {
                        // A VIDEO-FIRST POST. The clip is the first item, wearing the black
                        // placeholder until its own frame decodes — exactly what a clip picked with
                        // the + wears. Its length and its poster arrive in `resolveSourceVideo`.
                        items = [DraftItem(image: Self.blackPoster, videoURL: v.url,
                                           duration: 0, assetID: v.assetID)]
                        index = 0
                        restoreCurrent()   // the SAME door every other arrival uses — see below
                        Task { await resolveSourceVideo(v.url) }
                    } else if seedItems.isEmpty {
                        // ⚠️ `restoreCurrent()`, NOT the bare `recomputeEdited()` below. THIS IS THE
                        // WHOLE OF "the first picture does not get the default zoom".
                        //
                        // The tools live OUTSIDE the item and `restoreCurrent` is the only place an
                        // item is ever put ON them — which is also where an unset zoom is resolved
                        // into a real one (`defaultZoom`). Every other way into this screen went
                        // through it: the + inside the editor (`appendPicked`), a batch from the
                        // picker (`applyPickerChange`), the hand-off below, even a delete. The very
                        // first item was the one exception — it was seeded straight into `items` and
                        // the screen was only asked to redraw. So `items[0].zoom` stayed at its
                        // "nobody has framed this yet" zero, `photoZoom` stayed at the 1 it is
                        // declared with, and a portrait picture opened fitted instead of filling.
                        //
                        // The same trap `appendPicked` fell into and carries a note about; this is
                        // the third and last door into the item list, closed the same way.
                        items = [DraftItem(image: source, assetID: sourceAssetID)]
                        index = 0
                        restoreCurrent()
                    } else {
                        // A hand-off from the video editor: the whole post arrives, the just-picked
                        // picture last — that is the one you continue on. restoreCurrent puts the
                        // arriving item's own state on the tools (a fresh picture: clean tools).
                        items = seedItems
                        index = max(0, items.count - 1)
                        // ⚠️ ONTO THE ITEM, NOT ONTO THE SCREEN. `restoreCurrent` one line below now
                        // puts the item's own caption on the tools, so a seed written to `caption`
                        // here would be overwritten by the empty one before it was ever seen.
                        if items.indices.contains(index) { items[index].caption = seedCaption }
                        restoreCurrent()
                        // The clips that came across unresolved join in tap order, each one on this
                        // screen rather than in front of it. See `seedVideos`. Sequential for the
                        // same reason `applyPickerChange` is: parallel decodes land in whatever
                        // order they happen to finish, and the strip's order is the tap order.
                        if !seedVideos.isEmpty {
                            let pending = seedVideos
                            Task {
                                for v in pending { await appendPicked(video: v.url, assetID: v.assetID) }
                            }
                        }
                    }
                }
                recomputeEdited()
            }
            .onChange(of: geo.size) { _, s in
                let c = Self.cardSize(in: s, top: cardTop)
                canvasSize = c
                cardBottomGap = max(Self.toolZoneHeight, s.height - cardTop - c.height)
            }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
        }
        // THE CANVAS never resizes for the keyboard, and that part was always right: automatic
        // avoidance squished it (user bug 1) and desynced the compact send button's visual frame from
        // its tappable one (user bug 2, taps landed on nothing). What changed is that the BAR is no
        // longer in here with it, so it can be lifted natively instead of by hand. Both old bugs stay
        // fixed and the jump goes with the hand-computed padding. See `body`.
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(false)   // user round 3: the clock/battery must stay visible above the card
        .alert("Couldn't share", isPresented: $postError) { Button("OK", role: .cancel) {} }
        // The X used to throw the whole post away on one tap: every crop, stroke, caption and
        // every extra item you had added, with nothing asked and nothing to undo it. The text
        // composer has confirmed since it was built; these two screens have far more to lose.
        //
        // A native ALERT, not a confirmationDialog, for the reason StoryTextComposer records: over a
        // full-screen presentation the dialog renders as a centred popover, and popovers HIDE
        // role-cancel buttons, which leaves "Discard" as the only way out of a discard prompt.
        // ⚠️ AND IT IS OURS, NOT SwiftUI'S, SO IT IS ACTUALLY DARK. This screen carries
        // `storyAlwaysDark()`, whose note used to claim it covered this alert — his 2026-08-12
        // screenshot is a pale grey panel with black text over a black editor, which disproves it.
        // A SwiftUI alert is presented into its own context, so the trait pinned on this screen
        // never reaches it. See `darkConfirm`.
        // ⛔ CLEAR ALL ASKS, and it asks with `darkConfirm` for the reason written twenty lines up:
        // a `confirmationDialog` over a full-screen presentation renders as a centred POPOVER, and
        // popovers hide role-cancel buttons — which would leave "Clear All" as the only way out of a
        // Clear All prompt. Same helper, same darkness, same shape as the two questions above it.
        .darkConfirm("Clear all drawing?", isPresented: $showClearAll,
                     destructive: "Clear All", cancel: "Cancel",
                     onDestructive: { drawing = PKDrawing() })
        .darkConfirm("Discard this story?", isPresented: $showDiscard,
                     destructive: "Discard", onDestructive: { dismiss() })
        // THE PEN'S OWN CANCEL, asked the same way and drawn the same way. It is a smaller question
        // than the one above — this session's strokes, not the whole post — so it says so.
        //
        // ⚠️ "KEEP" STAYS ON THE PEN. It does not leave with the drawing intact, which is what it
        // did for one build and what he corrected: "I said keep, please stay the page." Keep is the
        // answer that CANCELS THE CANCEL — the ✕ was a mistake, nothing happens, the pen is still
        // open with every stroke where it was. That is what `darkConfirm`'s own default label for
        // this button says in full ("Keep Editing"), and it is the only reading under which the two
        // buttons are not two ways of leaving.
        //
        // The way OUT with the drawing is the ✓ beside the ✕, which is the button that has always
        // meant that. Raised only when something was actually drawn; see `closePenFromCancel`.
        .darkConfirm("Discard your drawing?", isPresented: $confirmDiscardDrawing,
                     destructive: "Discard", cancel: "Keep Drawing",
                     onDestructive: { closePen(discarding: true) })
        // OUR OWN PICKER, images AND videos, always (owner 2026-08-05: "The + button should always
        // open our custom media picker… Never fall back to Apple's Photo Picker"). It stays open
        // while you tap — each pick lands in the strip behind it — and the X brings you back.
        .sheet(isPresented: $showAddPicker) {
            StoryLibraryPicker(
                // BOTH KINDS CLOSE THE PICKER NOW (owner 2026-08-06: "I chose other image but photo
                // picker still I see it, it most go back Story image editor page"). Video has done
                // this since 2026-08-05; images were deliberately left open for multi-pick, which he
                // had called working at the time. He has changed that — a pick takes you back to the
                // picture you are about to edit, whichever kind it was.
                onImage: { ui, id in
                    showAddPicker = false
                    appendPicked(image: ui, assetID: id)
                },
                onVideo: { url, id in
                    showAddPicker = false
                    Task { await appendPicked(video: url, assetID: id) }
                },
                // TICK SEVERAL, ADD ONCE. His 2026-08-07 report: adding one at a time is "soo hard".
                // The batch lands in tap order, and each item goes through the SAME append the single
                // path uses — so every one of them gets `restoreCurrent`'s clean tools rather than
                // the previous picture's crop, which is the trap `759546c` was written for.
                allowsMultiple: true,
                // WHAT THIS POST ALREADY HOLDS, so the five is the STORY's and not this sheet's.
                // His 2026-08-11 report: five, Add, + again, five more, for ever. Everything with an
                // asset behind it comes back ticked; a camera capture has none, so it is counted
                // instead — either way it spends one of the five.
                preselected: postAssetIDs,
                reservedCount: postReservedCount,
                onApply: { removed, added in
                    showAddPicker = false
                    Task { await applyPickerChange(removed: removed, added: added) }
                })
        }
        .sheet(item: $pendingShare) { s in
            // Detents/drag-indicator are set INSIDE ShareStorySheet now, so both the photo and text
            // flows get the same compact fitted sheet.
            ShareStorySheet(image: s.data, caption: s.caption, video: s.video, extras: pendingExtras,
                            stickers: s.stickers,
                            onPosted: { onPosted(); dismiss() })
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Everything ON the card, built in the CARD's own coordinate space — the same space the
    /// flatten renders, the pen bakes against and the text overlays position in. One space for the
    /// seen and the posted picture is the whole WYSIWYG contract of this screen.
    @ViewBuilder private func cardContent(card: CGSize) -> some View {
        // The pen's canvas for this pass — the card, enlarged when the photo is zoomed out so its
        // surround can still be drawn on. See `penCanvasSize`.
        let penCanvas = Self.penCanvasSize(card: card, zoom: photoZoom)
        ZStack {
            Color.black
            // ⚠️ THE CANVAS THE POST WILL BAKE, not a blur of the photo. WYSIWYG is the whole
            // contract of this screen, and it was broken here in exactly the way the video editor's
            // was: this wash was a big blur + desaturation + dark veil, `flatten` baked a downscaled
            // wash, and the story viewer drew a third thing over the posted file. Three backdrops
            // for one picture, and he framed his photo against whichever one he happened to see.
            //
            // Same sampler and same drawer as `flatten` and as the story viewer — `StoryCanvas` —
            // so what he frames here is the file that lands.
            // ⚠️ ALWAYS DRAWN, NEVER CONDITIONAL, AND THAT IS HIS 2026-08-16 "when i start zoom in
            // for fast seconds it be like black, when i remove my fingers after that the blur is
            // coming". MY OWN REGRESSION, from this morning.
            //
            // It used to be `if !imageFillsCanvas(card)`, and I made that test zoom-aware so a
            // shrunken picture would show its canvas. The two halves then ran on different clocks:
            // the PICTURE follows the fingers live through a UIKit transform — which is the whole
            // reason a pinch on this screen does not shake — while `photoZoom` is only written when
            // the fingers come off. So the condition was answering with the size the picture had
            // BEFORE the gesture. Pinch out from a filling photo and it shrank away from a canvas
            // that was still being told it was covered: black behind it for the length of the
            // gesture, and the gradient arriving a beat after the fingers left.
            //
            // A condition that lags the thing it describes cannot be corrected, only removed. The
            // gradient costs nothing to draw and is invisible under a picture that covers it — which
            // is exactly what `flatten` does, unconditionally, and has always done. One less thing
            // that can disagree with the picture.
            LinearGradient(colors: [Color(uiColor: canvasColours.top),
                                    Color(uiColor: canvasColours.bottom)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: card.width, height: card.height)
                .allowsHitTesting(false)
            // Photo: full card width, aspect-fit on the wash. Zoom/pan applied DIRECTLY to a
            // UIImageView's transform in UIKit (no SwiftUI @State write per touch -> zero
            // re-render mid-pinch -> butter smooth, anchored between the fingers). The final
            // scale/offset sync back to photoZoom/photoOffset on release for the WYSIWYG flatten.
            // The UIKit container clips to its own bounds, so a zoomed photo never leaves the card.
            ZoomableImageView(image: edited, player: currentIsVideo ? previewPlayer : nil,
                              scale: $photoZoom, offset: $photoOffset,
                              maxScale: 4, interactive: !isDrawing && editingID == nil,
                              relay: photoTransform,
                              onTap: {
                                  captionFocused = false; selectedID = nil
                                  // ⚠️ PLAY AND PAUSE ARE BOTH THE WHOLE FRAME, AND BOTH BELONG TO
                                  // THIS ONE RECOGNISER — his 2026-08-14 report ("pause is working
                                  // all frame video, play must work all the frame like how it works
                                  // [for] pause") and his 2026-08-16 one ("I can only zoom the video
                                  // when it is paused") are the same line of code.
                                  //
                                  // Pause used to be a clear SwiftUI layer laid over the card while
                                  // the clip ran. A full-card `onTapGesture` is not a picture, it is
                                  // a surface: it took the touches for the whole frame, so the pinch
                                  // and the pan underneath it were unreachable for as long as the
                                  // video was playing. Nobody frames a moving clip was the
                                  // assumption, and he frames a moving clip.
                                  //
                                  // One view owns tap, pinch and pan now, at every moment, and the
                                  // circle stays as the thing that SAYS it can be played.
                                  if currentIsVideo, !isDrawing, editingID == nil {
                                      togglePreview()
                                  }
                              },
                              onSwipe: { step in
                                  // ZOOMED IN = a horizontal drag is panning the PICTURE, never
                                  // a page turn (owner 2026-08-05: "if I make zoom, block swipe
                                  // — if I want to swipe I can click thumbnail"). The thumbnails
                                  // remain the way to switch while zoomed.
                                  guard photoZoom <= 1.01 else { return }
                                  // The strip and the swipe are the same move, so they go through
                                  // the same door: select() parks this picture's edits and brings
                                  // the next one's back. Ends of the post simply do not move.
                                  guard items.count > 1, !isDrawing, editingID == nil,
                                        draggingID == nil else { return }
                                  let next = index + step
                                  guard items.indices.contains(next) else { return }
                                  captionFocused = false
                                  withAnimation(.snappy(duration: 0.22)) { select(next) }
                              })
                .frame(width: card.width, height: card.height)

            videoMark

            // Stickers — above the photo, UNDER the text. A caption is the thing you want readable
            // when the two land on each other, and the same order is baked in `flatten`.
            ForEach($stickers) { $s in
                StickerOverlayView(
                    sticker: $s,
                    canvasSize: canvasSize,
                    interactive: !isDrawing && editingID == nil,
                    onTapChip: { cycleChipColour(s.id) },
                    onDragChange: { live in
                        draggingID = s.id
                        // ⛔ THE HINT GOES THE MOMENT ANYTHING IS DRAGGED (owner 2026-08-22, with the
                        // words stranded in mid-air beside a badge he had moved). It is drawn from
                        // the sticker's COMMITTED centre, which does not move until the finger lifts,
                        // so during a drag it could only ever be in the wrong place — and following
                        // the badge would be the wrong answer anyway: the hint is there to explain a
                        // badge that just appeared, and somebody dragging it has plainly understood.
                        if linkHintStickerID != nil {
                            withAnimation(.smooth(duration: 0.2)) { linkHintStickerID = nil }
                        }
                        let hot = isOverTrash(live)
                        if hot != trashHot { trashHot = hot; if hot { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
                    },
                    onDragEnd: { live in
                        // Dragged onto the bin, same as a caption. It is the only way to remove one:
                        // a sticker has no selected state and no ✕, which is the reference behaviour
                        // and is why the bin appears the moment anything is being dragged.
                        if isOverTrash(live) { stickers.removeAll { $0.id == s.id } }
                        draggingID = nil; trashHot = false; guideV = false; guideH = false
                    },
                    onSnap: { v, h in
                        if v && !guideV { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        if h && !guideH { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        guideV = v; guideH = h
                    },
                    // ⛔ THE BIN GOES AWAY WHEN THE HAND DOES, whichever gesture was holding it.
                    // `onDragEnd` above still owns the DROP — whether this landed on the bin is a
                    // question only a real drag release can answer — and this owns nothing but the
                    // tidy-up, so the two cannot disagree about what happened.
                    onRelease: {
                        draggingID = nil; trashHot = false; guideV = false; guideH = false
                    }
                )
            }
            // Still under the text either way — a caption is the thing you want readable when the
            // two land on each other, and `flatten` bakes the same order.
            .zIndex(drawingOnTop ? 1 : 3)

            // THE HINT OVER A JUST-ADDED LINK. See `showLinkHint`.
            //
            // ⚠️ IT IS NOT A STICKER AND IT MUST NEVER BECOME ONE. `flatten` bakes `stickers`, so
            // anything living in that array is posted; this is a note to the person composing and
            // has no business in the picture. Drawn as its own layer, from its own state, and gone
            // before the story could be sent.
            if let hinted = stickers.first(where: { $0.id == linkHintStickerID }) {
                Text("Tap for more")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .fixedSize()
                    // Centred on the badge and lifted clear of its top edge: half the badge's drawn
                    // height carries it to the edge, and the gap is added past that. Read off the
                    // sticker's live geometry so it follows one that is dragged while the hint is up.
                    .position(x: hinted.center.x,
                              y: hinted.center.y
                                 - hinted.drawnSize.height * hinted.scale / 2
                                 - Self.linkHintGap)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                    .allowsHitTesting(false)   // the badge under it stays the target
                    .zIndex(6)
            }

            // Text overlays — above the photo, below the drawing canvas + controls.
            ForEach($overlays) { $o in
                TextOverlayView(
                    overlay: $o,
                    isSelected: selectedID == o.id,
                    canvasSize: canvasSize,
                    interactive: !isDrawing && editingID == nil,
                    onTap: { selectedID = o.id; editingID = o.id },
                    onDragChange: { live in
                        draggingID = o.id
                        let hot = isOverTrash(live)
                        if hot != trashHot { trashHot = hot; if hot { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
                    },
                    onDragEnd: { live in
                        if isOverTrash(live) { overlays.removeAll { $0.id == o.id }; selectedID = nil }
                        draggingID = nil; trashHot = false; guideV = false; guideH = false
                    },
                    onSnap: { v, h in
                        if v && !guideV { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        if h && !guideH { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        guideV = v; guideH = h
                    },
                    // ⛔ THE BIN GOES AWAY WHEN THE HAND DOES, whichever gesture was holding it.
                    // `onDragEnd` above still owns the DROP — whether this landed on the bin is a
                    // question only a real drag release can answer — and this owns nothing but the
                    // tidy-up, so the two cannot disagree about what happened.
                    onRelease: {
                        draggingID = nil; trashHot = false; guideV = false; guideH = false
                    }
                )
                .opacity(editingID == o.id ? 0 : 1)   // hide the one being edited (it lives in the editor)
            }
            // ABOVE THE INK WHEN THE INK WAS NOT THE LAST THING TOUCHED. See `drawingOnTop`.
            .zIndex(drawingOnTop ? 2 : 4)

            // ⚠️ A `Group`, because a modifier cannot be attached to an `if` in a ViewBuilder —
            // "instance member 'zIndex' cannot be used on type 'View'". The wrapper is the one thing
            // that gives the branch a value to hang it on.
            Group {
            if isDrawing {
                // ⛔ THE STROKES BELONG TO THE PICTURE, NOT TO THE CARD — his 2026-08-18 "if I zoom
                // in, the line must stay on that same part of the image". READ THIS BEFORE MOVING
                // THE PEN AGAIN.
                //
                // `PKDrawing` was authored and rendered in CARD space while the photo underneath is
                // drawn `.scaleEffect(photoZoom).offset(photoOffset)`. Pinch the picture and the
                // strokes stayed nailed to the screen while the thing they were drawn on slid out
                // from under them. `flatten` had the identical omission, which is exactly why nobody
                // caught it: the export and the screen agreed with each other, so WYSIWYG held —
                // both were anchored to the wrong thing, in the same wrong way.
                //
                // The transform below is the photo's own, applied to the pen layer as well, so the
                // two move as one surface. Applied to BOTH the live canvas and the static render,
                // and to the export in `flatten`, or the three drift apart again.
                //
                // ⚠️ AND IT IS WHY STROKES DRAWN WHILE ZOOMED STILL LAND IN THE RIGHT PLACE. A
                // SwiftUI transform maps touches through its inverse, so PencilKit goes on recording
                // in its OWN untransformed coordinates — which is the un-zoomed card space, which is
                // the picture's space. Nothing has to be converted on the way in or the way out.
                //
                // Must otherwise live in the SAME space (the card) as the photo + overlays + the
                // flatten capture rect, or strokes bake shifted and the bottom band is clipped.
                //
                // OUR PEN, NOT APPLE'S PALETTE (owner 2026-08-03: "use my owner pen"). PencilKit still
                // draws the strokes — it is the drawing engine, not a look — but its tool picker is off
                // and the ink comes from our own bar, exactly as ChatImageEditor has always done it.
                DrawingCanvas(drawing: $drawing, isActive: true,
                              penColor: penHue == 0 ? .white
                                                    : UIColor(hue: penHue, saturation: 1, brightness: 1, alpha: 1),
                              showsToolPicker: false,
                              inkType: isHighlighter ? .marker : .pen,
                              penWidth: penWidth,
                              onStroke: { drawing in
                                  // A stroke is the last thing touched, so the ink comes forward.
                                  drawingOnTop = true
                                  withAnimation(.easeInOut(duration: 0.15)) { strokeInFlight = drawing }
                              },
                              // ⛔ ZOOM WHILE THE PEN IS OPEN. The canvas covers the photo, so it
                              // carries the two-finger gestures and hands them to the photo's own
                              // coordinator — see `PhotoTransformRelay.drivePinch`. Nothing about
                              // where the ink LANDS changes: the strokes already wear this same
                              // transform (the long note above), and PencilKit goes on recording in
                              // its own untransformed space, which is the picture's space.
                              //
                              // ⚠️ AFTER `onStroke`, because a memberwise initialiser takes its
                              // arguments in declaration order and this property is declared below it.
                              photoRelay: photoTransform)
                    // Big enough to STILL cover the card once the zoom has shrunk it — see
                    // `penCanvasSize`. At a zoom of 1 or more this is exactly the card.
                    .frame(width: penCanvas.width, height: penCanvas.height)
                    .scaleEffect(photoZoom).offset(photoOffset)
                    // ⛔ AND THEN BACK TO THE CARD'S SIZE FOR LAYOUT, WHICH IS THE TEXT MOVING BY
                    // ITSELF (owner, 2026-08-20: "when i make zoom out image Aa text is moving up …
                    // never move that text").
                    //
                    // A ZStack takes the size of its LARGEST child, and at a zoom below 1 this
                    // canvas is deliberately larger than the card — that is what lets the surround
                    // be drawn on. So the whole card stack grew with it, and every `.position()` in
                    // that stack — the text overlays, the stickers, the alignment guides — is
                    // measured from the stack's top-left corner, which had just moved up and to the
                    // left of the card's. The text did not move; the space it is positioned in did.
                    //
                    // A second frame reports the card's size to the layout and lets this one
                    // overflow it visually, which is exactly what it needs to do. `scaleEffect` is
                    // already a render-time transform and never reported its shrink here either.
                    .frame(width: card.width, height: card.height)
            } else if !drawing.bounds.isEmpty {
                // Bug fix: after "Done", keep the markup VISIBLE in the preview (it used to vanish because
                // the canvas only existed in edit mode). Render the saved strokes as a static image, same
                // space + on top, so it persists and matches the flattened export exactly.
                //
                // ⚠️ RENDERED AT THE ZOOM IT WILL BE SEEN AT. `drawing.image(scale:)` rasterises
                // once, and the transform below then blows that raster up — so at 3× a stroke drawn
                // sharp came out soft. Asking for the pixels the zoom is about to need costs nothing
                // at zoom 1, which is nearly always.
                // ⚠️ THE TRANSFORM ARRIVES FRAME BY FRAME, NOT AT THE END OF THE GESTURE — his
                // 2026-08-19: "the pen stays in its old position during the zoom, then suddenly
                // snaps to the correct position when I finish". It was `.scaleEffect(photoZoom)`,
                // and `photoZoom` is written when the FINGERS COME OFF, because a SwiftUI state
                // write per touch re-renders this screen and shakes the pinch. So the pen did not
                // lag the picture, it did not move at all until the gesture ended.
                //
                // Same report the video gave in August, and nearly the same fix: the video went
                // INSIDE the zoom view, under the one transform. The pen cannot — it is drawn above
                // the stickers and below the text, and `flatten` bakes it in that order, so moving
                // it inside the picture would put the screen and the export out of step. It rides
                // the transform instead. See `PhotoTransformRelay`.
                LiveTransformImage(image: drawing.image(from: CGRect(origin: .zero, size: penCanvas),
                                                        scale: UIScreen.main.scale * max(1, photoZoom)),
                                   relay: photoTransform,
                                   scale: photoZoom, offset: photoOffset)
                    .frame(width: penCanvas.width, height: penCanvas.height)
                    // The card's size for layout — same reason as the live canvas above.
                    .frame(width: card.width, height: card.height)
                    .allowsHitTesting(false)
            }
            // ⛔ THE INK GOES OVER OR UNDER EVERYTHING PLACED, DEPENDING ON WHICH CAME LAST.
            //
            // It used to be neither: the canvas is declared after the text and the stickers and a
            // ZStack draws in declaration order, so the ink was permanently on top and a caption
            // written after a scribble went under it with no way to bring it forward.
            //
            // ⚠️ AND THE EXPORT ALREADY DISAGREED WITH THE SCREEN. The bake puts stickers, then
            // the drawing, then the text — so text has always come out ABOVE the ink in the posted
            // story while sitting UNDER it in the preview. One of the two was wrong about the other
            // whatever anybody chose; they are driven by the same flag now.
            }
            .zIndex(drawingOnTop ? 5 : 0)

            // ⛔ THE WAY OUT OF THE KEYBOARD, ABOVE EVERYTHING THE CANVAS CAN CARRY.
            //
            // His report: place a sticker, scale it up until it fills the screen, type a caption —
            // and then nothing will close the keyboard. The tap that dismisses it lives on
            // `ZoomableImageView`, which is the PHOTO, and the photo is the bottom of this stack. A
            // sticker is above it (zIndex 1 or 3) and takes its own touches, so once one is big
            // enough to cover the card there is no photo left to tap and the keyboard is trapped.
            // Text overlays and the ink layer would do exactly the same at full size; the sticker is
            // simply the easiest one to grow.
            //
            // So the dismiss stops being the photo's job. While — and only while — the caption is
            // focused, this sits over the whole card above every other layer and takes one tap. It
            // cannot swallow anything the rest of the time because it does not exist the rest of the
            // time, so dragging, pinching and tapping a sticker are untouched.
            //
            // ⚠️ zIndex 6, WHICH MUST STAY ABOVE EVERY LAYER IT CAN BE ON SCREEN WITH. The content
            // layers run 0–5 and swap around `drawingOnTop`; if one is ever added above 5, this has
            // to move with it or the bug comes straight back in whatever that new layer is.
            //
            // The drag chrome at 7 and 8 is higher and that is fine: it is up only while something is
            // being dragged, and nothing can be dragged while a caption has the keyboard.
            //
            // THE LEDGER, so the next person adding a layer does not have to read the whole stack:
            //   0–5  photo, stickers, captions, pen — the pair that swap are `drawingOnTop`
            //   6    this caption tap-catcher, only while the caption is focused
            //   7    centre guides, only while dragging
            //   8    the bin, only while dragging
            //
            // The photo's own `onTap` keeps its `captionFocused = false` — it is still correct, it
            // is just no longer the only way out.
            if captionFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { captionFocused = false }
                    .zIndex(6)
            }

            // Center alignment guides + trash zone (only while dragging an overlay).
            //
            // ⛔ THIS WHOLE BLOCK CARRIED NO `zIndex` AT ALL, WHICH MEANS ZERO (owner 2026-08-22: a
            // sticker dragged down covers the delete button). Zero is the BOTTOM of this stack: the
            // stickers sit at 1 or 3 and the captions at 2 or 4, so the very thing being dragged
            // toward the bin was guaranteed to paint over it, and over the guides meant to line it
            // up. It was never a layering choice, it was a layer nobody gave a number to.
            //
            // Drag chrome is the top of the stack by definition — it exists only while something is
            // moving and its whole job is to be seen while that happens. The bin outranks the guides
            // because a guide crossing the bin should pass behind it, not through the glyph.
            if draggingID != nil {
                if guideV { Rectangle().fill(.yellow.opacity(0.9)).frame(width: 1).frame(maxHeight: .infinity).position(x: card.width / 2, y: card.height / 2).zIndex(7) }
                if guideH { Rectangle().fill(.yellow.opacity(0.9)).frame(height: 1).frame(maxWidth: .infinity).position(x: card.width / 2, y: card.height / 2).zIndex(7) }
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: trashDiameter, height: trashDiameter)
                    .background(trashHot ? Color.red : .black.opacity(0.5), in: Circle())
                    .scaleEffect(trashHot ? 1.25 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: trashHot)
                    .position(trashCenter)
                    .zIndex(8)
            }
        }
        .coordinateSpace(name: "canvas")
    }

    /// The items in this post, bottom right above the caption bar, exactly as he drew them: the one
    /// on screen has a blue frame and an X, the others are plain and switch to when tapped.
    ///
    /// Only when there is more than one. A single thumbnail of the picture already filling the
    /// screen is a picture of what you are looking at.
    /// A video item shows its POSTER here, not moving frames — this editor is built around a picture
    /// and the clip is only played once it reaches the video editor. Without a mark that reads as a
    /// still photo, and you would only find out it was a clip after posting it. The strip already
    /// carries the same badge, so the two agree.
    ///
    /// Its own property, not another branch inside `body`: that ZStack is one branch away from the
    /// type-checker giving up, which is exactly what happened to the video editor's.
    @ViewBuilder private var videoMark: some View {
        if currentIsVideo, !isDrawing, editingID == nil {
            // A REAL BUTTON NOW. It was `allowsHitTesting(false)` — a picture of a play button on a
            // screen with nothing to play, which is exactly what the owner reported. It hides while
            // the clip is running so it does not sit over the video you asked to watch.
            // ⚠️ THE PLAY CIRCLE IS FOR STARTING. STOPPING IS THE WHOLE PICTURE — his 2026-08-14
            // report, twice: "I click play, I can't make pause", "pause icon are appearing all the
            // time".
            //
            // Both of those are one mistake. A 72pt target in the middle of a clip is a small thing
            // to hit, and leaving it on screen to be hit was answering the second complaint by
            // making the first one worse: an icon parked over the picture he is framing. Every
            // video editor answers this the same way — the whole frame stops it — and that target
            // cannot be missed.
            //
            // ⚠️ AND STOPPING IS NO LONGER A LAYER OVER THE PICTURE. It was a clear full-card
            // `onTapGesture` raised while the clip ran, and a surface like that takes the whole
            // frame's touches: the pinch and the pan under it were dead for as long as the video was
            // playing, which is his 2026-08-16 "I can only zoom the video when it is paused". The
            // stop tap lives in the canvas's own tap recogniser now, beside its pinch and pan, so
            // one view owns all three at every moment. Nothing is laid over anything.
            // ⚠️ AND IT IS A PICTURE AGAIN — `allowsHitTesting(false)` — WHICH IS HIS 2026-08-16
            // "when i click play video is not running". MY OWN REGRESSION.
            //
            // ONE TOUCH WAS BEING COUNTED TWICE. This was a real `Button`, and the canvas underneath
            // it is a `UIViewRepresentable` whose container is a genuine subview of the hosting view
            // — so SwiftUI's own tap recogniser sits on an ANCESTOR of it, and an ancestor's
            // recogniser sees every touch that lands on a descendant. Tapping the circle therefore
            // fired the button AND the canvas's tap: play, then pause, in the same instant. Nothing
            // moved, and the circle never went away because `previewPlaying` came back false.
            //
            // ⚠️ IT WAS NOT A LATENT BUG THAT I EXPOSED — IT WAS BEING HELD SHUT BY AN ACCIDENT. The
            // canvas's tap used to read `if currentIsVideo, !previewPlaying`, so the second call
            // found the flag already true and did nothing. Taking that guard out to make the frame
            // able to PAUSE is what turned a harmless double-fire into a cancellation.
            //
            // Two owners of one action cannot be timed apart; there has to be one. The frame is the
            // right one — it is the target that cannot be missed, and it is already where the pinch
            // and the pan live. So the circle goes back to being what it says it is: a sign that
            // this can be played. (It was `allowsHitTesting(false)` once before and that WAS a bug,
            // because back then nothing else took the tap. Now the frame does.)
            if !previewPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.35), in: Circle())
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    // `clipPreview` lived here: the player layer as a SwiftUI SIBLING of the canvas, wearing
    // `.scaleEffect(photoZoom).offset(photoOffset)` to keep it on top of the poster. It could only
    // ever be a frame behind — photoZoom is written on RELEASE, because writing it per touch is what
    // shakes — so through every pinch the poster followed the fingers and the moving picture did
    // not, then jumped. The clip is a subview of `ZoomableImageView` now, under the same UIKit
    // transform as the poster, which is the only way the two can be in the same place at the same
    // time. See the note on its `player` parameter.

    /// The player for the clip on screen, built on first need. Returns nil for a photo.
    ///
    /// ONE PLACE BUILDS IT, and the end-of-clip observer is part of building it. The observer used to
    /// be attached inside `togglePreview`'s `previewPlayer == nil` branch, so a player built HERE
    /// first never got one: trim's scrub calls this, and after a trim the clip played to its end,
    /// stopped, never seeked back and left `previewPlaying` true for good. The card's play button
    /// hangs off that flag (`.opacity(previewPlaying ? 0 : 1)`), so it stayed invisible as well.
    @discardableResult
    private func ensurePreviewPlayer() -> AVPlayer? {
        if let previewPlayer { return previewPlayer }
        guard items.indices.contains(index), let url = items[index].videoURL else { return nil }
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        // The clip's own sound setting, from the moment it can make a sound. A player built AFTER
        // the button was pressed would otherwise start unmuted on a clip already marked silent.
        p.isMuted = items[index].muted
        previewPlayer = p
        // Back to the start when it finishes, so a second press replays rather than doing nothing.
        // The TOKEN is kept: see `previewEndObserver`.
        previewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero)
                previewPlaying = false
            }
        // ⚠️ AND THE PLAYHEAD IS REPORTED FROM HERE, BECAUSE NOTHING WAS REPORTING IT AT ALL.
        //
        // His report: the white line on the trim strip does not move while the clip plays.
        // `trimPlayhead` was declared, handed to `VideoTrimStrip` and written by exactly one thing —
        // the strip's own scrub gesture, through the binding. There was no clock behind it, so the
        // line could only ever be where a finger had last put it. `VideoApprovalView`, the chat's
        // trimmer, has had the observer this is copied from since it was written; the story trimmer
        // was built later and never got one.
        //
        // Same 0.05s the chat trimmer uses. A periodic observer only delivers while time is actually
        // moving, so a paused screen costs nothing, and the `showTrim` guard keeps a playing clip on
        // the ordinary editor from re-evaluating this body twenty times a second for a line that is
        // not on screen. `trimDragging` is the other half: while his finger owns the line, the
        // player is the one following, and writing back would fight the drag.
        //
        // It is attached HERE for the reason the note above gives about the end observer — one place
        // builds the player, and a player built by trim's own scrub must arrive with everything a
        // player needs.
        trimTimeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { t in
                guard showTrim, !trimDragging else { return }
                trimPlayhead.seconds = t.seconds
            }
        return p
    }

    /// The ONE door to this screen's seeking — see `seekInFlight` for what going straight to the
    /// player cost.
    ///
    /// ⚠️ `precise` IS NOT A DETAIL. A seek under a moving finger only has to look right, and a
    /// tolerance lets the decoder answer from a nearby sample immediately, which is what makes a
    /// scrub feel attached to the thumb. The seek that has to be EXACT is the one that lands when the
    /// finger lifts, and the frame he cuts on is that one. So the old comment's rule — "a scrub that
    /// lands on somewhere near is a scrub you cannot trust to cut on" — is kept where it is true and
    /// dropped where it was only costing frames.
    private func seekPreview(to seconds: Double, precise: Bool) {
        guard let p = ensurePreviewPlayer() else { return }
        pendingSeek = (CMTime(seconds: max(0, seconds), preferredTimescale: 600), precise)
        guard !seekInFlight else { return }   // the one in flight will pick up the latest when it lands
        drainSeeks(p)
    }

    private func drainSeeks(_ p: AVPlayer) {
        guard let next = pendingSeek else { seekInFlight = false; return }
        pendingSeek = nil
        seekInFlight = true
        // 0.12s is under four frames at 30fps and invisible while a thumb is moving; the exact one
        // follows it the moment the thumb stops.
        let tol: CMTime = next.precise ? .zero : CMTime(seconds: 0.12, preferredTimescale: 600)
        p.seek(to: next.time, toleranceBefore: tol, toleranceAfter: tol) { _ in
            // The completion's queue is not documented, and everything below it is `@State`.
            DispatchQueue.main.async {
                if pendingSeek != nil { drainSeeks(p) } else { seekInFlight = false }
            }
        }
    }

    private func togglePreview() {
        guard let p = ensurePreviewPlayer() else { return }
        if previewPlaying { p.pause() } else { playPreview(p) }
        previewPlaying.toggle()
    }

    /// ⚠️ EVERY `play()` ON THIS SCREEN GOES THROUGH HERE, and that is his "I am on a call in
    /// another app and the video will not play". An AVPlayer activates the shared audio session for
    /// itself, the session was on a category that activates by asking whoever holds it to stop, and
    /// a call says no — so the player silently did not start. `StoryPreviewAudio` carries the whole
    /// diagnosis; this is the one door it has to be applied at.
    private func playPreview(_ p: AVPlayer) {
        StoryPreviewAudio.prepare()
        // ⛔ CLEAR THE STILL-FRAME WORK BEFORE ASKING FOR MOTION. Whatever exact seeks the brightness
        // dial left behind are for a frame nobody is going to look at any more — the next thing on
        // screen is the clip running — but the video pipeline would finish them first while the
        // audio, which carries no filter, started at once. That gap is the owner's "I can hear sound
        // but video is not running". Cancelling is safe: `play()` resumes from wherever the item
        // actually is, and a nudge is under two milliseconds from there. See `nudgePreviewFrame`.
        p.currentItem?.cancelPendingSeeks()
        nudgeInFlight = false
        nudgePending = false
        p.play()
        // THE NET, because CallKit cannot be the whole answer: an app that does not report its calls
        // — or anything else sitting on a session it will not release — would leave the clip exactly
        // as he found it, still and silent with no error anywhere to notice. So the RESULT is checked
        // rather than assumed. A player that was told to play and a third of a second later is not
        // playing gets a mixable session and one more attempt.
        //
        // `.paused` specifically, never a bare "not playing": a clip that is buffering reports
        // `.waitingToPlayAtSpecifiedRate`, which is a player doing its job and must not be restarted
        // underneath itself. A local file is playing well inside this window either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard previewPlaying, previewPlayer === p,
                  p.timeControlStatus == .paused, p.error == nil else { return }
            StoryPreviewAudio.forceMixable()
            p.play()
        }
    }

    /// Leaving a clip, or the screen. An AVPlayer left running behind a photo keeps its audio session
    /// and its decoder, which is the kind of thing that only shows up as a battery complaint.
    private func stopPreview() {
        previewPlayer?.pause()
        // Hand the category back the moment nothing is previewing. See `StoryPreviewAudio.give`.
        StoryPreviewAudio.give()
        // ...and the observer goes with it. Dropping the player is not enough: the registration holds
        // a strong reference to both it and this view until it is removed by name.
        if let t = previewEndObserver { NotificationCenter.default.removeObserver(t) }
        previewEndObserver = nil
        // The same rule, and it has to happen while the player it was added to is still here: a
        // periodic observer is removed from the player, not by name, so dropping the reference first
        // would leak it and the block that retains this view with it.
        if let t = trimTimeObserver { previewPlayer?.removeTimeObserver(t) }
        trimTimeObserver = nil
        previewPlayer = nil
        previewPlaying = false
        // ⚠️ AND THE LIVE EXPOSURE, or the next clip previewed finds a handle to a composition that
        // is no longer attached to anything: the dial would set a value nothing reads and stay dead
        // for that clip, with no way back short of leaving the editor.
        brightnessTask?.cancel()
        brightnessTask = nil
        brightnessLive = nil
    }

    @ViewBuilder private var itemStrip: some View {
        if items.count > 1 {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    Button { select(i) } label: {
                        // SMALLER, AND SQUARE (owner 2026-08-04: "make small… make it also 1:1").
                        // A 52x66 portrait thumb is a small copy of the picture; a square one is a
                        // marker for it, which is what a strip of these is for. scaledToFill still
                        // centre-crops, so nothing stretches.
                        Image(uiImage: it.image)
                            .resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .bottomLeading) {
                                if it.isVideo {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                        .padding(4)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(i == index ? Color(.systemBlue) : .clear, lineWidth: 2))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        // The X removes, and only on the one you are on — an X on every thumbnail
                        // turns a row of pictures into a row of buttons.
                        if i == index {
                            Button { remove(i) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
            .padding(.bottom, 8)
        }
    }

    /// Add more pictures or videos to this post. Inside the caption bar on the left, where he put it.
    private var addMoreButton: some View {
        Button { showAddPicker = true } label: {
            // HIS OWN DRAWING (2026-08-06), and the SAME one on both editors. The photo editor used
            // `plus.square.on.square` and the video editor a bare `plus` — two different marks for
            // one action on two screens that are meant to be the same screen.
            //
            // Template-rendered, so `.foregroundStyle` tints it. The SVG's `currentColor` was
            // replaced with a literal black: a template asset takes its colour from the caller, and
            // `currentColor` has nothing to resolve against inside an asset catalogue — it renders
            // as nothing at all. Same trap as the icon batch on 2026-08-01.
            Image("ic_add_media")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 19, height: 19)
                .foregroundStyle(.white)
                // 40 tall on purpose: this is what sets the caption bar's resting height, and it
                // gives the button the full height of the bar as a touch target rather than 19 of it.
                .frame(width: 38, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(StoryPressStyle())
        .accessibilityLabel("Add more photos or videos")
    }

    /// The caption pill (and the thumbnail strip above it), floating ON the card near its bottom
    /// edge — the reference layout ("move the caption bar to the same position shown in the second
    /// reference image"). Its own layer so it can ride the keyboard while the canvas, which ignores
    /// the keyboard, never moves a pixel.
    private var captionLayer: some View {
        VStack(spacing: 12) {
            Spacer()
            if !captionFocused { itemStrip }
            // Caption bar — dark pill. While typing, Send sits beside it so you can post without
            // dismissing the keyboard (it used to hide with the toolbar → no way to send).
            HStack(alignment: .bottom, spacing: 10) {
                captionBar
                // While typing, a SMALL round send button (not the wide NEXT pill) so the caption
                // field keeps most of the width.
                if captionFocused { compactSendButton }
            }
        }
        .padding(.horizontal, 16)
        // At rest the pill sits INSIDE the card, 14pt up from its bottom edge. It used to add 14 to
        // the CONSTANT `toolZoneHeight`, which was the same thing only while the card was always
        // exactly that far off the floor. Now that the card takes the viewer's 9:16 rule it can end
        // higher than that, and a pill measured from the screen would hang below it on the black.
        // Focused, the keyboard is the floor and a small gap is enough.
        .padding(.bottom, captionFocused ? 8 : cardBottomGap + 14)
        // ⚠️ AND THIS PADDING MOVES ON THE KEYBOARD'S CLOCK, NOT INSTANTLY. THAT IS HIS JUMP.
        //
        // His report: while the keyboard is open the bar is right, and dismissing it makes the bar
        // "jump and then drop down". Both halves of that sentence are literally what happened, and
        // they are two different movements:
        //
        //   1. Losing focus flips this padding from 8 to `cardBottomGap + 14` — about 70pt — in a
        //      SINGLE FRAME, while the keyboard is still fully up. The bar leaps UP. That is the jump.
        //   2. Then SwiftUI's keyboard avoidance lowers the safe-area inset over the system's 0.25s
        //      curve and the bar rides it down. That is the drop.
        //
        // The two end positions were never wrong, which is why he says the open state is correct;
        // only the path between them was, because one of the two movements was not animated at all.
        // It is the same fault the note at the top of `body` describes and thought it had removed —
        // "two state changes, two moments, neither animated with the keyboard" — surviving in the one
        // number that still switches on focus.
        //
        // Nothing here measures a keyboard, and that rule stands: this is a CLOCK, not a height.
        // Resigning first responder starts the keyboard's animation in the same runloop turn as the
        // focus flip, so matching its length is enough to make the two one motion.
        //
        // ⚠️ AND MATCHING ITS LENGTH WAS NOT ENOUGH, BECAUSE `.easeOut(0.25)` IS NOT THE CURVE THE
        // KEYBOARD TRAVELS ON. The keyboard reports curve 7, its own private one; the reference app
        // maps 7 to a spring and hands UIKit `UIView.AnimationOptions(rawValue: 7 << 16)`, and where
        // it cannot sample that it writes the same shape out as `bezierPoint(0.23, 1.0, 0.32, 1.0)`.
        // Ease-out is a much lazier curve than that, so the pill and the keys left together and
        // arrived apart — which is the whole of "it does not look smooth".
        //
        // Both numbers now come off the notification itself. See `KeyboardWatcher.systemAnimation`.
        .animation(keyboard.systemAnimation, value: captionFocused)
        // ⚠️ NOT FOR THE Aa EDITOR'S KEYBOARD. `edges: []` is "ignore nothing", so this is one
        // modifier with one identity rather than a branch that would rebuild the layer. See
        // `textToolKeyboardUp` for why it is latched rather than read off `editingID`.
        .ignoresSafeArea(.keyboard, edges: textToolKeyboardUp ? .bottom : [])
        // Trash owns the bottom while dragging text. The Aa editor takes it too, but only once its
        // keyboard is standing over this bar rather than the instant it opens — see `textToolBarsDown`.
        .opacity(draggingID == nil && !textToolBarsDown ? 1 : 0)
    }

    /// Aa / crop-or-clip tools + NEXT, on the black band UNDER the card. Pinned: the keyboard never
    /// moves it (it hides while typing instead), so nothing here can push on the canvas.
    private var toolRowLayer: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                // THE TOOLS BELONG TO THE ITEM YOU ARE LOOKING AT, not to the screen.
                //
                // Owner: with a photo on thumbnail 1 and a video on thumbnail 2, tapping the
                // video still brought up the photo's controls. Crop is the one that was actually
                // wrong to offer, and he already ruled on it himself when he had the video editor
                // built: "NO CROP here — that is a photo tool". A clip gets what a clip has
                // instead: its sound, and its length.
                //
                // Aa and the pen stay for both, because they already work on a video — they
                // travel to the export and are composited into the frames there (see
                // `videoBurnIn`). Removing them would take away something that works.
                HStack(spacing: 22) {
                    capsuleTool("textformat", active: false) { addTextOverlay() }   // Aa — add text on either
                    if currentIsVideo {
                        // (Sound is NOT here any more — it is beside the ✕ at the top, on his
                        // instruction. Everything left in this capsule opens something; sound was
                        // the one entry that silently flipped a state.)
                        capsuleTool("scissors", active: items[index].isTrimmed) { openTrim() }
                    } else if Self.cropEnabled {
                        capsuleTool("crop", active: croppedSource != nil) {
                            withAnimation(.easeInOut(duration: 0.3)) { showCrop = true }
                        }
                    }
                    // STICKERS — his 2026-08-16 request. One button, one sheet, one callback: the
                    // tray hands back a sticker and the editor places it, so nothing else on this
                    // screen had to change to gain the tool.
                    capsuleTool(asset: "ic_sticker", active: !stickers.isEmpty) {
                        captionFocused = false
                        showStickers = true
                    }
                    capsuleTool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", active: isDrawing) {
                        // The pen's ✕ undoes back to here, so the snapshot is taken on the way IN
                        // and nowhere else — see `cancelDrawing`.
                        if isDrawing { closePen(discarding: false) }   // shutting it here KEEPS, like ✓
                        else { drawingAtPenOpen = drawing; isDrawing = true }
                    }
                    // NO EXTRA TOOL beyond these. It used to carry a second "add another
                    // picture", kept on the reasoning that two doors to one action beat two doors
                    // to two different ones. He has now seen both and called it: "remove the
                    // bottom Upload Story button because it is a duplicate. Keep the one in the
                    // caption bar exactly as it is."
                }
                .padding(.horizontal, 20).frame(height: 46)   // user spec: 46px
                .liquidGlass(Capsule())   // real Apple Liquid Glass capsule (not a flat dark fill)

                Spacer()
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // ⚠️ `textToolBarsDown`, NOT `editingID`, AND THAT ONE WORD IS HIS 08-18 REPORT. This row is
        // pinned under the keyboard, so it does not need to flee the moment a text block is tapped —
        // it needs to still be there while the keyboard covers it. The tools and NEXT are what the
        // Aa bar replaces, and until the keyboard has carried that bar onto the screen there is
        // nothing to replace them WITH.
        .opacity(!captionFocused && draggingID == nil && !textToolBarsDown ? 1 : 0)
    }

    /// The caption field in its glass pill, exactly as it was inside the old bottom bar.
    private var captionBar: some View {
        HStack(spacing: 6) {
            addMoreButton
            // Grows with the text (up to 5 lines) instead of staying a single truncated line.
            TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color.white.opacity(0.6)), axis: .vertical)
                .foregroundStyle(.white).focused($captionFocused)
                // ...and the text itself carries a hairline shadow so it reads on white.
                .shadow(color: .black.opacity(0.45), radius: 1.5)
                .lineLimit(1...5)
                // The text carries its own breathing room instead of the bar padding it. One
                // line is then 34 tall, under the 40 the + pins, so the resting bar is exactly
                // 40 and a long caption still grows from there.
                .padding(.vertical, 6)
                .onChange(of: caption) { _, v in if v.count > StoryText.charLimit { caption = String(v.prefix(StoryText.charLimit)) } }
                // ⚠️ ONE CONSTANT, and it used to be a hand-copied 700 beside a comment
                // saying "cap like the text composer" — which caps at 720. See `StoryText`.
        }
        // EXACTLY 40 AT REST (owner spec). It was 50: the + is a 32pt square and the bar
        // added 9pt of its own padding above and below it, so `minHeight: 40` never bit —
        // the content was already taller than the floor it was being held to. The + now
        // measures 40 itself, which sets the height and keeps a full-height touch target.
        .padding(.leading, 6).padding(.trailing, 18).frame(minHeight: 40)
        // ⚠️ THE WHOLE PILL TAKES THE TAP, AND THIS IS THE OTHER HALF OF "the keyboard opens late".
        //
        // A SwiftUI `TextField` only claims its own text rectangle. Inside a 40pt pill that leaves
        // the 18pt trailing gutter, the 6pt above and below the text, and everything to the right of
        // a short caption as dead glass — tap there and NOTHING happens, so the keyboard arrives on
        // whichever later tap happens to land on the words. That is not a slow keyboard, it is a
        // missed one, and it reads identically.
        //
        // Their input panel puts the activation on the panel, not on the text view
        // (`MessageInputPanelComponent` activates the input from a tap anywhere in it), which is what
        // makes theirs feel instant: there is no way to miss.
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { captionFocused = true }
        // LIQUID GLASS, TINTED DARK (owner 2026-08-03: "in story caption bar make it liquid
        // glass"). Plain glass was here once and came back off: on a bright photo it went pale
        // and the white placeholder disappeared into it, which he photographed. `tint` is
        // Apple's own glass tint, so this is still real glass and not a dark pill pretending —
        // it just carries enough of its own darkness that white text always has something to
        // sit on. The text keeps its hairline shadow for the same reason.
        // Rounder, on his word (2026-08-04). Not a Capsule: this bar GROWS to five lines
        // when the caption is long, and a capsule's ends become huge lozenges as it does.
        // 26 reads as a pill at resting height and still looks deliberate when it is tall.
        .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous),
                     tint: .black.opacity(0.28))
        // Light photos made the white caption text invisible (user screenshot: white-on-
        // white). A soft bar shadow lifts the pill off bright backgrounds...
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    /// TRIM, for a video item in a multi-item post. Reuses `VideoTrimStrip`, which is the same strip
    /// the video editor and VideoApprovalView drive — his standing instruction was "do not build a
    /// new trim system", and there is nothing here a second one would do better.
    ///
    /// It does not preview frames while you drag, because this screen has no player: a video item
    /// shows its poster with a play mark. The filmstrip and the handles are real, and the cut is
    /// applied once at post time by the same export path the video editor uses. If he wants the live
    /// scrub as well, that means an AVPlayer on this screen, which is a bigger piece and is worth
    /// asking about rather than assuming.
    @ViewBuilder private var trimOverlay: some View {
        // ⚠️ `!showCrop`, BECAUSE THIS LAYER IS ABOVE THE CROP ONE IN THE STACK. Adjust is opened from
        // the trim bar, and without this the crop screen would come up UNDERNEATH the page that asked
        // for it. Standing down rather than reordering the stack: the order below is what every other
        // overlay on this screen was built against, and `showTrim` staying true is also what brings
        // him back to the trim page — with the handles where he left them — when Adjust closes.
        if showTrim, !showCrop, items.indices.contains(index), items[index].isVideo {
            let dur = max(0.1, items[index].duration)
            VStack {
                Spacer()
                // HOW LONG THE CLIP IS, small, at the corner of the picture — his 2026-08-18 request
                // with the spot circled on his own screenshot.
                //
                // ⚠️ IT IS THE LENGTH BEING KEPT, NOT THE LENGTH OF THE FILE, and on a screen whose
                // whole job is choosing a piece of a clip those are the same number until a handle
                // moves. Frozen at the file's length it would read 0:58 over a ten-second selection,
                // which is the one moment somebody actually looks at it.
                //
                // No pill and no background: it sits over the bottom of the picture, where a card is
                // usually dark, and a shadow is enough to carry it over a bright frame. A capsule
                // there would be a third control on a screen that already has its own bar.
                HStack {
                    Spacer()
                    Text(trimLengthLabel)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                }
                // ⚠️ MEASURED FROM THE CARD'S EDGE, NOT THE SCREEN'S, AND THAT IS THE WHOLE BUG.
                //
                // His screenshot with the number circled against the corner: this bar sits in a
                // full-width VStack, so a flat 22 is 22 from the SCREEN — while the card behind it is
                // scaled to 0.9 for the trim, which pulls its right edge inward by 5% of the width,
                // about 21pt on his phone. The two landed within a point of each other, so the label
                // sat exactly on the card's edge, right where its 40pt corner is curving away.
                //
                // The 5% is the step-back's own arithmetic ((1 - 0.9) / 2), so this follows the card
                // if that number ever changes. 22 past it puts the number a clear thumb's width
                // inside the corner instead of on it.
                .padding(.horizontal, (canvasSize.width > 1 ? canvasSize.width : UIScreen.main.bounds.width) * 0.05 + 22)
                // Up off the bottom curve for the same reason — the corner eats both edges, not one.
                .padding(.bottom, 16)
                // REAL BINDINGS NOW, not `.constant`. Dragging a handle seeks the clip, so you can
                // see the frame you are cutting on — which is the whole reason a trim screen has a
                // picture above it. It was blind because the composer had no player; it has one.
                // ⚠️ THROUGH A HOST THAT OWNS THE 20Hz, so the playhead's clock cannot reach this
                // screen's body. See `TrimPlayheadBox`.
                // ⛔ ONE SLOT, TWO CONTROLS. The filmstrip and the brightness dial are the same band
                // of the screen: the Video tab trims, the Adjust tab lights. Swapping rather than
                // stacking is what keeps the picture the same size on both tabs — a second row would
                // push the clip up the moment you switched, which is the one thing this page cannot
                // do while you are judging a frame.
                if trimTab == .video {
                    TrimStripHost(playhead: trimPlayhead, duration: dur, thumbnails: trimThumbs,
                                  trimStart: $trimStart, trimEnd: $trimEnd, scrubTime: $trimScrub,
                                  playing: $previewPlaying, draggingPlayhead: $trimDragging)
                        .frame(height: 56)
                        .padding(.horizontal, 16)
                        // Reserve the slot rather than let a late filmstrip shove the layout up.
                        .opacity(trimThumbs.isEmpty ? 0 : 1)
                } else {
                    BrightnessDial(value: Binding(
                        get: { items.indices.contains(index) ? items[index].brightness : 0 },
                        set: { v in
                            guard items.indices.contains(index) else { return }
                            items[index].brightness = v
                            applyPreviewBrightness(v)
                        }))
                        .frame(height: 56)
                        .padding(.horizontal, 16)
                }
                // ✕ · one tool group · ✓ — HIS 2026-08-16 REDESIGN, and it is the same three-part
                // bar the pen and the crop screen already wear rather than a fourth arrangement.
                //
                // The two that end the session used to sit in the TOP corners with the strip alone
                // at the bottom, so the screen was worked from both ends: the thumb reads the strip,
                // then travels the height of the picture to accept it. Everything this screen does
                // is at the bottom now, in the order the other two editors put it.
                trimBar
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    // ⚠️ 6, WHICH IS THE NUMBER EVERY OTHER BAR ON THIS SCREEN USES. His 2026-08-18
                    // report: the trim page's buttons do not sit where the editor's, the pen's and
                    // the crop's do. Measured off his screenshots — the trim bar's centre sat at
                    // 0.952 of the screen against the tool row's 0.977, about 22pt too high, which is
                    // exactly the 28 this was against the tool row's 6.
                    //
                    // All three respect the bottom safe area and stand just above it, so matching the
                    // number matches the position on every phone rather than on his.
                    .padding(.bottom, 6)
            }
            // ⚠️ NOTHING AT ALL NOW. IT WAS 0.55, THEN 0.18, AND HIS 2026-08-16 INSTRUCTION IS THAT
            // THE TRIM PAGE SHOWS THE CLIP AT ITS OWN BRIGHTNESS "IN ALL CASES". The history below
            // is why there was ever a number here; there is no longer one to defend. The surface
            // stays, because it is also the tap target — see the second note.
            //
            // His 2026-08-14 report: "the trim page video brightness is going low, I can't see what
            // I'm trimming."
            //
            // The wash is over the WHOLE screen and the clip is underneath it, so it was taking
            // nearly half the light out of the one picture this screen exists to let him look at.
            // It was there to say "the editor is behind this now" — and two other things already
            // say that: the canvas steps back to 0.9 and drops 10pt as the trim opens, and every
            // one of the editor's own bars is gone while it is up. A third voice saying the same
            // thing was the only one charging for it.
            //
            // What is left is enough to seat the glass buttons on and no more.
            //
            // ⚠️ AND IT ANSWERS A TAP, which is the other half of the same report: "I can't play
            // video in the trim page." The play circle was visible the whole time — it belongs to
            // the canvas underneath — and this wash sits over it, so the tap died in the wash. A
            // full-screen background is not a picture, it is a surface, and it was silently
            // swallowing the only control on the screen. The strip and the two buttons are children
            // of this stack and sit above it, so they keep their own touches.
            // ⚠️ AND IT TAKES NO TOUCHES OF ITS OWN ANY MORE, FOR THE REASON WRITTEN ON THE PLAY
            // CIRCLE. This carried `contentShape` + `onTapGesture { togglePreview() }` so the trim
            // page could be tapped to play — and that is a SwiftUI surface over the canvas, so one
            // touch reached both it and the canvas's own tap recogniser: play, then pause, nothing.
            // The canvas already answers a tap on a clip anywhere on the frame, trim page included,
            // so there is nothing left for this to do but get out of the way.
            .background(Color.clear.ignoresSafeArea())
            .transition(.opacity)
            .task(id: items[index].id) { await loadTrimThumbs() }
            // The strip reports where the finger is; the clip goes there. `.zero` tolerance because a
            // scrub that lands on "somewhere near" is a scrub you cannot trust to cut on.
            .onChange(of: trimScrub) { _, t in
                guard let t else { return }
                previewPlayer?.pause(); previewPlaying = false
                lastScrubSeconds = t
                // Tolerant while the finger owns it, exact the moment it lets go — see `seekPreview`
                // and the note on `seekInFlight`.
                seekPreview(to: t, precise: !trimDragging)
            }
            // The exact frame lands here, once, on the release. Without it a scrub would leave the
            // picture up to a tenth of a second away from the cut it is about to make.
            .onChange(of: trimDragging) { _, dragging in
                guard !dragging, let t = lastScrubSeconds else { return }
                seekPreview(to: t, precise: true)
            }
        }
    }

    /// THE TRIM PAGE'S OWN BAR: ✕ · a glass capsule of tools · Done.
    ///
    /// ⚠️ THE CAPSULE HOLDS THE TOOLS THAT EXIST, AND NOTHING ELSE. He listed five —
    /// undo, sound, delete, speed, cut — and two of those are not controls, they are engines this
    /// screen does not have: `cut` in his sense splits the clip into SEGMENTS (which is also what
    /// makes `delete` mean anything: "delete only works when I cut the video, then select the part
    /// I cut"), and `speed` re-times the export. Our clip model is one pair of handles,
    /// `trimStart`/`trimEnd`, and the export composes from exactly that pair.
    ///
    /// A button that is drawn and does nothing is the one thing this project does not ship, so the
    /// bar is built for the tools that are real today and has room for the rest: undo, which is a
    /// genuine question this screen could never answer before, and sound, which was stranded on the
    /// composer's top bar — hidden for the whole of the trim, so the clip you are cutting could not
    /// be silenced while you cut it.
    private var trimBar: some View {
        HStack(spacing: 12) {
            // X puts the handles back where they were; Done keeps them. Neither may leave half a
            // cut behind, which is the rule the video editor's trim already follows.
            Button { closeTrim(keep: false) } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            HStack(spacing: 22) {
                // UNDO IS THE HANDLES, NOT THE SCREEN. It puts this sitting's cut back to where the
                // page opened, which is the only edit the page makes — so it is the pen's undo with
                // this screen's one kind of change. Leaving is still ✕'s job.
                //
                // ⛔ IT IS DISABLED WHEN THERE IS NOTHING TO UNDO, AND THE NOTE THAT USED TO SIT HERE
                // CLAIMED THAT AND DID NOT DO IT — his 2026-08-18 report, "Undo works when I have not
                // made any change, and using it without a change freezes the video".
                //
                // `active:` is the TINT and only the tint. The button underneath was live either way,
                // so with the handles untouched a tap ran the whole body: two writes that changed
                // nothing, a pause, and a zero-tolerance seek back to `trimStart`.
                //
                // That seek is the freeze, and it got worse this morning rather than better. The page
                // opens on the frame he was WATCHING now (see `openTrim`), so `trimStart` is usually
                // not where the picture is — an "undo" with nothing to undo threw away his position
                // and asked the decoder for an exact frame it had no reason to fetch. A precise seek
                // is the expensive kind: the renderer flushes and decodes forward from the previous
                // keyframe, and this screen has already paid for that once (`seekInFlight`).
                //
                // ⚠️ AND EVEN WHEN THERE IS SOMETHING TO UNDO, THE SEEK IS ONLY ASKED FOR IF THE START
                // MOVED. Dragging the END handle and undoing it leaves the first frame exactly where
                // it was, so there is nothing to seek to — the same rule `openTrim` follows.
                capsuleTool("arrow.uturn.backward",
                            active: canUndoTrim,
                            tint: Color(hex: 0x3DA1FD)) {
                    guard canUndoTrim else { return }
                    let startMoved = trimStart != trimOpenedStart
                    trimStart = trimOpenedStart
                    trimEnd = trimOpenedEnd
                    previewPlayer?.pause(); previewPlaying = false
                    guard startMoved else { return }
                    lastScrubSeconds = trimStart
                    // The white line follows by hand: the periodic observer only writes it while time
                    // is MOVING, and the clip has just been paused. See `openTrim`.
                    trimPlayhead.seconds = trimStart
                    seekPreview(to: trimStart, precise: true)
                }
                .disabled(!canUndoTrim)
                // The composer's mute, reachable from the screen that needs it. Same two lines as
                // the top bar's copy, including the one that tells the PLAYER — a flag that only
                // reaches the export is a button that looks dead while you are listening to it.
                // ⛔ THE TWO TABS. Video is the trim this page has always been; Adjust swaps the
                // filmstrip for the brightness dial. Default is Video on every open — the page is
                // nearly always entered to cut something.
                capsuleTool("video.fill", active: trimTab == .video, tint: Color(hex: 0x3DA1FD)) {
                    withAnimation(.easeInOut(duration: 0.18)) { trimTab = .video }
                }
                capsuleTool("sun.max.fill", active: trimTab == .adjust, tint: Color(hex: 0x3DA1FD)) {
                    withAnimation(.easeInOut(duration: 0.18)) { trimTab = .adjust }
                }
                capsuleTool(items[index].muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            active: items[index].muted, tint: Color(hex: 0x3DA1FD)) {
                    items[index].muted.toggle()
                    previewPlayer?.isMuted = items[index].muted
                }
                // ⚠️ THE ADJUST (CROP) DOOR IS GONE FROM THIS PAGE — his 2026-08-17, with the button
                // circled: "in story trim page plz remove crop view feature".
                //
                // It was added the same day on his own "only add an Adjust option, I don't need the
                // Cut/Delete/Speed segment model right now", and he has now seen it on the page and
                // does not want it there. Only the DOOR is removed: `showCrop`, `ChatCropView`,
                // `cropRect` and the transcoder's use of it are all untouched, so cropping a clip
                // still works from the editor's own tool row and anything already cropped keeps its
                // rectangle. This page is the trim again — undo, mute, and the two ends.
                //
                // ⚠️ DO NOT PUT IT BACK ON THE STRENGTH OF THE EARLIER INSTRUCTION. Both are his,
                // this one is later, and it is about where the control lives rather than what it does.
            }
            .padding(.horizontal, 20).frame(height: 46)
            .liquidGlass(Capsule())

            Spacer(minLength: 8)

            Button { closeTrim(keep: true) } label: {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Is there a cut to put back? The page's only edit is where the two handles are, so this is the
    /// whole of what Undo can mean — and it gates the button as well as tinting it, which is the half
    /// that was missing. A hair of tolerance because a handle drag lands on a float: two positions
    /// that differ by a thousandth of a second are the same cut, and treating them as different is
    /// how a button that should be dead stays live.
    private var canUndoTrim: Bool {
        abs(trimStart - trimOpenedStart) > 0.001 || abs(trimEnd - trimOpenedEnd) > 0.001
    }

    /// ⛔ THE DIAL HAS TO SHOW ON THE CLIP, or it is a number with no picture attached — and the
    /// export would then be the first place anybody saw what they had chosen.
    ///
    /// The SAME builder the export uses (`StoryVideoBrightness`), so the preview cannot drift from
    /// the file. Neutral clears the composition rather than installing an identity one: a player item
    /// with no composition takes the plain decode path, which is what an unadjusted clip deserves.
    ///
    /// Coalesced through a task: the dial reports on every touch and rebuilding a video composition
    /// per frame of a drag would stutter the very picture being judged. Only the last value survives.
    /// ⛔ TWO REASONS THE DIAL WAS NOT LIVE, AND THE PAUSE IS THE BIGGER ONE.
    ///
    /// **A paused player does not redraw.** Trim opens on a still frame by its own rule (`openTrim`
    /// sets `previewPlaying = false`), and assigning `videoComposition` to an item that is not
    /// playing changes what the NEXT frame will look like — and there is no next frame. The picture
    /// therefore sat unchanged for the whole drag and only caught up when he pressed play. A
    /// zero-tolerance seek to the time it is already at is what forces it to render one now.
    ///
    /// **And the composition was rebuilt per touch.** A composition bakes its filter in at build
    /// time, so following the dial meant an asynchronous build between every move of his thumb and
    /// the picture, which is what the 35ms coalesce was papering over. It is built ONCE now and
    /// reads its exposure live — see `StoryVideoBrightness.LiveExposure` — so every move after the
    /// first is a float and a redraw, with nothing to wait for and nothing to coalesce.
    private func applyPreviewBrightness(_ value: Double) {
        guard let item = previewPlayer?.currentItem else { return }
        let ev = StoryVideoBrightness.exposureEV(for: value)
        if let live = brightnessLive {
            live.ev = ev
            nudgePreviewFrame(item)
            return
        }
        // First touch of the dial for this clip: build the one composition, then never again.
        //
        // ⛔ A BUILD ALREADY RUNNING IS LEFT ALONE. This used to cancel and start over on every touch
        // the dial reported, and a fast first drag reports dozens — so the one composition everything
        // waits for was repeatedly thrown away a moment before it finished, and did not exist until
        // the finger stopped moving. Nothing is lost by waiting: the block below reads the dial's
        // CURRENT value when it lands, not the one this call carried.
        guard brightnessTask == nil else { return }
        brightnessTask = Task { [weak item] in
            var built: (AVVideoComposition, StoryVideoBrightness.LiveExposure)?
            if let item, let asset = item.asset as AVAsset? {
                built = await StoryVideoBrightness.liveComposition(for: asset)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // ⚠️ FREED WHETHER OR NOT IT WORKED, and every early exit above now comes through
                // here to do it. The guard on the way in treats a non-nil task as "a build is
                // running", so a build that failed and left the slot occupied would lock the dial
                // out of ever trying again for this clip.
                brightnessTask = nil
                guard let item, let built else { return }
                let (comp, live) = built
                // The dial may have moved on while this was building; take the value as it stands
                // rather than the one this call was made with.
                live.ev = StoryVideoBrightness.exposureEV(
                    for: items.indices.contains(index) ? items[index].brightness : Double(ev))
                brightnessLive = live
                item.videoComposition = comp
                nudgePreviewFrame(item)
            }
        }
    }

    /// Make a stopped player show the frame it is already on, once, through whatever the composition
    /// now says. Zero tolerance on both sides or AVFoundation is free to answer with the frame it has
    /// already drawn, which is the one being replaced.
    /// ⛔ THE SEEK HAS TO ASK FOR A DIFFERENT TIME, OR THERE IS NOTHING FOR AVFOUNDATION TO DO.
    ///
    /// This asked for the time the item was already at, and that is a no-op: same time, and — since
    /// the composition is built once and only its exposure changes inside — the same composition
    /// object too. Nothing about the request differs from the frame already on screen, so the
    /// rendered frame is reused and the dial does nothing. Which is exactly what he reported: live
    /// while the clip plays, because playback runs every frame through the handler regardless, and
    /// dead the moment he pauses.
    ///
    /// A time one six-hundredth of a second away is a DIFFERENT frame request, so the pipeline
    /// decodes and runs the handler, which reads the exposure as it now stands. It alternates either
    /// side of where the playhead is rather than always stepping one way, so a long drag cannot walk
    /// the clip forward: the most it is ever off is that one step, and the next move puts it back.
    /// ⛔ ONE NUDGE AT A TIME, AND THE REASON IS THE OWNER'S 2026-08-22 REPORT: brightness dragged
    /// fast to full, then play, and the sound started while the picture stayed on one frame for
    /// several seconds. Only ever after using the dial, and never once the page had been left.
    ///
    /// A zero-tolerance seek is expensive here in a way it is not anywhere else in the app, because
    /// this item is carrying a Core Image `videoComposition`: every one of them decodes to an exact
    /// frame and runs the filter over it. They were issued one per touch delivery with no completion
    /// handler and no coalescing, so a full-range drag left a deep queue of exact seeks behind it.
    /// `play()` then started the audio immediately — audio has no composition on it — while the
    /// video pipeline was still working through that queue. The clip was never stuck; it was busy.
    ///
    /// The flag is what the screen's own `seekPreview`/`drainSeeks` coalescer does, applied to the
    /// path that was bypassing it: while a nudge is in flight the dial keeps writing `live.ev`, so
    /// the exposure stays live and only the redraw is dropped, which is invisible on a still frame.
    private func nudgePreviewFrame(_ item: AVPlayerItem) {
        guard previewPlayer?.rate == 0 else { return }   // playing already draws every frame
        // ⚠️ THE DROPPED ONE IS REMEMBERED, NOT LOST. Coalescing without this would swallow the LAST
        // move of a drag — the finger stops, the final exposure never gets a frame, and the picture
        // sits one dial-step behind where the dial is. The trailing redraw is the whole difference
        // between coalescing and skipping.
        guard !nudgeInFlight else { nudgePending = true; return }
        let epsilon = CMTime(value: 1, timescale: 600)   // ~1.7ms, under half a frame at 240fps
        let now = item.currentTime()
        let target = nudgeForward ? CMTimeAdd(now, epsilon) : CMTimeSubtract(now, epsilon)
        nudgeForward.toggle()
        nudgeInFlight = true
        item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            // Back on the main actor: these are read and written only from there, and a completion
            // handler is not promised any particular queue.
            Task { @MainActor in
                nudgeInFlight = false
                guard nudgePending else { return }
                nudgePending = false
                nudgePreviewFrame(item)
            }
        }
    }

    private func openTrim() {
        guard items.indices.contains(index), items[index].isVideo else { return }
        // TRIM ARRIVES ON A STILL FRAME, the video editor's own rule (`openTrim` there does the same
        // thing to `playing`). You cannot pick the frame you are cutting on out of a moving picture,
        // and leaving the flag true was also how the card's play button ended up hidden after trim:
        // closing put nothing back, and the button is drawn `.opacity(previewPlaying ? 0 : 1)`.
        previewPlaying = false
        // ⛔ ALWAYS THE VIDEO TAB ON OPEN (his rule). The page is nearly always entered to cut
        // something, and a tab remembered from the last visit would put a dial in front of somebody
        // who came here for the strip.
        trimTab = .video
        trimStart = items[index].trimStart
        trimEnd = items[index].trimEnd > 0 ? items[index].trimEnd : items[index].duration
        trimOpenedStart = trimStart
        trimOpenedEnd = trimEnd
        // ⚠️ EVERY CLIP IS SHOWN BY THE PLAYER HERE, AND THAT IS THE WHOLE OF HIS 2026-08-16
        // "the video becomes noticeably darker/dimmer… only videos added later through the +".
        //
        // The canvas has two ways to show a clip and they do not look the same. One is the live
        // `AVPlayerLayer`, which renders the file's own colours; the other is the POSTER, a still
        // pulled with `AVAssetImageGenerator`, which tone-maps an HDR clip down to SDR — flatter and
        // visibly darker, and every clip off an iPhone camera in a dark room is HDR.
        //
        // Which one you got was decided by whether a player happened to exist. The first clip of a
        // post keeps whatever player it built and is normally watched before it is trimmed; picking
        // a later one goes through `select(_:)`, which calls `stopPreview()` because a player
        // belongs to the clip you were on — so that clip arrived at the trim page with nothing but
        // its poster, and the trim page is exactly where the difference is worth noticing.
        //
        // Building it here takes the choice away: the trim screen renders through the player for
        // every clip, first or fifth. It also seeks to the cut's own start, so the frame you are
        // cutting on is on screen the moment the screen opens rather than after the first drag.
        let player = ensurePreviewPlayer()
        player?.pause()
        // ⛔ IT OPENS ON THE FRAME HE WAS WATCHING, NOT ON THE START OF THE CLIP — his 2026-08-18
        // "when video is playing or paused then I click trim, always realtime, don't reset … just
        // make pause then continue, don't start from the beginning".
        //
        // This always seeked to `trimStart`, which for an untouched clip is zero. So watching thirty
        // seconds in and reaching for the scissors threw those thirty seconds away and put the first
        // frame on the trim page — and the trim page is precisely where the frame he was looking at
        // is the thing he wants to cut around.
        //
        // The seek is not removed, it is aimed. A clip that has never been played has a player at
        // zero and still needs putting on `trimStart`: that is the case the seek was written for
        // (a clip added through + arrives with only its poster, and the poster is visibly darker
        // than the player's own frame — see the note above). Only a position that is genuinely
        // inside the kept range is worth keeping, so a clip watched past its own trim end still
        // opens on the start rather than on a frame that is about to be cut off.
        //
        // ⚠️ AND WHEN THERE IS NOTHING TO MOVE, NOTHING IS ASKED FOR. Issuing a precise seek to the
        // time the player is already sitting on is a decoder flush for no change on screen, and this
        // screen has paid for exactly that once already — see `seekInFlight`.
        let at = player?.currentTime().seconds ?? 0
        let keepPosition = at.isFinite && at > trimStart + 0.05 && at < trimEnd - 0.05
        let open = keepPosition ? at : trimStart
        lastScrubSeconds = open
        // The white line starts under the frame that is on screen. It is set by hand because the
        // periodic observer only writes it while time is MOVING, and the clip has just been paused —
        // left alone it would say zero over a picture thirty seconds in.
        trimPlayhead.seconds = open
        // Through the serialiser like every other seek on this screen. Opening trim a SECOND time
        // used to add a precise seek on top of a queue the first trim's scrub had not finished
        // draining, which is the exact moment his clip froze — see `seekInFlight`.
        if abs(open - at) > 0.01 { seekPreview(to: open, precise: true) }
        withAnimation(.easeInOut(duration: 0.28)) { showTrim = true }
    }

    /// m:ss for the trim page's corner label. Rounded to the nearest second, the same rule the chat's
    /// own media approval screen uses, so one clip does not read as two different lengths in two
    /// places in the app.
    private var trimLengthLabel: String {
        let end = trimEnd > 0 ? trimEnd : (items.indices.contains(index) ? items[index].duration : 0)
        let t = Int(max(0, end - trimStart).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func closeTrim(keep: Bool) {
        if keep, items.indices.contains(index) {
            items[index].trimStart = trimStart
            items[index].trimEnd = trimEnd
        } else {
            trimStart = trimOpenedStart; trimEnd = trimOpenedEnd
        }
        // ⚠️ THE STRIP IS NOT THROWN AWAY ANY MORE — see `loadTrimThumbs` for what that cost. It is
        // ten frames of THIS clip and the clip has not changed, so the next open draws it instantly
        // and decodes nothing.
        withAnimation(.easeInOut(duration: 0.28)) { showTrim = false }
    }

    /// Ten frames across the clip — the same filmstrip recipe the video editor's trim uses.
    /// ⛔ THIS IS WHAT WAS FREEZING THE CLIP AFTER A SECOND TRIM. Read before changing any of it.
    ///
    /// His report: trim → Done → trim → Done, and the video in the editor stops while the AUDIO
    /// keeps playing, then catches up on its own a few seconds later.
    ///
    /// Nothing is wrong with the player. An `AVAssetImageGenerator` is a DECODE SESSION on the same
    /// file the `AVPlayer` is playing, and a process gets a small, fixed number of video decode
    /// pipelines from the system. Audio is not one of them, which is exactly why the sound survives
    /// and the picture does not — the player's VIDEO renderer is what gets starved, and it recovers
    /// by itself the moment a generator lets go. "A few seconds" is the length of the decode, not a
    /// timer somewhere.
    ///
    /// Three things stacked those sessions up, and all three are fixed here:
    ///
    ///   1. ⚠️ **NOTHING EVER CANCELLED THE GENERATOR.** SwiftUI cancels this `.task` when the trim
    ///      page goes away, but a cancelled Swift Task does not stop AVFoundation — only
    ///      `cancelAllCGImageGeneration()` does, and nothing called it. The loop did not look at
    ///      `Task.isCancelled` either, so it went on asking for the rest of the frames after the page
    ///      had closed.
    ///   2. ⚠️ **`closeTrim` THREW THE FINISHED STRIP AWAY** (`trimThumbs = []`), so opening trim a
    ///      second time started a SECOND generator on the same asset while the first was very likely
    ///      still running. That is why it takes two trims and not one.
    ///   3. `requestedTimeToleranceBefore = .zero` forbade the generator from answering with an
    ///      earlier keyframe, so every one of the ten frames was a decode forward from the previous
    ///      keyframe rather than a keyframe read.
    ///
    /// The tolerance is half a slot now. A filmstrip is ten evenly spaced posters — being inside its
    /// own slot is all "correct" means for it, and the frame somebody actually cuts on comes from the
    /// player's own scrub seek, which is still `.zero` on both sides and always was.
    private func loadTrimThumbs() async {
        guard items.indices.contains(index), let u = items[index].videoURL else { return }
        let itemId = items[index].id
        // Already decoded, same clip: draw it and touch no decoder at all.
        if trimThumbsItem == itemId, !trimThumbs.isEmpty { return }
        let dur = max(0.1, items[index].duration)
        let count = 10
        let slot = dur / Double(count - 1)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: slot / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: 160, height: 160)
        // The generator outlives this function's scope only if AVFoundation is still working, which
        // is the whole problem — so cancellation is explicit and covers every way out.
        defer { gen.cancelAllCGImageGeneration() }
        var imgs: [UIImage] = []
        for i in 0..<count {
            if Task.isCancelled { return }
            let t = CMTime(seconds: slot * Double(i), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { imgs.append(UIImage(cgImage: cg)) }
        }
        if Task.isCancelled { return }
        let done = imgs
        await MainActor.run { trimThumbs = done; trimThumbsItem = itemId }
    }

    /// Crop, presented INLINE with a cross-fade — the chat editor's own `cropOverlay`, move for move
    /// (owner 2026-08-03: "make the animation like when i stay edit page then i click crop").
    ///
    /// It was a fullScreenCover, which slides up from the bottom like a new screen; cropping is not
    /// somewhere you go, it is something you do to the picture in front of you, and a cross-fade in
    /// place says that.
    ///
    /// AND IT FIXES THE X IN THE STATUS BAR, which is the same report. The cover carried an
    /// `.ignoresSafeArea()` left over from the library cropper that used to live there and wanted
    /// full bleed. ChatCropView paints its own black to the edges and places its X and its Done with
    /// `safeAreaInset`, so telling it to ignore the safe area drove the top bar under the clock.
    /// Inline, it sits in this screen's own safe area exactly as it does inside the chat.
    /// WHERE THE PICTURE ACTUALLY IS ON SCREEN, in global points — the rectangle the crop screen
    /// opens out of and lands back on.
    ///
    /// ⚠️ IT IS NOT `cardRect`. The card is the 9:16 frame; the picture is aspect-fit INSIDE it and
    /// then carries his own framing. `ZoomableImageView` draws it with a `UIImageView` pinned to the
    /// card, `contentMode = .scaleAspectFit`, under `translate(photoOffset) · scale(photoZoom)` — and
    /// a UIView's transform is about its own centre, so the drawn picture is the fitted rectangle
    /// scaled by the zoom and moved by the pan. That is what this rebuilds, in the same order.
    ///
    /// ⚠️ `croppedSource ?? current` IS THE SAME IMAGE THE CROP SCREEN IS HANDED, and it has to be:
    /// the aspect the flight is measured from must be the aspect of the picture that flies, or a
    /// re-crop would start from a rectangle of the wrong shape.
    ///
    /// Nil while the card has not been measured, which is the same "no rect, no flight" the crop
    /// screen already understands — the chat editor and media approval reach it that way every time.
    private var photoRectOnScreen: CGRect? {
        guard cardRect.width > 1, cardRect.height > 1 else { return nil }
        let img = (croppedSource ?? current).size
        guard img.width > 1, img.height > 1 else { return nil }
        let fit = min(cardRect.width / img.width, cardRect.height / img.height)
        let w = img.width * fit * photoZoom
        let h = img.height * fit * photoZoom
        let shown = CGRect(x: cardRect.midX + photoOffset.width - w / 2,
                           y: cardRect.midY + photoOffset.height - h / 2,
                           width: w, height: h)
        // ⚠️ A PICTURE THAT COVERS THE CARD ANSWERS WITH THE CARD, and that is not a hedge.
        //
        // Most pictures here are framed past the edges — `restoreCurrent` opens a portrait photo at
        // its fill zoom, so the drawn rectangle is genuinely larger than the card and the card is
        // clipping it. What he can SEE in that case is a card-shaped window onto the picture, and the
        // window's centre IS the card's centre, so the card is the honest rectangle to fly from and
        // there was never a jump in that case. Handing the raw rectangle instead would open the
        // flight on more picture than the card was showing — a reveal at the first frame, which is a
        // new fault in place of the one being fixed.
        //
        // The case he photographed is the other one: a picture that does NOT cover the card sits in a
        // band of it, high or low, while the card's centre is somewhere else entirely. There the
        // picture's own rectangle is the only one that means anything.
        let coversCard = shown.minX <= cardRect.minX + 0.5 && shown.minY <= cardRect.minY + 0.5
            && shown.maxX >= cardRect.maxX - 0.5 && shown.maxY >= cardRect.maxY - 0.5
        return coversCard ? cardRect : shown
    }

    /// Where a picture of `imageSize` sits inside the card at zoom 1: aspect-fit, centred. The same
    /// rule `photoRectOnScreen` uses before it applies the pinch, and the same one
    /// `Image(...).scaledToFit()` applies on screen — one shape, so the pen and the photo cannot
    /// disagree about where the picture is.
    private func fittedPhotoRect(_ imageSize: CGSize, in card: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, card.width > 0, card.height > 0 else { return .zero }
        let fit = min(card.width / imageSize.width, card.height / imageSize.height)
        let w = imageSize.width * fit, h = imageSize.height * fit
        return CGRect(x: (card.width - w) / 2, y: (card.height - h) / 2, width: w, height: h)
    }

    /// Carry the pen strokes through a crop. `r` is the kept rectangle as a 0-1 fraction of the
    /// picture the crop screen was handed. See the note at the call site for why this cannot be a
    /// transform on screen.
    private func applyCropToDrawing(_ r: CGRect) {
        guard !drawing.bounds.isEmpty, r.width > 0.0001, r.height > 0.0001 else { return }
        let card = canvasSize
        let base = (croppedSource ?? current).size
        let oldFit = fittedPhotoRect(base, in: card)
        guard oldFit.width > 1 else { return }
        // The part of the old fitted picture that survives...
        let kept = CGRect(x: oldFit.minX + r.minX * oldFit.width,
                          y: oldFit.minY + r.minY * oldFit.height,
                          width: oldFit.width * r.width,
                          height: oldFit.height * r.height)
        guard kept.width > 1 else { return }
        // ...and where it lands once it is the whole picture and re-fitted.
        let newFit = fittedPhotoRect(CGSize(width: base.width * r.width, height: base.height * r.height),
                                     in: card)
        guard newFit.width > 1 else { return }
        let s = newFit.width / kept.width
        let t = CGAffineTransform.identity
            .translatedBy(x: newFit.minX, y: newFit.minY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -kept.minX, y: -kept.minY)
        drawing = drawing.transformed(using: t)
    }

    @ViewBuilder private var cropOverlay: some View {
        if showCrop {
            // From the CURRENT cropped result when there is one, so re-opening crop refines instead
            // of resetting to the original.
            ChatCropView(image: croppedSource ?? current, inline: true,
                         onClose: {
                             withAnimation(.easeInOut(duration: 0.3)) { showCrop = false }
                             // The card is back the instant the crop screen goes, and the next crop
                             // must start from "the card is up" again.
                             cropFlying = false
                         },
                         onFlightStart: { cropFlying = true },
                         onRect: { r in
                             // ⛔ THE STROKES FOLLOW THE CROP — the second half of his 2026-08-18
                             // "after cropping the Pen drawing should remain correctly positioned
                             // relative to the image".
                             //
                             // Anchoring the pen to `photoZoom`/`photoOffset` (see `cardContent`)
                             // makes it move with a PINCH, and that is most of the ask — but a crop
                             // is a different kind of move and no transform on screen expresses it.
                             // Cropping replaces the base picture and re-fits it, so the strokes'
                             // un-zoomed card coordinates stop meaning what they meant: the kept
                             // region grows to fill the card, and anything drawn on it has to grow
                             // with it or it slides off the part of the photo it was drawn on.
                             //
                             // ⚠️ `photoZoom` AND `photoOffset` ARE NOT TOUCHED BY A CROP — nothing
                             // in this file writes them outside `restoreCurrent` — so this maps the
                             // UN-zoomed rects and the pinch keeps applying on top, unchanged.
                             //
                             // The mapping is the kept sub-rect of the old fitted picture onto the
                             // new fitted picture: `p' = newFit.origin + s · (p − kept.origin)`.
                             // Built in that order, because `translatedBy`/`scaledBy` compose onto
                             // the right, so the last one written is the first one applied.
                             applyCropToDrawing(r)
                             // Re-cropping refines the crop you already have, so the new rectangle is
                             // read INSIDE the old one rather than against the original — otherwise a
                             // second pass would jump back out to the full frame and lose the first.
                             if let old = cropRect {
                                 cropRect = CGRect(x: old.minX + r.minX * old.width,
                                                   y: old.minY + r.minY * old.height,
                                                   width: r.width * old.width,
                                                   height: r.height * old.height)
                             } else {
                                 cropRect = r
                             }
                         },
                         // THE PICTURE THIS SCREEN IS OPENING OUT OF, and the corner it is wearing
                         // while it does. Their presenter hands the same two things over before it
                         // presents; see the note on `ChatCropView.initialContentRect`.
                         // ⛔ THE PICTURE'S RECTANGLE, NOT THE CARD'S — his 2026-08-18 "the image is
                         // first moved to the center of the screen, and only then does the zoom-out
                         // begin … start it from the image's current position, even if that position
                         // is near the top".
                         //
                         // This was `cardRect`, the whole 9:16 card. The picture inside it is
                         // aspect-FIT and then carries the framing he set with two fingers, so the two
                         // rectangles are the same only for a photograph that happens to fill the card
                         // at zoom 1. Every other picture sits in a band of that card — high, low or
                         // small — and the flight began by drawing it at the CARD's size and on the
                         // CARD's centre. That is the move to the middle he is describing, and it
                         // happens in one frame because it is where the flight STARTS rather than
                         // something it animates. Done then ran it backwards: zoom home to the card's
                         // centre, then a step to where the picture really lives.
                         //
                         // Handed the picture's own rectangle, the flight starts and ends exactly
                         // where the picture is and the whole transition is one scale.
                         initialContentRect: photoRectOnScreen,
                         initialCornerRadius: 40) { cropped in
                croppedSource = cropped
                recomputeEdited()
            }
            // ⚠️ NO CROSS-FADE ON THE WAY IN, AND THE ONE MOTION IS 0.3s EASE-IN-OUT — THE SAME
            // CLOCK THE CANVAS BEHIND IT STEPS BACK ON.
            //
            // It was `.opacity + .scale(0.97)` over 0.26s after a 0.10s delay, which is two
            // renderings of one photograph at two different sizes dissolving into each other. That
            // is his "the image is suddenly replaced with a new screen" in as many words: however
            // well timed, a dissolve says these are two pictures.
            //
            // Neither reference app fades anything. The one this screen was first built against
            // resizes its own picture into the crop layout over 0.15s with no transition object at
            // all; the one he asked for on 2026-08-17 animates the picture's FRAME from where it was
            // to the crop layout over **0.3s ease-in-out** (`TGPhotoEditorTabController`) while the
            // crop controls fade in over **0.3s** on top of it (`TGPhotoCropController.transitionIn`).
            // 0.3 is also what the canvas underneath already uses, so the picture that shrinks and the
            // editor that steps back behind it now finish together instead of one at half time.
            //
            // `ChatCropView` owns the whole flight, off `initialContentRect`; the job here is to get
            // out of its way. See `runEntry` — and in particular the `min(1, …)` that used to sit in
            // it and made the zoom-out, which is the ONLY direction this screen is ever entered in,
            // the one direction that could not happen.
            //
            // The removal keeps its fade. Closing has no picture to be continuous with — the canvas
            // underneath is already where it was — and he reported nothing about the way out.
            // ⚠️ NO FADE EITHER WAY NOW. The removal kept one while closing had no picture to be
            // continuous with; it has one since `ChatCropView` learned to fly home — the kept
            // rectangle lands exactly on the card and the card is already drawing it, so a
            // cross-fade would be dissolving a photograph into itself. His 2026-08-18 "zoom back".
            .transition(.identity)
            .zIndex(20)
        }
    }

    /// OUR pen bar, the same one the chat's image editor uses: a colour track, undo, pen vs
    /// ⛔ THE PEN'S TOP BAR: undo on the left, Clear All on the right (owner, 2026-08-21, with the
    /// reference in front of him). The undo that used to sit in the bottom tool group is gone — one
    /// undo, in the place he put it.
    ///
    /// ⚠️ NEITHER APPEARS UNTIL THERE IS SOMETHING TO ACT ON ("only appearing after when user used
    /// pen"). An undo with nothing to undo and a Clear All with nothing to clear are two controls
    /// that exist to tell you they cannot be used — the same rule the trim screen's undo already
    /// follows and the same one that took the "..." off an empty archive.
    @ViewBuilder private var penTopBar: some View {
        if !drawing.strokes.isEmpty {
            HStack {
                Button {
                    var s = drawing.strokes
                    if !s.isEmpty { s.removeLast(); drawing = PKDrawing(strokes: s) }
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                // ⛔ IT ASKS FIRST. Clear All throws away every stroke of the sitting and the only
                // way back would be tapping undo once per stroke, which is not a way back.
                Button { showClearAll = true } label: {
                    Text("Clear All")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .liquidGlass(Capsule(), interactive: true)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    /// highlighter, a width that cycles, and a tick to finish. Nothing here is Apple's palette.
    private var penBar: some View {
        let currentColor = penHue == 0 ? Color.white : Color(hue: penHue, saturation: 1, brightness: 1)
        return VStack(spacing: 14) {
            GradientSlider(value: $penHue, track: LinearGradient(
                colors: [.white] + stride(from: 0.02, through: 1.0, by: 0.08).map { Color(hue: $0, saturation: 1, brightness: 1) },
                startPoint: .leading, endPoint: .trailing))
                .padding(.horizontal, 20)
            // ✕ · one tool group · ✓ — his 2026-08-14 design, the same three-part bar the crop
            // screen wears, so the two tools of one editor are laid out the same way. Five loose
            // glass circles in a row read as five unrelated things; the four that are the PEN are
            // one object now, and the two that end the session sit at the two ends where the thumb
            // already is.
            HStack(spacing: 12) {
                // CANCEL, and it asks before it throws anything away. See `closePenFromCancel`.
                Button { closePenFromCancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                HStack(spacing: 22) {
                    // ⛔ NO UNDO HERE ANY MORE. It moved to the top bar on his order (2026-08-21) and
                    // there is exactly one of it: two undo buttons on one screen is two answers to
                    // the same question. See `penTopBar`.
                    capsuleTool("pencil.tip", active: !isHighlighter, tint: Color(hex: 0x3DA1FD)) { isHighlighter = false }
                    capsuleTool("highlighter", active: isHighlighter, tint: Color(hex: 0x3DA1FD)) { isHighlighter = true }
                    // The width, which is also the only place the chosen colour is shown as a
                    // solid. No glass circle of its own any more — the capsule is its background.
                    Button { penWidth = penWidth >= 16 ? 4 : penWidth + 6 } label: {
                        Circle().fill(currentColor)
                            .frame(width: min(penWidth + 6, 24), height: min(penWidth + 6, 24))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(StoryPressStyle())
                }
                .padding(.horizontal, 20).frame(height: 46)   // the story toolbar's own capsule
                .liquidGlass(Capsule())

                Spacer(minLength: 8)

                // Keep the drawing. Blue-tinted glass, the app's one shape for a prominent round
                // action, matching the crop screen's ✓.
                Button { closePen(discarding: false) } label: {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    /// HAS THIS PEN SESSION CHANGED ANYTHING? Cheap answer first, exact answer second.
    ///
    /// The stroke count settles it for everything ordinary — a stroke added, a stroke undone. It
    /// cannot settle "drew one, undid it, drew another", which is the same count and a different
    /// picture, so that falls through to comparing the serialised drawings. `PKDrawing` is not
    /// `Equatable`, and its data is the only exact comparison there is.
    private var penSessionEdited: Bool {
        guard let snapshot = drawingAtPenOpen else { return !drawing.strokes.isEmpty }
        if snapshot.strokes.count != drawing.strokes.count { return true }
        return snapshot.dataRepresentation() != drawing.dataRepresentation()
    }

    /// THE PEN'S ✕ IS A CANCEL, AND A CANCEL ASKS BEFORE IT THROWS WORK AWAY.
    ///
    /// His 2026-08-14 order, in his words: "X must function as Cancel, with a Discard / Keep
    /// confirmation when the user has made pen changes." Nothing drawn since the pen opened and
    /// there is nothing to ask about, so it simply leaves. This is the same rule the composer's own
    /// X already follows for the whole post, for the same reason: one tap should not be able to
    /// destroy work with nothing asked and nothing to undo it.
    private func closePenFromCancel() {
        if penSessionEdited { confirmDiscardDrawing = true } else { closePen(discarding: false) }
    }

    /// The one way out of the pen. `discarding` puts the strokes back to the snapshot taken when it
    /// opened (`toolRowLayer`); either way the snapshot is released, so it can never be spent on a
    /// later session.
    private func closePen(discarding: Bool) {
        if discarding, let snapshot = drawingAtPenOpen { drawing = snapshot }
        drawingAtPenOpen = nil
        isDrawing = false
    }

    // Plain icon button inside the dark tool capsule (no per-button background — the capsule is the bg).
    @ViewBuilder
    private func capsuleTool(_ icon: String, active: Bool, tint: Color = .green,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? tint : .white)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(StoryPressStyle())
    }

    /// The same control for an icon we draw ourselves rather than one of Apple's.
    ///
    /// The sticker tool is the only one of the four that has no SF Symbol worth using — `face.smiling`
    /// is a smiley, not a sticker, and it said the wrong thing beside three tools that all name what
    /// they do. `ic_sticker` is the shape everyone draws for this: a disc with one corner peeled.
    /// Template-rendered from the catalogue, so it takes the same tint as its three neighbours.
    private func capsuleTool(asset: String, active: Bool, tint: Color = .green,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                // 22, not the 20 the symbols use: an SF Symbol at `.font(size: 20)` draws well past
                // its nominal box, and matching the number rather than the drawn size would leave
                // this one visibly the smallest thing in the capsule.
                .frame(width: 22, height: 22)
                .foregroundStyle(active ? tint : .white)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(StoryPressStyle())
    }

    // Shared green Send — used in the toolbar (idle) AND beside the caption (while typing).
    // Compact round send used beside the caption while the keyboard is open (keeps the field wide).
    private var compactSendButton: some View {
        Button {
            // Presenting the share sheet WHILE the keyboard is dismissing silently failed
            // (tap closed the keyboard, no sheet). Resign first, let it settle, then send.
            captionFocused = false
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await send()
            }
        } label: {
            Group {
                if posting { ProgressView().tint(.white) }
                else { Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
        }
        .buttonStyle(StoryPressStyle()).disabled(posting)
    }

    private var sendButton: some View {
        Button { Task { await send() } } label: {
            HStack(spacing: 4) {
                if posting {
                    ProgressView().tint(.white)
                } else {
                    Text("NEXT").font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 46)   // user spec: 46px
            // Blue-tinted real Liquid Glass (prominent action), not a flat blue fill.
            .liquidGlass(Capsule(), interactive: true, tint: Color(.systemBlue))
            // WHOLE PILL tappable (user: only the "NEXT" text responded). Without an explicit
            // contentShape, SwiftUI hit-tests only the opaque text/chevron, not the padded capsule.
            .contentShape(Capsule())
        }
        .buttonStyle(StoryPressStyle()).disabled(posting)
    }

    // MARK: - Text overlays
    /// Bottom centre of the card, his 2026-08-16 placement. 60pt up from the bottom edge leaves a
    /// 52pt bin sitting clear of it with room for the grown state.
    private var trashCenter: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height - 60) }
    /// His size, and the hit area is the BUTTON rather than a zone around it.
    private let trashDiameter: CGFloat = 52
    /// ⚠️ THE FINGER HAS TO BE ON THE BIN — his 2026-08-16 "dragging the text downward deletes it".
    ///
    /// This was a 64pt radius around the bin, tested against the TEXT'S OWN CENTRE, and the two
    /// together made the whole bottom of the picture a delete zone: park a caption near the bottom
    /// edge, which is where captions go, and its centre lands inside the circle without the finger
    /// ever being near the bin. Signal deletes on the drag POINT being inside the control, which is
    /// what "drag it onto the bin" means and what the caller now passes.
    ///
    /// A little larger than the glyph so a thumb that covers it still counts, and no larger.
    private func isOverTrash(_ p: CGPoint) -> Bool {
        hypot(p.x - trashCenter.x, p.y - trashCenter.y) < trashDiameter / 2 + 12
    }
    private func addTextOverlay() {
        captionFocused = false
        let o = TextOverlay(center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        // Placed last, so text and stickers come forward over the ink. See `drawingOnTop`.
        drawingOnTop = false
        overlays.append(o)
        selectedID = o.id
        editingID = o.id   // open the editor immediately
        // THEIR `currentTextItem.isNewItem`. The continuity rule only applies to a text that has
        // never been placed: one the person has already dragged somewhere has a position they chose,
        // and moving it to wherever the editor happened to centre it would be taking that away.
        newOverlayID = o.id
    }

    /// A text overlay that has been created but never placed. See `addTextOverlay` and the geometry
    /// hand-back at the editor's call site.
    @State private var newOverlayID: UUID?

    /// WHERE THE EDITOR LEFT THE WORDS, TURNED INTO THE CANVAS'S OWN COORDINATES.
    ///
    /// Theirs, in `applyTextEdits`:
    ///
    ///     let locationInView = view.convert(textView.bounds.center, from: textView).clamp(view.bounds)
    ///     let textCenterImageUnit = ImageEditorCanvasView.locationImageUnit(forLocationInView: ...)
    ///     textItem = textItem.with(unitCenter: textCenterImageUnit)
    ///
    /// The point is measured on screen, expressed as a UNIT of the canvas, and written onto the item —
    /// so the canvas draws it where the editor was drawing it and there is nothing left to animate.
    /// That is the whole of their continuity: no matched geometry, no second motion, no timing.
    /// `clamp` is theirs too — a text dragged to the very edge of the editor must still land on the
    /// canvas.
    private func canvasCenter(fromScreen p: CGPoint) -> CGPoint? {
        guard cardRect.width > 1, cardRect.height > 1,
              canvasSize.width > 1, canvasSize.height > 1 else { return nil }
        let unitX = min(1, max(0, (p.x - cardRect.minX) / cardRect.width))
        let unitY = min(1, max(0, (p.y - cardRect.minY) / cardRect.height))
        return CGPoint(x: unitX * canvasSize.width, y: unitY * canvasSize.height)
    }

    // MARK: - Stickers

    /// The middle of the card, which is where every sticker starts. Nothing clever: it is the one
    /// place that is on screen whatever the picture is, and the first thing anybody does with a
    /// sticker is drag it somewhere else.
    private var canvasCentre: CGPoint {
        let s = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        return CGPoint(x: s.width / 2, y: s.height / 2)
    }

    /// A sticker chosen in the tray, placed.
    ///
    /// ⚠️ IT IS PLACED AS A STILL — see `StickerOverlay`. The tray animates, because a wall of frozen
    /// stickers is a worse tray; the canvas does not, because a story photo is a JPEG and a story
    /// clip is composited against one flat overlay, so an animation could not survive either export.
    /// The editor showing something the file cannot hold is the one thing this screen refuses to do.
    @MainActor private func addSticker(_ g: GiphyService.Gif) async {
        guard let image = await Self.stickerStill(g.url) else { return }
        let width = min(180, max(90, (canvasSize == .zero ? 390 : canvasSize.width) * 0.42))
        drawingOnTop = false
        stickers.append(StickerOverlay(image: image, center: canvasCentre, baseWidth: width))
    }

    /// The first frame of a sticker, from disk if it has ever been drawn before.
    ///
    /// `GifBytesCache` is the GIF picker's own store and it is deliberately shared: a sticker seen in
    /// the tray is already on this phone by the time it is tapped, so placing one usually costs no
    /// network at all.
    private static func stickerStill(_ url: String) async -> UIImage? {
        // ⛔ OURS FIRST, AND IT NEVER TOUCHES THE NETWORK. `sticker://` is not a real scheme — see
        // `BuiltInStickers` — so this has to come before anything that would treat the string as a
        // url. It is also why a built-in works in the recents tab with no extra code: recents store
        // the `Gif`, and both places that touch bytes ask this question.
        if let own = BuiltInStickers.image(url) { return own }
        if let data = GifBytesCache.data(url) { return firstFrame(data) }
        guard let u = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
        GifBytesCache.store(data, url)
        return firstFrame(data)
    }
    private static func firstFrame(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }

    /// A LINK OR A PLACE IS A STICKER TOO, and this is the line that makes it one: the chip is drawn
    /// once, here, into a `UIImage`, and from that moment the editor cannot tell it from a sticker
    /// off the tray. It moves with the same gesture, bakes with the same line and rides the same
    /// export. What is different about it is `action`, which nothing before the post ever reads.
    @MainActor private func chipSticker<C: View>(action: StickerAction?,
                                                 recipe: StickerOverlay.ChipRecipe? = nil,
                                                 @ViewBuilder _ chip: () -> C) {
        let r = ImageRenderer(content: chip())
        r.scale = 3        // it is text at sticker size; a 1x bake of that is a smudge
        r.isOpaque = false
        guard let img = r.uiImage else { return }
        drawingOnTop = false
        stickers.append(StickerOverlay(image: img, center: canvasCentre,
                                       baseWidth: img.size.width, action: action,
                                       chip: recipe))
    }

    /// ⚠️ THE NAME NEVER LEAVES THE PICTURE, AND THAT IS NOT A SHORTCUT. A chip is baked into the
    /// posted image, and what the story carries to the server is a tappable rectangle plus a URL
    /// (`StoryTapTarget`) — there is no label field on it and the reference app has none either: its
    /// own custom name exists only as pixels and in the local draft. So the name is spent here, on
    /// the bake, and nothing downstream has to learn a new word.
    @MainActor private func addLinkSticker(_ url: URL, name: String) {
        let text = StoryLinkSticker.label(for: url, name: name)
        chipSticker(action: .link(url), recipe: .init(symbol: "link", text: text)) {
            stickerChip(symbol: "link", text: text)
        }
        // The badge has just landed in the middle of somebody's picture with no explanation. See
        // `linkHintStickerID`.
        showLinkHint()
    }

    /// "Tap for more" over the badge that was just added, for five seconds.
    ///
    /// ⚠️ THE TIMER IS KEYED TO THE BADGE, NOT TO THE CLOCK. Adding a second link inside the five
    /// seconds moves the hint to the new one and the first badge's countdown must not then take the
    /// hint off the second — so the guard is "am I still the sticker that asked for this", which is
    /// a question about identity rather than about time.
    ///
    /// It only ever hides the WORDS. The badge is a real sticker and stays exactly where it landed.
    @MainActor private func showLinkHint() {
        guard let id = stickers.last?.id else { return }
        withAnimation(.smooth(duration: 0.25)) { linkHintStickerID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkHintSeconds) {
            guard linkHintStickerID == id else { return }
            withAnimation(.smooth(duration: 0.3)) { linkHintStickerID = nil }
        }
    }

    @MainActor private func addPlaceSticker(_ name: String, _ coord: CLLocationCoordinate2D) {
        let text = name.uppercased()
        chipSticker(action: .place(name: name, lat: coord.latitude, lon: coord.longitude),
                    recipe: .init(symbol: "mappin.and.ellipse", text: text)) {
            stickerChip(symbol: "mappin.and.ellipse", text: text)
        }
    }

    /// The time it is, stamped. ⚠️ `action: nil` — it is a picture, not a button, and that is the
    /// whole difference between it and the two above. It is also why it is a STILL of the clock at
    /// the moment it was placed rather than a live one: what posts is a photograph, so a ticking
    /// sticker could only ever be a lie about the file. The time somebody posted at is the useful
    /// fact anyway.
    ///
    /// ⚠️ IT STILL CARRIES A RECIPE, AND `action: nil` IS NOT THE TEST FOR THAT. His 2026-08-18
    /// follow-up: the clock cycles its colour on a tap like the other two. What a chip DOES when it
    /// is tapped in the viewer (`action`) and what it is MADE OF (`chip`) are two different
    /// questions, and only the second one decides whether the editor can re-bake it.
    @MainActor private func addTimeSticker() {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")   // 12- or 24-hour, per the phone's own setting
        let text = f.string(from: Date())
        chipSticker(action: nil, recipe: .init(symbol: "clock", text: text)) {
            stickerChip(symbol: "clock", text: text)
        }
    }

    /// Solid white with black on it, and that is a decision rather than a default: these two sit on
    /// somebody's photograph and have to be legible on a snowfield and in a night club alike. Glass
    /// takes its colour from what is behind it, which is exactly the wrong property here.
    /// ⚠️ THE SIZES BELOW WERE STEPPED UP ON 2026-08-22 ("default size link badge is small"). Measured
    /// off his screenshot before and after: the badge stood 123 × 34pt and now stands about 150 × 44,
    /// which puts it at the height iOS gives a control you are meant to hit.
    ///
    /// One set of numbers for all three chips, because a link, a place and a clock are one family and
    /// two of them at a different size would read as a mistake rather than as a choice. If only the
    /// link was meant to grow, that is a different shape and worth saying so.
    @ViewBuilder private func stickerChip(symbol: String, text: String,
                                          style: StoryChipStyle = .white) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold))
                // Only the chain takes a colour of its own, and only on a chip that IS a link —
                // `symbol` is the whole test, because it is the one thing that differs between a
                // link, a pin and a clock. See `StoryChipStyle.linkGlyph`.
                .foregroundStyle(symbol == "link" ? style.linkGlyph : style.ink)
            Text(text).font(.system(size: 18, weight: .bold)).lineLimit(1)
                .foregroundStyle(style.ink)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(style.background, in: Capsule())
    }

    /// Re-bake a chip in the next colour. ⚠️ THE PICTURE IS THE STICKER — a chip has been a flat
    /// `UIImage` since the day it was made one, so changing its colour is not a property write, it is
    /// the same render again with different paint. `chip` is the recipe kept for exactly this.
    @MainActor private func cycleChipColour(_ id: UUID) {
        guard let i = stickers.firstIndex(where: { $0.id == id }), let recipe = stickers[i].chip else { return }
        let next = stickers[i].chipStyle.next
        let r = ImageRenderer(content: stickerChip(symbol: recipe.symbol, text: recipe.text, style: next))
        r.scale = 3
        r.isOpaque = false
        guard let img = r.uiImage else { return }
        stickers[i].chipStyle = next
        stickers[i].image = img
        // ⚠️ AND THE WIDTH IS RE-READ, not kept. The three styles draw the same glyph at the same
        // size so it should not move a point — but `baseWidth` IS the sticker's size, and pinning it
        // to the first bake would silently stretch the picture if a style ever changed the padding.
        stickers[i].baseWidth = img.size.width
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func trimEmpty(_ id: UUID) {
        if let idx = overlays.firstIndex(where: { $0.id == id }),
           overlays[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlays.remove(at: idx); selectedID = nil
        }
    }

    // MARK: - Items

    /// Park the live tool state back on the item it belongs to. NOTHING IS FLATTENED: the picture is
    /// left as it came in and the edits are stored next to it, so coming back finds the crop still a
    /// crop you can change and the strokes still strokes you can undo.
    @MainActor private func stashCurrent() {
        guard items.indices.contains(index) else { return }
        items[index].cropped = croppedSource
        items[index].cropRect = cropRect
        items[index].filterIndex = filterIndex
        items[index].drawing = drawing
        items[index].overlays = overlays
        items[index].stickers = stickers
        items[index].zoom = photoZoom
        items[index].offset = photoOffset
        items[index].caption = caption
    }

    /// The mirror image: put an item's edits back on the tools.
    @MainActor private func restoreCurrent() {
        guard items.indices.contains(index) else { return }
        let it = items[index]
        croppedSource = it.cropped
        cropRect = it.cropRect
        filterIndex = it.filterIndex
        drawing = it.drawing
        overlays = it.overlays
        stickers = it.stickers
        caption = it.caption
        // ⚠️ RESOLVED ONCE, HERE, AND WRITTEN BACK. A zero is an item nobody has framed yet; from
        // this moment it has a number of its own and `defaultZoom` is never asked about it again.
        if it.zoom <= 0 {
            // ⚠️ PHOTOS ONLY, WHICH IS HIS SCOPE ("only in editor story image") AND THE CAUTIOUS
            // READING. On a clip the pinch is not a zoom at all, it is the transcoder's crop
            // rectangle (`videoBurnIn`), so a default one would silently centre-crop every portrait
            // video anybody posts. Their own rule does cover video; ours can be widened to it later
            // on his word, and not before.
            let z = it.isVideo ? 1 : defaultZoom(for: it.cropped ?? it.image)
            items[index].zoom = z
            photoZoom = z
        } else {
            photoZoom = it.zoom
        }
        photoOffset = it.offset
        selectedID = nil; editingID = nil
        recomputeEdited()
    }

    /// WHERE A PICTURE STARTS IN THE STORY FRAME — their rule, read off `VideoFinishPass.process`,
    /// which is the pass that puts the media on the story canvas:
    ///
    ///     if input.texture.height > input.texture.width {
    ///         baseScale = max(canvasSize.width / w, canvasSize.height / h)   // FILL
    ///     } else {
    ///         baseScale = canvasSize.width / w                               // fit the WIDTH
    ///     }
    ///
    /// So a TALLER-THAN-WIDE picture fills the frame and is centre-cropped, and a square or
    /// landscape one spans the full width with the gradient above and below it. Their `cropScale`
    /// starts at 1.0 and MULTIPLIES that base, which is why a pinch in their editor starts from the
    /// filled state rather than from a fitted one.
    ///
    /// Ours draws with `scaledToFit`, which is their width-fit for anything square or wider — that
    /// is why he reported 1:1 as already correct — and is a HEIGHT-fit for a tall picture, which is
    /// the case he reported. So the only thing missing was the multiplier for a portrait picture,
    /// and this is it: how much a fitted picture has to grow to cover the card.
    ///
    /// ⚠️ THE GRADIENT IS UNAFFECTED. It is sampled from the picture's own colours and drawn behind,
    /// so it is right at any scale; at a filling scale it simply stops being visible.
    /// ⚠️ AND THIS IS A DEFAULT, NOT A RULE THE PICTURE OBEYS. It is written into the item once and
    /// then belongs to the owner: a pinch, a crop, a 90° turn all leave their own number behind, and
    /// the upload reads that number.
    private func defaultZoom(for image: UIImage) -> CGFloat {
        let w = image.size.width, h = image.size.height
        guard w > 1, h > 1, h > w else { return 1 }   // square or landscape: their width fit
        // ⚠️ THE CARD'S ASPECT, WITH A CONSTANT BEHIND IT. Only the SHAPE of the frame matters here,
        // and this can be asked before the canvas has been measured — an unmeasured one would
        // resolve to 1 and, because the answer is written into the item and never asked again,
        // LOCK the picture at fitted. The card is 9:16 by design on every phone with the room for
        // it, so that is the fallback rather than a zero.
        let a = w / h
        let c: CGFloat = (canvasSize.width > 1 && canvasSize.height > 1)
            ? canvasSize.width / canvasSize.height
            : 9.0 / 16.0
        // `scaledToFit` already matched one axis; the fill is the ratio on the other.
        return max(1, a > c ? a / c : c / a)
    }

    private func select(_ i: Int) {
        guard i != index, items.indices.contains(i) else { return }
        // The player belongs to the clip you were on. Carrying it to the next item would leave a
        // video playing under somebody else's photo, with its audio still going.
        stopPreview()
        stashCurrent()
        index = i
        restoreCurrent()
    }

    /// ⚠️ `restoreCurrent()`, NOT `recomputeEdited()`. The same trap the two append paths fell into.
    ///
    /// The tools live OUTSIDE the items (croppedSource, cropRect, filterIndex, drawing, overlays,
    /// photoZoom, photoOffset). Deleting an item and only recomputing left the DELETED one's crop,
    /// filter, strokes, text and pinch sitting on the tools, wearing whichever item slid into its
    /// place, and `stashCurrent` at post time then wrote them onto that item for real. Delete a
    /// scribbled-on photo and the next one was posted carrying the scribble.
    ///
    /// The player goes too: it belonged to the item that just left, and `select(_:)` stops it for
    /// exactly this reason.
    private func remove(_ i: Int) {
        guard items.count > 1, items.indices.contains(i) else { return }
        stopPreview()
        items.remove(at: i)
        if index >= items.count { index = items.count - 1 }
        else if i < index { index -= 1 }
        restoreCurrent()   // ends in recomputeEdited()
    }

    /// Is there anything behind the X worth asking about? One untouched picture is not: there the X
    /// means "wrong photo", and a prompt would be in the way of the thing he is trying to do. A
    /// second item, a caption, or any edit at all IS, because none of it can be got back.
    ///
    /// Only the item on screen is checked for edits, and that is enough: with more than one item the
    /// first line has already answered, and with exactly one its edits are the live tool state.
    private var hasWork: Bool {
        if items.count > 1 { return true }
        if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        // …and one parked on an item that is not on screen. Only reachable with a single item, where
        // the live caption above has already answered — kept so the two cannot disagree if the
        // one-item shortcut at the top of this method ever changes.
        if items.contains(where: { !$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return true }
        if croppedSource != nil || cropRect != nil || filterIndex != 0 { return true }
        if !drawing.bounds.isEmpty || !overlays.isEmpty || !stickers.isEmpty { return true }
        if let it = items.first, it.isTrimmed || it.muted { return true }
        // ⚠️ MEASURED AGAINST THE ZOOM THIS SCREEN APPLIED ITSELF, NOT AGAINST 1 — his 2026-08-17
        // report: open a picture, touch nothing, tap X, and it asks whether to discard.
        //
        // `restoreCurrent` frames a portrait photo on arrival (`defaultZoom`, their fill rule), so a
        // picture that has never been touched sits at 1.35 or thereabouts before the screen has even
        // drawn. Asking `photoZoom > 1.001` therefore asked "is this picture taller than it is wide",
        // and for every such picture the X went through the prompt this method exists to skip.
        //
        // The baseline is recomputed rather than remembered because it is a pure function of the
        // picture and this asks it the same way `restoreCurrent` does. A crop or a filter has already
        // returned true above, so `cropped` here is the same input that answer was derived from.
        //
        // The post path is deliberately untouched: `videoBurnIn`'s own `reframed` test still counts a
        // default zoom as framing to burn in, because it IS the framing the picture is posted with.
        // The two questions are different — "what does this look like" and "did he do anything".
        let base = items.first.map { $0.isVideo ? 1 : defaultZoom(for: $0.cropped ?? $0.image) } ?? 1
        return abs(photoZoom - base) > 0.001
            || abs(photoOffset.width) > 0.5 || abs(photoOffset.height) > 0.5
    }

    private func closeEditor() {
        if hasWork { showDiscard = true } else { dismiss() }
    }

    // MARK: - Send
    private func send() async {
        stashCurrent()
        let keep = index

        // ⛔ THE SHEET GOES UP FIRST, EMPTY, AND THE PICTURE CATCHES IT UP (owner, 2026-08-21: "when
        // i click Next, share story sheet is coming late, feeling lag").
        //
        // Every item used to be rendered before this line — a `flatten` per photo, a burn-in per
        // video — and only then was the sheet allowed to appear. So the tap on Next bought a wait
        // with nothing on screen but a spinner where the word had been, and the wait grows with the
        // number of pictures in the post. The sheet does not draw the picture at all: it is an
        // audience list, a switch and a button, and none of them need a single byte.
        //
        // The payload's `id` is stable and `data` is a `var`, so filling it in below updates the
        // sheet in place. A fresh value would have a fresh id, which `.sheet(item:)` reads as a
        // different sheet — dismiss, present, and a worse flicker than the wait it replaced.
        //
        // ⚠️ POST STORY IS DISABLED UNTIL THE BYTES ARRIVE. `send` has always ended with
        // `guard !data.isEmpty`, and with the sheet up early that guard has to exist on the button
        // as well or a fast thumb posts a zero-byte story. See `ShareStorySheet.isPreparing`.
        pendingShare = StoryShareData(data: Data())
        pendingExtras = []

        // EVERY item is rendered HERE, at post time, from the edits stored beside it — which is what
        // being able to un-crop after switching costs: the work moves from "on the way out of an
        // item" to "once, when you actually post". `flatten` composes from the tool state rather
        // than from what is on screen, so restoring an item is enough to render it correctly.
        var rendered: [(data: Data, video: URL?, burn: StoryBurnIn?, muted: Bool,
                        trim: ClosedRange<Double>?, taps: [StoryTapTarget], caption: String)] = []
        for i in items.indices {
            index = i
            restoreCurrent()
            if let u = items[i].videoURL {
                // A VIDEO'S EDITS ARE NOT DISCARDED ANY MORE (owner 2026-08-04). Aa, crop and pen were
                // offered on a video and then silently dropped at post time, which is worse than not
                // offering them. They cannot be flattened into a picture, so they travel as far as the
                // export and are composited into the frames there — see VideoTranscoder.burnIn.
                let burn = await videoBurnIn()
                rendered.append((items[i].image.jpegData(compressionQuality: 0.72) ?? Data(), u, burn,
                                 items[i].muted, items[i].trimRange, tapTargets(crop: burn?.cropRect),
                                 items[i].caption.trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }
            rendered.append((await flatten(), nil, nil, false, nil, tapTargets(crop: nil),
                             items[i].caption.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        index = keep
        restoreCurrent()

        let data = rendered.first?.data ?? Data()
        // Never hand off a zero-byte (broken) image. The sheet is already up, so it comes down with
        // the error rather than the error arriving instead of it.
        guard !data.isEmpty else { pendingShare = nil; postError = true; return }

        var extras: [StoryExtra] = []
        for r in rendered.dropFirst() {
            if let u = r.video {
                extras.append(StoryExtra(video: StoryVideoPayload(url: u, thumbnail: r.data,
                                                                 muted: r.muted, trim: r.trim, burn: r.burn),
                                         stickers: r.taps, caption: r.caption))
            } else {
                extras.append(StoryExtra(photo: r.data, stickers: r.taps, caption: r.caption))
            }
        }
        // THE FIRST ITEM'S CLIP IS NO LONGER THROWN AWAY. `StoryShareData` carried only `data`, which
        // for a video is its poster, so a post whose first item was a video posted a still of it.
        // Reachable today: pick a photo, add a video, delete the photo with the X on the strip.
        let leadVideo = rendered.first.flatMap { r -> StoryVideoPayload? in
            guard let u = r.video else { return nil }
            return StoryVideoPayload(url: u, thumbnail: r.data, muted: r.muted, trim: r.trim, burn: r.burn)
        }
        // ⛔ FILLED IN, NOT REPLACED. The sheet has been on screen since before any of this ran; a
        // fresh `StoryShareData` would carry a fresh `id`, which `.sheet(item:)` reads as a different
        // sheet and answers by dismissing this one and presenting another. Mutating keeps the id.
        pendingShare?.data = data
        // The FIRST ITEM's caption, which is not necessarily the one in the pill: `send` walks every
        // item and leaves the tools on whichever was on screen.
        pendingShare?.caption = rendered.first?.caption ?? ""
        pendingShare?.video = leadVideo
        pendingShare?.stickers = rendered.first?.taps ?? []
        pendingExtras = extras
    }

    /// WHERE THE LINK AND PLACE STICKERS ARE, IN THE POSTED FRAME'S OWN TERMS — see `StoryTapTarget`.
    ///
    /// Plain stickers are not in here and never will be: they are already the picture, and a tap area
    /// over one would be a button that does nothing but swallow the tap that advances the story.
    ///
    /// ⚠️ `crop` IS NOT OPTIONAL DECORATION. A zoomed clip posts a PIECE of the canvas, so a sticker
    /// at the middle of the editor is not at the middle of the file. Projecting through the kept
    /// rectangle is the difference between a link you can tap and a link somewhere off the edge of
    /// the frame. Photos pass nil because `flatten` renders the whole canvas.
    private func tapTargets(crop: CGRect?) -> [StoryTapTarget] {
        let canvas = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        guard canvas.width > 1, canvas.height > 1 else { return [] }
        let keep = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard keep.width > 0.01, keep.height > 0.01 else { return [] }
        return stickers.compactMap { s -> StoryTapTarget? in
            guard let action = s.action else { return nil }
            let url: String
            switch action {
            case .link(let u):
                url = u.absoluteString
            case .place(let name, let lat, let lon):
                // Apple Maps, which every iPhone has and which hands off to whatever the person has
                // set as their maps app. `q` is what the pin is labelled; `ll` is where it is.
                var c = URLComponents(string: "https://maps.apple.com/")
                c?.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lon)"),
                                 URLQueryItem(name: "q", value: name)]
                guard let built = c?.url?.absoluteString else { return nil }
                url = built
            }
            let drawn = CGSize(width: s.drawnSize.width * s.scale, height: s.drawnSize.height * s.scale)
            // Canvas space → 0-1 of the canvas → 0-1 of the piece that was kept.
            let nx = (s.center.x / canvas.width - keep.minX) / keep.width
            let ny = (s.center.y / canvas.height - keep.minY) / keep.height
            let nw = (drawn.width / canvas.width) / keep.width
            let nh = (drawn.height / canvas.height) / keep.height
            // Cropped clean out of the posted frame — no tap area, rather than one nobody can reach.
            guard nx > -0.05, nx < 1.05, ny > -0.05, ny < 1.05 else { return nil }
            return StoryTapTarget(x: Double(nx), y: Double(ny), w: Double(nw), h: Double(nh),
                                  rotation: s.rotation.radians, url: url)
        }
    }

    /// Everything drawn on top of a VIDEO, in one transparent image the size of the canvas it was
    /// drawn on, plus the crop rectangle.
    ///
    /// Deliberately the same builder and the same transforms as `flatten` uses for a photo, so the two
    /// cannot drift apart and have text land in one place on a picture and another on a clip. What it
    /// does NOT draw is the picture itself — the frames are the picture, and painting the poster in
    /// would freeze the first frame over the whole video.
    @MainActor private func videoBurnIn() async -> StoryBurnIn? {
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        // THE PINCH IS THE VIDEO'S CROP TOOL. A zoomed/panned clip LOOKED reframed in here and
        // then uploaded with its original framing — photoZoom/photoOffset were never read on this
        // path, only the photo flatten's. That was the owner's report word for word: "the Story
        // displays the original, unedited frame." The zoom becomes the transcoder's crop rectangle
        // below, which is the mechanism it has always had for exactly this.
        let reframed = photoZoom > 1.001 || abs(photoOffset.width) > 0.5 || abs(photoOffset.height) > 0.5
        // ⚠️ SHRUNK IS NOT REFRAMED, AND IT CANNOT BE A CROP. A zoom in keeps a piece of the frame,
        // which a rectangle describes exactly; a zoom out is the clip drawn SMALLER with canvas
        // around it, and there is no rectangle inside the frame that says that. It travels as
        // `contentScale` instead, and the maths below is skipped for it — run on a scale under 1 it
        // resolves to the clip's own fitted rectangle, which is a crop that changes nothing, so the
        // zoom-out would have been quietly dropped between the editor and the file.
        let shrunk = photoZoom > 0 && photoZoom < 0.999
        // ⚠️ STICKERS COUNT AS ART. Left off this line a clip with nothing but a sticker on it takes
        // the untouched path and posts without it — the video half of the same trap `flatten`'s fast
        // path carries a note about.
        let hasArt = !drawing.bounds.isEmpty || !overlays.isEmpty || !stickers.isEmpty
        guard hasArt || cropRect != nil || reframed || shrunk else { return nil }

        var art: UIImage?
        if hasArt {
            let composed = ZStack(alignment: .bottom) {
                Color.clear
                // Stickers first, so a caption dropped on top of one still reads — the same order
                // the canvas and the photo flatten both use.
                ForEach(stickers) { s in
                    storyStickerImage(s)
                        .scaleEffect(s.scale)
                        .rotationEffect(s.rotation)
                        .position(s.center)
                }
                if !drawing.bounds.isEmpty {
                    // The SAME canvas the pen drew on — see `penCanvasSize`. Rendering a
                    // zoomed-out drawing from the card's rect would clip everything outside the
                    // picture, which is exactly the area that became drawable.
                    Image(uiImage: drawing.image(from: CGRect(origin: .zero,
                                                             size: Self.penCanvasSize(card: size, zoom: photoZoom)),
                                                 scale: UIScreen.main.scale))
                        .resizable()
                }
                ForEach(overlays) { o in
                    storyStyledText(o, maxWidth: size.width * 0.9)
                        .scaleEffect(o.scale)
                        .rotationEffect(o.rotation)
                        .position(o.center)
                }
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: composed)
            renderer.scale = UIScreen.main.scale
            renderer.isOpaque = false          // black here would hide the whole video behind it
            art = renderer.uiImage
        }

        var crop = cropRect   // legacy path: the tool that could set this is no longer offered on video
        if reframed, !shrunk {
            // The same maths the photo flatten uses, ending in the transcoder's terms. The export
            // canvas is geometrically similar to this card (same aspect travels below) and fits the
            // clip exactly as scaledToFit does, so the poster's fitted rect here IS the clip's
            // fitted rect there, normalised. The kept piece is the editor viewport, intersected
            // with the clip's own zoomed footprint — the black bands outside the picture are
            // cropped away, the same call the photo flatten already makes, so the viewer letterboxes
            // a reframed clip with its live blur exactly like an untouched one.
            let z = max(1, photoZoom)
            let fit = photoFitSize(in: size)
            let fitRect = CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2,
                                 width: fit.width, height: fit.height)
            let vRect = CGRect(x: size.width / 2 + photoOffset.width - fit.width * z / 2,
                               y: size.height / 2 + photoOffset.height - fit.height * z / 2,
                               width: fit.width * z, height: fit.height * z)
            let visible = vRect.intersection(CGRect(origin: .zero, size: size))
            if visible.width > 1, visible.height > 1 {
                // The viewport, mapped back onto the UNZOOMED clip inside the canvas.
                let inCanvas = CGRect(x: fitRect.minX + (visible.minX - vRect.minX) / z,
                                      y: fitRect.minY + (visible.minY - vRect.minY) / z,
                                      width: visible.width / z, height: visible.height / z)
                crop = CGRect(x: inCanvas.minX / size.width, y: inCanvas.minY / size.height,
                              width: inCanvas.width / size.width, height: inCanvas.height / size.height)
                // Text and pen were drawn over the ZOOMED clip, but the export paints them onto the
                // unzoomed canvas and then magnifies the kept rectangle. Re-project the art into
                // that rectangle so it comes back out exactly where — and exactly as big as — the
                // editor showed it. Without this, a caption on a zoomed clip drifted and doubled in
                // size on upload.
                if let a = art {
                    let fmt = UIGraphicsImageRendererFormat()
                    fmt.scale = a.scale; fmt.opaque = false
                    art = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
                        a.draw(in: inCanvas)
                    }
                }
            }
        }
        return StoryBurnIn(overlay: art, cropRect: crop,
                           canvasAspect: size.height > 0 ? size.width / size.height : nil,
                           contentScale: shrunk ? photoZoom : 1,
                           backdrop: shrunk ? canvasBackdrop(size: size) : nil,
                           // The Adjust tab's dial, carried with everything else the editor did.
                           brightness: items.indices.contains(index) ? items[index].brightness : 0)
    }

    /// The story's own canvas as a picture, for the export to put behind a clip that has been pinched
    /// smaller than the frame.
    ///
    /// ⚠️ THE SAME GRADIENT `flatten` BAKES AND THE SAME ONE THE VIEWER DRAWS, from the same two
    /// sampled colours through the same renderer. That is the one-sampler rule this screen lives by:
    /// a second way of drawing the same backdrop is a second answer to what colour it is, and the
    /// difference only ever shows up on somebody's phone.
    @MainActor private func canvasBackdrop(size: CGSize) -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let c = canvasColours
        let r = ImageRenderer(content:
            LinearGradient(colors: [Color(uiColor: c.top), Color(uiColor: c.bottom)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height))
        r.scale = 1   // it is a two-colour ramp; a retina copy of it is three times the memory for nothing
        return r.uiImage
    }

    @MainActor private func flatten() async -> Data {
        let base = edited
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        // THE FAST PATH IS NOW ALSO A "DOES IT FILL" TEST. Nothing to draw, nothing to type, no
        // zoom AND the photo already fills the frame → post it untouched at full resolution, which
        // keeps a 9:16 photo off the renderer and out of a re-encode.
        //
        // A photo that does NOT fill can no longer take that path, and that is the whole change on
        // this side: it goes through the composition below so the CANVAS IS BAKED INTO THE POSTED
        // FILE. The reference app exports every story as a full 1080x1920 frame with the gradient already in
        // it, which is why their viewer never has to invent a background and never gets it wrong.
        // Ours posted the bare photo and left the viewer to letterbox it live at watch time — that
        // live backdrop is the thing that tore while he scrolled, and a file that fills the frame
        // never asks for one.
        let zoomed = abs(photoZoom - 1) > 0.001 || abs(photoOffset.width) > 0.5 || abs(photoOffset.height) > 0.5
        // ⚠️ `stickers.isEmpty` BELONGS IN THIS TEST. The fast path posts the photo untouched, so
        // anything left off this line is a thing he placed and never sees again.
        if drawing.bounds.isEmpty && overlays.isEmpty && stickers.isEmpty && !zoomed && imageFillsCanvas(size) {
            return StoryPhoto.encode(base)
        }
        // BAKED AT THE CARD'S OWN SIZE, which is the space the pen drew in and the text overlays are
        // positioned in, so what he framed is byte-for-byte what lands. On every full-size phone the
        // card IS 9:16 and so is this file, which is the whole point — it fills a story frame and no
        // viewer ever has to invent a background for it.
        //
        // On a short phone the card is `min(9:16, the room there is)` and the file comes out
        // slightly squat, so a 9:16 viewer still draws a canvas behind it. That is fine, and it is
        // fine only because of the one-sampler rule: the canvas the viewer draws is the SAME
        // gradient from the SAME two colours this bake would have used, so the two are
        // indistinguishable. Forcing the file to 9:16 instead would buy nothing visible and would
        // cost this editor its WYSIWYG on exactly the devices with the least room to spare.
        let colours = canvasColours
        let composed = ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(uiColor: colours.top), Color(uiColor: colours.bottom)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height)
            // Foreground photo with the SAME fit + zoom + pan as the editor → WYSIWYG.
            Image(uiImage: base).resizable().scaledToFit()
                .scaleEffect(photoZoom).offset(photoOffset)
                .frame(width: size.width, height: size.height).clipped()
            // Stickers, in the same order the canvas draws them: above the photo, under the pen and
            // the text. Same builder (`storyStickerImage`) and same three transforms as on screen →
            // WYSIWYG, which is the whole contract of this function.
            ForEach(stickers) { s in
                // ⚠️ A CHIP GOES BACK TO BEING TYPE HERE, AND THAT IS THE WHOLE FIX FOR ITS BLUR
                // (owner 2026-08-22: "when i upload link link text quality is losing"). Everywhere
                // else a chip is a bitmap on purpose, but on this one pass it is being drawn into a
                // 1080-wide canvas, and a bitmap can only be stretched into that: it was baked at 3×
                // its own small size, then resampled to `drawnSize`, then resampled AGAIN by this
                // renderer — twice off its grid, and a fourth time over if the finger had pinched it
                // bigger, which is the case that actually looks broken.
                //
                // The recipe is what makes this possible and it is already kept for the colour
                // cycler, so nothing new is stored. Re-drawn from it, the words are glyphs again and
                // land at whatever resolution the canvas asks for. Geometry is unchanged: the live
                // chip's natural size is the size `baseWidth` was measured from in the first place.
                Group {
                    if let recipe = s.chip {
                        stickerChip(symbol: recipe.symbol, text: recipe.text, style: s.chipStyle)
                    } else {
                        storyStickerImage(s)
                    }
                }
                .scaleEffect(s.scale)
                .rotationEffect(s.rotation)
                .position(s.center)
            }
            .zIndex(drawingOnTop ? 1 : 3)
            // ⚠️ A `Group`, because a modifier cannot be attached to an `if` in a ViewBuilder —
            // "instance member 'zIndex' cannot be used on type 'View'". The wrapper is the one thing
            // that gives the branch a value to hang it on.
            Group {
            if !drawing.bounds.isEmpty {
                // ⚠️ THE PHOTO'S TRANSFORM, THE SAME TWO LINES IT CARRIES ABOVE. The pen layer is
                // anchored to the picture on screen now (see the note in `cardContent`), so leaving
                // it flat here would put the export and the editor back out of step — which is the
                // one thing this whole function exists to prevent. Rendered at the zoom's own scale
                // for the same reason the on-screen copy is.
                Image(uiImage: drawing.image(from: CGRect(origin: .zero,
                                                          size: Self.penCanvasSize(card: size, zoom: photoZoom)),
                                             scale: UIScreen.main.scale * max(1, photoZoom))).resizable()
                    .scaleEffect(photoZoom).offset(photoOffset)
                    .frame(width: size.width, height: size.height).clipped()
            }
            // The same flag the screen uses. The bake and the preview are two drawings of one
            // decision, and before this they disagreed: the screen put the ink over the text and
            // this put the text over the ink, so a posted story never looked like the one that was
            // composed. Whichever was touched last is on top, in both.
            }
            .zIndex(drawingOnTop ? 5 : 0)
            // Bake the text overlays — same builder + transforms as on-screen → WYSIWYG.
            ForEach(overlays) { o in
                storyStyledText(o, maxWidth: size.width * 0.9)
                    .scaleEffect(o.scale)
                    .rotationEffect(o.rotation)
                    .position(o.center)
            }
            .zIndex(drawingOnTop ? 2 : 4)
            // (Caption is NOT baked here — it's posted as text and drawn as an overlay.)
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed)
        // ⚠️ THE STORY CANVAS, NOT THE SCREEN'S SCALE. This was `UIScreen.main.scale`, so the
        // posted frame's size depended on which phone drew it, and then the upload capped whatever
        // came out at 1600px anyway. Asking the renderer for 1080 across makes 9:16 come out at
        // exactly 1080×1920 on every device — the size a story is posted at everywhere — and it is
        // free, because it is the same composition drawn at a different scale rather than a resample
        // afterwards. See `StoryPhoto`.
        r.scale = size.width > 0 ? StoryPhoto.canvasWidth / size.width : UIScreen.main.scale
        // The render is the story. There is no crop-back any more (see the note below), so the only
        // fallback left is the untouched photo, for a renderer that returned nothing at all.
        // ONE encode either way, through the ladder that answers for the byte budget.
        return r.uiImage.map { StoryPhoto.encode($0) } ?? StoryPhoto.encode(base)
    }

    // `flattenBackdrop` lived here: the photo aspect-filled into an eighth-size canvas and darkened
    // by 0.38, which is a blur by downscale. It is gone with the rest of the blur system. The posted
    // file's backdrop is `StoryCanvas`'s gradient now, drawn straight into the composition above
    // from the same two colours the editor card shows and the story viewer would draw.
    //
    // The CROP-BACK went with it, and that is the more important half. The bake used to be undone
    // for anything except a pinched-out photo: the canvas was rendered, then cut back to the
    // photo's own rectangle, so the posted file was the bare picture again and the viewer had to
    // invent a background for it at watch time. Every story now lands as a full frame, which is
    // the reference app's model and the reason their viewer has no backdrop code to go wrong.

    // The picture's aspect-fit size within the canvas — the photo frame's real footprint.
    private func photoFitSize(in canvas: CGSize) -> CGSize {
        let iw = edited.size.width, ih = edited.size.height
        guard iw > 0, ih > 0 else { return canvas }
        let s = min(canvas.width / iw, canvas.height / ih)
        return CGSize(width: iw * s, height: ih * s)
    }
    // Edge-to-edge photos keep the plain full-bleed canvas (no backdrop, no rounding).
    //
    // ⚠️ AT THE SIZE IT IS ACTUALLY DRAWN, WHICH INCLUDES THE PINCH. This asked whether the FITTED
    // picture covered the card and ignored `photoZoom` entirely, which was harmless only while the
    // zoom could not go below 1. It can now, so a 9:16 photo pinched smaller would have reported
    // itself as still filling the frame: no gradient in the editor, black around it — while
    // `flatten` takes the composed path for any zoom at all and bakes the gradient into the file.
    // The screen and the post would have disagreed about the one thing this editor promises.
    private func imageFillsCanvas(_ canvas: CGSize) -> Bool {
        let f = photoFitSize(in: canvas)
        let z = photoZoom > 0 ? photoZoom : 1        // 0 = an item nobody has framed yet
        return f.width * z >= canvas.width - 1 && f.height * z >= canvas.height - 1
    }

    // MARK: - Image ops
    private static func apply(_ filterName: String?, to image: UIImage) -> UIImage {
        guard let filterName, let ci = CIImage(image: image),
              let filter = CIFilter(name: filterName) else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let out = filter.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    // Sample the edited photo's top + bottom bands so the controls flip dark over a light region.
    private func updateIconContrast() {
        let img = edited
        topIconDark = Self.regionIsLight(img, top: true)
        bottomIconDark = Self.regionIsLight(img, top: false)
    }
    private static func regionIsLight(_ image: UIImage, top: Bool) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        let band = max(1, h / 4)
        let rect = top ? CGRect(x: 0, y: 0, width: w, height: band)
                       : CGRect(x: 0, y: h - band, width: w, height: band)
        guard let crop = cg.cropping(to: rect) else { return false }
        let ci = CIImage(cgImage: crop)
        guard let f = CIFilter(name: "CIAreaAverage",
                               parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return false }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let lum = 0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])
        return lum > 150   // light region → dark icons
    }
}

// MARK: - Text-on-photo overlay (modern style)

struct TextOverlay: Identifiable, Equatable {
    let id = UUID()
    var text: String = ""
    var center: CGPoint                 // in canvasSize coordinates → WYSIWYG with flatten
    var scale: CGFloat = 1
    var rotation: Angle = .zero
    var color: Color = .white
    /// WHERE `color` SITS ON THE PICKER'S SPECTRUM, 0 (black) to 1 (white).
    ///
    /// The reference app stores the same pair for the same stated reason: "so that we can consistently
    /// restore palette view state". A colour alone cannot put the thumb back — two points on the bar
    /// can resolve to nearly the same colour, and a caption reopened for editing has to find the
    /// control where it was left.
    var colorPhase: CGFloat = 1
    var alignment: TextAlignment = .center
    var font: FontStyle = .rounded
    var background: BgStyle = .plain
    var baseSize: CGFloat = 34

    enum FontStyle: String, CaseIterable, Equatable {
        case rounded, classic, serif, mono
        var design: Font.Design {
            switch self {
            case .rounded: return .rounded
            case .classic: return .default
            case .serif:   return .serif
            case .mono:    return .monospaced
            }
        }
    }
    enum BgStyle: String, CaseIterable, Equatable { case plain, semi, solid }
}

// Shared styled text — used BOTH on-screen and in flatten() so export == screen.
@ViewBuilder
/// THE INK THAT STAYS READABLE ON A SOLID BADGE OF THIS COLOUR — his 2026-08-16 report: black text
/// on a black badge is a black rectangle.
///
/// The badge is filled with the text's own colour, so the ink cannot also be that colour. It used to
/// be hardcoded to black, which is right for the light half of the palette and invisible for the
/// dark half — white on white worked only because white happens to be light.
///
/// Rec. 709 luminance, which weights green far above blue because the eye does: it is why pure blue
/// (0.07) takes white ink and pure green (0.72) takes black, and why a mid-grey threshold on the raw
/// channels would get both wrong. `getRed` fails on a non-RGB colour space, and black is the honest
/// answer there because it is what this has always returned.
func storyBadgeInk(on c: Color) -> Color {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a) else { return .black }
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.5 ? .black : .white
}

func storyStyledText(_ o: TextOverlay, maxWidth: CGFloat) -> some View {
    Text(o.text.isEmpty ? " " : o.text)
        .font(.system(size: o.baseSize, weight: .semibold, design: o.font.design))
        .multilineTextAlignment(o.alignment)
        .foregroundStyle(o.background == .solid ? storyBadgeInk(on: o.color) : o.color)
        .padding(.horizontal, o.background == .plain ? 6 : 14)
        .padding(.vertical, o.background == .plain ? 2 : 8)
        .background {
            switch o.background {
            case .plain: Color.clear
            case .semi:  RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
            case .solid: RoundedRectangle(cornerRadius: 10).fill(o.color)
            }
        }
        .shadow(color: .black.opacity(o.background == .plain ? 0.55 : 0), radius: 3, y: 1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: maxWidth)
}

// One draggable / pinchable / rotatable / tappable text overlay.
/// WHAT A STICKER DOES WHEN SOMEBODY TAPS IT IN THE VIEWER — nil for a plain one, which is most of
/// them. It is the only part of a sticker that has to survive being posted, because everything else
/// about it is already in the picture.
enum StickerAction: Equatable {
    case link(URL)
    case place(name: String, lat: Double, lon: Double)
}

/// A sticker on the canvas.
///
/// ⚠️ ONE TYPE FOR ALL THREE KINDS, AND THE ARTWORK IS ALWAYS A `UIImage`. A downloaded sticker
/// arrives as one; a Link or a Place chip is DRAWN to one the moment it is made. That is what keeps
/// the rest of this screen from growing a second of everything: one view draws them, one gesture
/// moves them, one line bakes them into the photo and the same line into a clip's burn-in. The
/// difference between a picture and a button is `action`, and nothing before the export reads it.
///
/// ⚠️ AND IT IS A STILL, INCLUDING FOR AN ANIMATED STICKER. A story photo is a JPEG and a story clip
/// is composited against one flat overlay image, so an animated sticker could not survive either
/// export. Showing the frame that will actually post is the WYSIWYG rule this screen is built on —
/// an editor that animates and a story that does not is a promise the file cannot keep.
struct StickerOverlay: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage
    var center: CGPoint                 // in canvasSize coordinates → WYSIWYG with flatten
    var scale: CGFloat = 1
    var rotation: Angle = .zero
    /// How wide it is drawn before the pinch, in canvas points. The height follows the artwork.
    var baseWidth: CGFloat = 150
    var action: StickerAction? = nil
    /// ⛔ WHAT THIS CHIP IS MADE OF, kept so it can be BAKED AGAIN in another colour — his 2026-08-18
    /// report: a white badge on a white picture cannot be read. Nil for a sticker off the tray, which
    /// is a picture somebody drew and has no colours of ours to cycle.
    struct ChipRecipe: Equatable { var symbol: String; var text: String }
    var chip: ChipRecipe? = nil
    /// White, black, blue, in that order, one tap apart. See `StoryChipStyle`.
    var chipStyle: StoryChipStyle = .white

    var drawnSize: CGSize {
        let s = image.size
        guard s.width > 1, s.height > 1 else { return CGSize(width: baseWidth, height: baseWidth) }
        return CGSize(width: baseWidth, height: baseWidth * s.height / s.width)
    }

    static func == (a: StickerOverlay, b: StickerOverlay) -> Bool {
        a.id == b.id && a.center == b.center && a.scale == b.scale
            && a.rotation == b.rotation && a.baseWidth == b.baseWidth
            // ⚠️ WITHOUT THIS THE TAP DOES NOTHING VISIBLE. The image is re-baked on a colour change
            // but `image` is not compared here (a `UIImage` compares by identity and would defeat the
            // diff), so equality has to notice the style or SwiftUI keeps drawing the old bake.
            && a.chipStyle == b.chipStyle
    }
}

/// ⛔ THE THREE COLOURS A LOCATION OR LINK BADGE CAN WEAR, and there are exactly three on his order:
/// "white background + black text, black background + white text, blue background + white text.
/// Each tap should switch to the next. Do not add a separate color picker or extra UI."
///
/// So there is no picker, no selected state and no handle: the badge IS the control, and the tap that
/// was doing nothing at all now does this. A drag still drags it, because the drag only begins after
/// two points of movement and a tap never travels that far.
///
/// Blue is `systemBlue`, which is what the NEXT button under it already wears, so a blue badge and
/// the blue button on the same screen are one blue rather than two.
enum StoryChipStyle: Int, Equatable {
    case white, black, blue

    var next: StoryChipStyle {
        switch self {
        case .white: return .black
        case .black: return .blue
        case .blue:  return .white
        }
    }

    var background: Color {
        switch self {
        case .white: return .white
        case .black: return .black
        case .blue:  return Color(.systemBlue)
        }
    }

    var ink: Color {
        switch self {
        case .white: return .black
        case .black, .blue: return .white
        }
    }

    /// THE CHAIN IS BLUE, THE WORDS ARE NOT (owner 2026-08-22: "link icon make it blue"). Only the
    /// link chip asks for this; a clock or a pin keeps one colour throughout, which is why this is a
    /// separate answer from `ink` rather than a change to it.
    ///
    /// Two blues, not one, because one of them would be unreadable on half the badges: the reference
    /// app's own link badge uses `#0a84ff` on its white card and the lighter `#64d2ff` on its black
    /// one. On our blue card there is no blue left to use, so the glyph keeps the ink.
    var linkGlyph: Color {
        switch self {
        case .white: return Color(red: 0x0a / 255, green: 0x84 / 255, blue: 0xff / 255)
        case .black: return Color(red: 0x64 / 255, green: 0xd2 / 255, blue: 0xff / 255)
        case .blue:  return ink
        }
    }
}

/// How much bigger than itself a placed sticker or caption is to the finger.
///
/// One number for both, because to the hand they are the same object — the same rule the two
/// gesture blocks already follow. 22 is a little over half Apple's 44pt minimum, applied on every
/// side, so the smallest chip on the canvas still clears 44 across while a sticker dropped beside
/// another does not swallow its neighbour's edge.
///
/// ⚠️ IT IS INSIDE THE TRANSFORMS, so it shrinks with a sticker the finger has pinched small. That is
/// deliberate: the alternative is a fixed halo that a sticker at 0.3 would be swimming in, and that
/// halo would cover whatever is next to it.
enum StoryOverlayTouch {
    static let pad: CGFloat = 22
}

/// Shared sticker drawing — used BOTH on-screen and in `flatten()`, so what is exported is what was
/// seen. Same contract as `storyStyledText` above it, for the same reason.
@ViewBuilder
func storyStickerImage(_ s: StickerOverlay) -> some View {
    Image(uiImage: s.image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: s.drawnSize.width, height: s.drawnSize.height)
}

/// The moving, pinching, turning half. Deliberately the same gestures, the same snap and the same
/// `0.3` floor as `TextOverlayView` — a sticker and a caption are the same object to the finger, and
/// two implementations of that would drift the moment one of them was tuned.
struct StickerOverlayView: View {
    @Binding var sticker: StickerOverlay
    let canvasSize: CGSize
    let interactive: Bool
    /// A tap on a CHIP cycles its colour. Nothing for a tray sticker, which has no recipe to re-bake.
    var onTapChip: () -> Void = {}
    var onDragChange: (CGPoint) -> Void
    var onDragEnd: (CGPoint) -> Void
    var onSnap: (Bool, Bool) -> Void
    /// Fired when the LAST finger leaves, whichever gesture it belonged to. See `touching`.
    var onRelease: () -> Void = {}

    @GestureState private var dragT: CGSize = .zero
    @GestureState private var gScale: CGFloat = 1
    @GestureState private var gRot: Angle = .zero

    private func snappedPure(_ p: CGPoint) -> CGPoint {
        let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
        var out = p
        if abs(p.x - cx) < t { out.x = cx }
        if abs(p.y - cy) < t { out.y = cy }
        return out
    }
    private var liveCenter: CGPoint {
        snappedPure(CGPoint(x: sticker.center.x + dragT.width, y: sticker.center.y + dragT.height))
    }

    /// THE TAP HAS TO LOOK LIKE IT LANDED (owner 2026-08-22: "there is almost no visual feedback").
    /// Multiplied into the live scale rather than replacing it, so a chip that has been pinched or
    /// turned dips from wherever it actually is.
    @State private var tapBounce: CGFloat = 1

    /// ⛔ TRUE WHILE ANY FINGER OF THE TRANSFORM IS DOWN, AND THE BIN'S ONLY TRUSTWORTHY SIGNAL
    /// (owner 2026-08-22: hold with one finger, pinch with a second, lift both, and the delete
    /// button stayed).
    ///
    /// The bin was driven by the DRAG's own `.onEnded`, and that callback is not promised: when a
    /// second finger lands, the pinch takes the sequence over and the drag can be cancelled rather
    /// than ended, so nothing ever said the finger had gone. `@GestureState` has no such gap —
    /// SwiftUI resets it to its initial value when the gesture finishes OR is cancelled, which is the
    /// one question being asked here.
    ///
    /// A tap never sets it: the drag needs two points of travel before the composed gesture produces
    /// a value at all, so `touching` stays false and nothing is released that was never held.
    @GestureState private var touching = false

    /// The reference app's own numbers, and it is a keyframe dip rather than a spring: scale runs
    /// `[s, s × 0.93, s]` at key times `[0, 0.33, 1]` over 0.30s, interpolated LINEARLY (their
    /// `animateKeyframes` sets `calculationMode = .linear`). Split at the key time, that is 0.099s
    /// down and 0.201s back — the asymmetry is what stops it reading as a wobble.
    ///
    /// ⚠️ NO HAPTIC HERE. Theirs fires none on this tap, and ours already buzzes inside
    /// `cycleChipColour` for the colour change; two on one tap is a stutter, not emphasis.
    private func bounce() {
        withAnimation(.linear(duration: 0.099)) { tapBounce = 0.93 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.099) {
            withAnimation(.linear(duration: 0.201)) { tapBounce = 1 }
        }
    }

    var body: some View {
        storyStickerImage(sticker)
            // ⛔ THIS IS ALSO WHY PINCHING A STICKER USED TO ZOOM THE PHOTOGRAPH (owner 2026-08-22).
            // Without a content shape a SwiftUI view is touchable only where it is actually PAINTED
            // — the sticker's opaque pixels, or for a caption the glyph run itself. A pinch puts two
            // fingers on opposite sides of the thing being pinched, which is exactly where there are
            // no pixels, so both touches fell past this view to the UIKit photo underneath and its
            // own `UIPinchGestureRecognizer` took them. One rectangle fixes the grabbing and the
            // zooming together, because they were never two problems.
            //
            // The pad rides inside the transforms on purpose: it is part of the sticker, so it turns
            // and scales with it and the grabbable area never sits crooked to the thing it belongs
            // to. See `StoryOverlayTouch.pad`.
            .padding(StoryOverlayTouch.pad)
            .contentShape(Rectangle())
            .scaleEffect(max(0.3, sticker.scale * gScale) * tapBounce)
            .rotationEffect(sticker.rotation + gRot)
            .position(liveCenter)
            .allowsHitTesting(interactive)
            .gesture(transform, including: interactive ? .all : .none)
            // Every route out of a gesture comes through here, including the ones that never call
            // `.onEnded`. See `touching`.
            .onChange(of: touching) { _, down in if !down { onRelease() } }
            // ⚠️ AFTER the drag, and it does not fight it: `DragGesture(minimumDistance: 2)` never
            // begins for a finger that does not move, so a tap falls through to here. Only a chip
            // answers — a picture off the tray has no colours of ours to cycle.
            .onTapGesture { if sticker.chip != nil { bounce(); onTapChip() } }
    }

    private var transform: some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .updating($dragT) { v, s, _ in s = v.translation }
            .onChanged { v in
                let raw = CGPoint(x: sticker.center.x + v.translation.width,
                                  y: sticker.center.y + v.translation.height)
                let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
                onSnap(abs(raw.x - cx) < t, abs(raw.y - cy) < t)
                // The finger, for the same reason and by the same rule as a caption's — one bin,
                // one question, one kind of answer. It is not optional here: the bin's hit area is
                // the control itself now, and a sticker still reporting its own centre would be
                // nearly impossible to drop on it.
                onDragChange(v.location)
            }
            .onEnded { v in
                let nc = snappedPure(CGPoint(x: sticker.center.x + v.translation.width,
                                             y: sticker.center.y + v.translation.height))
                sticker.center = nc
                onDragEnd(v.location)
            }
        let mag = MagnifyGesture()
            .updating($gScale) { v, s, _ in s = v.magnification }
            .onEnded { v in sticker.scale = max(0.3, sticker.scale * v.magnification) }
        let rot = RotateGesture()
            .updating($gRot) { v, s, _ in s = v.rotation }
            .onEnded { v in sticker.rotation += v.rotation }
        return SimultaneousGesture(drag, SimultaneousGesture(mag, rot))
            // ⛔ THE ONLY HONEST ANSWER TO "IS A FINGER STILL ON THIS" — see `touching`.
            .updating($touching) { _, s, _ in s = true }
    }
}

struct TextOverlayView: View {
    @Binding var overlay: TextOverlay
    let isSelected: Bool
    let canvasSize: CGSize
    let interactive: Bool
    var onTap: () -> Void
    /// ⚠️ THE FINGER'S POSITION, NOT THE TEXT'S CENTRE. The caller asks one question of this point —
    /// "is it on the bin" — and answering it with the text's centre made the whole bottom of the
    /// picture delete on contact (his 2026-08-16 report). The text's own position is not the
    /// caller's business: this view writes it to the binding itself.
    var onDragChange: (CGPoint) -> Void
    var onDragEnd: (CGPoint) -> Void
    var onSnap: (Bool, Bool) -> Void
    /// Fired when the LAST finger leaves, whichever gesture it belonged to. See `touching`.
    var onRelease: () -> Void = {}

    @GestureState private var dragT: CGSize = .zero
    @GestureState private var gScale: CGFloat = 1
    @GestureState private var gRot: Angle = .zero
    /// Same flag, same reason as `StickerOverlayView.touching`: a drag whose sequence a pinch
    /// took over may be cancelled rather than ended, so `.onEnded` cannot be the thing that puts
    /// the bin away. Gesture state resets on both paths.
    @GestureState private var touching = false

    private func snappedPure(_ p: CGPoint) -> CGPoint {
        let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
        var out = p
        if abs(p.x - cx) < t { out.x = cx }
        if abs(p.y - cy) < t { out.y = cy }
        return out
    }
    private var liveCenter: CGPoint {
        snappedPure(CGPoint(x: overlay.center.x + dragT.width, y: overlay.center.y + dragT.height))
    }
    private var liveScale: CGFloat { max(0.3, overlay.scale * gScale) }
    private var liveRot: Angle { overlay.rotation + gRot }

    var body: some View {
        storyStyledText(overlay, maxWidth: canvasSize.width * 0.9)
            // The caption's version of the same rectangle — see the long note in `StickerOverlayView`.
            // Text is the worse of the two cases: a glyph run is mostly holes, so even a one-finger
            // drag missed between the letters.
            .padding(StoryOverlayTouch.pad)
            .contentShape(Rectangle())
            .scaleEffect(liveScale)
            .rotationEffect(liveRot)
            // (No dashed selection border — removed per request; the text just shows plainly while editing.)
            .position(liveCenter)
            .allowsHitTesting(interactive)
            .highPriorityGesture(TapGesture().onEnded { onTap() })
            .gesture(transform, including: interactive ? .all : .none)
            // Every route out of a gesture comes through here, including the ones that never call
            // `.onEnded`. See `touching`.
            .onChange(of: touching) { _, down in if !down { onRelease() } }
    }

    private var transform: some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .updating($dragT) { v, s, _ in s = v.translation }
            .onChanged { v in
                let raw = CGPoint(x: overlay.center.x + v.translation.width, y: overlay.center.y + v.translation.height)
                let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
                onSnap(abs(raw.x - cx) < t, abs(raw.y - cy) < t)
                // The finger, in the canvas's own space — the bin is placed in that space too, so
                // the two are directly comparable.
                onDragChange(v.location)
            }
            .onEnded { v in
                let nc = snappedPure(CGPoint(x: overlay.center.x + v.translation.width, y: overlay.center.y + v.translation.height))
                overlay.center = nc
                onDragEnd(v.location)
            }
        let mag = MagnifyGesture()
            .updating($gScale) { v, s, _ in s = v.magnification }
            .onEnded { v in overlay.scale = max(0.3, overlay.scale * v.magnification) }
        let rot = RotateGesture()
            .updating($gRot) { v, s, _ in s = v.rotation }
            .onEnded { v in overlay.rotation += v.rotation }
        return SimultaneousGesture(drag, SimultaneousGesture(mag, rot))
            // ⛔ THE ONLY HONEST ANSWER TO "IS A FINGER STILL ON THIS" — see `touching`.
            .updating($touching) { _, s, _ in s = true }
    }
}

// ⚠️ `TextEditorOverlay` IS DELETED, AND THE DELETION IS THE FIX rather than a tidy-up.
//
// It was a SwiftUI screen that tried to reach three UIKit mechanisms through SwiftUI doors: a
// keyboard toolbar for the controls, automatic keyboard avoidance for the centring, and a timer for
// the hand-back. Each door is a near-miss, and the near-misses are exactly his six reports — the bar
// that never appeared, the words that were not centred, the block that moved after Done.
//
// The replacement is `StoryTextToolEditor.swift`, which is the reference app's own editor: an
// `inputAccessoryView` for the bar, `keyboardLayoutGuide` for the editing area, and
// `resignFirstResponder` for Done. Its header holds all four mechanisms and where each was read from.

// Springy press feedback for the story-editor controls.
/// An AVPlayerLayer sized to its view. Deliberately tiny: the composer needs to SEE the clip, and a
/// full `AVPlayerViewController` would bring its own controls, its own gestures and its own idea of
/// full screen to a canvas that already has three tools competing for the same touches.
struct ClipPreviewLayer: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .clear
        v.playerLayer.videoGravity = .resizeAspect   // the poster underneath is aspect-fit too
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// ⛔ THE TRIM PLAYHEAD, HELD OUTSIDE THE EDITOR'S OWN STATE. Read the long note on
/// `StoryEditorView.trimPlayhead` before moving it back.
///
/// One number, written twenty times a second by the player's periodic observer while a clip is
/// playing. Held here, in a class, only the view that observes it re-renders on that clock.
final class TrimPlayheadBox: ObservableObject {
    @Published var seconds: Double = 0
}

/// The trim strip, and the only view in the app that re-renders on the playhead's 20Hz.
///
/// It exists purely to put an `@ObservedObject` somewhere small. `VideoTrimStrip` itself is shared
/// with the video editor and with the chat's media approval and takes a plain `Binding<Double>` —
/// his standing instruction is that there is one trim system and it is not to be forked — so the box
/// is unwrapped here, one level above it, instead of being pushed down into it.
struct TrimStripHost: View {
    @ObservedObject var playhead: TrimPlayheadBox
    let duration: Double
    let thumbnails: [UIImage]
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var scrubTime: Double?
    @Binding var playing: Bool
    @Binding var draggingPlayhead: Bool

    var body: some View {
        VideoTrimStrip(duration: duration, thumbnails: thumbnails,
                       trimStart: $trimStart, trimEnd: $trimEnd,
                       playhead: $playhead.seconds, scrubTime: $scrubTime,
                       playing: $playing, draggingPlayhead: $draggingPlayhead)
    }
}

struct StoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// Smooth editor zoom/pan: a UIImageView pinned to fill the container (Auto Layout) whose layer TRANSFORM
// is updated DIRECTLY inside the gesture handlers — no SwiftUI @State write per touch, so there is no body
// re-render mid-pinch (that re-render is what caused the violent shake). Pinch + pan recognize together and
// accumulate-then-reset; the pinch anchors between the fingers. On release it springs to the clamped value
// and syncs the final scale/offset back to the bindings so the WYSIWYG flatten matches exactly.
/// The photo's transform as it happens, for anything that must ride ON TOP of the picture rather
/// than inside it.
///
/// ⚠️ WHY THIS EXISTS AT ALL, because the obvious answer is wrong twice over. The picture is
/// pinched by writing a `CGAffineTransform` straight onto a UIView, and `photoZoom`/`photoOffset` are
/// only written back when the fingers COME OFF — a SwiftUI state write per touch re-renders this
/// whole screen and shakes the gesture. So anything drawn as a SwiftUI sibling with
/// `.scaleEffect(photoZoom)` is not merely late, it does not move at ALL until the gesture ends and
/// then jumps to its new place. That is his 2026-08-19 report about the pen, word for word, and it is
/// the same report the video gave in August.
///
/// The video was fixed by moving it INSIDE the zoom view, under the one transform. The pen cannot go
/// there: it is drawn above the stickers and below the text, and `flatten` bakes it in that order.
/// Moving it inside the picture's own view would put it under the stickers on screen and over them in
/// the export, and the two disagreeing is the one thing this editor refuses to do.
///
/// So the transform is relayed instead. No `@Published`, no `ObservableObject`, nothing SwiftUI
/// observes: the coordinator hands each frame's numbers to a closure that writes a `transform` onto
/// one UIView. Same idea as `TrimPlayheadBox` above — a class in `@State` so the reference is held
/// and nothing re-renders.
final class PhotoTransformRelay {
    /// Set by whoever is riding along. Called on every frame of the gesture, on the main thread.
    var apply: ((CGFloat, CGSize) -> Void)?

    /// ⛔ AND THE OTHER DIRECTION, WHICH IS WHAT LETS THE PEN PAGE ZOOM (owner 2026-08-22: "in the pen
    /// page I can't zoom the image").
    ///
    /// The photo's pinch and pan live on the photo's own container, and while the pen is open the
    /// PencilKit canvas covers it. Gesture recognisers only ever see touches delivered to their own
    /// view or its descendants, and the canvas is a SIBLING — so the photo's recognisers were not
    /// being refused the pinch, they were never offered it. Enabling them would have changed nothing.
    ///
    /// So the canvas grows its own two-finger recognisers and hands them to the photo's coordinator
    /// through here. The photo keeps ALL the arithmetic — clamping, limits, the spring on release —
    /// and there is no second implementation of any of it to drift. `UIGestureRecognizer` reports
    /// scale and translation relative to whichever view it is asked about, so a recogniser living on
    /// the canvas answers the photo's questions exactly as the photo's own would.
    var drivePinch: ((UIPinchGestureRecognizer) -> Void)?
    var drivePan: ((UIPanGestureRecognizer) -> Void)?
    /// The last transform published, so a rider that appears mid-gesture starts in the right place.
    private(set) var last: (scale: CGFloat, offset: CGSize) = (1, .zero)

    func publish(scale: CGFloat, offset: CGSize) {
        last = (scale, offset)
        apply?(scale, offset)
    }
}

/// A still image that wears the photo's transform frame by frame, through `PhotoTransformRelay`.
///
/// The transform is written inside a `CATransaction` with actions disabled: without it every write
/// during a pinch starts CoreAnimation's own quarter-second implicit animation, and the layer chases
/// the fingers a beat behind instead of tracking them — which would trade one lag for another.
struct LiveTransformImage: UIViewRepresentable {
    let image: UIImage
    let relay: PhotoTransformRelay
    /// The committed transform, for the frames that are not part of a gesture.
    let scale: CGFloat
    let offset: CGSize

    /// ⛔ A PLAIN CONTAINER, AND THE TRANSFORM GOES ON THE VIEW INSIDE IT. READ THIS BEFORE
    /// FLATTENING THIS BACK INTO ONE VIEW.
    ///
    /// SwiftUI owns the frame of whatever `makeUIView` returns and writes it on every layout pass.
    /// UIKit says the frame is undefined while a transform is not the identity — setting it rewrites
    /// the view's BOUNDS to `frame.size / scale`. So when the image view was itself the root, the
    /// card-sized drawing was painted into bounds of `card / photoZoom` and the transform scaled it
    /// back out by the same factor: the two cancelled, and the pen layer rendered at 1x no matter
    /// what the zoom was. The live canvas uses a SwiftUI `.scaleEffect`, which is immune, and both
    /// export paths apply the zoom themselves — so the post-Done preview was the only surface
    /// disagreeing, which is exactly the owner's "in the pen page and after Done it shows
    /// different", strokes a third of the size and thrown up and to the left. The shift is not about
    /// the card's centre: cancelling the zoom scales about the pinch's own anchor, `centre + offset`.
    ///
    /// `ZoomableImageView` below has always done it this way — container out, Auto Layout inside,
    /// transform on the inner view — which is why the photograph never had this bug and the pen did.
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .clear
        box.isUserInteractionEnabled = false
        let v = UIImageView(image: image)
        // ⚠️ `.scaleToFill`, WHICH IS WHAT `.resizable()` MEANT. The layer this replaced was
        // `Image(uiImage:).resizable().frame(card)`, and resizable stretches the picture to the frame
        // it is given whatever its own point size is. `.scaleAspectFit` does NOT: the raster comes
        // back at the zoom's own point size, and fitting would shrink and re-centre it inside the
        // frame. The drawing is rendered from a rect that IS the card, so its aspect already matches
        // and filling distorts nothing. There is no case where fitting is the right answer here.
        v.contentMode = .scaleToFill
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        // Pinned, not framed: Auto Layout writes bounds and centre, neither of which a transform
        // makes undefined. This is the whole reason the inner view can be trusted to keep its scale.
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        context.coordinator.image = v
        arm(context.coordinator)
        Self.apply(scale: scale, offset: offset, to: v)
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {
        guard let v = context.coordinator.image else { return }
        if v.image !== image { v.image = image }
        // Re-arm on every update: a rebuilt representable leaves the old closure holding a dead view.
        arm(context.coordinator)
        Self.apply(scale: scale, offset: offset, to: v)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var image: UIImageView?
    }

    /// ⚠️ THE CLOSURE MUST NOT CAPTURE `self`. The relay is a class this struct holds strongly, so a
    /// closure that captured the struct to reach an instance method would close the loop: relay →
    /// closure → struct → relay. `apply` is static for that reason alone.
    private func arm(_ c: Coordinator) {
        relay.apply = { [weak c] s, o in
            guard let v = c?.image else { return }
            LiveTransformImage.apply(scale: s, offset: o, to: v)
        }
    }

    /// The transform is written inside a `CATransaction` with actions disabled: without it every
    /// write during a pinch starts CoreAnimation's own quarter-second implicit animation, and the
    /// layer chases the fingers a beat behind instead of tracking them — which would trade one lag
    /// for another.
    private static func apply(scale s: CGFloat, offset o: CGSize, to v: UIImageView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.transform = CGAffineTransform(translationX: o.width, y: o.height).scaledBy(x: s, y: s)
        CATransaction.commit()
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// ⚠️ THE CLIP RIDES INSIDE THIS VIEW, IT IS NOT A LAYER OVER IT — his 2026-08-16 report, "the
    /// video does not properly follow my fingers during the pinch".
    ///
    /// The `AVPlayerLayer` used to be a SwiftUI sibling wearing `.scaleEffect(photoZoom)`, and
    /// photoZoom is only written on RELEASE — the whole reason the pinch is done in UIKit is that a
    /// SwiftUI state write per touch re-renders the screen and shakes. So the poster underneath
    /// followed the fingers and the moving picture on top of it did not move at all, then jumped to
    /// its new size when the fingers came off. Two pictures of the same clip disagreeing for the
    /// length of every gesture.
    ///
    /// Here they are one view with one transform, so a clip is framed exactly like a photograph and
    /// there is nothing left to keep in step.
    var player: AVPlayer? = nil
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    var maxScale: CGFloat = 4
    /// ⚠️ BELOW 1 IS A REAL FRAMING, NOT A BOUNCE — his 2026-08-16 report: "zoom out only works
    /// after I have already zoomed in… I cannot zoom out from the default state."
    ///
    /// 1 is the picture FITTED, so a floor of 1 means the only way to shrink anything was to undo a
    /// zoom you had already made, and from the default state a pinch-out was simply dead. Below it
    /// the media sits smaller on the story's own gradient, which is a composition both this editor
    /// and the export can already draw.
    var minScale: CGFloat = 0.4
    var interactive: Bool = true
    /// Anything riding on top of the picture gets each frame of the gesture through this. Declared
    /// HERE rather than beside the closures: Swift requires call-site order to match declaration
    /// order, and it reads better before two multi-line closures than wedged between them.
    /// See `PhotoTransformRelay`.
    var relay: PhotoTransformRelay? = nil
    var onTap: () -> Void = {}
    /// SWIPE TO THE NEXT PICTURE, +1 forward and -1 back (owner 2026-08-04: "when i swipe touching
    /// screen nothing happens… it most work swipe to next image").
    ///
    /// It belongs HERE and not on a SwiftUI gesture over the top, because this view's own pan
    /// recogniser is what was eating the swipe. Nothing to do with the strip.
    var onSwipe: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = false
        iv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iv.topAnchor.constraint(equalTo: container.topAnchor),
            iv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // The clip, over its own poster, in the SAME container and under the SAME transform. Both
        // are aspect-fit into the card, so the moving picture lands exactly on the still one.
        // A view-backed layer on purpose (`layerClass`), not a bare sublayer: UIKit turns implicit
        // animations off for those, and a loose AVPlayerLayer would quarter-second-lag every frame
        // of the pinch behind the poster it is supposed to be sitting on.
        let clip = ClipPreviewLayer.LayerView()
        clip.backgroundColor = .clear
        clip.playerLayer.videoGravity = .resizeAspect
        clip.isUserInteractionEnabled = false
        clip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clip)
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            clip.topAnchor.constraint(equalTo: container.topAnchor),
            clip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        clip.playerLayer.player = player
        clip.isHidden = player == nil

        context.coordinator.container = container
        context.coordinator.imageView = iv
        context.coordinator.clipView = clip
        // The pen page's canvas covers this view and takes the touches, so it grows its own two-finger
        // recognisers and calls straight into these. See `PhotoTransformRelay.drivePinch`.
        relay?.drivePinch = { [weak c = context.coordinator] g in c?.handlePinch(g) }
        relay?.drivePan = { [weak c = context.coordinator] g in c?.handlePan(g) }

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        // ⚠️ TWO FINGERS OR IT IS NOT A PAN — owner 2026-08-16, and it is one line because the
        // recogniser already had the ceiling and was only ever missing the floor.
        //
        // Framing a photo is a TWO-FINGER job in every mainstream photo and story editor: the
        // fingers that set the scale are the fingers that set the position, so the two halves of
        // one framing decision are made in one motion. A one-finger drag over the picture means
        // nothing there, and it must mean nothing here — it was the sole reason a picture could
        // slide off its own framing while somebody was just resting a thumb on it or reaching for
        // the strip.
        //
        // It also frees the one finger for what this card already gives it: a tap (play, and
        // dismissing the caption) and a flick (the next picture in the post, `handleSwipe`).
        // Those two are one-touch recognisers, so with the floor at 2 the pan can no longer
        // out-race them for a drag it should never have claimed.
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        // Left and right flicks, the same recogniser another mainstream messenger's camera uses to change mode. A discrete
        // swipe, so it can never fight the pinch or the pan for the picture itself.
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipeLeft.direction = .left
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipeRight.direction = .right
        for g in [pinch, pan, tap, swipeLeft, swipeRight] as [UIGestureRecognizer] {
            g.delegate = context.coordinator; container.addGestureRecognizer(g)
        }
        context.coordinator.pinch = pinch; context.coordinator.pan = pan
        return container
    }

    func updateUIView(_ v: UIView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.imageView?.image !== image { c.imageView?.image = image }
        if c.clipView?.playerLayer.player !== player { c.clipView?.playerLayer.player = player }
        // Hidden rather than removed: a photo item has no clip and must not have an empty player
        // layer sitting over its picture, but the view stays so the constraints never rebuild.
        c.clipView?.isHidden = player == nil
        c.pinch?.isEnabled = interactive
        c.pan?.isEnabled = interactive
        if !c.active {   // adopt external scale/offset (e.g. a reset) only when not mid-gesture
            // ⚠️ ONLY WHEN IT HAS ACTUALLY MOVED, AND THIS IS THE OTHER HALF OF THE VIDEO FREEZE.
            //
            // `applyTransform` writes `transform` onto the view whose layer IS the `AVPlayerLayer`.
            // This ran on every single `updateUIView`, which is every single body evaluation of a
            // screen that has plenty of reasons to evaluate — and while a clip is playing it had
            // twenty a second. Rewriting a layer's transform to the value it already holds is not
            // free: CoreAnimation re-evaluates it, and any write that lands inside an animation
            // transaction (a page change is one, for 0.28s) starts an implicit animation on the
            // layer showing the video.
            //
            // `appliedOnce` rather than trusting the initial values to differ: the first pass often
            // matches what the coordinator was built with, and skipping THAT one would leave a
            // reframed picture at 1.0 until something else moved it.
            let newOffset = CGPoint(x: offset.width, y: offset.height)
            let moved = !c.appliedOnce || c.curScale != scale || c.curOffset != newOffset
            c.curScale = scale
            c.curOffset = newOffset
            if moved { c.appliedOnce = true; c.applyTransform() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ZoomableImageView
        weak var container: UIView?
        weak var imageView: UIImageView?
        weak var clipView: ClipPreviewLayer.LayerView?
        var pinch: UIPinchGestureRecognizer?
        var pan: UIPanGestureRecognizer?
        var curScale: CGFloat
        var curOffset: CGPoint
        var active = false
        /// Has the seat been written to the layers at least once? See `updateUIView`.
        var appliedOnce = false

        init(_ p: ZoomableImageView) {
            parent = p
            curScale = p.scale
            curOffset = CGPoint(x: p.offset.width, y: p.offset.height)
        }

        func applyTransform() {
            let t = CGAffineTransform(translationX: curOffset.x, y: curOffset.y).scaledBy(x: curScale, y: curScale)
            imageView?.transform = t
            clipView?.transform = t
            // ...and everything riding on top of the picture, in the same frame. See PhotoTransformRelay.
            parent.relay?.publish(scale: curScale, offset: CGSize(width: curOffset.x, height: curOffset.y))
        }

        private func clampOffset() {
            guard let c = container, let img = imageView?.image else { return }
            let b = c.bounds.size
            guard b.width > 1, img.size.width > 1 else { return }
            let fitScale = min(b.width / img.size.width, b.height / img.size.height)
            let fit = CGSize(width: img.size.width * fitScale, height: img.size.height * fitScale)
            let maxX = max(0, (fit.width * curScale - b.width) / 2)
            let maxY = max(0, (fit.height * curScale - b.height) / 2)
            curOffset.x = min(maxX, max(-maxX, curOffset.x))
            curOffset.y = min(maxY, max(-maxY, curOffset.y))
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: active = true
            case .changed:
                curScale = min(parent.maxScale * 1.15, max(parent.minScale * 0.9, curScale * g.scale))
                g.scale = 1
                applyTransform()   // direct transform — no SwiftUI write, no re-render, no shake
            case .ended, .cancelled:
                active = false
                curScale = min(parent.maxScale, max(parent.minScale, curScale))
                clampOffset()
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3,
                               options: [.allowUserInteraction]) { self.applyTransform() }
                parent.scale = curScale
                parent.offset = CGSize(width: curOffset.x, height: curOffset.y)
            default: break
            }
        }
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began: active = true
            case .changed:
                let t = g.translation(in: container)
                g.setTranslation(.zero, in: container)
                // A FITTED PICTURE HAS NOWHERE TO GO — and that is decided HERE, not by refusing to
                // begin. It used to be a `gestureRecognizerShouldBegin` gate, and once the pan needs
                // two fingers that gate turns into a bug: a two-finger motion that starts as a drag
                // and becomes a pinch would have had the pan marked FAILED for the whole sequence
                // before the zoom arrived, so the fingers that just zoomed in could not then move
                // the picture without lifting off. Refusing the movement instead of refusing the
                // gesture leaves the pan alive and waiting for the scale to cross.
                //
                // The translation is taken and thrown away above the guard on purpose: without
                // that, everything the fingers travelled while still at 1x would be banked and
                // land in one jump the instant the pinch crossed.
                guard curScale > 1.01 else { break }
                curOffset.x += t.x; curOffset.y += t.y
                applyTransform()
            case .ended, .cancelled:
                active = false
                clampOffset()
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3,
                               options: [.allowUserInteraction]) { self.applyTransform() }
                parent.offset = CGSize(width: curOffset.x, height: curOffset.y)
            default: break
            }
        }
        @objc func handleTap(_ g: UITapGestureRecognizer) { parent.onTap() }

        @objc func handleSwipe(_ g: UISwipeGestureRecognizer) {
            parent.onSwipe(g.direction == .left ? 1 : -1)
        }

        // THE PAN USED TO REFUSE TO BEGIN BELOW 1.01x (`gestureRecognizerShouldBegin`), because it
        // was live at every zoom level on ONE finger and so ate the sideways flick to the next
        // picture. The two-finger floor in `makeUIView` is a better answer to that same problem —
        // the flick is one touch and the pan can no longer see it at all — and the old gate would
        // now cost more than it saves, so the "is there anything to move" question moved into
        // `handlePan`'s `.changed`. See the note there.

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            !(g is UITapGestureRecognizer || o is UITapGestureRecognizer)
        }
    }
}

// PencilKit drawing surface.
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let isActive: Bool
    var penColor: UIColor? = nil          // set (with showsToolPicker false) → external palette
    var showsToolPicker: Bool = true
    var inkType: PKInkingTool.InkType = .pen   // pen vs marker/highlighter
    var penWidth: CGFloat = 6
    /// True while a stroke is being drawn. The editor uses it to clear its chrome out of the way.
    var onStroke: (Bool) -> Void = { _ in }
    /// ⛔ ZOOM WHILE DRAWING (owner 2026-08-22). Nil for every other user of this canvas — the chat
    /// image editor has no zoom of its own to drive — so they are untouched.
    var photoRelay: PhotoTransformRelay? = nil

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.drawingPolicy = .anyInput
        v.backgroundColor = .clear
        v.isOpaque = false
        v.tool = PKInkingTool(inkType, color: penColor ?? .white, width: penWidth)
        v.delegate = context.coordinator
        if showsToolPicker { context.coordinator.toolPicker.addObserver(v) }   // native PencilKit tool palette
        // ⚠️ TWO FINGERS ONLY, AND THAT IS THE WHOLE ARBITRATION. PencilKit draws from a SINGLE-touch
        // gesture, so a recogniser with a floor of two can never be the thing that stole a stroke —
        // the two simply cannot both be describing the same touches. No simultaneity to grant, no
        // failure requirement to set, and nothing here that can delay a line by waiting to find out.
        //
        // The same floor the photo's own pan already carries, for the same reason it carries it.
        if photoRelay != nil {
            let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.penPinch(_:)))
            let pan = UIPanGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.penPan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            // A pinch and a two-finger pan are one motion — you scale and reposition with the same
            // pair of fingers — so they have to be allowed to run together, exactly as they are on
            // the photo itself.
            pinch.delegate = context.coordinator
            pan.delegate = context.coordinator
            v.addGestureRecognizer(pinch)
            v.addGestureRecognizer(pan)
        }
        return v
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {
        if v.drawing != drawing { v.drawing = drawing }
        v.isUserInteractionEnabled = isActive
        if let penColor { v.tool = PKInkingTool(inkType, color: penColor, width: penWidth) }   // external palette drives the ink
        guard showsToolPicker else { return }
        // Show Apple's PKToolPicker (pens/marker/eraser/colors/undo) while drawing is active.
        let picker = context.coordinator.toolPicker
        picker.setVisible(isActive, forFirstResponder: v)
        if isActive { DispatchQueue.main.async { v.becomeFirstResponder() } }
        else { v.resignFirstResponder() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    // Done removes this view from the hierarchy — hide the tool picker FIRST, or it lingers on screen.
    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: uiView)
        uiView.resignFirstResponder()
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        let parent: DrawingCanvas
        let toolPicker = PKToolPicker()
        init(_ p: DrawingCanvas) { parent = p }

        /// Handed straight to the photo's own coordinator, which owns every number involved — the
        /// limits, the clamp, the spring on release. See `PhotoTransformRelay.drivePinch`.
        @objc func penPinch(_ g: UIPinchGestureRecognizer) { parent.photoRelay?.drivePinch?(g) }
        @objc func penPan(_ g: UIPanGestureRecognizer) { parent.photoRelay?.drivePan?(g) }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Only with each OTHER. Saying yes to everything would include PencilKit's own drawing
            // gesture, and a stroke recorded during a pinch is a line nobody asked for.
            (g is UIPinchGestureRecognizer || g is UIPanGestureRecognizer)
                && (other is UIPinchGestureRecognizer || other is UIPanGestureRecognizer)
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { parent.drawing = canvasView.drawing }

        // PencilKit's own "a stroke is happening" pair. Reporting it is what lets the editor get its
        // buttons out of the way while the finger is down — the alternative, a gesture recogniser of
        // our own on the canvas, would have to compete with the one drawing the line.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { parent.onStroke(true) }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { parent.onStroke(false) }
    }
}

// Real interactive crop: pan/zoom the image inside a fixed frame, surroundings DIMMED
// (you see what you're cropping out), rotation dial (-45°…45°) with auto-zoom so corners never gap,
// rotate-90, flip, aspect MENU, grid that fades in during a gesture, corner handles, Reset.
// Done renders exactly what's inside the frame. Body split into sub-views for the type-checker.
struct CropView: View {
    let source: UIImage
    var onDone: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @GestureState private var gScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gOffset: CGSize = .zero
    @State private var angle: Double = 0          // fine rotation from the dial
    @GestureState private var dialDrag: CGFloat = 0
    @State private var quarter: Int = 0           // rotate-90 steps
    @State private var flipped = false
    @State private var aspectIdx = 0

    private var aspects: [(name: String, ratio: CGFloat)] {
        [("Original", source.size.height == 0 ? 1 : source.size.width / source.size.height),
         ("Square", 1), ("2:3", 2.0 / 3.0), ("3:5", 3.0 / 5.0), ("3:4", 3.0 / 4.0),
         ("4:5", 4.0 / 5.0), ("5:7", 5.0 / 7.0), ("9:16", 9.0 / 16.0)]
    }
    private var liveScale: CGFloat { max(1, scale * gScale) }
    private var liveOffset: CGSize { CGSize(width: offset.width + gOffset.width, height: offset.height + gOffset.height) }
    private var liveAngle: Double { min(45, max(-45, angle - Double(dialDrag) / 6)) }
    private var isEdited: Bool { angle != 0 || quarter != 0 || flipped || scale != 1 || offset != .zero }
    private var interacting: Bool { gScale != 1 || gOffset != .zero || dialDrag != 0 }

    // Min extra zoom so the (possibly rotated) image always covers the frame — no corner gaps.
    private func coverScale(_ angleDeg: Double, _ w: CGFloat, _ h: CGFloat) -> CGFloat {
        let r = angleDeg * .pi / 180
        let c = abs(CGFloat(cos(r))), s = abs(CGFloat(sin(r)))
        guard w > 0, h > 0 else { return 1 }
        return max((w * c + h * s) / w, (w * s + h * c) / h)
    }

    var body: some View {
        GeometryReader { geo in
            let ratio = aspects[aspectIdx].ratio
            let frameW: CGFloat = min(geo.size.width - 32, geo.size.height * 0.5 * ratio)
            let frameH: CGFloat = frameW / ratio
            ZStack {
                Color.black.ignoresSafeArea()
                cropArea(frameW: frameW, frameH: frameH)
                controls(geo: geo, frameW: frameW, frameH: frameH)
            }
        }
        .statusBarHidden()
    }

    private func cropArea(frameW: CGFloat, frameH: CGFloat) -> some View {
        ZStack {
            framedPhoto(frameW: frameW, frameH: frameH, live: true, clip: false)   // overflow shown
            Color.black.opacity(0.5).ignoresSafeArea()                              // dim the surroundings
                .reverseMask { RoundedRectangle(cornerRadius: 1).frame(width: frameW, height: frameH) }
                .allowsHitTesting(false)
            thirdsGrid.frame(width: frameW, height: frameH)
                .opacity(interacting ? 1 : 0).animation(.easeInOut(duration: 0.2), value: interacting)
                .allowsHitTesting(false)
            CropCorners().stroke(.white, lineWidth: 3).frame(width: frameW + 4, height: frameH + 4)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(SimultaneousGesture(zoomGesture, panGesture))
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture().updating($gScale) { v, s, _ in s = v }.onEnded { v in scale = max(1, scale * v) }
    }
    private var panGesture: some Gesture {
        DragGesture().updating($gOffset) { v, s, _ in s = v.translation }
            .onEnded { v in offset.width += v.translation.width; offset.height += v.translation.height }
    }

    private func controls(geo: GeometryProxy, frameW: CGFloat, frameH: CGFloat) -> some View {
        VStack {
            Spacer()
            Text("Reset")
                .font(.subheadline).foregroundStyle(.white.opacity(isEdited ? 1 : 0.4))
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { resetAll() } }
            rotationDial.frame(height: 40).padding(.vertical, 6)
            HStack {
                circleButton("xmark", bg: Color.white.opacity(0.18)) { onCancel() }
                Spacer()
                HStack(spacing: 26) {
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { quarter = (quarter + 1) % 4 } } label: {
                        Image(systemName: "rotate.left").font(.title3).foregroundStyle(.white)
                    }
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { flipped.toggle() } } label: {
                        Image(systemName: "arrow.left.and.right").font(.title3).foregroundStyle(flipped ? .green : .white)
                    }
                    Menu {
                        ForEach(aspects.indices, id: \.self) { i in
                            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { aspectIdx = i } } label: {
                                if aspectIdx == i { Label(aspects[i].name, systemImage: "checkmark") } else { Text(aspects[i].name) }
                            }
                        }
                    } label: {
                        Image(systemName: "aspectratio").font(.title3).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20).frame(height: 48).background(Color.white.opacity(0.14), in: Capsule())
                Spacer()
                circleButton("checkmark", bg: Color.blue) { onDone(render(frameW: frameW, frameH: frameH)) }
            }
            .padding(.horizontal, 16).padding(.bottom, geo.safeAreaInsets.bottom + 14)
        }
    }

    private func circleButton(_ icon: String, bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(bg, in: Circle())
        }
    }

    // Photo: scaled-to-fill the frame, with rotation (+auto cover-zoom) + flip + zoom + pan.
    // clip=false for the on-screen view (overflow shows under the dim); clip=true for the output render.
    private func framedPhoto(frameW: CGFloat, frameH: CGFloat, live: Bool, clip: Bool) -> some View {
        let a: Double = (live ? liveAngle : angle) + Double(quarter) * 90
        let base: CGFloat = live ? liveScale : max(1, scale)
        let s: CGFloat = base * coverScale(a, frameW, frameH)
        let o: CGSize = live ? liveOffset : offset
        return Image(uiImage: source)
            .resizable().scaledToFill()
            .rotationEffect(.degrees(a))
            .scaleEffect(x: flipped ? -s : s, y: s)
            .offset(o)
            .frame(width: frameW, height: frameH)
            .allowsHitTesting(false)
            .modifier(ClipIf(clip: clip))
    }

    private var thirdsGrid: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }.stroke(.white.opacity(0.5), lineWidth: 0.5)
        }
    }

    private var rotationDial: some View {
        GeometryReader { g in
            ZStack {
                HStack(spacing: 7) {
                    ForEach(-45...45, id: \.self) { d in
                        Rectangle()
                            .fill(.white.opacity(d % 15 == 0 ? 0.9 : 0.35))
                            .frame(width: d % 15 == 0 ? 2 : 1, height: d % 15 == 0 ? 18 : 11)
                    }
                }
                .frame(maxHeight: .infinity)
                .offset(x: -CGFloat(liveAngle) * 9)
                Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(.green)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: g.size.width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture().updating($dialDrag) { v, s, _ in s = v.translation.width }
                    .onEnded { v in angle = min(45, max(-45, angle - Double(v.translation.width) / 6)) }
            )
        }
    }

    private func resetAll() { scale = 1; offset = .zero; angle = 0; quarter = 0; flipped = false }

    @MainActor private func render(frameW: CGFloat, frameH: CGFloat) -> UIImage {
        let content = framedPhoto(frameW: frameW, frameH: frameH, live: false, clip: true)
        let r = ImageRenderer(content: content)
        r.scale = UIScreen.main.scale
        return r.uiImage ?? source
    }
}

// Conditionally clip a view to its frame (used so the crop's display shows overflow but the render doesn't).
private struct ClipIf: ViewModifier {
    let clip: Bool
    func body(content: Content) -> some View { clip ? AnyView(content.clipped()) : AnyView(content) }
}

extension View {
    // Punch a hole in `self` the shape of `mask` (used to dim everything except the crop frame).
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle().overlay(mask().blendMode(.destinationOut)).compositingGroup()
        }
    }
}

// L-shaped corner brackets for the crop frame.
struct CropCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len: CGFloat = 22
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + len)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + len, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return p
    }
}

/// ⛔ THE BRIGHTNESS DIAL — the trim page's Adjust tab (owner, 2026-08-20, with his screenshot).
///
/// A row of ticks with a mark in the middle: drag left and the clip darkens, drag right and it
/// brightens, and the centre is untouched. Deliberately NOT a `Slider` — the reference is a ruler
/// you push past, it has no thumb to grab, and the whole strip is the target rather than a 30pt knob
/// somewhere along it.
///
/// It reports through a plain binding and holds no state of its own beyond the drag, so switching
/// tabs, changing item or leaving the page cannot strand a half-finished gesture.
private struct BrightnessDial: View {
    @Binding var value: Double            // -1…1, 0 = untouched
    @State private var dragStart: Double?
    @State private var dragging = false
    @State private var lastTick = 0

    private let ticks = 41

    /// Which tick the mark is nearest. Drives both the haptic and how the ruler lights up around it.
    private var markTick: Double { (Double(ticks - 1) / 2) * (1 + value) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let travel = w / 2 - 8
            ZStack {
                HStack(spacing: 0) {
                    ForEach(0..<ticks, id: \.self) { i in
                        tick(i)
                    }
                }
                // ⛔ NO IMPLICIT ANIMATION ON THE MARK WHILE A FINGER IS DOWN. It had an easeOut on
                // every value change, so the mark arrived a tenth of a second after the thumb — which
                // reads as the control being slow rather than smooth. A dragged control follows the
                // finger exactly; only the moments nobody is touching it are animated.
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3, height: 36)
                    .offset(x: CGFloat(value) * travel)
                    .animation(dragging ? nil : .spring(duration: 0.28, bounce: 0.18), value: value)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // Anchored on the value the drag STARTED from, not the finger's absolute
                        // position: a ruler you push should follow your thumb by the distance it
                        // moved, and jumping to wherever the first touch landed is how a control like
                        // this loses a setting somebody had already dialled in.
                        let start = dragStart ?? value
                        if dragStart == nil {
                            dragStart = start
                            dragging = true
                            lastTick = Int(markTick.rounded())
                        }
                        let span = max(1, w - 16)
                        value = min(1, max(-1, start + Double(g.translation.width / span) * 2))
                        // ⛔ ONE TAP PER TICK CROSSED. This is what a ruler is missing when it feels
                        // dead: the eye sees the mark move, the hand feels nothing. `.selection` is
                        // the light one Apple uses for pickers, not the heavier impact used for a
                        // button, so a long drag is a run of ticks and not a rattle.
                        let t = Int(markTick.rounded())
                        if t != lastTick {
                            lastTick = t
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        dragging = false
                        // Snap the last sliver back to neutral, so "put it back" needs no steady hand,
                        // and let the spring above carry it there.
                        if abs(value) < 0.03 {
                            withAnimation(.spring(duration: 0.28, bounce: 0.18)) { value = 0 }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
            )
            // Double tap is the reset every dial of this kind has.
            .onTapGesture(count: 2) {
                guard value != 0 else { return }
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) { value = 0 }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    /// ⛔ THE RULER ANSWERS THE MARK. Ticks near it stand taller and brighter and fall away with
    /// distance, so the thing moving under the thumb is the whole control rather than one line
    /// travelling across a static row. The falloff is smooth, which is what makes a drag read as
    /// continuous even though the ticks themselves are discrete.
    @ViewBuilder private func tick(_ i: Int) -> some View {
        let centre = i == ticks / 2
        let d = abs(Double(i) - markTick)
        let near = max(0, 1 - d / 4)                 // 1 at the mark, 0 four ticks away
        let lift = near * near                       // squared: the response stays tight to the thumb
        Rectangle()
            .fill(Color.white.opacity((centre ? 0.85 : 0.35) + lift * 0.5))
            .frame(width: centre ? 2 : 1.5,
                   height: (centre ? 26 : 16) + lift * 12)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.12), value: lift)
    }
}


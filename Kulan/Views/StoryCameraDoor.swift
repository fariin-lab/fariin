import SwiftUI
import UIKit

/// THE STORY CAMERA OPENS THE WAY A CHAT DOES, ONLY MIRRORED.
///
/// Owner, 2026-08-24, after seeing the first attempt on his phone: "the current animation has too
/// many bugs in both the opening and closing transitions — replace it with Apple's native UIKit
/// transition. Use Apple's swipe, like when I click a chat and the chat page opens, but coming from
/// the left side. Animation only: + opens the camera, ✕ closes it, no finger swipe."
///
/// ⛔ WHAT WAS HERE BEFORE IS DELETED, AND HIS VERDICT ON IT WAS RIGHT. The first version drove a
/// SwiftUI `progress` by hand and moved four things off it — an offset, a scale, a half-speed inner
/// offset and a dim — plus an interactive drag. That is a lot of state to keep correct across a
/// screen rotation, a re-render and a mid-flight second tap, and his screenshot caught it wedged:
/// camera at 80%, parked somewhere in the middle, the app beside it. Every one of those bugs was in
/// machinery we owned.
///
/// ⚠️ THE TRANSITION IS UIKIT'S NOW, NOT OURS. `UIViewControllerAnimatedTransitioning` is the API
/// that already runs every push and every modal in the system: UIKit owns the container, the
/// completion, the interruption and the cleanup, and this file supplies two frames and a duration.
/// There is no progress variable and no gesture left to get out of step.
///
/// A note on why this is not literally a `UINavigationController` transition, which is what he
/// described: a push and a pop run right-to-left and there is no public flag to reverse either. The
/// numbers below ARE the system's — full travel for the screen on top, 30% for the one beneath, one
/// duration, one curve — with the sign flipped, so it reads as the same motion coming the other way.
final class StoryCameraSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// True for opening, false for closing. One class for both so the two directions cannot drift.
    private let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }

    /// ⛔ 0.3 AND THEIR SPRING, READ FROM THEIR SOURCE — owner, 2026-08-25: "the camera speed is
    /// slow… read then get the speed number [the reference app] is using then use it, the speed you
    /// are using is wrong."
    ///
    /// Their `CameraScreen.animateIn` / `animateOut` drive every part of the entrance and the exit —
    /// preview position, bounds, scale, the chrome views — at `duration: 0.3` with
    /// `kCAMediaTimingFunctionSpring`, without exception. Ours was 0.35 on `.curveEaseInOut`: a
    /// twentieth of a second longer AND a curve that decelerates lazily where theirs arrives, which
    /// is why it read as slow rather than as slightly slow.
    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval { 0.3 }

    /// Their timing function, handed to UIKit the way UIKit accepts it.
    ///
    /// ⚠️ `kCAMediaTimingFunctionSpring` is a Core Animation name with no `UIView.AnimationOptions`
    /// spelling, but the curve behind it is the system's curve 7 — the same one the keyboard reports
    /// and the same one `KeyboardWatcher.systemAnimation` already writes out for SwiftUI in this app.
    /// `7 << 16` is the documented shape of the options field (curve in the high bits), and it is how
    /// the reference app itself passes this curve to UIKit.
    private static let refSpringCurve = UIView.AnimationOptions(rawValue: 7 << 16)

    /// ⛔ THIS IS A POP, NOT A PUSH — owner, 2026-08-24, with ours beside theirs: "the camera page
    /// must be UNDER the page that is going up, and the page that is going must have rounded corners
    /// like image 2."
    ///
    /// ⚠️ THE FIRST VERSION HAD THE Z-ORDER THE WRONG WAY ROUND, and that one fact is both of his
    /// points. It was built as a push: the arriving camera on TOP, travelling the full width, with
    /// the app moving 30% beneath it. So the camera's hard edge cut across the chat list, and a
    /// screen that is underneath has no corners to round.
    ///
    /// A pop is the same animation with the roles swapped, and it is what he photographed: the
    /// LEAVING screen rides on top and travels the whole way out, revealing the arriving one
    /// underneath, which drifts in over the last 30% of the distance. Because the chat list is now
    /// the thing on top, it is the thing that carries a corner radius, exactly as in their shot.
    private static let parallax: CGFloat = 0.30


    /// ⚠️ THE PAGE THAT LEAVES IS A SNAPSHOT, AND IT HAS TO BE. The app's real view lives in the
    /// window, NOT in the transition's container, so it cannot be raised above the camera and cannot
    /// be given corners without mutating the live app's own layer. A snapshot can be put anywhere in
    /// the container, styled freely, and thrown away when the animation ends — the real view is never
    /// touched, which is also why nothing can be left behind if the transition is interrupted.
    /// ⛔ THE CORNERS ROUNDED ONLY SOMETIMES — owner, 2026-08-24, with a square-cornered chat list
    /// mid-slide. Two things made it a coin toss and both are gone:
    ///
    /// ⚠️ THE CORNER WAS BEING SET ON THE SNAPSHOT ITSELF. `snapshotView` does not return an ordinary
    /// view — it is a special replicant of another view's rendered content, and it is not a surface
    /// to hang a resolving corner configuration on. The snapshot is now CARGO: it rides inside a
    /// plain `UIView` that owns the corner and does the clipping, and a plain view resolves the way
    /// the API documents.
    ///
    /// ⚠️ AND THE CORNER WAS RESOLVED IN THE SAME BREATH AS THE FIRST ANIMATED FRAME. A concentric
    /// corner is worked out during layout; the card was created, added and animated in one runloop
    /// turn, so whether a layout pass happened first was down to timing — which is exactly what
    /// "sometimes it works" looks like from the outside. The caller forces that pass now, before any
    /// animation is set up.
    /// ⛔ FIFTH ATTEMPT, AND THIS ONE COPIES A SHIPPING APP INSTEAD OF REASONING — owner,
    /// 2026-08-25: the corner rounds now but "the radius is too small… make it the same large Apple
    /// iOS 26 corners as tapping a chat or a profile".
    ///
    /// ⚠️ FOUR ATTEMPTS TRIED TO MAKE `containerConcentric` ANSWER, AND THE FOURTH TRIED TO READ ITS
    /// ANSWER. Attempts 1-3 set a bare `.containerConcentric()` on the card and got square; attempt 4
    /// put a probe view in the window, read `layer.cornerRadius` and cached it — which also came back
    /// zero, so the modest 12pt fallback is what he then photographed as "too small".
    ///
    /// ⚠️ THE REFERENCE APP NEVER READS IT AND NEVER USES THE BARE FORM. Every one of their call
    /// sites supplies a minimum and clips:
    ///
    ///     cornerConfiguration = .uniformCorners(radius: .containerConcentric(minimum: 12))
    ///     backgroundView.cornerConfiguration = .uniformBottomRadius(.containerConcentric(minimum: 26), …)
    ///     bottomRadius: .containerConcentric(minimum: 20)
    ///
    /// So resolving to zero where there is nothing to be concentric with is the DOCUMENTED, expected
    /// behaviour, and `minimum:` is the API's own answer to it — not a workaround. The number below
    /// is therefore a floor that iOS is free to raise, which is exactly the shape of his original
    /// rule ("let iOS decide it per device"), rather than a fixed radius that overrides it.
    ///
    /// ⚠️ AND THE FLOOR IS APPLE-SIZED NOW. The display corner is not public API — UIKit knows it
    /// during its own push transitions because it is inside UIKit. 55 is the modern iPhone display
    /// corner (the 15/16 Pro class); on a device whose real corner differs, concentric supplies the
    /// true number and this is never reached. The old 12 was chosen to "look like a card without
    /// pretending to match the hardware", which was the wrong goal: he wants it to match.
    private static let appleCardRadius: CGFloat = 55

    private static func makeCard(of view: UIView, bounds: CGRect) -> UIView? {
        guard let snapshot = view.snapshotView(afterScreenUpdates: false) else { return nil }
        let card = UIView(frame: bounds)
        card.clipsToBounds = true          // theirs sets this at every concentric call site
        card.layer.cornerCurve = .continuous
        card.cornerConfiguration = .uniformCorners(radius: .containerConcentric(minimum: appleCardRadius))
        snapshot.frame = card.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(snapshot)
        return card
    }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard let fromVC = ctx.viewController(forKey: .from),
              let toVC = ctx.viewController(forKey: .to) else {
            ctx.completeTransition(false)
            return
        }
        let width = container.bounds.width
        let duration = transitionDuration(using: ctx)

        // Underneath, the camera only ever covers the last 30% of the distance. On top, the page
        // being left travels the whole width.
        let beneathStart = CGAffineTransform(translationX: -width * Self.parallax, y: 0)
        let aboveOffscreen = CGAffineTransform(translationX: width, y: 0)

        if presenting {
            let camera = toVC.view!
            camera.frame = container.bounds
            container.addSubview(camera)
            camera.transform = beneathStart

            // Added AFTER the camera, so it sits above it.
            let card = Self.makeCard(of: fromVC.view, bounds: container.bounds)
            if let card { container.addSubview(card) }

            UIView.animate(withDuration: duration, delay: 0, options: Self.refSpringCurve) {
                camera.transform = .identity
                card?.transform = aboveOffscreen
            } completion: { _ in
                card?.removeFromSuperview()
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
        } else {
            let camera = fromVC.view!
            // Coming back, the app arrives on top from the right and the camera slips away under it.
            let card = Self.makeCard(of: toVC.view, bounds: container.bounds)
            if let card {
                container.addSubview(card)
                card.transform = aboveOffscreen
            }
            UIView.animate(withDuration: duration, delay: 0, options: Self.refSpringCurve) {
                camera.transform = beneathStart
                card?.transform = .identity
            } completion: { _ in
                card?.removeFromSuperview()
                camera.transform = .identity
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
        }
    }
}

/// Hands UIKit the animator for each direction. A singleton because a transitioning delegate is held
/// WEAKLY by the presented controller — a fresh instance would be released before it was ever asked,
/// and the presentation would silently fall back to the default slide-up.
final class StoryCameraTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
    static let shared = StoryCameraTransitionDelegate()
    private override init() { super.init() }

    func animationController(forPresented _: UIViewController, presenting _: UIViewController,
                             source _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        StoryCameraSlideAnimator(presenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        StoryCameraSlideAnimator(presenting: false)
    }
}

/// Opening and closing the story camera, from anywhere.
@MainActor enum StoryCameraDoor {
    /// Weak: if UIKit takes it away for any reason, this reference goes with it rather than leaving
    /// `open()` convinced a camera is still up and refusing to present another.
    private static weak var presented: UIViewController?

    static func open() {
        guard presented == nil, let top = topViewController() else { return }
        let sheet = AddStorySheet(onPosted: { Task { await StoriesRepository.shared.load(force: true) } },
                                  onDismiss: { StoryCameraDoor.close() },
                                  onPostedClose: { StoryCameraDoor.closeAfterPost() })
        let host = UIHostingController(rootView: sheet)
        // ⚠️ `.overFullScreen`, NOT `.fullScreen`, AND THE CLOSING ANIMATION DEPENDS ON IT. A
        // `.fullScreen` presentation takes the presenting view out of the hierarchy. On the way out
        // the camera slides 30% to the left, and what is revealed in that strip is the real app
        // sitting in the window — remove it and that strip is a black band for the whole animation.
        host.modalPresentationStyle = .overFullScreen
        host.transitioningDelegate = StoryCameraTransitionDelegate.shared
        // The camera paints its own black; without this the app shows through wherever it does not.
        host.view.backgroundColor = .black
        presented = host
        top.present(host, animated: true)
    }

    /// ⛔ DISMISS THE HOST, NOT WHATEVER THE HOST IS PRESENTING — owner, 2026-08-25: "when I upload
    /// story, [after] post story it's showing the camera page again".
    ///
    /// ⚠️ `dismiss(animated:)` TAKES DOWN THE RECEIVER'S CHILD, NOT THE RECEIVER. A controller with
    /// something presented dismisses THAT; only a controller presenting nothing forwards the call to
    /// its own presenter. The story editor is a `fullScreenCover` raised FROM this host (see
    /// `AddStorySheet`), so at the moment a story is posted the host has a child — and this line
    /// dismissed the EDITOR and left the camera standing. The camera he sees is not a new screen
    /// being shown; it is the old one never being taken away.
    ///
    /// Asking the PRESENTER removes the ambiguity: dismissing the host takes everything the host
    /// raised down with it, in one animation, whether or not an editor is open. The nil-coalesce
    /// keeps the old behaviour for the case the door is ever used with nothing presenting it.
    static func close() {
        guard let host = presented else { return }
        presented = nil
        (host.presentingViewController ?? host).dismiss(animated: true)
    }

    /// ⛔ A POSTED STORY DOES NOT SLIDE AWAY — owner, 2026-10-16, with the reference app filmed beside
    /// ours: after Post Story, ours ran the ✕ close (the app sliding back over the camera), theirs
    /// sends the picture into the My Story card while the sheet drops and the black lifts off the
    /// page that was behind it all along.
    ///
    /// Everything that is on screen at the tap is copied into `StoryPostFlight`'s own window FIRST,
    /// then the camera and everything it raised are taken down with no animation, so the real app is
    /// already standing under the copies when they start to move. The ✕ keeps `close()`.
    static func closeAfterPost() {
        let source = StoryPostFlight.takePending()
        guard let host = presented else { return }
        var top: UIViewController = host
        while let next = top.presentedViewController { top = next }
        // From the TOP screen: the editor is a full-screen cover, which takes the camera's own view
        // out of the window while it is up.
        guard let window = top.view.window ?? host.view.window, let scene = window.windowScene
        else { close(); return }
        presented = nil

        // The share sheet, as drawn (glass included), so it can keep falling after it is gone.
        var sheet: (image: UIImage, frame: CGRect, radius: CGFloat)?
        if top !== host, let v = top.presentationController?.presentedView ?? top.view {
            let f = v.convert(v.bounds, to: nil)
            if f.width > 1, f.height > 1 {
                let img = UIGraphicsImageRenderer(bounds: f).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                // The crop is square; the sheet is not. Its own corner where the system says it,
                // else the iOS 26 sheet corner, so the editor's black behind the corners does not
                // ride down with it.
                let r = max(v.layer.cornerRadius, v.subviews.first?.layer.cornerRadius ?? 0)
                sheet = (img, f, r > 0 ? r : 38)
            }
        }
        // The editor's buttons and caption, which ride on the picture and fade off it.
        let chrome = top.presentingViewController?.view?.snapshotView(afterScreenUpdates: false)

        (host.presentingViewController ?? host).dismiss(animated: false)
        StoryPostFlight.run(scene: scene, bounds: window.bounds, source: source,
                            chrome: chrome, sheet: sheet)
    }

    /// Present on whatever is actually on top — presenting on a controller that is itself covered
    /// does nothing at all and reads as a dead tap. Same walk as `WebLink`'s.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController
            ?? scenes.first?.keyWindow?.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

/// THE POSTED PICTURE FLYING INTO MY STORY — the reference app's post exit, read from its source
/// (`MediaEditorScreen.animateOut(finished: true)` and its share sheet's `animateOut`), 2026-10-16.
///
/// At the tap, all at once:
///   • the share sheet drops by its own height, 0.3s ease-in-out;
///   • the black behind the editor fades, 0.15s, uncovering the app that was there all along;
///   • the picture flies to the My Story card: centre, scale, a centred crop to the card's shape and
///     the corner radius, all 0.4s on their spring curve, which below 0.5s is the cubic
///     (0.38, 0.70, 0.125, 1.0) (`CAAnimationUtils`, the `kCAMediaTimingFunctionSpring` branch);
///   • the editor's buttons and caption ride on the picture and fade off it, 0.25s.
/// The card is hidden while the copy flies and shown again under it as the copy goes.
///
/// ⚠️ ONE PLACE WE DO NOT COPY THEM: they fade a snapshot of the destination AVATAR in over the last
/// 0.25s, because their circle shows the profile photo. Our card shows the story picture itself,
/// the same one that is flying, so that fade would only swap a picture for an older copy of it.
///
/// No card on screen (the camera was opened from somewhere else): their fallback, the picture
/// fades, shrinks to 0.8 and drops by a screen height, 0.4s.
@MainActor enum StoryPostFlight {
    struct Source { let image: UIImage; let rect: CGRect; let cornerRadius: CGFloat }

    private static var pending: Source?
    private static var window: UIWindow?

    /// The editor names the picture and where it is drawn, just before it reports the post.
    static func prepare(imageData: Data, rect: CGRect, cornerRadius: CGFloat) {
        guard rect.width > 1, rect.height > 1, let img = UIImage(data: imageData) else { pending = nil; return }
        pending = Source(image: img, rect: rect, cornerRadius: cornerRadius)
    }

    static func takePending() -> Source? {
        defer { pending = nil }
        return pending
    }

    private static let flight: TimeInterval = 0.4
    private static func springCurve() -> UICubicTimingParameters {
        UICubicTimingParameters(controlPoint1: CGPoint(x: 0.38, y: 0.70),
                                controlPoint2: CGPoint(x: 0.125, y: 1.0))
    }

    /// My Story's card, wherever this layout draws it, if it is on screen now. The row turns into the
    /// uploading row a frame after the post; all three sit in the same slot.
    private static func destination(in bounds: CGRect) -> (key: String, rect: CGRect, radius: CGFloat)? {
        var ids = [StoryDoor.uploadingSourceKey]
        if let mine = StoriesRepository.shared.mine?.id { ids.append(mine) }
        ids.append(StoriesTabView.addRowKey)
        for id in ids {
            let key = MediaOpenRects.key(.storyRow, id)
            guard let r = MediaOpenRects.liveViewRect(key), bounds.intersects(r) else { continue }
            return (key, r, MediaOpenRects.registeredCornerRadius(key) ?? 12)
        }
        return nil
    }

    static func run(scene: UIWindowScene, bounds: CGRect, source: Source?,
                    chrome: UIView?, sheet: (image: UIImage, frame: CGRect, radius: CGFloat)?) {
        window?.isHidden = true
        let overlay = UIWindow(windowScene: scene)
        overlay.frame = bounds
        overlay.windowLevel = .normal + 1
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        overlay.rootViewController = root
        let stage = root.view!
        window = overlay

        let dim = UIView(frame: bounds)
        dim.backgroundColor = .black
        stage.addSubview(dim)

        // The picture, in its own clipping box the size of the editor's card.
        var card: UIView?
        var chromeView: UIView?
        if let source {
            let box = UIView()
            box.bounds = CGRect(origin: .zero, size: source.rect.size)
            box.center = CGPoint(x: source.rect.midX, y: source.rect.midY)
            box.clipsToBounds = true
            box.layer.cornerCurve = .continuous
            box.layer.cornerRadius = source.cornerRadius
            let photo = UIImageView(image: source.image)
            photo.contentMode = .scaleAspectFill
            photo.frame = box.bounds
            box.addSubview(photo)
            if let chrome {
                // Placed so the editor's own pixels line up with the card they were drawn over.
                chrome.frame = CGRect(x: -source.rect.minX, y: -source.rect.minY,
                                      width: bounds.width, height: bounds.height)
                box.addSubview(chrome)
                chromeView = chrome
            }
            stage.addSubview(box)
            card = box
        }

        var sheetView: UIImageView?
        if let sheet {
            let v = UIImageView(image: sheet.image)
            v.frame = sheet.frame
            v.clipsToBounds = true
            v.layer.cornerCurve = .continuous
            v.layer.cornerRadius = sheet.radius
            stage.addSubview(v)
            sheetView = v
        }

        overlay.isHidden = false

        // The sheet drops, the black lifts: both start on the tap.
        if let sheetView {
            let drop = bounds.height - sheetView.frame.minY
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
                sheetView.transform = CGAffineTransform(translationX: 0, y: drop)
            }
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseInOut) { dim.alpha = 0 }
        if let chromeView {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) { chromeView.alpha = 0 }
        }

        let finish: (String?) -> Void = { hiddenKey in
            if hiddenKey != nil { MediaSourceVisibility.shared.reveal() }
            if window === overlay { overlay.isHidden = true; window = nil }
        }

        guard let card, let source else {
            // Nothing to fly: let the sheet finish falling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish(nil) }
            return
        }

        guard let dest = destination(in: bounds) else {
            let anim = UIViewPropertyAnimator(duration: flight, timingParameters: springCurve())
            anim.addAnimations {
                card.transform = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 0.8, y: 0.8)
            }
            UIView.animate(withDuration: flight, delay: 0, options: .curveEaseInOut) { card.alpha = 0 }
            anim.addCompletion { _ in finish(nil) }
            anim.startAnimation()
            return
        }

        // Hide the real card while its copy is on the way. The row becomes the uploading row a frame
        // later, and that is the one that must stay hidden then.
        var hiddenKey = dest.key
        MediaSourceVisibility.shared.hide(hiddenKey)
        DispatchQueue.main.async {
            let uploading = MediaOpenRects.key(.storyRow, StoryDoor.uploadingSourceKey)
            if hiddenKey != uploading, MediaOpenRects.liveViewRect(uploading) != nil {
                hiddenKey = uploading
                MediaSourceVisibility.shared.hide(uploading)
            }
        }

        // Their maths: scale by width, crop the height to the card's shape around the middle, and
        // divide the radius by the scale so it lands at the card's real corner.
        let w = source.rect.width, h = source.rect.height
        let scale = dest.rect.width / w
        let aspect = dest.rect.height / dest.rect.width
        let anim = UIViewPropertyAnimator(duration: flight, timingParameters: springCurve())
        anim.addAnimations {
            card.center = CGPoint(x: dest.rect.midX, y: dest.rect.midY)
            card.transform = CGAffineTransform(scaleX: scale, y: scale)
            card.bounds = CGRect(x: 0, y: (h - w * aspect) / 2, width: w, height: w * aspect)
            card.layer.cornerRadius = scale > 0 ? dest.radius / scale : 0
        }
        anim.addCompletion { _ in finish(hiddenKey) }
        anim.startAnimation()
    }
}

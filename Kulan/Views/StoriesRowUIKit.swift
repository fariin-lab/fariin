import UIKit
import SwiftUI
import Combine
import Observation
import StoryUI

//
// THE STORIES ROW, IN UIKIT. (owner 2026-08-08: "completely change Stories row to UIKit ... do not
// change the design, appearance, layout, or behavior in any way".)
//
// This file replaces the SwiftUI `StoriesRow` that used to live in StoriesViews.swift — the
// horizontal scroller, my own card, the friend cards, the dip, the rings, the covers, the labels,
// the uploading placeholder and the two alerts. Nothing about it is meant to look or behave
// differently. Every number below was copied out of the SwiftUI version rather than re-chosen, and
// the notes that explained WHY a number is what it is have been carried across with it, because a
// number with no reason attached is the first thing a future edit gets wrong.
//
// WHAT STAYED SwiftUI ON PURPOSE, AND WHY IT IS NOT A GAP:
//  • `StoriesRow` is still the name MainShell constructs, with the same arguments in the same order.
//    It is a `UIViewRepresentable` now. MainShell was not touched — its `body` is already one very
//    large expression sitting on the type-checker's budget (see the ⚠️ note at its call site), and
//    the cheapest change to that file is no change at all.
//  • `StoryRingView`, `StoryImage`, `AvatarView`, `SkeletonFill` and `UploadingAvatarRing` are still
//    SwiftUI and are still used by other screens (the chat-list avatars, the viewer, the carousel).
//    They are NOT used here any more: this file draws its own, in UIKit, from the same measurements.
//    Two drawings of one thing is a maintenance trap, so each UIKit one below points at the SwiftUI
//    original it must stay equal to.
//
// THE FOUR CONTRACTS THIS ROW OWES THE REST OF THE APP, all of them unchanged:
//  1. `MediaOpenRects` — every card registers its own live UIView and window rect under
//     `key(.storyRow, <group id>)` at radius 24. The story flight flies to and from those, and
//     `menuTarget(at:)` hit-tests them. This got SIMPLER in UIKit: the registered view is now the
//     card itself rather than a transparent SwiftUI `.background` anchor. See `heroBox`.
//  2. `MediaSourceVisibility` — a card whose key is hidden draws at alpha 0, so the same picture is
//     never on screen twice while the flight or the lifted menu preview holds it.
//  3. `StoryRowLongPress.Coordinator` — the row's one press recogniser, unchanged, installed on this
//     scroll view directly instead of being found by walking up from a SwiftUI representable.
//  4. The row's HEIGHT, which MainShell reads to set the chat list's top margin. See `StoryRowMetrics`.
//

// MARK: - Metrics

/// Every measurement the row is built from, in one place. These are the SwiftUI values verbatim:
/// `storySpacing` 10, `storyHPad` 12, `.padding(.vertical, 10)`, `VStack(spacing: 6)`, a 12pt label
/// and the 1.46 card aspect.
@MainActor enum StoryRowMetrics {
    static let spacing: CGFloat = 10
    static let hPad: CGFloat = 12
    static let vPad: CGFloat = 10
    static let labelGap: CGFloat = 6
    static let radius: CGFloat = 24
    static let labelFont = UIFont.systemFont(ofSize: 12)

    /// Four cards across the screen with three gaps between them and a margin at each end — the
    /// SwiftUI expression, unchanged. Still measured against `UIScreen.main.bounds` rather than the
    /// row's own width, so the answer cannot depend on when it is asked (the row is laid out inside a
    /// list whose width arrives late) and cannot disagree with the width the SwiftUI row reported to
    /// MainShell before it.
    static var cardW: CGFloat { (UIScreen.main.bounds.width - hPad * 2 - spacing * 3) / 4 }
    static var cardH: CGFloat { cardW * 1.46 }
    static var labelH: CGFloat { ceil(labelFont.lineHeight) }
    /// What `sizeThatFits` reports and MainShell turns into the chat list's top content margin.
    static var rowH: CGFloat { vPad * 2 + cardH + labelGap + labelH }
}

/// SwiftUI's `.spring(response:dampingFraction:)` in UIKit terms.
///
/// NOT `UIView.animate(usingSpringWithDamping:)` — that is a different curve with different
/// arguments, and using it would have quietly changed every motion in this row. Apple's own mapping
/// for the modern spring is duration ↔ response and bounce ↔ (1 − dampingFraction), which is what
/// `UISpringTimingParameters(duration:bounce:)` takes, so the two frameworks run the same spring.
@MainActor enum StorySpring {
    static func animator(response: Double, damping: Double) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: response,
                               timingParameters: UISpringTimingParameters(duration: response,
                                                                          bounce: 1 - damping))
    }

    static func run(response: Double, damping: Double,
                    _ animations: @escaping () -> Void,
                    completion: (() -> Void)? = nil) {
        let a = animator(response: response, damping: damping)
        a.addAnimations(animations)
        if let completion { a.addCompletion { _ in completion() } }
        a.startAnimation()
    }
}

/// The beat between the tap and the open: long enough for the dip to be seen, short enough to read
/// as response rather than lag. 0.06 on his "when i click story opening add slightly speed"
/// (2026-08-07) — this beat is dead time, so it is the cheapest speed in the whole gesture.
@MainActor private func afterStoryDip(_ open: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: open)
}

/// A container that is invisible to touches: it lets its own interactive children be hit, and hands
/// everything else back to whatever is behind it.
///
/// ⚠️ WITHOUT THIS THE WHOLE CARD STOPS BEING A BUTTON, and the reason is a real difference between
/// the two frameworks. In SwiftUI the picture and the circle were drawn INSIDE the Button's label,
/// so a tap anywhere on them was a tap on the button. In UIKit the deepest view under the finger
/// wins, and a plain container view accepts a touch it has no use for — which would swallow every
/// tap that did not land on the badge and leave the card looking dead.
final class StoryPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - The ring

/// `StoryRingView` in UIKit. Same spec, and it must stay equal to it — the chat-list avatars still
/// draw the SwiftUI one, and the two rings are seen on the same screen.
///
///  • UNSEEN gradient 0x34C76F (green) → 0x3DA1FD (blue), top to bottom, both themes
///  • SEEN solid, per theme: 0x505052 dark, 0xCACACA light (the owner's own two hex values —
///    "already seen" is said by being QUIETER than the page, which is darker on white and lighter
///    on black, so one grey cannot do it)
///  • the SEEN ring is thinner than the unseen ring
///  • segment gap = activeLineWidth · 2, measured along the circumference
///  • `.inset(by: activeW / 2)` keeps the stroke inside the frame, so a 2pt line on a 37pt frame
///    reaches exactly 37 and not 39
final class StoryRingUIView: UIView {
    var seen: [Bool] = [] {
        didSet { if seen != oldValue { setNeedsLayout() } }
    }
    var lineWidth: CGFloat = 2.0 {
        didSet { if lineWidth != oldValue { setNeedsLayout() } }
    }

    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    private let seenLayer = CAShapeLayer()

    private static let unseenTop = UIColor(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x6F / 255, alpha: 1)
    private static let unseenBottom = UIColor(red: 0x3D / 255, green: 0xA1 / 255, blue: 0xFD / 255, alpha: 1)
    private static let seenColor = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x50 / 255, green: 0x50 / 255, blue: 0x52 / 255, alpha: 1)
            : UIColor(red: 0xCA / 255, green: 0xCA / 255, blue: 0xCA / 255, alpha: 1)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        gradient.colors = [Self.unseenTop.cgColor, Self.unseenBottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradientMask.fillColor = nil
        gradientMask.strokeColor = UIColor.black.cgColor
        gradientMask.lineCap = .round
        gradient.mask = gradientMask
        layer.addSublayer(gradient)

        seenLayer.fillColor = nil
        seenLayer.lineCap = .round
        layer.addSublayer(seenLayer)

        // CGColor does not follow the theme on its own, so the seen grey is re-resolved by hand.
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: StoryRingUIView, _) in
            v.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // No implicit CALayer animation: this view is re-laid-out inside the row's own springs, and a
        // path animating on its own timing underneath them is a second animation nobody asked for.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let d = min(bounds.width, bounds.height)
        guard d > 0 else { return }
        let activeW = lineWidth
        // ⚠️ GROUPED ONCE THERE ARE MORE STORIES THAN 37pt CAN HOLD. Straight `seen.count` here is
        // what made a 29-story ring invisible and a 30-story ring absent — the whole reckoning is
        // written out in `StoryRingGeometry`. This is the SwiftUI ring's twin and must stay equal
        // to it, so it takes the same two numbers from the same place.
        let arcs = StoryRingGeometry.condensed(seen, diameter: d, lineWidth: activeW)
        let n = max(1, arcs.count)
        let seenW = max(1, lineWidth * 0.66)
        let gap = StoryRingGeometry.gap(count: n, diameter: d, lineWidth: activeW)
        let seg = 1.0 / CGFloat(n)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = d / 2 - activeW / 2

        let unseenPath = UIBezierPath()
        let seenPath = UIBezierPath()
        for i in 0..<n {
            let isSeen = i < arcs.count ? arcs[i] : false
            let from = CGFloat(i) * seg + gap / 2
            let to = CGFloat(i + 1) * seg - gap / 2
            guard to > from else { continue }
            // SwiftUI's `trim` starts at 3 o'clock and the ring is rotated −90°, so the first segment
            // begins at the top.
            let a0 = from * 2 * .pi - .pi / 2
            let a1 = to * 2 * .pi - .pi / 2
            let arc = UIBezierPath(arcCenter: centre, radius: radius,
                                   startAngle: a0, endAngle: a1, clockwise: true)
            if isSeen { seenPath.append(arc) } else { unseenPath.append(arc) }
        }

        gradient.frame = bounds
        gradientMask.frame = bounds
        gradientMask.lineWidth = activeW
        gradientMask.path = unseenPath.cgPath
        gradient.isHidden = unseenPath.isEmpty

        seenLayer.frame = bounds
        seenLayer.lineWidth = seenW
        seenLayer.strokeColor = Self.seenColor.resolvedColor(with: traitCollection).cgColor
        seenLayer.path = seenPath.cgPath
        seenLayer.isHidden = seenPath.isEmpty
    }
}

// MARK: - The avatar circle

/// `AvatarView` in UIKit, at the two sizes this row uses. Same first-frame rule, same fallback, same
/// cross-fade.
///
/// THE SYNCHRONOUS DISK SEED IS DELIBERATE and is carried over verbatim: memory alone starts empty
/// on every launch, so on a cold start every avatar fell through to its coloured letter and faded to
/// the real photo a frame later — the flash of letters the owner photographed. An avatar is a few
/// KB and the read is gated on the cache's in-memory index, so a miss never touches the filesystem.
final class StoryAvatarUIView: UIView {
    private let imageView = UIImageView()
    private let gradient = CAGradientLayer()
    private let letter = UILabel()
    private var loadTask: Task<Void, Never>?
    private var name = ""
    private var photoUrl: String?
    private var diameter: CGFloat = 32

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true

        layer.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0, y: 0)      // .topLeading
        gradient.endPoint = CGPoint(x: 1, y: 1)        // .bottomTrailing

        letter.textColor = .white
        letter.textAlignment = .center
        addSubview(letter)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isHidden = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, photoUrl: String?, size: CGFloat) {
        let sameSubject = (name == self.name && photoUrl == self.photoUrl && size == diameter)
        self.name = name
        self.photoUrl = photoUrl
        self.diameter = size
        letter.font = .systemFont(ofSize: size * 0.42, weight: .bold)
        letter.text = String(name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?")
        gradient.colors = AvatarPalette.gradient(for: name).map { UIColor($0).cgColor }
        setNeedsLayout()
        guard !sameSubject else { return }

        loadTask?.cancel()
        loadTask = nil

        // First frame: memory, then disk. Seeded images are NOT cross-faded — they were already
        // there, and fading them in is the blink this seed exists to remove.
        if let u = photoUrl, !u.isEmpty, let warm = DiskImageCache.shared.smallImageSync(u) {
            show(warm, animated: false)
        } else {
            show(nil, animated: false)
        }

        guard let u = photoUrl, !u.isEmpty, imageView.image == nil else { return }
        loadTask = Task { [weak self] in await self?.load(u) }
    }

    private func show(_ image: UIImage?, animated: Bool) {
        let changed = (imageView.image == nil) != (image == nil)
        imageView.image = image
        guard animated, changed else {
            imageView.isHidden = image == nil
            letter.isHidden = image != nil
            gradient.isHidden = image != nil
            return
        }
        // `.animation(.easeOut(duration: 0.25), value: image != nil)`
        UIView.transition(with: self, duration: 0.25,
                          options: [.transitionCrossDissolve, .curveEaseOut]) {
            self.imageView.isHidden = image == nil
            self.letter.isHidden = image != nil
            self.gradient.isHidden = image != nil
        }
    }

    private func load(_ url: String) async {
        guard let u = URL(string: url) else { return }
        if let cached = await DiskImageCache.shared.image(for: url) {
            guard !Task.isCancelled, photoUrl == url else { return }
            show(cached, animated: true)
            ProfilePhotoIndex.noteLoad(url, ok: true)
            return
        }
        if let (data, _) = try? await MediaSession.shared.data(from: u), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: url)
            guard !Task.isCancelled, photoUrl == url else { return }
            show(ui, animated: true)
            ProfilePhotoIndex.noteLoad(url, ok: true)
            return
        }
        // Nothing behind the url — told to the index, because the profile header has to answer
        // "circle or big photo" before it draws and cannot wait for a download of its own.
        ProfilePhotoIndex.noteLoad(url, ok: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        letter.frame = bounds
        imageView.frame = bounds
        layer.cornerRadius = bounds.width / 2
    }
}

// MARK: - The shimmer

/// `SkeletonFill` in UIKit: an opaque grey block with a highlight sweeping across it, 1.25s linear,
/// forever. Opaque system greys on purpose — a near-transparent tint vanished against a card.
final class StorySkeletonUIView: UIView {
    private let highlight = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        highlight.startPoint = CGPoint(x: 0, y: 0.5)   // .leading → .trailing
        highlight.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(highlight)
        applyColors()
        // The trait observer is GONE with the trait: `applyColors` no longer asks what the style is,
        // so re-running it on a style change would repaint the same two colours it already has. A
        // subscription that cannot change anything is a subscription a later reader has to prove is
        // dead, so it goes with the branch it existed for.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// ⚠️ THE STORY ROW IS ALWAYS DARK, SO THIS SHIMMER IS ALWAYS THE DARK ONE. MEASURED, TWICE.
    ///
    /// His 2026-08-10 report, the sixth in the corner family: light corners on one card in the row
    /// while every neighbour's corners are pure black. Sampled off his screenshot rather than
    /// reasoned about, because this family has cost several fixes that were argued rather than
    /// measured — the four corners of that card read 231, 234, 247 and 253 against 0,0,0 on the
    /// cards either side.
    ///
    /// 231-234 is `systemGray4` (209) under a white highlight at 0.55, which is precisely this
    /// function's LIGHT branch, and it is the SAME NUMBER `5deeae9a` recorded for the grey wedges in
    /// the viewer a few hours earlier ("226-243 … nothing else in this app is that colour, remember
    /// the number"). That fix pinned the viewer's placeholder and left a note that if light greys
    /// turned up anywhere else it was the thread. They have, and this is it.
    ///
    /// So the trait is not asked any more. Every story surface in this app is dark by standing rule
    /// (`storyAlwaysDark`), and a view that can resolve LIGHT inside it is a view that can paint a
    /// near-white block on a black screen. Pinned HERE and not in `SkeletonFill`, which the chat and
    /// call lists share and where the light shimmer is the right answer — the same call-site rule
    /// `5deeae9a` followed.
    ///
    /// ⚠️ STILL UNEXPLAINED, AND NOT FIXED BY THIS: how the shimmer reaches the corner at all. It
    /// sits inside `clip`, which has `clipsToBounds` and the card's radius, so it should not be able
    /// to paint outside the rounded shape whatever colour it is. This makes the artifact
    /// `systemGray5` (~44) against black instead of ~240, which is the difference between glaring
    /// and invisible — but the geometry question is open and a second report here means it is that,
    /// not the colour. Do not re-argue the colour: it is measured.
    private func applyColors() {
        backgroundColor = .systemGray5
        let tint = UIColor.white.withAlphaComponent(0.14)
        highlight.colors = [UIColor.clear.cgColor, tint.cgColor, UIColor.clear.cgColor]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.55, height: bounds.height)
        CATransaction.commit()
        startSweep()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { highlight.removeAllAnimations() } else { startSweep() }
    }

    /// The SwiftUI original offsets the highlight from −1·w·1.7 to +1·w·1.7 while it sits at the
    /// leading edge of the frame, so its CENTRE travels from 0.275w − 1.7w to 0.275w + 1.7w.
    private func startSweep() {
        guard window != nil, bounds.width > 0, highlight.animation(forKey: "sweep") == nil else { return }
        let w = bounds.width
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = w * 0.275 - w * 1.7
        a.toValue = w * 0.275 + w * 1.7
        a.duration = 1.25
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        highlight.add(a, forKey: "sweep")
    }
}

// MARK: - The cover

/// The card's picture: `StoryImage` at the row's own settings (plain fill / crop, never the
/// fit-and-blur the viewer uses), with the shimmer underneath it until the bytes arrive.
///
/// The retry ladder is carried across unchanged. The two reported failures — "sometimes a black
/// image" and "after updating the app I can't see my story" — were both a single failed fetch that
/// used to be permanent. The skeleton stays up between tries and it recovers the instant one lands.
final class StoryCoverUIView: UIView {
    private let skeleton = StorySkeletonUIView()
    private let imageView = UIImageView()
    private var url: String = ""
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // ⚠️ THE COVER CARRIES THE CARD'S OWN CORNER TOO, AND THIS IS THE WHITE-CORNER FIX.
        //
        // His report, 2026-08-17, on MY card and — once he checked — on a friend's as well: white
        // square corners behind the card's rounded ones, only on a card that HAS a picture. Measured
        // off his screenshot rather than argued: pure 253-255 in the corner wedge against a card body
        // of 70, in the exact shape of "square minus a 24pt rounded rect", on all four corners.
        //
        // ⚠️ AND THE EARLIER NOTE IN THIS FILE BLAMING THE SHIMMER IS WRONG. It pinned the colour to
        // `systemGray5`, which is about 44 in dark mode; the artifact measures 255. That note was
        // measured in LIGHT mode, where `systemGray5` is ~229, which is why it looked like a match.
        // Do not follow it.
        //
        // What is left is a child of this view painting outside the card's rounded shape. `clip` above
        // has `clipsToBounds` and the radius, and that note gave up on how anything could escape it —
        // so this stops asking which child and closes the whole family: the cover is EXACTLY
        // `clip.bounds`, so giving it the same corner and its own clip changes nothing about what it
        // draws and leaves nothing of it outside the curve. A picture, a shimmer, or a transition's
        // snapshot are all inside this view.
        layer.cornerRadius = StoryRowMetrics.radius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addSubview(skeleton)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isHidden = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(url: String) {
        guard url != self.url else { return }
        self.url = url
        loadTask?.cancel()
        loadTask = nil

        // First frame from memory, exactly as `StoryImage.init` does — a fresh instance drawing one
        // skeleton frame over bytes we already hold is the card flash he filmed while scrolling.
        if let warm = DiskImageCache.shared.memoryImage(url) {
            show(warm, animated: false)
        } else {
            show(nil, animated: false)
            loadTask = Task { [weak self] in await self?.load(url) }
        }
    }

    private func show(_ image: UIImage?, animated: Bool) {
        imageView.image = image
        guard animated else {
            imageView.isHidden = image == nil
            skeleton.isHidden = image != nil
            return
        }
        // `.animation(.easeOut(duration: 0.25), value: image != nil)`
        //
        // ⚠️ A PLAIN ALPHA CROSS-FADE, NOT `UIView.transition`, AND THAT IS THE SECOND HALF OF THE
        // WHITE-CORNER FIX.
        //
        // `.transitionCrossDissolve` works by RENDERING THIS VIEW INTO A SNAPSHOT and fading between
        // two of them. A snapshot is a new view UIKit inserts for the length of the transition, and it
        // is the one thing here that is not simply a child of this view laid out at `bounds` — which
        // makes it the one candidate that could paint outside an ancestor's rounded clip. Fading the
        // two subviews directly needs no snapshot at all: same 0.25s, same ease-out, same result,
        // nothing added to the hierarchy.
        //
        // It also stops a full-size render of every card at the moment its picture lands, which is
        // work the row was paying on every scroll into view.
        // Both on screen for the length of the fade, whichever way it is going: a view that is still
        // hidden cannot animate its alpha, and a reused card can arrive at this line from either
        // state.
        let showImage = image != nil
        imageView.alpha = showImage ? 0 : 1
        skeleton.alpha = showImage ? 1 : 0
        imageView.isHidden = false
        skeleton.isHidden = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.imageView.alpha = showImage ? 1 : 0
            self.skeleton.alpha = showImage ? 0 : 1
        } completion: { _ in
            self.imageView.isHidden = !showImage
            self.skeleton.isHidden = showImage
            // Left ready for the next time this reused view swaps the other way.
            self.imageView.alpha = 1
            self.skeleton.alpha = 1
        }
    }

    private func load(_ target: String) async {
        if let cached = await DiskImageCache.shared.image(for: target) {
            guard !Task.isCancelled, url == target else { return }
            show(cached, animated: true)
            return
        }
        guard let u = URL(string: target), !target.isEmpty else { return }
        let delays: [UInt64] = [0, 600_000_000, 1_500_000_000, 3_000_000_000, 6_000_000_000]
        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if Task.isCancelled || url != target { return }
            if let (data, _) = try? await MediaSession.shared.data(from: u), let img = UIImage(data: data) {
                DiskImageCache.shared.store(img, data: data, for: target)
                guard !Task.isCancelled, url == target else { return }
                show(img, animated: true)
                return
            }
        }
        // Still failing after every attempt — leave the shimmer up rather than a dead black card. A
        // repo reload with a fresh URL runs this again.
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        skeleton.frame = bounds
        imageView.frame = bounds
    }
}

// MARK: - The plus badges

/// The small badge on my card when it already has a picture: a 16pt disc in the label colour with a
/// 9pt bold plus cut out of it, standing on a white rim ONE point proud of the disc.
///
/// DRAWN, NOT `plus.circle.fill`, and only so the rim can be 1pt (owner: "why is the badge white
/// big, make it same like the avatar circle, don't change the + size"). The symbol carries its own
/// air inside its box, so a disc padded past that BOX showed two or three points of white past the
/// black circle you can actually see. Box is not ink. A circle we fill ourselves fills its frame
/// exactly, so −1 is one point of white, measured from the edge you are looking at.
final class StorySmallPlusBadge: UIControl {
    private let rim = UIView()
    private let disc = UIView()
    private let glyph = UIImageView()
    static let size: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        rim.backgroundColor = .systemBackground
        rim.isUserInteractionEnabled = false
        addSubview(rim)

        disc.backgroundColor = .label
        disc.isUserInteractionEnabled = false
        addSubview(disc)

        glyph.image = UIImage(systemName: "plus",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))?
            .withRenderingMode(.alwaysTemplate)
        glyph.tintColor = .systemBackground
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        disc.frame = bounds
        disc.layer.cornerRadius = bounds.width / 2
        glyph.frame = bounds
        rim.frame = bounds.insetBy(dx: -1, dy: -1)
        rim.layer.cornerRadius = rim.bounds.width / 2
    }

    /// The rim stands outside the control's own bounds, so it has to be drawn behind everything and
    /// allowed to overflow.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        clipsToBounds = false
        sendSubviewToBack(rim)
    }
}

/// The big badge on my card when it has NO picture: the reference add-status look — `plus.circle.fill`
/// at 19pt in the two-tone palette, cut cleanly into whatever it sits on by a white rim 2.5pt proud.
///
/// The SF Symbol itself, not a hand-drawn copy: at this size the symbol's own proportions are the
/// look, and re-drawing them by eye is how two badges end up almost the same.
final class StoryLargePlusBadge: UIControl {
    private let rim = UIView()
    private let glyph = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        rim.backgroundColor = .systemBackground
        rim.isUserInteractionEnabled = false
        addSubview(rim)

        glyph.isUserInteractionEnabled = false
        glyph.contentMode = .center
        addSubview(glyph)
        applyGlyph()
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: StoryLargePlusBadge, _) in
            v.applyGlyph()
        }

        // `.shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)`
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `.symbolRenderingMode(.palette)` with `.foregroundStyle(Color(.systemBackground), Color.primary)`:
    /// the plus takes the background colour and the disc takes the label colour, so it is a black
    /// badge that flips white in dark mode.
    private func applyGlyph() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 19)
            .applying(UIImage.SymbolConfiguration(paletteColors: [
                .systemBackground.resolvedColor(with: traitCollection),
                .label.resolvedColor(with: traitCollection),
            ]))
        glyph.image = UIImage(systemName: "plus.circle.fill", withConfiguration: cfg)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize { glyph.image?.size ?? CGSize(width: 19, height: 19) }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
        rim.frame = bounds.insetBy(dx: -2.5, dy: -2.5)
        rim.layer.cornerRadius = rim.bounds.width / 2
        sendSubviewToBack(rim)
    }
}

// MARK: - The circle in the card's corner

/// The 32pt avatar that sits at the bottom-left of every card, with whatever ring the card's state
/// asks for, and (on my own card) the small plus hanging off its corner.
///
/// THE CIRCLE IS 32 IN EVERY STATE and the ring is 37 around it — his requirement, stated twice.
/// Shrinking the avatar was a misreading of "make it small": what he was pointing at is the WHITE,
/// not the picture. So only the two white circles are lighter than they were — the ring around the
/// avatar is a 1pt hairline instead of a 2pt band, and the rim behind the plus hugs the glyph.
final class StoryCornerCircle: UIView {
    static let avatar: CGFloat = 32
    static let ring: CGFloat = 37

    let avatarView = StoryAvatarUIView()
    private let ringView = StoryRingUIView()
    private let whiteHairline = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The circle is picture, not a control: a tap on it opens the story, exactly as it did when
        // it was drawn inside the SwiftUI Button's label. The plus badge is a separate control and
        // lives on the card, not in here — see `StoryCardUIView.smallBadge`.
        isUserInteractionEnabled = false
        addSubview(avatarView)
        addSubview(ringView)

        whiteHairline.fillColor = nil
        whiteHairline.strokeColor = UIColor.white.cgColor
        whiteHairline.lineWidth = 1
        whiteHairline.isHidden = true
        layer.addSublayer(whiteHairline)

        // The shadow every circle in this row wears: `.shadow(color: .black.opacity(0.28), radius: 2, y: 1)`.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameters:
    ///   - seen: the per-story flags. EMPTY means "nothing posted", which on my own card draws the
    ///           white hairline instead of a story ring, and on a friend's card draws no ring at all.
    ///   - hairlineWhenEmpty: my card only. A white ring around a face is the shape a POSTED story
    ///           wears, so at story-ring size it read as one on a card with nothing posted.
    ///   - animated: the ring cross-fades on a change (`.animation(.easeInOut(duration: 0.3), value: seen)`).
    func setSeen(_ seen: [Bool], hairlineWhenEmpty: Bool, animated: Bool) {
        let wantHairline = hairlineWhenEmpty && seen.isEmpty
        let changed = seen != ringView.seen || whiteHairline.isHidden == wantHairline
        let apply = {
            self.ringView.seen = seen
            self.ringView.isHidden = seen.isEmpty
            self.whiteHairline.isHidden = !wantHairline
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        guard animated, changed else { apply(); return }
        UIView.transition(with: self, duration: 0.3,
                          options: [.transitionCrossDissolve, .curveEaseInOut], animations: apply)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.avatar, height: Self.avatar) }

    override func layoutSubviews() {
        super.layoutSubviews()
        avatarView.frame = bounds
        // The ring is an OVERLAY, not a second item in a stack: it draws outside the 32pt circle
        // without resizing it, which is why the circle stays where the card pins it.
        ringView.frame = bounds.insetBy(dx: (Self.avatar - Self.ring) / 2, dy: (Self.avatar - Self.ring) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        whiteHairline.frame = bounds
        whiteHairline.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        CATransaction.commit()
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }
}

// MARK: - One card

/// One card in the row — my own or a friend's, they are the same view with different inputs, exactly
/// as they were two SwiftUI views built from one `card(...)` helper and one `StoryFriendCard`.
///
/// A `UIControl`, so the press behaves the way SwiftUI's `Button` did: highlighted while the finger
/// is down and inside, cancelled when the scroll view claims the touch, fired on release inside.
/// That last part matters — the row's long press cancels this control's touch when it recognises,
/// which is the half of "releasing after a long press opens the story" that lives on this side.
final class StoryCardUIView: UIControl {
    /// The rectangle the story flies out of and lands back on: the cover WITH its circle on it.
    ///
    /// On the card, not on the enclosing stack, or the landing would aim at a rectangle that includes
    /// the name underneath and the story would seat itself low and too tall. And circle INCLUDED,
    /// which is the avatar half of his report: it used to be the photo alone, so the slot the story
    /// flew out of kept its little avatar floating over an empty hole. One rectangle leaves, the same
    /// rectangle comes home.
    let heroBox = StoryPassthroughView()

    private let clip = StoryPassthroughView()
    private let cover = StoryCoverUIView()
    private let emptyBG = UIView()
    private let bigAvatar = StoryAvatarUIView()
    private var bigBadge: StoryLargePlusBadge?
    private var smallBadge: StorySmallPlusBadge?
    private let corner = StoryCornerCircle()
    private let nameLabel = UILabel()

    private var visibilityToken: AnyCancellable?
    private(set) var rectKey: String = ""
    private var onTap: (() -> Void)?
    private var onBadge: (() -> Void)?

    /// TRUE only on MY card, and only once something is posted: the corner circle then means "add a
    /// story", the same as the plus does. Cards are REUSED between mine and a friend's, so this is
    /// written in both configure paths and can never be left over from the last person to occupy
    /// this view — a friend's avatar must always open their story.
    private var avatarAddsStory = false
    /// Where the finger went down, in this card's own space.
    ///
    /// `UIControl` hands its action no location, and the corner circle is deliberately not a control
    /// (`isUserInteractionEnabled = false`, so the whole card stays one button and the row's press
    /// recogniser keeps working over it). Remembering the touch is therefore the only way to tell a
    /// tap on the circle from a tap on the picture — and it costs no new gesture recogniser, which
    /// this row cannot afford (see the scroll-and-gesture rules).
    private var touchDownPoint: CGPoint = .zero
    private var didLayoutOnce = false
    /// The diameter the centred circle is drawn at when the card has no picture: 0.62 of the card on
    /// a friend's, 0.48 on my own. Stored rather than read back off the view, or the second layout
    /// pass would measure the size the first one guessed.
    private var emptyAvatarSize: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        // The ZStack: nothing here clips, because the circle and its shadow sit on top of the picture
        // and must be free to draw outside it. Only the picture is rounded.
        addSubview(heroBox)

        clip.clipsToBounds = true
        clip.layer.cornerRadius = StoryRowMetrics.radius
        clip.layer.cornerCurve = .continuous        // every card in this app is continuous
        heroBox.addSubview(clip)

        emptyBG.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.2)
        emptyBG.isUserInteractionEnabled = false
        clip.addSubview(emptyBG)
        clip.addSubview(bigAvatar)
        clip.addSubview(cover)

        heroBox.addSubview(corner)

        nameLabel.font = StoryRowMetrics.labelFont
        nameLabel.textColor = .label
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        // A card whose key is hidden steps aside for the lift or the flight: the same picture must
        // never be on screen twice at the hand-over. Alpha, never `isHidden` — a hidden view stops
        // reporting its frame, which would erase the very rect the transition is flying towards.
        visibilityToken = MediaSourceVisibility.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyVisibility() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configuration

    /// A friend's card.
    func configureFriend(group: StoryGroup, seen: [Bool], animated: Bool, onTap: @escaping () -> Void) {
        self.onTap = onTap
        // A friend's avatar opens their story like the rest of their card. Written here because this
        // view may have been my own card a moment ago — see `avatarAddsStory`.
        avatarAddsStory = false
        nameLabel.text = group.name.isEmpty ? "User" : group.name
        applyCover(group.stories.last?.previewUrl,
                   name: group.name.isEmpty ? "User" : group.name,
                   avatar: group.photoUrl,
                   emptyAvatarScale: 0.62,
                   showBigBadge: false)
        corner.avatarView.configure(name: group.name.isEmpty ? "User" : group.name,
                                    photoUrl: group.photoUrl,
                                    size: StoryCornerCircle.avatar)
        corner.isHidden = false
        corner.setSeen(seen, hairlineWhenEmpty: false, animated: animated && didLayoutOnce)
        setRectKey(MediaOpenRects.key(.storyRow, group.id))
    }

    /// THE KEY MY OWN CARD REGISTERS UNDER WHEN THERE IS NOTHING POSTED. It exists so the card can
    /// still be FOUND — the long press hit-tests the same rectangle registry the story flight uses,
    /// so a card that registers nothing cannot be pressed at all. That is why a long press on an
    /// empty My Story did nothing while a posted one raised its menu. Nothing flies to this key; it
    /// is a hit target and a lift source, in the shape of the one `StoryDoor.uploadingSourceKey`
    /// already uses for the placeholder.
    static let emptyMyStoryKey = "my-story-empty"

    /// My own card. `heroKey` is nil when there is nothing posted — there is no story to OPEN, so the
    /// tap composes instead, and the rectangle it registers is `emptyMyStoryKey` rather than a story.
    func configureMine(coverUrl: String?, meName: String, mePhoto: String?, seen: [Bool],
                       heroKey: String?, animated: Bool,
                       onTap: @escaping () -> Void, onBadge: @escaping () -> Void) {
        self.onTap = onTap
        self.onBadge = onBadge
        nameLabel.text = "My Story"

        let hasCover = !(coverUrl ?? "").isEmpty
        // WITH something posted, the circle is a second, bigger way to reach "add a story". With
        // NOTHING posted the circle is hidden anyway and the whole card already composes, which is
        // the behaviour he asked me to leave alone: "if user not posting any story and everywhere
        // click user it menas add already that is working dont tuch".
        avatarAddsStory = hasCover
        // avatarName: what the LETTER CIRCLE falls back to when there is no photo. The label is "My
        // Story" but the circle must use the real name — label-as-avatar-name drew a purple "M"
        // while Edit Profile drew the correct initial (device report).
        applyCover(coverUrl, name: meName, avatar: mePhoto,
                   emptyAvatarScale: 0.48,
                   showBigBadge: !hasCover && seen.isEmpty)

        if hasCover {
            corner.isHidden = false
            corner.avatarView.configure(name: meName, photoUrl: mePhoto, size: StoryCornerCircle.avatar)
            addSmallBadgeIfNeeded()
            smallBadge?.isHidden = false
            corner.setSeen(seen, hairlineWhenEmpty: true, animated: animated && didLayoutOnce)
        } else {
            corner.isHidden = true
            smallBadge?.isHidden = true
        }
        setRectKey(MediaOpenRects.key(.storyRow, heroKey ?? Self.emptyMyStoryKey))
    }

    private func addSmallBadgeIfNeeded() {
        guard smallBadge == nil else { return }
        let b = StorySmallPlusBadge()
        b.addTarget(self, action: #selector(badgeTapped), for: .touchUpInside)
        // On the hero box, not inside the 32pt circle: it hangs 4pt past that circle's corner, and a
        // control drawn outside its parent's bounds is a control nobody can tap.
        heroBox.addSubview(b)
        smallBadge = b
        setNeedsLayout()
    }

    private func applyCover(_ url: String?, name: String, avatar: String?,
                            emptyAvatarScale: CGFloat, showBigBadge: Bool) {
        let has = !(url ?? "").isEmpty
        cover.isHidden = !has
        emptyBG.isHidden = has
        bigAvatar.isHidden = has
        emptyAvatarSize = StoryRowMetrics.cardW * emptyAvatarScale
        if has {
            cover.configure(url: url ?? "")
        } else {
            // Roomy proportions (polish 2026-07-22): the circle stays well clear of the card edges —
            // a near-edge circle with a big badge read cramped, not pro.
            bigAvatar.configure(name: name, photoUrl: avatar, size: emptyAvatarSize)
        }
        if showBigBadge {
            if bigBadge == nil {
                let b = StoryLargePlusBadge()
                b.addTarget(self, action: #selector(badgeTapped), for: .touchUpInside)
                clip.addSubview(b)
                bigBadge = b
            }
            bigBadge?.isHidden = false
        } else {
            bigBadge?.isHidden = true
        }
        setNeedsLayout()
    }

    private func setRectKey(_ key: String) {
        guard key != rectKey else { return }
        rectKey = key
        // The view, not a number somebody wrote down earlier: the flight asks it where it is at the
        // instant it needs to know. Registered here AND on every window change, because a card that
        // has been scrolled away and come back is a different answer.
        MediaOpenRects.captureView(key, key.isEmpty ? nil : heroBox)
        applyVisibility()
    }

    // MARK: Touches

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchDownPoint = touch.location(in: self)
        return super.beginTracking(touch, with: event)
    }

    @objc private func tapped() {
        // A press that raised the menu must not also open the story when the finger lifts.
        guard !StoryRowPress.swallowsTap else { return }
        // THE CIRCLE MEANS ADD, THE PICTURE MEANS OPEN. Owner, 2026-08-08: "if i tuch + button or it
        // i tuch circle avater it menas add story but if i tuch other areas like the big iamge
        // preview it meanes open story i posted before". The plus on its own was too small to hit.
        //
        // Measured against the RING, not the 32pt frame: `StoryCornerCircle` draws its 37pt ring
        // outside its own bounds, so the circle he is aiming at is 2.5pt bigger on every side than
        // the view is. Nothing else grows — a tap anywhere outside that circle still opens.
        //
        // No dip and no flight on this path: this is the plus badge's behaviour reached from a
        // different pixel, so it must do exactly what the plus does and nothing more.
        if avatarAddsStory, !corner.isHidden, let onBadge {
            let pad = (StoryCornerCircle.ring - StoryCornerCircle.avatar) / 2
            if corner.convert(corner.bounds, to: self).insetBy(dx: -pad, dy: -pad).contains(touchDownPoint) {
                onBadge()
                return
            }
        }
        // The tap dips the card and the story flies out of the dip (owner 2026-08-07, citing
        // another mainstream messenger). The dip is the control's own pressed state, so a held finger keeps the card
        // pressed and the release lets it spring back.
        afterStoryDip { [weak self] in self?.onTap?() }
    }

    /// A high-priority tap gesture in SwiftUI, a control on top in UIKit — either way tapping + adds
    /// a story without opening the card behind it.
    ///
    /// NO `swallowsTap` GUARD HERE, and that is deliberate rather than an oversight: the badge never
    /// had one. It does not need one either — the row's press recogniser cancels the touches of
    /// whatever was being tracked when it recognises, this control included.
    @objc private func badgeTapped() {
        onBadge?()
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let t: CGAffineTransform = isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            // `.spring(response: 0.28, dampingFraction: 0.7)`, and it runs on the WHOLE card — so the
            // rectangle the flight reads is wherever the spring-back has got to, which is what makes
            // the dip and the lift read as one motion.
            StorySpring.run(response: 0.28, damping: 0.7) { self.transform = t }
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = StoryRowMetrics.cardW
        let h = StoryRowMetrics.cardH
        heroBox.frame = CGRect(x: 0, y: 0, width: w, height: h)
        clip.frame = heroBox.bounds
        cover.frame = clip.bounds
        emptyBG.frame = clip.bounds

        if !bigAvatar.isHidden, emptyAvatarSize > 0 {
            let s = emptyAvatarSize
            bigAvatar.frame = CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)
            if let bigBadge, !bigBadge.isHidden {
                let bs = bigBadge.intrinsicContentSize
                // `.overlay(alignment: .bottomTrailing) { … .offset(x: 3, y: 3) }`
                bigBadge.frame = CGRect(x: bigAvatar.frame.maxX - bs.width + 3,
                                        y: bigAvatar.frame.maxY - bs.height + 3,
                                        width: bs.width, height: bs.height)
            }
        }

        // `.padding(8)` on a bottom-leading circle.
        corner.frame = CGRect(x: 8, y: h - 8 - StoryCornerCircle.avatar,
                              width: StoryCornerCircle.avatar, height: StoryCornerCircle.avatar)
        if let smallBadge, !smallBadge.isHidden {
            // ⚠️ BOTTOMS FLUSH, AND HALF THE BADGE OUTSIDE THE CIRCLE — his 2026-08-12 screenshots,
            // one of the current position and one of the wanted one.
            //
            // It used to be `offset(x: 4, y: 4)` from the circle's bottom-trailing corner, and the
            // `y: 4` is what he photographed: the badge hung four points BELOW the avatar, so it
            // read as dropping off the circle rather than sitting on it. `maxY - s` puts the two
            // bottom edges on the same line, which is what he asked for and what the reference
            // screenshot shows.
            //
            // Horizontally it is now centred ON the circle's edge — `maxX - s/2` leaves exactly half
            // the badge over the avatar and half outside it, his words. The old number left it about
            // three quarters inside, which is why it looked tucked under the face rather than
            // clipped to the rim. Sizes are untouched; only the origin moved.
            let s = StorySmallPlusBadge.size
            smallBadge.frame = CGRect(x: corner.frame.maxX - s / 2, y: corner.frame.maxY - s,
                                      width: s, height: s)
        }

        nameLabel.frame = CGRect(x: 0, y: h + StoryRowMetrics.labelGap,
                                 width: w, height: StoryRowMetrics.labelH)
        didLayoutOnce = true
        publishRect()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Re-registered on every window change: a card is reused as the row re-orders, and "it was
        // registered once at birth" is not good enough.
        if window != nil, !rectKey.isEmpty { MediaOpenRects.captureView(rectKey, heroBox) }
        applyVisibility()
    }

    /// Where the person's name is drawn, in window space, so the long press can lift it along with
    /// the card. Deliberately NOT part of the rectangle registered with `MediaOpenRects`: the flight
    /// must keep flying to the picture alone, or a story would seat itself low and too tall to make
    /// room for a label it is not carrying.
    var labelWindowRect: CGRect? {
        guard window != nil, !nameLabel.isHidden, nameLabel.bounds.width > 1 else { return nil }
        return nameLabel.convert(nameLabel.bounds, to: nil)
    }

    /// The label itself, so the lift can photograph IT rather than the window under it. A window
    /// crop of a label is the chat list with glyphs on top — his white box. See
    /// `StoryMenuTarget.labelView`.
    var labelView: UIView? { labelWindowRect == nil ? nil : nameLabel }

    /// The written-down rectangle stays as the fallback for anything that asks before the view can
    /// answer. Refreshed on layout and on every scroll, in window space, at the card's real radius.
    func publishRect() {
        guard !rectKey.isEmpty, window != nil else { return }
        MediaOpenRects.capture(rectKey, heroBox.convert(heroBox.bounds, to: nil),
                               cornerRadius: StoryRowMetrics.radius)
    }

    /// ⚠️ THE PICTURE STEPS ASIDE, THE NAME STAYS — unless the thing replacing the card is carrying
    /// a name of its own. See `MediaSourceVisibility.hidesLabel`. This used to set the whole card's
    /// alpha, which is a regression against the SwiftUI row it replaced: there the opacity lived on
    /// `MediaRectReporter`, applied to the picture, and the name was its sibling.
    /// ⚠️ THE CARD'S OWN `alpha` IS NOT TOUCHED HERE, and that is deliberate: it belongs to the row
    /// (a fresh card fades in on the re-sort, a departing one fades out, and my own card cross-fades
    /// with the uploading placeholder). Writing it from here would slam any of those back to 1 on
    /// the next visibility change.
    func applyVisibility() {
        let hidden = !rectKey.isEmpty && MediaSourceVisibility.shared.hiddenId == rectKey
        heroBox.alpha = hidden ? 0 : 1
        nameLabel.alpha = hidden && MediaSourceVisibility.shared.hidesLabel ? 0 : 1
    }
}

// MARK: - The uploading card

/// Shown in the first slot while a story is uploading: the local image, a spinning ring around my
/// own avatar, and one word for what is happening.
///
/// ⚠️ THE RING RUNS FOR THE WHOLE POST (owner, 2026-08-06). Do not put it back on `uploadPhase`. It
/// used to be drawn only while `.preparing`, on the reasoning that once the bytes are ready this
/// person's own copy is finished and the upload that follows is for everybody else. He has overruled
/// that in as many words — "there should be no moment where the loading indicator is hidden while
/// the operation is still in progress" — and he is right about what it looked like: the ring
/// vanishing at the hand-off reads as finished, and then the card sits there with nothing moving,
/// which reads as stuck. The two halves are still named differently in the label, which was the part
/// worth keeping: one word for the wait that is holding you up, another for the one that is not.
final class StoryUploadingCardUIView: UIView {
    private let heroBox = UIView()
    private let clip = UIView()
    private let imageView = UIImageView()
    private let dim = UIView()
    private let avatar = StoryAvatarUIView()
    private let spinner = CAShapeLayer()
    private let spinHost = UIView()
    private let label = UILabel()
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(heroBox)

        clip.clipsToBounds = true
        clip.layer.cornerRadius = StoryRowMetrics.radius
        clip.layer.cornerCurve = .continuous
        heroBox.addSubview(clip)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        clip.addSubview(imageView)

        dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        clip.addSubview(dim)

        // The same shadow every other circle in the row wears. Without it this one sat flat on the
        // photo while its neighbours lifted off theirs, which was the last way the uploading circle
        // differed from the one it turns into.
        spinHost.layer.shadowColor = UIColor.black.cgColor
        spinHost.layer.shadowOpacity = 0.28
        spinHost.layer.shadowRadius = 2
        spinHost.layer.shadowOffset = CGSize(width: 0, height: 1)
        spinHost.clipsToBounds = false
        spinHost.addSubview(avatar)
        // EVERY NUMBER HERE IS THE STORY RING'S, so the ring you watch while it uploads is the same
        // ring you get when it has uploaded: 32pt circle, 37pt frame, 2.0 line, and the inset that
        // keeps the stroke INSIDE that frame. Without the inset a 2pt line straddles its path and the
        // ring grows by a point the moment the upload finishes.
        spinner.fillColor = nil
        spinner.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinHost.layer.addSublayer(spinner)
        heroBox.addSubview(spinHost)

        label.font = StoryRowMetrics.labelFont
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameter animatedPhase: the label cross-fades between its two words
    ///   (`.animation(.easeInOut(duration: 0.2), value: uploadPhase)`).
    func configure(image: UIImage?, meName: String, mePhoto: String?, phaseText: String,
                   animatedPhase: Bool, onTap: @escaping () -> Void) {
        self.onTap = onTap
        imageView.image = image
        imageView.isHidden = image == nil
        clip.backgroundColor = image == nil ? .secondarySystemFill : .clear
        avatar.configure(name: meName, photoUrl: mePhoto, size: StoryCornerCircle.avatar)
        if label.text != phaseText {
            if animatedPhase {
                UIView.transition(with: label, duration: 0.2,
                                  options: [.transitionCrossDissolve, .curveEaseInOut]) {
                    self.label.text = phaseText
                }
            } else {
                label.text = phaseText
            }
        }
        // The flight's source, the same as every other card in this row.
        MediaOpenRects.captureView(MediaOpenRects.key(.storyRow, StoryDoor.uploadingSourceKey), heroBox)
        setNeedsLayout()
    }

    @objc private func tapped() { onTap?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = StoryRowMetrics.cardW
        let h = StoryRowMetrics.cardH
        heroBox.frame = CGRect(x: 0, y: 0, width: w, height: h)
        clip.frame = heroBox.bounds
        imageView.frame = clip.bounds
        dim.frame = clip.bounds

        let a = StoryCornerCircle.avatar
        spinHost.frame = CGRect(x: 8, y: h - 8 - a, width: a, height: a)
        avatar.frame = spinHost.bounds
        spinHost.layer.shadowPath = UIBezierPath(ovalIn: spinHost.bounds).cgPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ringRect = spinHost.bounds.insetBy(dx: (a - StoryCornerCircle.ring) / 2,
                                               dy: (a - StoryCornerCircle.ring) / 2)
        spinner.frame = ringRect
        let r = StoryCornerCircle.ring / 2 - 1        // `.inset(by: 1)`
        let centre = CGPoint(x: ringRect.width / 2, y: ringRect.height / 2)
        // `.trim(from: 0, to: 0.72)`, starting at the top like every other ring here.
        spinner.path = UIBezierPath(arcCenter: centre, radius: r,
                                    startAngle: -.pi / 2,
                                    endAngle: -.pi / 2 + 0.72 * 2 * .pi,
                                    clockwise: true).cgPath
        CATransaction.commit()

        label.frame = CGRect(x: 0, y: h + StoryRowMetrics.labelGap, width: w, height: StoryRowMetrics.labelH)
        startSpin()
        MediaOpenRects.capture(MediaOpenRects.key(.storyRow, StoryDoor.uploadingSourceKey),
                               heroBox.convert(heroBox.bounds, to: nil),
                               cornerRadius: StoryRowMetrics.radius)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { spinner.removeAllAnimations() } else { startSpin() }
    }

    private func startSpin() {
        guard window != nil, spinner.animation(forKey: "spin") == nil else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = 2 * Double.pi
        a.duration = 0.9
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        spinner.add(a, forKey: "spin")
    }
}

// MARK: - The row

/// The stories strip itself: the scroller, the order, the freeze, the prefetch, the alerts and the
/// one press recogniser.
@MainActor
final class StoriesRowUIView: UIView, UIScrollViewDelegate {
    // Inputs, pushed in by the representable.
    var meName: String = "You"
    var mePhoto: String?
    var freezeOrder: Bool = false { didSet { if freezeOrder != oldValue { freezeChanged() } } }
    var onCompose: () -> Void = {}
    var onOpen: (StoryGroup) -> Void = { _ in }
    var onMessage: (StoryGroup) -> Void = { _ in }
    var onProfile: (StoryGroup) -> Void = { _ in }
    var onOpenUploading: () -> Void = {}

    private let repo = StoriesRepository.shared
    private let service = StoriesService.shared
    private let doorState = StoryDoorState.shared

    private let scrollView = UIScrollView()
    private let content = UIView()
    private let myCard = StoryCardUIView()
    private let uploadingCard = StoryUploadingCardUIView()
    private var friendCards: [String: StoryCardUIView] = [:]     // group id → card
    private var displayedIds: [String] = []

    /// The order the row had when the viewer opened, by group id. Latched on the way in, dropped on
    /// the way out, so nothing here survives to stale a later row.
    private var frozenOrder: [String] = []
    /// ⚠️ AND THE RINGS, LATCHED THE SAME WAY AND FOR THE SAME REASON AS THE ORDER.
    ///
    /// The flight photographs the tapped card at TAP time, ring included, and lands that photograph
    /// back onto the live card at the end of the close. Watch somebody's last unseen story and the
    /// live ring greys out WHILE YOU ARE INSIDE — so the two rectangles the hand-over swaps are no
    /// longer identical, and the ring visibly changes colour at the moment of the swap. The re-sort
    /// and the greying then both play after the story is gone, which is when the big apps do it.
    private var frozenSeen: [String: [Bool]] = [:]

    private var pressCoordinator: StoryRowLongPress.Coordinator?
    private var lastActiveAuthorUid: String?
    private var lastPrefetchKey: String = ""
    private var lastErrorShown: String?
    private var didLoad = false
    private var hasAppliedOnce = false
    private var isAnimatingOrder = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        // Bounce only when the cards actually overrun the screen, which is what SwiftUI's default
        // scroll bounce behaviour does.
        scrollView.alwaysBounceHorizontal = false
        scrollView.bounces = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.addSubview(content)

        content.addSubview(myCard)
        content.addSubview(uploadingCard)
        uploadingCard.alpha = 0
        uploadingCard.isHidden = true

        armObservation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Appearing

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            pressCoordinator?.uninstall()
            pressCoordinator = nil
            return
        }
        installPress()
        apply(animated: false)
        // `.task { await repo.load() }` — once, when the row first appears.
        if !didLoad {
            didLoad = true
            Task { await repo.load() }
        }
    }

    /// THE ROW'S LONG PRESS, unchanged: one `UILongPressGestureRecognizer` on the row's own scroll
    /// view, and the lift is a photograph of the card that is actually on screen. It is installed by
    /// handing the coordinator a view INSIDE the scroller, because that is the anchor it looks for —
    /// the same thing the SwiftUI `.background { StoryRowLongPress { … } }` did from inside the
    /// scrolling content, minus the representable that used to carry it.
    private func installPress() {
        guard pressCoordinator == nil else { return }
        // `?? nil` is not noise: optional chaining on a method that already returns an optional gives
        // a DOUBLE optional, which is not the type the coordinator asks for.
        let c = StoryRowLongPress.Coordinator(target: { [weak self] p in self?.menuTarget(at: p) ?? nil })
        c.install(from: content)
        pressCoordinator = c
    }

    // MARK: Observation

    /// `@Observable` in UIKit. `onChange` fires just BEFORE the value changes and the subscription is
    /// one-shot, so the work hops to the next turn of the main actor and re-arms itself there.
    private func armObservation() {
        withObservationTracking {
            _ = repo.others
            _ = repo.mine
            _ = service.uploading
            _ = service.uploadPhase
            _ = service.uploadingImage
            _ = service.uploadError
            _ = doorState.activeAuthorUid
            _ = doorState.restoreRowToUid
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Re-armed BEFORE the work, so a change that lands while the row is updating is
                // still seen. Tracking is one-shot and there is no way to make it otherwise.
                self.armObservation()
                self.apply(animated: true)
            }
        }
    }

    // MARK: Order

    /// Ordering: UNVIEWED first, then VIEWED — BOTH sorted by newest post first (never by when I
    /// watched). Re-sorts live the instant a person's last unseen story is watched, and the cards
    /// animate.
    private var orderedOthers: [StoryGroup] {
        func newestFirst(_ a: StoryGroup, _ b: StoryGroup) -> Bool {
            (a.stories.last?.createdAt ?? .distantPast) > (b.stories.last?.createdAt ?? .distantPast)
        }
        let visible = repo.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        let unviewed = visible.filter { $0.hasUnseen }.sorted(by: newestFirst)
        let viewed = visible.filter { !$0.hasUnseen }.sorted(by: newestFirst)
        return unviewed + viewed
    }

    /// THE ROW HOLDS STILL WHILE A STORY IS OPEN, and that is not cosmetic. The order re-sorts LIVE:
    /// the moment the last unseen story of the person you are watching is marked seen, their card
    /// leaves the unviewed group and slides right — while you are still inside their story. The close
    /// then flies home to the card's NEW place, which with a few people in the row can be off the
    /// screen entirely. That was his screenshot of a story leaving sideways: the animation was
    /// correct and the target had moved under it.
    ///
    /// Frozen by IDENTITY, not by value: the cards themselves stay live, so covers still update.
    /// Anyone who posts while you are watching joins the end rather than being dropped.
    private var displayedOthers: [StoryGroup] {
        let live = orderedOthers
        guard freezeOrder, !frozenOrder.isEmpty else { return live }
        var byId: [String: StoryGroup] = [:]
        for g in live { byId[g.id] = g }
        let kept = frozenOrder.compactMap { byId[$0] }
        let keptIds = Set(kept.map(\.id))
        return kept + live.filter { !keptIds.contains($0.id) }
    }

    /// The ring a card draws: the latched one while a viewer is up, the live one otherwise. One door,
    /// so the row and my own card cannot answer this differently.
    private func displayedSeen(_ g: StoryGroup) -> [Bool] {
        if freezeOrder, let latched = frozenSeen[g.id] { return latched }
        return StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt)
    }

    /// Latch the order the moment a viewer opens, drop it the moment it closes. Nothing is kept
    /// beyond that, so a later row can never inherit a stale one.
    private func freezeChanged() {
        frozenOrder = freezeOrder ? orderedOthers.map(\.id) : []
        guard freezeOrder else { frozenSeen = [:]; apply(animated: true); return }
        var flags: [String: [Bool]] = [:]
        for g in orderedOthers { flags[g.id] = StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt) }
        // My own card is in here too: watching my own last story greys my own ring mid-visit exactly
        // the same way.
        if let m = repo.mine { flags[m.id] = StoryPrefs.seenFlags(m.stories, upTo: m.lastViewedAt) }
        frozenSeen = flags
        apply(animated: true)
    }

    /// Local hide/unhide has no observable state behind it (it lives in UserDefaults), so the row is
    /// told directly — the SwiftUI version bumped a `prefsTick` for the same reason.
    func prefsChanged() { apply(animated: true) }

    // MARK: Applying state

    private func apply(animated: Bool) {
        let groups = displayedOthers
        let ids = groups.map(\.id)
        let orderChanged = ids != displayedIds
        let animate = animated && hasAppliedOnce

        // My own card, and the uploading placeholder that cross-fades into it. The reload happens
        // before `uploading` flips, so there is no stale image in the hand-over.
        applyMyCard(animated: animate)

        // Cards: one per person, created and destroyed as people come and go.
        var live = Set<String>()
        var fresh = Set<String>()
        for g in groups {
            live.insert(g.id)
            let card = friendCards[g.id] ?? {
                let c = StoryCardUIView()
                c.alpha = 0
                fresh.insert(g.id)
                friendCards[g.id] = c
                content.addSubview(c)
                return c
            }()
            card.configureFriend(group: g, seen: displayedSeen(g), animated: animate) { [weak self] in
                self?.onOpen(g)
            }
        }
        let gone = friendCards.keys.filter { !live.contains($0) }

        displayedIds = ids
        layoutCards(removing: gone, fresh: fresh, animated: animate && orderChanged)

        // ASKED FOR, SO ANSWERED, WHETHER OR NOT ANYBODY MOVED. This used to run only on a change
        // of order, and it is the only thing that clears the pending uid, so closing a story whose
        // ring was already fully seen (nothing to re-sort, so no change) left the request sitting
        // there: the row did not come back to the person being watched, and the uid was spent much
        // later by some unrelated reorder, sliding the row sideways to somebody from a visit that
        // had ended long before. `restoreRowIfAsked` still stands down while the order is frozen, so
        // it cannot fire until the row is showing the order it is meant to restore into.
        restoreRowIfAsked()
        scrollToActiveIfNeeded()
        prefetchIfNeeded()
        presentErrorIfNeeded()
        hasAppliedOnce = true
    }

    private func applyMyCard(animated: Bool) {
        let uploading = service.uploading
        if uploading {
            uploadingCard.isHidden = false
            uploadingCard.configure(image: service.uploadingImage,
                                    meName: meName, mePhoto: mePhoto,
                                    // "Preparing…" is the honest word for the half that is actually
                                    // holding them up. "Uploading…" is his word (2026-08-06); it said
                                    // "Adding…", borrowed from another mainstream messenger, and he does not want it.
                                    phaseText: service.uploadPhase == .preparing ? "Preparing…" : "Uploading…",
                                    animatedPhase: animated) { [weak self] in
                // Tapping the still-uploading card ALWAYS opens the live upload viewer.
                self?.onOpenUploading()
            }
        } else {
            // Cover = last story, else the profile photo fills the card (rollback 2026-07-22: the
            // full-photo look is preferred). No photo at all → centered circle.
            let mine = repo.mine
            myCard.configureMine(coverUrl: mine?.stories.last?.previewUrl ?? mePhoto,
                                 meName: meName, mePhoto: mePhoto,
                                 seen: mine.map(displayedSeen) ?? [],
                                 heroKey: mine?.id,
                                 animated: animated,
                                 onTap: { [weak self] in
                                     guard let self else { return }
                                     if let m = self.repo.mine { self.onOpen(m) } else { self.onCompose() }
                                 },
                                 onBadge: { [weak self] in self?.onCompose() })
        }

        let showUploading: CGFloat = uploading ? 1 : 0
        guard myCard.alpha != 1 - showUploading || uploadingCard.alpha != showUploading else { return }
        // A cross-fade, so the "Uploading…" placeholder morphs straight into the final card in the
        // same frame — no jump. `.animation(.easeInOut(duration: 0.3), value: stories.uploading)`.
        let swap = {
            self.myCard.alpha = 1 - showUploading
            self.uploadingCard.alpha = showUploading
        }
        let settle = { self.uploadingCard.isHidden = !uploading }
        guard animated else { swap(); settle(); return }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState],
                       animations: swap) { _ in settle() }
    }

    // MARK: Layout

    private func layoutCards(removing gone: [String], fresh: Set<String> = [], animated: Bool) {
        let w = StoryRowMetrics.cardW
        let h = StoryRowMetrics.cardH + StoryRowMetrics.labelGap + StoryRowMetrics.labelH
        let y = StoryRowMetrics.vPad

        func place(_ v: UIView, at index: Int) {
            let x = StoryRowMetrics.hPad + CGFloat(index) * (w + StoryRowMetrics.spacing)
            // `center` and `bounds`, never `frame`: a card that is mid-dip carries a scale transform,
            // and setting the frame of a transformed view is how a card ends up the wrong size.
            v.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            v.center = CGPoint(x: x + w / 2, y: y + h / 2)
        }

        let arrange = {
            place(self.myCard, at: 0)
            place(self.uploadingCard, at: 0)
            for (i, id) in self.displayedIds.enumerated() {
                guard let card = self.friendCards[id] else { continue }
                place(card, at: i + 1)
                // TWO DIFFERENT ALPHAS, and they are not the same question. This one is MEMBERSHIP:
                // a card born this pass starts at 0 and fades in with the spring (see the note
                // below), a departing one fades out. Which PART of a card steps aside for a flight
                // or a lift is the card's own business, and asking it here rather than keeping a
                // second copy of that rule is what stops the name and the picture disagreeing.
                card.alpha = 1
                card.applyVisibility()
            }
            for id in gone { self.friendCards[id]?.alpha = 0 }
        }
        let cleanup = {
            for id in gone {
                self.friendCards[id]?.removeFromSuperview()
                self.friendCards.removeValue(forKey: id)
            }
        }

        let count = displayedIds.count + 1
        let contentW = StoryRowMetrics.hPad * 2 + CGFloat(count) * w
            + CGFloat(max(0, count - 1)) * StoryRowMetrics.spacing
        scrollView.contentSize = CGSize(width: contentW, height: StoryRowMetrics.rowH)
        content.frame = CGRect(x: 0, y: 0, width: contentW, height: StoryRowMetrics.rowH)

        // ⚠️ A CARD THAT HAS JUST BEEN BORN IS PLACED BEFORE THE SPRING, NEVER BY IT.
        //
        // His 9:07 report, "first time when i open App other stories is caming late", with a shot of
        // the row as a row of narrow overlapping OVALS. That shape is the diagnosis: a fresh UIView
        // has `bounds` of zero, so animating it into place ran its WIDTH from 0 to 93.5 — and a 24pt
        // corner on a view only forty points wide is a capsule, not a card. They were also stacked on
        // top of each other because every one of them was still travelling out from the origin.
        //
        // SwiftUI never did this. A `ForEach` inserts a new card ALREADY LAID OUT and gives it the
        // default `.opacity` transition, so only its alpha ever moved. This is that, restored: the
        // geometry lands first and unanimated, the spring is left with the fade and with the cards
        // that were already on screen and are genuinely sliding to new places.
        for (i, id) in displayedIds.enumerated() where fresh.contains(id) {
            guard let card = friendCards[id] else { continue }
            place(card, at: i + 1)
        }
        guard animated else { arrange(); cleanup(); publishRects(); return }
        // Smoothly slide cards to their new spots when a story moves unviewed → viewed-front.
        // `.animation(.spring(response: 0.42, dampingFraction: 0.82), value: displayedOthers.map(\.id))`
        isAnimatingOrder = true
        StorySpring.run(response: 0.42, damping: 0.82, arrange) {
            self.isAnimatingOrder = false
            cleanup()
            self.publishRects()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        // A layout pass in the middle of the re-sort would put every card straight onto its final
        // spot and cut the spring off at the knees. The animation is already placing them.
        guard !isAnimatingOrder else { return }
        layoutCards(removing: [], animated: false)
    }

    private func publishRects() {
        myCard.publishRect()
        for card in friendCards.values { card.publishRect() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // The written-down rectangles follow the finger, exactly as the SwiftUI reporter did on every
        // global-frame change. The live view is the real answer, but the fallback must not be stale.
        publishRects()
    }

    // MARK: The row follows the story

    /// ⚠️ THE ROW FOLLOWS HIM, and this is the other half of the wrong-landing fix.
    ///
    /// The viewer pages person to person; the row never moved. So the moment he swiped past the third
    /// or fourth card the person he was watching had no card on screen, and a close with nowhere to
    /// fly fell back to the person he had opened from. The row scrolls to whoever is active now, so
    /// there is always somewhere true to land AND the row he comes back to is sitting on the story he
    /// was actually watching — his "the list position must return to Salmo".
    ///
    /// FREE, because it happens behind a full-screen viewer: nobody sees the row move. Unanimated for
    /// the same reason, and because an animating scroll would still be settling when a fast pull-down
    /// asks for the card's rectangle.
    private func scrollToActiveIfNeeded() {
        let uid = doorState.activeAuthorUid
        guard uid != lastActiveAuthorUid else { return }
        lastActiveAuthorUid = uid
        guard let uid, !uid.isEmpty else { return }
        scrollToAuthor(uid)
    }

    /// AND HE IS STILL THERE AFTER THE RE-SORT. The close hands the story back to a card, then the
    /// repo reloads and the watched people move behind the unwatched — a scroll OFFSET does not
    /// survive that, so the row would settle on whoever happened to land at those points. The person
    /// is restored instead, once, the frame the new order is drawn.
    private func restoreRowIfAsked() {
        guard !freezeOrder, let uid = doorState.restoreRowToUid, !uid.isEmpty else { return }
        doorState.restoreRowToUid = nil
        scrollToAuthor(uid)
    }

    /// ENSURE VISIBLE, NEVER CENTRE — his 2026-08-10 instruction, and the reference app's rule read from
    /// its source before it.
    ///
    /// This used to be `proxy.scrollTo(uid, anchor: .center)` translated literally: work out the
    /// card's x, subtract half the viewport, set the offset. It moved the row on EVERY change of
    /// active person, including the open tap, whether or not the card had ever left the screen. So
    /// closing a story whose card was sitting in plain sight still slid the whole row sideways to
    /// put that card in the middle, which is the animation he is asking to be rid of: a card that
    /// never went anywhere does not need bringing back.
    ///
    /// `StoryPeerListComponent.setPreviewedItem` scrolls only when the item's frame does not
    /// intersect the row's bounds, and then by `scrollRectToVisible(frame.insetBy(dx: -40),
    /// animated: false)` — the minimum that puts it on screen with a 40pt margin, unanimated, never
    /// centred. His three rules are that call: fully visible does nothing, partly or wholly off
    /// screen scrolls just far enough, and the flight then lands on the card wherever it now is.
    ///
    /// Unanimated stays, and it matters more than ever now: the close asks for the card's rectangle
    /// immediately afterwards, and a scroll still settling would hand the flight a moving target.
    private func scrollToAuthor(_ uid: String) {
        guard let index = displayedIds.firstIndex(where: { id in
            // The scroll is keyed by AUTHOR, the cards by group id — the same pairing the SwiftUI
            // `.id(g.authorUid)` had.
            displayedOthers.first(where: { $0.id == id })?.authorUid == uid
        }) else { return }
        let w = StoryRowMetrics.cardW
        let x = StoryRowMetrics.hPad + CGFloat(index + 1) * (w + StoryRowMetrics.spacing)
        // `scrollView.bounds.origin` IS the content offset, so this rectangle is exactly what is on
        // screen right now — no arithmetic to get wrong. The card is given the same y and height so
        // `contains` asks a purely horizontal question.
        let visible = scrollView.bounds
        let card = CGRect(x: x, y: visible.minY, width: w, height: visible.height)
        // RULE 1: already all the way inside → the row does not move. This is the report.
        guard !visible.contains(card) else { return }
        // RULE 2: off screen or cut off → the minimum that brings it in, with the reference app's 40pt of
        // breathing room, so a card does not arrive flush against the edge reading as still cut off.
        scrollView.scrollRectToVisible(card.insetBy(dx: -Self.ensureVisibleMargin, dy: 0),
                                       animated: false)
    }

    /// The reference app's `-40` in `scrollRectToVisible(itemFrame.insetBy(dx: -40))`.
    private static let ensureVisibleMargin: CGFloat = 40

    // MARK: Prefetch

    /// WARM THE FRONT OF EACH RING WHILE THE ROW IS ON SCREEN.
    ///
    /// The viewer's own prefetcher can only warm what comes after something already open — the FIRST
    /// tap was cold every time, and that is the tap somebody decides whether this app is fast on.
    ///
    /// Keyed on the ordered ids rather than a bare appearance: the row re-sorts live as stories are
    /// watched and as new ones land, and the ring that just moved to the front is exactly the one
    /// worth having ready.
    private func prefetchIfNeeded() {
        let ordered = orderedOthers
        let key = ordered.map(\.id).joined()
        guard key != lastPrefetchKey else { return }
        lastPrefetchKey = key
        // The one story each person will actually open on — their first UNSEEN item, which is where
        // the viewer starts — falling back to their first if everything is watched. Warming the last
        // item instead (the one the card's cover comes from) would warm the wrong end of the ring.
        let items: [StoryPrefetcher.Item] = ordered.compactMap { g in
            let s = g.stories.first(where: { !StoryPrefs.isStorySeen($0.id) }) ?? g.stories.first
            guard let s, !s.mediaUrl.isEmpty else { return nil }
            return StoryPrefetcher.Item(media: s.mediaUrl, poster: s.previewUrl, isVideo: s.isVideo)
        }
        StoryPrefetcher.prefetchFirsts(items)
    }

    // MARK: The menu

    /// WHICH CARD IS UNDER THE FINGER, and what its menu says. Asked at press time by the row's press
    /// recogniser, so it describes the row as it stands rather than as it stood at layout.
    ///
    /// The rectangles come from the same registry the story flight flies to, which means the lift and
    /// the flight can never disagree about where a card is — one answer, one source.
    private func menuTarget(at p: CGPoint) -> StoryMenuTarget? {
        func hit(_ id: String) -> CGRect? {
            guard !id.isEmpty,
                  let r = MediaOpenRects.liveRect(MediaOpenRects.key(.storyRow, id)),
                  r.contains(p) else { return nil }
            return r
        }
        // THE HIT USES THE MODEL RECT, THE LIFT USES THE DRAWN ONE. At press time the card is
        // mid-press-dip: the model already says 0.92 while the pixels still show ~0.96, and a crop
        // taken with the model rectangle magnifies the picture (his 2026-08-09 zoom report — see
        // `MediaOpenRects.drawnRect`). The finger test stays on `liveRect`: it is the same answer
        // the flight flies to, and a hit test does not care about a few points of spring.
        func lifted(_ key: String, _ model: CGRect) -> CGRect {
            MediaOpenRects.drawnRect(key) ?? model
        }
        // My own card first: it is drawn first and nothing overlaps it.
        if let m = repo.mine, !m.stories.isEmpty, let r = hit(m.id) {
            let key = MediaOpenRects.key(.storyRow, m.id)
            return StoryMenuTarget(key: key, rect: lifted(key, r), actions: [
                CMAction(title: "Add Story", icon: "ic_stories") { [weak self] in self?.onCompose() },
                CMAction(title: "Posted Stories", icon: "circle.dashed") { [weak self] in self?.onOpen(m) },
            ], labelRect: myCard.labelView.flatMap { MediaOpenRects.drawnRect(of: $0) } ?? myCard.labelWindowRect,
               labelView: myCard.labelView)
        }
        // NOTHING POSTED, AND THE PRESS STILL HAS TO ANSWER. The branch above needs a story to
        // find a rectangle, so with an empty My Story the whole press fell through to the friends
        // loop, matched nothing, and the menu never came up — while the same press on a posted card
        // worked. The card is still a card, and the one thing it can offer is the compose action it
        // already performs on a tap.
        // `!service.uploading` keeps the placeholder out of it: while a post is going up the slot is
        // drawn by the uploading card, and a lift there would photograph that card while offering an
        // action about a different one. That press did nothing before and it still does nothing.
        if repo.mine?.stories.isEmpty ?? true, !service.uploading,
           let r = hit(StoryCardUIView.emptyMyStoryKey) {
            let key = MediaOpenRects.key(.storyRow, StoryCardUIView.emptyMyStoryKey)
            return StoryMenuTarget(key: key, rect: lifted(key, r), actions: [
                CMAction(title: "Add Story", icon: "ic_stories") { [weak self] in self?.onCompose() },
            ], labelRect: myCard.labelView.flatMap { MediaOpenRects.drawnRect(of: $0) } ?? myCard.labelWindowRect,
               labelView: myCard.labelView)
        }
        for g in displayedOthers {
            guard let r = hit(g.id) else { continue }
            let key = MediaOpenRects.key(.storyRow, g.id)
            let lv = friendCards[g.id]?.labelView
            // A friend's card dips on press exactly as mine does, so its lift takes the drawn rect too.
            return StoryMenuTarget(key: key, rect: lifted(key, r), actions: [
                CMAction(title: "Send Message", icon: "message") { [weak self] in self?.onMessage(g) },
                CMAction(title: "Open Profile", icon: "person.crop.circle") { [weak self] in self?.onProfile(g) },
                CMAction(title: "Hide Stories", icon: "archivebox", destructive: true) { [weak self] in
                    self?.confirmHide(g)
                },
                // The name is lifted with the card now (his "also show Name"). It comes from the card
                // itself rather than from the group, so what rises is the label the row is drawing.
            ], labelRect: lv.flatMap { MediaOpenRects.drawnRect(of: $0) } ?? friendCards[g.id]?.labelWindowRect,
               labelView: lv)
        }
        return nil
    }

    // MARK: Alerts

    private var presenter: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController {
                var top = vc
                while let p = top.presentedViewController { top = p }
                return top
            }
            responder = r.next
        }
        return nil
    }

    /// A native ALERT, not an action sheet: over the stories row a confirmation dialog rendered as an
    /// anchored popover with its arrow pointing at the row. An alert is the standard centred modal.
    private func confirmHide(_ g: StoryGroup) {
        let name = g.name.isEmpty ? "this person" : g.name
        let a = UIAlertController(
            title: "Hide Stories?",
            message: "New story updates from \(name) won't appear at the top of the stories list anymore.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Hide Stories", style: .destructive) { [weak self] _ in
            StoryPrefs.setHidden(g.authorUid, true)
            self?.prefsChanged()
        })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter?.present(a, animated: true)
    }

    private func presentErrorIfNeeded() {
        guard let message = service.uploadError, message != lastErrorShown else {
            if service.uploadError == nil { lastErrorShown = nil }
            return
        }
        // MARKED AS SHOWN ONLY ONCE IT REALLY HAS BEEN SHOWN. There is no presenter while the row is
        // off a window, which is exactly where you are when an upload fails while you are reading a
        // chat, and recording the message first threw the alert away AND buried it: the guard above
        // never let that same text through again, and the OK handler that clears `uploadError` never
        // ran, so the failure sat in the service unseen for the rest of the session. Leaving now
        // costs nothing: `uploadError` is still set and still observed, so the next `apply` puts the
        // alert up the moment there is somewhere to put it.
        guard let host = presenter else { return }
        lastErrorShown = message
        let a = UIAlertController(title: "Couldn't post story", message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.service.uploadError = nil
            self?.lastErrorShown = nil
        })
        host.present(a, animated: true)
    }
}

// MARK: - The SwiftUI face

/// The row as MainShell still constructs it: same name, same arguments, same order.
///
/// ⚠️ `freezeOrder` KEEPS ITS DEFAULT AND ITS POSITION. The memberwise initialiser is what MainShell
/// calls, so the order of these properties is the call site's argument order — moving one is a
/// compile error over there, in a `body` that is already at the type-checker's limit.
struct StoriesRow: UIViewRepresentable {
    var meName: String
    var mePhoto: String?
    var freezeOrder: Bool = false
    var onCompose: () -> Void
    var onOpen: (StoryGroup) -> Void
    var onMessage: (StoryGroup) -> Void = { _ in }
    var onProfile: (StoryGroup) -> Void = { _ in }
    var onOpenUploading: () -> Void = {}

    func makeUIView(context: Context) -> StoriesRowUIView {
        let v = StoriesRowUIView()
        push(v)
        return v
    }

    func updateUIView(_ v: StoriesRowUIView, context: Context) { push(v) }

    private func push(_ v: StoriesRowUIView) {
        v.meName = meName
        v.mePhoto = mePhoto
        v.onCompose = onCompose
        v.onOpen = onOpen
        v.onMessage = onMessage
        v.onProfile = onProfile
        v.onOpenUploading = onOpenUploading
        v.freezeOrder = freezeOrder      // last: its observer re-lays the row out
    }

    /// MainShell reads this height (`onGeometryChange`) and turns it into the chat list's top content
    /// margin, so it has to be the row's real height and it has to be known without waiting for a
    /// layout pass. Every part of it is a constant or derives from the screen width.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: StoriesRowUIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? UIScreen.main.bounds.width, height: StoryRowMetrics.rowH)
    }
}

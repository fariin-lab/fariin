//
//  UserView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 29.04.2022.
//

import SwiftUI
import UIKit   // UIMenu + UIAction.subtitle - see StoryMoreMenu

struct UserView: View {

    var image: String
    var name: String
    /// The app's verification tick, answered by the host — see `StoryUIUser.isVerified`. Drawn beside
    /// the name in both header shapes, because a badge that appears only on some stories reads as a
    /// bug rather than as a distinction.
    var isVerified: Bool = false
    var date: String
    /// Who this story went to. Nil draws nothing and the header keeps its old two-line shape.
    var audience: StoryAudienceBadge? = nil
    var onProfile: (() -> Void)?   // tap the avatar+name block → that user's profile
    var showMore: Bool = false     // show the "…" dropdown menu; its buttons post notifications the host runs
    var isMyStory: Bool = false    // my own story → Delete (red) instead of Hide Stories; no Forward
    /// Offer "Edit viewers" on this story. The host decides — see `Story.canEditAudience`.
    var canEditAudience: Bool = false
    /// Was it posted to Everyone. Decides whether Share is offered — see `Story.isPublicStory`.
    var isPublicStory: Bool = false

    @Binding var isPresented: Bool

    /// The same glyph and the same blue the app's own `VerifiedMark` draws, so a tick on a story
    /// looks like a tick everywhere else. Nothing when the host says no, so this costs an untouched
    /// header exactly nothing.
    @ViewBuilder private var verifiedTick: some View {
        if isVerified {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white, Color(red: 0.0, green: 0.48, blue: 1.0))
                .symbolRenderingMode(.palette)
                .accessibilityLabel("Verified")
        }
    }

    /// WHAT THE "…" OFFERS, in the order he drew it.
    ///
    /// SAVE AND SHARE ARE MINE-ONLY. Both take a story OFF this app permanently, and a story is a
    /// promise that it is gone in 24 hours: Save puts it in a camera roll and Share hands the picture
    /// straight to another app. The author is never told either happened.
    ///
    /// The standard messengers do not offer them on another person's story. The reference app does,
    /// but only when the author switched it on for that story. Nobody sells it as a paid feature
    /// (owner asked, 2026-08-05).
    ///
    /// ⚠️ FORWARD IS GONE, on his 2026-08-18 instruction. It put the picture into another chat
    /// inside this app — which sounds gentler than Share and is not: the copy that lands in a chat
    /// does not expire in 24 hours, so forwarding a story quietly turned an ephemeral thing into a
    /// permanent one, and the author was never told. Share survives, narrowed to the one audience
    /// where it costs nothing — see below.
    ///
    /// No Delete on my own story — the owner bar already has a trash button, so it lived in two
    /// places. Others' stories keep Hide Stories and Report (App Store 1.2; the host files the doc).
    private var moreItems: [StoryMoreMenu.Item] {
        var out: [StoryMoreMenu.Item] = []
        if isMyStory {
            out.append(.init(title: "Save", systemImage: "square.and.arrow.down") {
                NotificationCenter.default.post(name: .init("storyActionSave"), object: nil)
            })
            // ⚠️ THE SECOND LINE IS THE AUDIENCE THIS STORY ACTUALLY WENT TO, and it is the same
            // string the pill under the name is showing — `storyAudienceTitle` on the host side, which
            // the badge already carries. One source, so the menu and the header can never name the
            // same audience two different ways. It sits between Forward and Share on his drawing.
            if canEditAudience {
                // His own drawing, 2026-08-18: a list inside a rounded square. `megaphone` said
                // "announce" — this row is about WHO the story is addressed to, which is a list.
                // `systemImage` stays as the fallback for a build where the asset is missing.
                out.append(.init(title: "Edit viewers", subtitle: audience?.text,
                                 systemImage: "megaphone",
                                 assetImage: "ic_edit_viewers") {
                    NotificationCenter.default.post(name: .init("storyActionEditViewers"), object: nil)
                })
            }
            // ⛔ SHARE ONLY ON A STORY ANYBODY CAN ALREADY REACH — his 2026-08-18 rule, and it is
            // the same reasoning that took Forward off this menu entirely.
            //
            // A story sent to My Friends or to a named list was chosen to be narrow. Share hands the
            // picture straight out of the app, where the audience the author picked means nothing and
            // nobody can take it back — so the one audience it belongs to is the one that is already
            // public. Forward had the same shape with none of the excuse, so it is gone.
            if isPublicStory {
                out.append(.init(title: "Share", systemImage: "square.and.arrow.up") {
                    NotificationCenter.default.post(name: .init("storyActionShare"), object: nil)
                })
            }
        } else {
            out.append(.init(title: "Hide Stories", systemImage: "eye.slash") {
                NotificationCenter.default.post(name: .init("storyActionHide"), object: nil)
            })
            out.append(.init(title: "Report", systemImage: "exclamationmark.bubble", destructive: true) {
                NotificationCenter.default.post(name: .init("storyActionReport"), object: nil)
            })
        }
        return out
    }

    var body: some View {
        // ⚠️ SPELLED OUT HERE RATHER THAN TAKEN FROM `hStackSpace` (owner 2026-08-22: the gap
        // between the two buttons went 13 → 12, then 12 → 10). That constant is shared with the
        // avatar-to-name gap on the very next line, and he asked for this one gap only — moving the
        // constant would have pulled the name in against the picture as a side effect.
        HStack(spacing: 10) {
            // Tappable header block (avatar 38pt + name 14pt + timestamp 12pt) → profile.
            HStack(spacing: Constant.UserView.hStackSpace) {
                CacheAsyncImage(urlString: image, name: name)   // 38×38 circle
                VStack(alignment: .leading, spacing: 2) {
                    // TWO SHAPES, AND THE AUDIENCE DECIDES WHICH. With a line to fit underneath,
                    // the name and the time share the top row: the time is a detail about the name,
                    // and stacking all three pushed a block into the picture. With nothing
                    // underneath — which is every story but my own — the header goes back to the
                    // shape it had before the audience line existed: name, time under it (owner,
                    // 2026-08-07: "show only name and time like before, name up time under name").
                    if audience == nil {
                        HStack(spacing: 4) {
                            Text(name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            verifiedTick
                        }
                        Text(date)
                            // 13, up from 12 (owner 2026-08-09: "too small… but not too much") —
                            // one point under the name so the hierarchy still reads name-first.
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            HStack(spacing: 4) {
                                Text(name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                verifiedTick
                            }
                            Text(date)
                                .font(.system(size: 13, weight: .regular))   // matches the no-badge branch
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                                // The name may be long; the time must not be the thing that gets cut,
                                // because half a timestamp reads as a bug rather than as a shortage of room.
                                .layoutPriority(1)
                        }
                    }
                    if let audience {
                        HStack(spacing: 5) {
                            // An asset wins when there is one. Sized by FRAME rather than by font,
                            // because a drawn glyph has no text metrics to follow, and squared to
                            // the symbol's own optical size so the pill's height does not change
                            // depending on which audience a story went to.
                            if let asset = audience.assetImage {
                                Image(asset, bundle: .main)
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: audience.systemImage)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(audience.text).font(.system(size: 12, weight: .regular))
                                .lineLimit(1)
                        }
                        // Brighter than the timestamp above it: this is information, not metadata,
                        // and at 0.7 on a bright photo it disappeared into the picture.
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onProfile?() }

            Spacer()

            // The "more" button sits directly left of the X, same row, so they auto-align (no
            // guessed padding).
            if showMore {
                // Tap it → the same native dropdown anchored under the button. Only the MENU moved
                // to UIKit, never the button — see `StoryMoreMenu` for the one reason it had to.
                StoryMoreGlyph()
                    .frame(width: 32, height: 32)
                    .storyHeaderIconShadow()
                    .frame(width: 44, height: 44)                      // keep the 44pt tap target
                    .contentShape(Rectangle())
                    .overlay(StoryMoreMenu(items: moreItems).frame(width: 44, height: 44))
            }

            // Glyph in a 44×44 touch target. No plate behind it — the shadow is what carries it
            // over a bright picture (owner, 2026-08-22).
            // ⚠️ 17 IS THE POINT SIZE, 14 IS THE MARK (owner 2026-08-22: the X goes 12pt → 14pt).
            // A symbol's drawn glyph is smaller than the point size it is asked for — measured off
            // his own screenshots, `xmark` comes out at about 0.83 of it, which is how the old 15
            // produced the 12pt mark. 14 / 0.83 rounds to 17. Keep them in step: changing this
            // number changes the mark by roughly five sixths of the change.
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .storyHeaderIconShadow()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .pauseStory, object: nil)
                    isPresented = false
                }
        }
        .padding(.horizontal)
    }
}

/// The story header's "more" mark: two left-aligned rounded bars, the lower one short.
///
/// Drawn rather than pulled from SF Symbols because no stock symbol is two bars of UNEQUAL length —
/// `line.3.horizontal` is three, `equal` is two of the same width — and the difference between them
/// is the whole shape. Numbers measured off the owner's 2026-08-22 mockup at 3× (56×4.5px over a
/// 19px gap, then 38×4.5px) rather than guessed.
private struct StoryMoreGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metric.gap) {
            Capsule().frame(width: Metric.topWidth, height: Metric.thickness)
            Capsule().frame(width: Metric.bottomWidth, height: Metric.thickness)
        }
        // A `Shape` fills with the foreground style, so this is what colours both bars.
        .foregroundColor(.white)
    }

    /// ⚠️ SCALED AS A WHOLE, NOT WIDENED (owner 2026-08-22: the mark goes 19pt → 21pt). Every number
    /// below is the measured one multiplied by 21/19, so the two bars keep the proportions taken off
    /// his mockup — the short bar stays the same fraction of the long one, and the bars stay the same
    /// weight relative to their length. Stretching only the top bar would have made it a different
    /// mark at the same size.
    private enum Metric {
        static let topWidth: CGFloat = 21
        static let bottomWidth: CGFloat = 14.4
        static let thickness: CGFloat = 1.8
        static let gap: CGFloat = 7.1
    }
}

extension View {
    /// What replaced the grey plate behind the story header's two icons (owner, 2026-08-22: white
    /// icons only, no visible background, still readable when the story photo is white).
    ///
    /// TWO shadows, because one cannot do both jobs. The tight one at radius 1 draws an edge so a
    /// 1.6pt white bar does not dissolve into white pixels; the soft one at radius 3 lifts the whole
    /// glyph off the picture. Kept low in opacity — over a dark story neither is visible, which is
    /// the point: this is insurance for the bright end, not a look.
    func storyHeaderIconShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.28), radius: 1, x: 0, y: 0)
            .shadow(color: .black.opacity(0.38), radius: 3, x: 0, y: 1)
    }
}

/// ⚠️ THE STORY MENU IS A UIKit `UIMenu` NOW, AND ONLY BECAUSE OF ONE SECOND LINE.
///
/// His 2026-08-18 drawing puts the story's current audience UNDER "Edit viewers", in grey — the way
/// iOS has drawn a menu item with a subtitle since iOS 15 (`UIMenuElement.subtitle`). SwiftUI's
/// `Menu` renders ONE line whatever view is handed to it: a `VStack` of two `Text`s comes out as the
/// first one alone. That is the same wall the "+ New" button in the audience sheet hit, and this is
/// the same answer it reached (`NewAudienceButton`).
///
/// ⚠️ THE BUTTON IS STILL THE SWIFTUI ONE, AND NOTHING ABOUT THE LOOK CHANGES. This is a
/// transparent `UIButton` laid over the mark that was already there, with
/// `showsMenuAsPrimaryAction`, so the glyph and its 44pt target are drawn by exactly the same
/// SwiftUI code as before (`StoryMoreGlyph`). The dropdown is identical too — SwiftUI's `Menu` is a
/// `UIMenu` underneath — which was his condition: the design does not move.
///
/// ⚠️ IT IS GIVEN AN EXPLICIT FRAME BY ITS CALLER, and it needs one. SwiftUI sizes a
/// representable from the view's intrinsic size, and a `UIButton` with no title barely has one —
/// left to itself the tap target would be a few points across in the middle of the mark, and most
/// taps on the glyph would land on nothing. (`sizeThatFits` would be the tidier answer and is
/// iOS 16; this package is built for 15.)
struct StoryMoreMenu: UIViewRepresentable {

    struct Item {
        var title: String
        /// The grey second line. Nil draws a one-line item, which is every entry but one.
        var subtitle: String? = nil
        var systemImage: String
        /// An icon from the APP's asset catalog, when no SF Symbol says the right thing. Nil for
        /// every entry that has one, which is most of them.
        ///
        /// ⚠️ `Bundle.main`, NOT THE PACKAGE'S. This type lives in StoryUI and the artwork lives in
        /// the app, which is the same arrangement `StoryAudienceBadge.assetImage` already uses and
        /// draws through `Image(asset, bundle: .main)`. Rendered as a TEMPLATE so the menu tints it
        /// like every symbol beside it rather than painting whatever colour the file carries.
        var assetImage: String? = nil
        var destructive: Bool = false
        var action: () -> Void

        init(title: String, subtitle: String? = nil, systemImage: String,
             assetImage: String? = nil,
             destructive: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.subtitle = subtitle
            self.assetImage = assetImage
            self.systemImage = systemImage
            self.destructive = destructive
            self.action = action
        }
    }

    let items: [Item]

    /// ⚠️ WHAT THE MENU IS MADE OF, AS ONE COMPARABLE STRING, AND IT IS THE WHOLE REASON THE MENU
    /// WAS DEAD.
    ///
    /// His 2026-08-18 report: the dropdown opens and shows the right three entries, and tapping any
    /// of them does nothing at all.
    ///
    /// `updateUIView` reassigned `b.menu` every single time it ran, and it runs on every re-render of
    /// the story page — which is TWENTY TIMES A SECOND, because the progress bar advances on a 0.05s
    /// tick and the header is redrawn with it. So for the whole time the dropdown was open, the
    /// button's menu was being replaced underneath the presented copy, and the `UIAction` the finger
    /// eventually landed on belonged to a `UIMenu` that had been thrown away several frames earlier.
    /// Nothing was wrong with the actions, the notifications or the host's handlers; the menu the
    /// user was looking at simply was not the button's menu any more.
    ///
    /// ⚠️ AND `Item` CANNOT BE `Equatable`, WHICH IS WHY THIS IS A STRING. It carries a closure, so
    /// the compiler cannot synthesise equality and SwiftUI cannot skip the update for us. Everything
    /// the menu actually DRAWS is in here; the closures are deliberately left out, because a fresh
    /// closure every render is exactly the thing that must stop forcing a rebuild.
    private var signature: String {
        items.map { "\($0.title)|\($0.subtitle ?? "")|\($0.systemImage)|\($0.destructive)" }
            .joined(separator: "\u{1F}")
    }

    /// THE BUTTON SAYS WHEN ITS OWN MENU OPENS AND CLOSES, BECAUSE UIKIT ALREADY TELLS IT.
    ///
    /// ⛔ HIS FOURTH REPORT ON THIS MENU, 2026-08-24: "when I open the menu the story is still
    /// running." Three attempts before this one INFERRED the moment — from `.menuActionTriggered`,
    /// from `.touchDown`, from a long-press recognizer, and released it by watching which UIWindow
    /// became key. Every one of them was built on a sentence in this file that was simply false:
    /// that a `UIButton` menu has no open/close callback.
    ///
    /// ⚠️ IT HAS TWO, THEY ARE PUBLIC, AND THEY ARE WHAT THE REFERENCE APP USES. `UIButton` conforms
    /// to `UIContextMenuInteractionDelegate`, so a subclass can override the two moments outright
    /// (their `ContextMenuButton` does exactly this and nothing else):
    ///
    ///   willDisplayMenuFor  → the menu is about to appear   → pause
    ///   willEndFor          → the menu is about to go away   → resume
    ///
    /// No touches, no windows, no timing. The inference is all deleted with this: guessing at a
    /// moment UIKit announces is what made this take four rounds.
    final class StoryMenuButton: UIButton {
        var onWillDisplayMenu: () -> Void = {}
        var onDidDismissMenu: () -> Void = {}

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                             animator: UIContextMenuInteractionAnimating?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            onWillDisplayMenu()
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willEndFor configuration: UIContextMenuConfiguration,
                                             animator: UIContextMenuInteractionAnimating?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            onDidDismissMenu()
        }
    }

    final class Coordinator: NSObject {
        var signature: String?
        /// The pause this menu owns, so it is released exactly once and only by the menu that took it.
        var pausedForMenu = false

        /// ⚠️ THE STORY STOPS WHILE THE DROPDOWN IS UP — his ask, and the note on the host's own
        /// `pauseStory` handler already said this was meant to happen ("Host shows/hides a sheet over
        /// the viewer (viewers list, share, menu)"). The menu was the one of those three that never
        /// posted it, so the bar kept running and the story kept advancing behind an open menu.
        ///
        /// No new pause system, which was his condition: this posts the same `.pauseStory` the
        /// viewers sheet, the share sheet and the dismiss drag post, and the host's `hostPause` gates
        /// the progress timer and the video mode together.
        func pause() {
            guard !pausedForMenu else { return }
            pausedForMenu = true
            NotificationCenter.default.post(name: .pauseStory, object: nil)
        }

        func resume() {
            guard pausedForMenu else { return }
            pausedForMenu = false
            NotificationCenter.default.post(name: .resumeStory, object: nil)
        }

        /// A menu still up when this view goes away must not strand the pause.
        deinit { resume() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> StoryMenuButton {
        let b = StoryMenuButton(type: .custom)
        b.showsMenuAsPrimaryAction = true
        b.backgroundColor = .clear
        // ⛔ THE MENU'S OWN TWO MOMENTS, AND NOTHING ELSE — see `StoryMenuButton`. Everything that
        // used to be here was an attempt to guess these: control events that a menu button need not
        // send, a zero-delay long-press recognizer, and window-key notifications to guess the close.
        // All deleted. UIKit announces both moments to the button itself.
        let coordinator = context.coordinator
        b.onWillDisplayMenu = { coordinator.pause() }
        b.onDidDismissMenu = { coordinator.resume() }
        // ⚠️ ALL FOUR PRIORITIES DROPPED, AND IT IS THE TAP TARGET THAT DEPENDS ON IT. A
        // `UIButton` with no title and no image has a tiny intrinsic size, and SwiftUI sizes a
        // representable from that unless the view says it will take whatever it is given — so the
        // button would end up a few points across in the middle of a 44pt mark, and most taps on the
        // glyph would miss it. The caller's `.frame(width: 44, height: 44)` is then the size.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            b.setContentHuggingPriority(.defaultLow, for: axis)
            b.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        b.menu = menu(context.coordinator)
        context.coordinator.signature = signature
        return b
    }

    func updateUIView(_ b: StoryMenuButton, context: Context) {
        // ⚠️ ONLY WHEN THE MENU HAS ACTUALLY CHANGED, AND THE GUARD IS THE FIX. A `UIMenu` cannot
        // have its children edited in place, so a genuine change still means a fresh one — but this
        // ran on every re-render, and the story page re-renders twenty times a second while the
        // progress bar moves. Replacing the menu under a menu that is currently OPEN is what made
        // every entry in it dead. See `signature`.
        //
        // The audience line under "Edit viewers" is the one thing here that legitimately changes
        // while the viewer is up, and it is in the signature, so it still updates.
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        b.menu = menu(context.coordinator)
    }

    /// The square an SF Symbol occupies in a menu row, measured from a real one. Asset artwork is
    /// drawn to fit inside it, aspect kept, so a hand-drawn icon sits at the same visual weight as
    /// the symbols above and below it. Nil-safe: without a reference symbol the art is left alone,
    /// which is exactly what it did before.
    private static func fittedToSymbolBox(_ art: UIImage) -> UIImage {
        guard let box = UIImage(systemName: "square.and.arrow.down")?.size,
              box.width > 1, box.height > 1, art.size.width > 1, art.size.height > 1 else { return art }
        let scale = min(box.width / art.size.width, box.height / art.size.height)
        let target = CGSize(width: art.size.width * scale, height: art.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            art.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func menu(_ coordinator: Coordinator) -> UIMenu {
        // ⛔ NO OPENING ELEMENT HERE ANY MORE. A `UIDeferredMenuElement.uncached` used to sit at the
        // head of this menu purely to be ASKED, so that being asked could stand in for "the menu is
        // opening". That was the third guess at a moment UIKit reports directly — see
        // `StoryMenuButton`, which overrides the two callbacks the button already receives.
        return UIMenu(title: "", children: items.map { item in
            // The app's own artwork when the entry names one, the SF Symbol otherwise. Template
            // rendering so a `UIMenu` tints it exactly like the symbols around it; without it the
            // file's own colour is drawn and the row looks like a different app's.
            // ⛔ AND THE ARTWORK IS SIZED LIKE A SYMBOL, NOT SHIPPED AT ITS OWN SIZE — his
            // 2026-08-28 screenshot, where "Edit viewers" wears a visibly bigger, heavier glyph than
            // Save and Share on either side of it.
            //
            // A `UIMenu` sizes an SF Symbol for itself: it applies the row's own point size and
            // every symbol comes out matching. A file from the asset catalogue gets no such
            // treatment — it is drawn at whatever it was exported at, so one hand-drawn icon among
            // symbols is the one row that looks wrong. Fitting it into the box a symbol occupies is
            // the whole fix, and it is measured from a real symbol rather than a guessed constant so
            // it follows the system's own metrics if they change.
            let icon = item.assetImage
                .flatMap { UIImage(named: $0) }
                .map { Self.fittedToSymbolBox($0).withRenderingMode(.alwaysTemplate) }
                ?? UIImage(systemName: item.systemImage)
            let action = UIAction(title: item.title,
                                  image: icon,
                                  attributes: item.destructive ? .destructive : []) { _ in
                // The menu is gone the moment an entry is chosen, so the pause it took is released
                // here as well as by the window notifications. What happens NEXT is the host's
                // business: a sheet it opens posts its own pause, and Save leaves the story running,
                // which is what picking Save should do.
                coordinator.resume()
                item.action()
            }
            // Set rather than passed to the initialiser: `subtitle` is a plain property on
            // `UIMenuElement`, and going through it keeps this working whatever the initialiser
            // overload set happens to be.
            action.subtitle = item.subtitle
            return action
        })
    }
}

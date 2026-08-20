import SwiftUI
import UIKit

// Flattened story image awaiting the audience sheet (used by both the photo editor + text composer).
/// `video` is the FIRST item when that item is a clip. It used to be missing, and the multi-item
/// editor had nowhere to put one: it handed the sheet only `data`, which for a video is its poster.
/// So a post whose first item was a video silently posted a still of it. Reachable by picking a
/// photo, adding a video, then deleting the photo — the X on the thumbnail strip does exactly that.
struct StoryShareData: Identifiable {
    let id = UUID()
    let data: Data
    var caption: String = ""
    var video: StoryVideoPayload? = nil
    /// The Link and Location stickers on this item — see `StoryTapTarget`.
    var stickers: [StoryTapTarget] = []
}

/// A STICKER THAT STILL DOES SOMETHING AFTER IT HAS BEEN POSTED.
///
/// ⚠️ THE PICTURE CANNOT CARRY THIS AND THAT IS THE ENTIRE PROBLEM IT SOLVES. A story is a flat JPEG
/// (or a clip with the art burned into its frames), so a Link sticker is, by the time it reaches
/// anybody, a photograph of a button. What is missing is not the drawing — that survives perfectly —
/// but WHERE it is and WHAT it opens. Those two facts travel beside the media, on the story document,
/// and the viewer lays an invisible tap area over the picture from them.
///
/// ⚠️ EVERYTHING IS NORMALISED 0-1 AGAINST THE STORY'S OWN FRAME, never points. The author's card,
/// the exported file and the viewer's card are three different sizes on three different phones; a
/// rectangle in points would be right on exactly one of them.
/// `Codable` and `Hashable` because `Story` is both and carries an array of these. All six members
/// are plain values, so both are synthesised — but leaving them off does not fail here, it fails on
/// `Story`, several hundred lines away, saying only that `Story` no longer conforms.
struct StoryTapTarget: Equatable, Codable, Hashable {
    var x: Double        // centre, 0-1 across the frame
    var y: Double        // centre, 0-1 down the frame
    var w: Double        // 0-1 of the frame's width
    var h: Double        // 0-1 of the frame's height
    var rotation: Double // radians, the same turn the sticker was left at
    /// Where it goes. A link sticker carries what was typed; a place carries a maps url built from
    /// its coordinates — ONE field, because "open this" is one behaviour and a second field would be
    /// a second thing for the viewer to branch on.
    var url: String

    var asDictionary: [String: Any] {
        ["x": x, "y": y, "w": w, "h": h, "rotation": rotation, "url": url]
    }

    /// ⚠️ ANYTHING THAT IS NOT A WEB OR MAPS URL IS DROPPED ON THE WAY IN, not on the way out. This
    /// is a string another phone wrote, handed to `openURL` — so `tel:`, `sms:` and every custom
    /// scheme some other app has registered are refused here, where the rule is written once, rather
    /// than at each of the places that might one day open one.
    static func from(_ raw: Any?) -> StoryTapTarget? {
        guard let d = raw as? [String: Any],
              let url = d["url"] as? String,
              let scheme = URL(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let x = d["x"] as? Double, let y = d["y"] as? Double,
              let w = d["w"] as? Double, let h = d["h"] as? Double,
              w > 0, h > 0 else { return nil }
        return StoryTapTarget(x: x, y: y, w: w, h: h,
                              rotation: d["rotation"] as? Double ?? 0, url: url)
    }
}

/// One more item posted behind the first, in the order the user arranged them. The audience sheet is
/// answered ONCE and every item inherits that answer — being asked who can see it seven times for one
/// post is the thing this avoids.
struct StoryExtra: Identifiable {
    let id = UUID()
    var photo: Data? = nil
    var video: StoryVideoPayload? = nil
    /// Per ITEM, not per post: each picture in a post has its own stickers, and posting them all
    /// against the first one is how a link ends up on somebody else's photograph.
    var stickers: [StoryTapTarget] = []
    /// ⚠️ AND SO IS THE CAPTION, which used to be posted as `""` on every extra. See below.
    var caption: String = ""
}

// A picked video awaiting the audience sheet: the source file + the poster frame the editor
// already generated (drives the uploading ring immediately; the transcode runs in the background).
// muted = the editor's speaker toggle → the upload strips the audio track (real, as standard messengers do).
// `trim`: the range the user kept on the trim screen, in seconds. nil = the whole clip. Carried
// rather than exported on the spot, so opening trim and changing your mind costs nothing and the
// clip is encoded exactly once, at post time.
struct StoryVideoPayload {
    let url: URL
    let thumbnail: Data
    var muted: Bool = false
    var trim: ClosedRange<Double>? = nil
    /// What the editor's tools did to this clip, if anything. nil = a plain video, which still takes
    /// the original untouched export path.
    var burn: StoryBurnIn? = nil
}

/// The story editor's Aa, Crop and Pen, as they apply to a VIDEO.
///
/// A photo can have its edits flattened into a picture. A video cannot, so they travel as far as the
/// export and are composited into the frames there — one transparent image for everything drawn, and
/// a rectangle for what was kept. See `VideoTranscoder.burnIn`.
struct StoryBurnIn {
    /// Text and pen strokes, rendered once at the size of the canvas they were placed on.
    var overlay: UIImage? = nil
    /// The crop, normalised (0-1) inside that same canvas.
    var cropRect: CGRect? = nil
    /// The canvas's own width/height, so the export can rebuild the exact frame he drew against.
    var canvasAspect: CGFloat? = nil
    /// HOW BIG THE CLIP IS ON THAT CANVAS, 1 being the fitted size the crop rectangle assumes.
    ///
    /// ⚠️ A ZOOM-OUT CANNOT BE A CROP, which is why this exists at all: `cropRect` says which piece
    /// of the frame to keep, and there is no piece of a frame that means "the clip, smaller, with
    /// canvas around it". Only ever below 1 — a zoom IN is still expressed as a crop, because that
    /// is exactly what it is.
    var contentScale: CGFloat = 1
    /// What sits BEHIND a clip that does not cover the canvas, rendered by the editor from the same
    /// two sampled colours it draws on screen, so the surround he framed against is the surround
    /// that lands.
    var backdrop: UIImage? = nil

    /// The trim page's Adjust dial, -1…1 with 0 untouched. It rides here rather than on
    /// `StoryVideoPayload` because everything else the editor did to the picture rides here, and the
    /// export reads them together.
    var brightness: Double = 0

    /// Nothing to do — so the caller can hand back nil and keep the untouched path.
    ///
    /// ⚠️ BRIGHTNESS COUNTS. Leaving it out is how an adjusted clip would take the untouched export
    /// path and post at its original light.
    var isEmpty: Bool {
        overlay == nil && cropRect == nil && backdrop == nil && contentScale == 1
            && StoryVideoBrightness.isNeutral(brightness)
    }
}

// MARK: - Share Story

/// "Who can see your story", then Post.
///
/// REBUILT AROUND NAMED AUDIENCES (owner 2026-08-06, with his eight reference screens). It used to
/// be three radio buttons over two loose uid sets kept in UserDefaults, answered fresh every time.
/// It is a list of the audiences he owns now — Everyone, My Friends, and every custom story he has
/// made — with a + New that builds another one without leaving the post.
///
/// WHAT MAKES "changes won't affect stories you've already sent" TRUE is not care here, it is the
/// shape: `recipients(contacts:)` is resolved at this moment and written onto the story, and nothing
/// on a posted story points back at the list it came from. Edit the list tomorrow, rename it, delete
/// it — yesterday's story cannot notice. The reference app is built the same way for the same reason.
///
/// Posting kicks off a BACKGROUND upload (StoriesService.postStoryBackground) and pops to chat.
struct ShareStorySheet: View {
    /// Defaulted because the EDIT door has no picture to hand over: it is changing who can see a
    /// story whose media was uploaded hours ago and is not being touched. Every posting call site
    /// still passes one, exactly as before.
    var image: Data = Data()
    var caption: String = ""
    var video: StoryVideoPayload? = nil   // set → posts a video story instead of the photo
    /// Everything after the first item, in order. They post behind it and share this audience.
    var extras: [StoryExtra] = []
    /// The Link and Location stickers on the FIRST item. Each extra carries its own — see
    /// `StoryTapTarget` and the note on `StoryExtra.stickers`.
    var stickers: [StoryTapTarget] = []
    /// ⚠️ THE STORY WHOSE AUDIENCE IS BEING CHANGED — set only by the "Edit viewers" door on a
    /// story that is already up, and nil for every post.
    ///
    /// His 2026-08-18 ask, and the reference app's own behaviour: the visibility of an active story
    /// can be changed after posting instead of deleting it and posting it again. It is the SAME
    /// sheet deliberately — he asked for his design left alone — with four differences, each of
    /// which is a thing that cannot mean anything about a story that already exists:
    ///
    ///   • "+ New" is gone, so no audience is created from here (his restriction), and with it the
    ///     One-Time Story entry, which is a kind of post rather than a setting on one.
    ///   • Block screenshots is gone: it is a property of the picture, not of who can see it, and
    ///     he asked for viewers only.
    ///   • The button says Update and writes to the existing story — no upload, no second story.
    ///   • The tick starts on the audience the story ACTUALLY went to, not on the store's default.
    var editing: Story? = nil
    var onPosted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = StoryAudienceStore.shared
    @State private var contacts: [StoryContact] = []
    @State private var creating = false
    @State private var emptyAudienceAlert = false
    @State private var posting = false   // one-shot guard so a double-tap can't double-post
    /// ONE-TIME STORY: the people picked for THIS post, and nothing else.
    ///
    /// Deliberately not a `StoryAudience` and deliberately not in the store (the owner's call: "pick
    /// people each time… nothing is saved and there is no new row in the list"). It lives for the
    /// length of this sheet, becomes the audience while it is non-empty, and is gone the moment the
    /// sheet is. Choosing any saved audience clears it, which is what makes the tick mean one thing.
    /// ⛔ THE AUTHOR'S "do not let this be copied" SWITCH, per story.
    ///
    /// ⚠️ THE WORDING IS THE FEATURE'S HONESTY. `CaptureShield` holds what iOS actually enforces: a
    /// screen recording is genuinely defeated, a screenshot comes out black through a mechanism
    /// Apple has never documented, and a second phone photographing the screen defeats both and
    /// always will. So the row says "Block screenshots" and the line under it does not promise more
    /// than that.
    @State private var captureProtectedChoice = false
    /// WHICH AUDIENCE THE SHEET HAS TICKED WHILE EDITING, held here rather than in the store.
    ///
    /// `StoryAudienceStore.selectedId` is the default for the NEXT post and is remembered between
    /// posts on purpose. Changing the audience of a story that is already up must not quietly change
    /// that — opening this sheet on an old Everyone story to look at it and closing it again would
    /// otherwise leave the next new story aimed at Everyone. Nil until `seedFromStory` runs.
    @State private var editSelection: String?
    /// An update that did not land, and it has to be SAID: the story keeps playing to its old
    /// audience either way, so a silent failure looks exactly like a success.
    @State private var updateError = false
    /// WHY it did not land, in the service's own words. A refusal and a dropped connection are two
    /// different things to be told, and `PostRefusal` already writes the sentence for each of them.
    @State private var updateErrorText = ""

    /// ⛔ WHAT ACTUALLY GETS POSTED, and a one-time story has no say in it. His 2026-08-18 order: "if
    /// user using One-Time Story it must always block screenshot, user cant make off".
    ///
    /// He is right that they belong together. A one-time story is the strongest promise this app
    /// makes about a picture — one person, one look, then gone — and a screenshot is the one move
    /// that breaks that promise permanently. Leaving the switch free would let somebody choose a
    /// guarantee and then quietly turn off the only thing defending it.
    ///
    /// Computed rather than written into the state, so the choice he made for ordinary stories is
    /// still there when he stops using one-time — the switch does not silently learn a new default
    /// from a post he made under a rule.
    private var captureProtected: Bool { oneTimeActive || captureProtectedChoice }
    @State private var oneTimePicking = false
    @State private var oneTimeViewers: Set<String> = []
    private var oneTimeActive: Bool { !oneTimeViewers.isEmpty }
    /// SEVERAL custom lists at once (owner 2026-08-09): ticking a second list ADDS it, and the post
    /// is ONE story whose audience is the union — his explicit answer, "do not create a separate
    /// story for each list". Sheet-local like the one-time set: the STORE still remembers exactly
    /// one audience between posts (the first-ticked list), because "which lists went together" is a
    /// property of a post, not a setting. Empty = the store's single selection rules, as always.
    @State private var multiCustom: Set<String> = []

    private var contactIds: Set<String> { StoryContact.ids(contacts) }

    /// The audience the sheet currently has ticked, and the one door that writes it. See
    /// `editSelection` for why editing does not touch the store.
    private var chosenId: String { editing == nil ? store.selectedId : (editSelection ?? store.selectedId) }
    private var chosen: StoryAudience { store.audience(id: chosenId) ?? store.myFriends }
    private func choose(_ id: String) {
        if editing == nil { store.select(id) } else { editSelection = id }
    }

    /// START ON THE AUDIENCE THE STORY ACTUALLY WENT TO. The store remembers the last audience
    /// POSTED to, which has nothing to do with the story being edited — without this, opening the
    /// sheet on a friends-only story could show Everyone already ticked, and one careless Update
    /// would widen it to the whole app.
    ///
    /// A custom list is matched BY NAME, because that is all a posted story carries: nothing on a
    /// story points back at the list it came from, which is what makes "changes never affect stories
    /// you've already sent" true by construction rather than by care. A comma-joined name is a post
    /// that went to several lists at once, and every one of them is ticked again. A name this phone
    /// does not know — the list was deleted, or the story was posted from another device — falls
    /// back to My Friends, which is the narrow way to be wrong rather than the wide one.
    private func seedFromStory(_ s: Story) {
        switch s.audienceLabel {
        case "everyone": editSelection = store.everyone.id
        case "custom":
            let remembered = StoryPrefs.audienceName(storyId: s.id) ?? ""
            let names = Set(remembered.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
            let hits = store.all.filter { $0.kind == .custom && names.contains($0.name) }
            editSelection = hits.first?.id ?? store.myFriends.id
            if hits.count > 1 { multiCustom = Set(hits.map(\.id)) }
        default: editSelection = store.myFriends.id
        }
    }

    /// How tall the sheet has to be to show every audience without scrolling.
    ///
    /// Measured from the pieces rather than guessed as a fraction of the screen, because the same
    /// fraction is a different number of rows on every phone. The row height is the real one: two
    /// lines of text plus the 40pt badge and its padding.
    ///
    /// Bounded at both ends. The floor stops a two-row sheet from being a sliver; the ceiling is 88%
    /// of the screen, so even a full five custom stories leaves the story visible above it and the
    /// sheet still reads as a sheet. With his ceiling of five that works out at seven rows, which
    /// fits inside 88% on every phone we support — but the clamp stays, because a number that only
    /// happens to fit is a number waiting to stop fitting.
    private var sheetHeight: CGFloat {
        // Badge 40 + the row's own 2pt above and below + `audienceRowInsets`. It followed the list's
        // default padding before and has to follow ours now, or the detent budgets for a row taller
        // than the one it is drawing.
        let rowH: CGFloat = 60
        let chrome: CGFloat = 56      // the inline navigation bar
            + 44                      // "Who can see your story" + the New button
            + 76                      // Post Story and its padding
            + Self.bottomSafeInset    // the home indicator, which the button sits above
        let wanted = chrome + footerHeight
            // The Block-screenshots section is not drawn while editing viewers, so it is not budgeted
            // for either — a sheet measured from its pieces has to be measured from the pieces it has.
            + (editing == nil ? Self.captureSectionHeight : 0)
            // ⚠️ AND THE ONE-TIME ROW, WHICH IS DRAWN ABOVE THE LIST AND WAS NEVER COUNTED. His
            // 2026-08-18: the sheet is the right size for custom folders every time and wrong the
            // moment a one-time story is on it.
            //
            // `store.all` is the audiences he owns — Everyone, My Friends, his custom lists — and
            // the One-Time Story row is NOT one of them. It is inserted ahead of the `ForEach` by
            // `if oneTimeActive`, so the list draws one row more than the budget below pays for and
            // the sheet comes up exactly 60pt short. That shortfall lands on the last thing in the
            // sheet, which is why what he circled is the Block-screenshots switch squashed against
            // Post Story. Same shape of bug as the capture section not being budgeted at all, one
            // row further up.
            //
            // Safe to make the height depend on this one, unlike the ticked row: `oneTimeActive` is
            // `!oneTimeViewers.isEmpty`, which only moves when the one-time PICKER is used, and that
            // is a separate sheet that has been dismissed by the time this one is on screen again.
            // Nothing here can resize under the finger that is choosing.
            + (oneTimeActive ? rowH : 0)
            + rowH * CGFloat(max(2, store.all.count))
        return min(wanted, UIScreen.main.bounds.height * 0.88)
    }

    /// ⚠️ MEASURED, NOT BUDGETED. This used to be a flat 44 for "the footer line under the list",
    /// and the public footer is not a line — it is two sentences that wrap to two lines on a normal
    /// phone and three on a small one. So the sheet came up too short: the last audience row was cut
    /// in half and the paragraph was not on screen at all, which is his 2026-08-07 screenshot with
    /// the gap circled. The bottom safe area was missing from the budget too, so the shortfall was
    /// the footer's overflow PLUS the home indicator.
    ///
    /// Measured off the real string at the real font and the real width, so it cannot drift when the
    /// wording changes — and the wording here has already changed twice. Erring wide by design: the
    /// width is taken narrower than the text really gets, so an estimate that is wrong is wrong in
    /// the direction that leaves room rather than the one that clips.
    private var footerHeight: CGFloat {
        // ⚠️ THE TALLEST OF ALL THREE, NOT THE ONE CURRENTLY SHOWING, and that is not laziness.
        //
        // The footer changes with the selection: the public sentence is two lines, "Only the people
        // in this list can watch it." is one. Measuring the CURRENT one would make the detent a
        // function of which row is ticked — so tapping from Everyone to a custom story would resize
        // the sheet under his finger, mid-tap. A sheet that moves while you are choosing is worse
        // than one that is slightly tall, and it would have been my own regression rather than a bug
        // I inherited.
        //
        // Sizing to the maximum costs at most one line of empty space on the shorter texts and makes
        // the height depend only on the number of audiences, which is what he asked for.
        let candidates = [
            "Each person can open this once. As soon as they do it is gone for them, and they cannot open it again.",
            "Anyone on Fariin who opens your profile can watch this. People you have chatted with also get it in their stories.",
            "Only the people in this list can watch it."
        ]
        // A grouped list footer is footnote, inset from both edges by the list AND the cell.
        let width = max(120, UIScreen.main.bounds.width - 72)
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let tallest = candidates.map { text -> CGFloat in
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil).height
        }.max() ?? 40
        return ceil(tallest) + 22   // the footer's own top and bottom padding
    }

    /// One line, and it is a `static let` for the same reason `footerHeight` measures its own
    /// strings: the height budget below reads THIS, so the sheet cannot be sized against a sentence
    /// the screen is no longer showing.
    static let captureFooter = "Screenshots and screen recordings come out blank."
    /// Why the switch will not move. Same length class as the line above it, so the sheet's height
    /// does not change when the audience does.
    static let captureLockedFooter = "Always on for a one-time story."

    /// What the Block-screenshots section costs the sheet — his "I can't see it without scrolling".
    ///
    /// ⚠️ IT WAS NOT IN THE BUDGET AT ALL. `sheetHeight` is measured from its pieces rather than
    /// guessed, and a whole new section was added to the list without adding it here, so the detent
    /// came up exactly one section too short and the switch sat below the fold. Same measured rule as
    /// the footer: the real string, the real font, the real width.
    private static var captureSectionHeight: CGFloat {
        let width = max(120, UIScreen.main.bounds.width - 72)
        // The taller of the two, never the one currently showing — the same rule and the same reason
        // as `footerHeight`: a detent that depends on which audience is ticked resizes the sheet
        // under the finger that is ticking it.
        let h = [captureFooter, captureLockedFooter].map { text -> CGFloat in
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)], context: nil).height
        }.max() ?? 20
        return 44                    // the switch's own row
            + 18                     // the gap a grouped list puts between two sections
            + ceil(h) + 14           // the footer and its padding
    }

    /// ⚠️ TIGHTER THAN THE LIST'S OWN, ON HIS 2026-08-18 "each one has more space, cut slightly".
    ///
    /// The row's CONTENT was never the problem: a 40pt badge and two lines with 2pt around them. What
    /// he circled is the grouped list's default padding, which measures about 15pt above and below
    /// every row — a 44pt row sitting in a 74pt slot. 8 leaves the touch target well over Apple's
    /// minimum and takes 14pt off each one, which on six audiences is most of a row's worth of sheet.
    ///
    /// ⚠️ HORIZONTAL IS MEASURED OFF HIS SCREENSHOT, NOT GUESSED AT THE DEFAULT. `listRowInsets`
    /// replaces all four, so naming only the vertical pair would shift every avatar and every tick
    /// sideways. 16 is where they already sit.
    /// ⚠️ THE NUMBER LIVES ON THE ROW NOW, not here, because the settings list draws the same row
    /// and had kept the grouped list's own 15pt — his 2026-08-18 "make it less, like the share
    /// sheet". One source, two lists. See `StoryAudienceRow.insets`.
    private static let audienceRowInsets = StoryAudienceRow<EmptyView>.insets

    /// The home indicator's strip. `postButton` is a bottom safe-area inset, so it sits ABOVE this
    /// and the sheet needs the room for both.
    private static var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .max() ?? 0
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Only while it exists. A one-time story is this post and no other, so an empty
                    // row sitting here between posts would be an audience you cannot pick.
                    if oneTimeActive { oneTimeRow.listRowInsets(Self.audienceRowInsets) }
                    ForEach(store.all) { a in
                        Button { tapAudience(a) } label: {
                            StoryAudienceRow(audience: a, contacts: contactIds) {
                                StoryTick(on: tickOn(a))
                            }
                        }
                        // ⚠️ EVERY WORD IN THIS ROW WAS BLUE, AND `StoryAudienceRow` ALREADY ASKS FOR
                        // `.primary` AND `.secondary` — WHICH IS THE TRAP.
                        //
                        // Those two are HIERARCHICAL styles: they do not name a colour, they name a
                        // level of whatever the current foreground style is. Inside a `Button` that
                        // style is the tint, so `.primary` resolved to solid accent and `.secondary`
                        // to a faded accent. That is exactly his screenshot — a blue title over a
                        // paler blue subtitle — and it is why the row looked correct everywhere the
                        // accent happens to be white (see the accent-is-white-at-night family) and
                        // wrong the moment this sheet is drawn light.
                        //
                        // `.plain` takes the tint out of the label's foreground, so the two levels
                        // resolve against the label colour they were written for. The tick keeps its
                        // own colour, because it sets one.
                        .buttonStyle(.plain)
                        .listRowInsets(Self.audienceRowInsets)
                    }
                } header: {
                    HStack {
                        Text("Who can see your story")
                        Spacer()
                        // NOTHING NEW IS MADE FROM THE EDIT DOOR, on his restriction: no custom
                        // audience is created here, and no One-Time Story either — a one-time story
                        // is a kind of post, not a setting an existing story can be moved on to.
                        if editing == nil {
                            NewAudienceButton(onCustom: { creating = true },
                                              canAddCustom: store.canAddCustom,
                                              onOneTime: { oneTimePicking = true })
                        }
                    }
                    // Sentence case, his reference. A section header uppercases its text by
                    // default, and the + New button is not a header at all.
                    .textCase(nil)
                } footer: {
                    if oneTimeActive {
                        Text("Each person can open this once. As soon as they do it is gone for them, and they cannot open it again.")
                    } else if multiCustom.count > 1 {
                        // Same length class as the singular line, so `footerHeight`'s tallest-of-all
                        // measure is untouched.
                        Text("Only the people in these lists can watch it.")
                    } else {
                        Text(chosen.isPublic
                             ? "Anyone on Fariin who opens your profile can watch this. People you have chatted with also get it in their stories."
                             : "Only the people in this list can watch it.")
                    }
                }
                // ⚠️ NO ICON AND ONE SHORT LINE, both on his 2026-08-18 order with the row and the
                // paragraph circled. The eye-slash was the only glyph in a sheet whose other rows
                // carry a photograph of a person, so it read as a broken avatar rather than a symbol;
                // and three sentences of caveat under a switch is a warning label, not a subtitle.
                //
                // The honesty survives the cut, which was the condition on this string: it says the
                // capture comes out blank rather than that it cannot happen. What is gone is the
                // sentence about photographing the screen with another phone — true, and not
                // something to spend three lines of a posting sheet on.
                // ⚠️ VIEWERS ONLY WHILE EDITING, on his "only the already-available viewer options
                // can be selected and updated". Block screenshots is a property of the picture rather
                // than of who can see it, and a switch that is shown but never written would be worse
                // than one that is not shown at all.
                if editing == nil {
                    Section {
                        Toggle("Block screenshots", isOn: Binding(
                            get: { captureProtected },
                            // A locked switch that still moves under the finger is worse than one that
                            // does not move at all: it says the choice is yours and then takes it back.
                            set: { if !oneTimeActive { captureProtectedChoice = $0 } }))
                            // ⚠️ EXPLICIT GREEN, AND THAT IS NOT DECORATION. A `Toggle` wears the app's
                            // accent, and this app's accent is WHITE in dark mode — so the switch read as
                            // on-and-white against the track, which is his circle. Apple's own switch is
                            // `systemGreen` and everybody's eye already knows what that means.
                            .tint(Color(.systemGreen))
                            .disabled(oneTimeActive)
                    } footer: {
                        Text(oneTimeActive ? Self.captureLockedFooter : Self.captureFooter)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { postButton }
            .navigationTitle("Share Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .alert("Couldn't update", isPresented: $updateError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(updateErrorText.isEmpty
                     ? "Who can see this story hasn't changed. Check your connection and try again."
                     : updateErrorText)
            }
            .alert("No one will see this", isPresented: $emptyAudienceAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Everyone in this list has been excluded or is no longer a chat. Pick another audience or add people to this one.")
            }
        }
        .onAppear {
            contacts = StoryContact.all()   // recomputed: a block made since this sheet was built must count
            if let editing, editSelection == nil { seedFromStory(editing) }
        }
        // A new list is SELECTED the moment it is made: he built it in the middle of posting, so it
        // is obviously the one he means. The reference app does the same.
        .sheet(isPresented: $creating) {
            CreateCustomStoryFlow(
                onCreated: { a in
                    oneTimeViewers = []
                    choose(a.id)
                    // Mid-multi-pick, the new list JOINS the ticks instead of replacing them — he
                    // built it while choosing lists, so it is one of the lists he is choosing.
                    if !multiCustom.isEmpty { multiCustom.insert(a.id) }
                    creating = false
                },
                onCancel: { creating = false })
        }
        // PICK THE PEOPLE, THEN COME BACK. Done does not post: the sheet already has a Post Story
        // button, and two ways to send from one screen is how somebody sends a story they meant to
        // reconsider. The picker's own Done is disabled until somebody is ticked, so a one-time
        // story can never arrive here with no recipients; the X clears the selection outright.
        .sheet(isPresented: $oneTimePicking) {
            NavigationStack {
                SelectViewersView(title: "One-Time Story", actionTitle: "Done",
                                  selected: $oneTimeViewers,
                                  onAction: { oneTimePicking = false },
                                  onCancel: { oneTimeViewers = []; oneTimePicking = false })
            }
        }
        // THE SHEET IS AS TALL AS ITS LIST (owner 2026-08-06: "the sheet height should fit the
        // content instead of using a fixed height"). It was a flat 60%, which fitted the two
        // built-ins and one custom story; his fourth row was cut off behind the Post button.
        .presentationDetents([.height(sheetHeight), .large])
        .presentationDragIndicator(.visible)
        // SOLID background — the default translucent material let the story photo show through the
        // sheet ("looks different"); this makes it a normal opaque grouped-list sheet.
        .presentationBackground(Color(.systemGroupedBackground))
    }

    /// The one-time selection, drawn as a row so it reads as the audience it currently is. Hand-built
    /// rather than squeezed into `StoryAudienceRow`, because that row takes a `StoryAudience` and
    /// this is deliberately not one — inventing a throwaway audience to satisfy a view is how a
    /// "nothing is saved" feature ends up saved.
    private var oneTimeRow: some View {
        Button { oneTimePicking = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.orange.gradient)
                    Image(systemName: "flame.fill").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("One-Time Story").foregroundStyle(.primary).lineLimit(1)
                    Text(oneTimeViewers.count == 1 ? "1 person · viewed once"
                                                   : "\(oneTimeViewers.count) people · viewed once")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                StoryTick(on: true)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }

    private var postButton: some View {
        Button { post() } label: {
            // UPDATE, NOT POST — his word, and the honest one: nothing is uploaded and no second
            // story is made, the one already up simply changes who can see it.
            Text(editing == nil ? "Post Story" : "Update").font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(.blue, in: Capsule())
        }
        .buttonStyle(StoryPressStyle())
        .disabled(posting)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    /// One tap on an audience row. Everyone and My Friends stay exclusive — a public post and a
    /// union of lists are different sentences, not different degrees. Custom lists TOGGLE, so a
    /// second tick ADDS a list rather than replacing the first (his 2026-08-09 ask).
    private func tapAudience(_ a: StoryAudience) {
        oneTimeViewers = []
        guard a.kind == .custom else { multiCustom = []; choose(a.id); return }
        var set = multiCustom
        // The single tick the store shows counts as one: tapping a SECOND list while "oky" is
        // ticked must read as adding to oky, not as replacing it silently.
        if set.isEmpty, chosen.kind == .custom { set.insert(chosen.id) }
        if set.contains(a.id) { set.remove(a.id) } else { set.insert(a.id) }
        multiCustom = set
        if set.isEmpty {
            // Unticking the last list cannot leave the post aimed at nothing — the same fallback
            // the store itself uses when a selected list is deleted.
            choose(store.myFriends.id)
        } else if chosen.kind != .custom || !set.contains(chosenId) {
            // The store remembers exactly ONE audience between posts; keep it on a ticked list.
            if let keep = store.all.first(where: { set.contains($0.id) }) { choose(keep.id) }
        }
    }

    private func tickOn(_ a: StoryAudience) -> Bool {
        guard !oneTimeActive else { return false }
        if multiCustom.isEmpty { return chosenId == a.id }
        return a.kind == .custom && multiCustom.contains(a.id)
    }

    private func post() {
        guard !posting else { return }   // ignore a second tap while the first is in flight
        if editing != nil { updateAudience(); return }
        if oneTimeActive { postOneTime(); return }
        if !multiCustom.isEmpty { postToLists(); return }
        let a = chosen
        let recipients = a.recipients(contacts: contactIds, hiddenFrom: store.hiddenFrom)
        // Block ONLY when you HAVE chats but this audience narrows down to literally no one. With no
        // chats at all, posting is still fine: it is YOUR OWN story and always visible to you, it
        // just has no other recipients yet. Without that carve-out a brand-new user could never post
        // their first story.
        if recipients.isEmpty && !contactIds.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            emptyAudienceAlert = true
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        posting = true

        // The service still speaks in excluded/included/everyone, and that is the right seam to keep:
        // it resolves the audience against the LIVE chat list at upload time, which is what stops a
        // list holding somebody you blocked five minutes ago from reaching them. Everything above is
        // a nicer way of arriving at these three values.
        let everyone = a.isPublic
        // ⛔ EACH AUDIENCE'S OWN EXCLUSIONS, AND NOBODY ELSE'S (owner, 2026-08-20). The hide list is
        // Everyone's — see `StoryAudience.appliesGlobalHide`. My Friends brings its own except-list
        // and inherits nothing; a custom list brings names, which need no exclusions at all.
        let ownExcept: Set<String> = (a.kind == .myFriends && a.mode == .except) ? Set(a.members) : []
        let excluded: Set<String> = a.appliesGlobalHide ? ownExcept.union(store.hiddenFrom) : ownExcept
        let included: Set<String> = {
            if a.kind == .custom { return Set(a.members) }
            if a.kind == .myFriends && a.mode == .only { return Set(a.members) }
            return []
        }()
        let replies = a.allowReplies
        // The label the header will show, decided here where the audience is actually known. The
        // NAME rides along for a custom list and is stored on this device only — see StoryAudienceTag.
        let tag: StoryAudienceTag = {
            switch a.kind {
            case .everyone: return .everyone
            case .custom:   return StoryAudienceTag(label: "custom", name: a.name)
            default:        return .friends
            }
        }()

        if let video {
            StoriesService.shared.postVideoStoryBackground(
                videoURL: video.url, thumbnail: video.thumbnail, muted: video.muted,
                burn: video.burn, trim: video.trim, caption: caption, stickers: stickers,
                excluded: excluded, included: included, everyone: everyone, allowsReplies: replies,
                tag: tag, captureProtected: captureProtected)
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption, stickers: stickers,
                excluded: excluded, included: included, everyone: everyone, allowsReplies: replies,
                tag: tag, captureProtected: captureProtected)
        }
        // The rest, in order, behind the first. The background posters already CHAIN rather than
        // cancel each other, so this queues instead of racing — which is what keeps a multi-item
        // post in the order the user arranged it.
        //
        // ⚠️ EACH EXTRA CARRIES ITS OWN CAPTION NOW. This used to send `""` on every one of them,
        // on the reasoning that a caption "belongs to the post" and repeating it would read as a
        // stutter. His 2026-08-17 report is that the premise was wrong: each picked picture becomes
        // its own story in the viewer, so a caption written on the third one had nowhere to go and
        // the field showed the first one's words whichever thumbnail was selected. The editor holds
        // one per item now, beside the crop and the drawing and the stickers.
        for extra in extras {
            if let v = extra.video {
                StoriesService.shared.postVideoStoryBackground(
                    videoURL: v.url, thumbnail: v.thumbnail, muted: v.muted, burn: v.burn, trim: v.trim,
                    caption: extra.caption, stickers: extra.stickers,
                    excluded: excluded, included: included, everyone: everyone,
                    allowsReplies: replies, tag: tag, captureProtected: captureProtected)
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: extra.caption, stickers: extra.stickers,
                    excluded: excluded, included: included, everyone: everyone,
                    allowsReplies: replies, tag: tag, captureProtected: captureProtected)
            }
        }
        onPosted()   // dismisses the editor -> back to chat; upload runs in the background
    }

    /// UPDATE, NOT POST. The story keeps its id, its posting time, its media, its caption and
    /// everybody who has already seen it; only who can see it changes. Nothing is uploaded and no
    /// second story is created — see `StoriesService.updateStoryAudience`.
    ///
    /// ⚠️ IT ARRIVES AT THE SAME THREE VALUES THE POST PATH DOES, and that is deliberate rather
    /// than repetitive. The service speaks in excluded/included/everyone and resolves them against
    /// the live chat list, so an EDITED audience and a POSTED one have to be derived the same way or
    /// "My Friends" would quietly mean two different sets of people depending on which door you came
    /// through. The empty-audience guard is the post path's, for the same reason.
    ///
    /// ⚠️ THE FAILURE IS SHOWN. The story goes on playing to its old audience when this does not
    /// land, so a swallowed error is indistinguishable from success — and the one error that is
    /// likely here is a refusal from the security rules, which is invisible by nature.
    private func updateAudience() {
        guard let story = editing else { return }
        // Several custom lists ticked at once resolve to their UNION, exactly as a post to several
        // lists does: one story, one audience, no copies. See `postToLists`.
        let lists = store.all.filter { $0.kind == .custom && multiCustom.contains($0.id) }
        let multi = lists.count > 1
        let a = chosen
        let recipients = multi
            ? lists.reduce(into: Set<String>()) {
                $0.formUnion($1.recipients(contacts: contactIds, hiddenFrom: store.hiddenFrom))
              }
            : a.recipients(contacts: contactIds, hiddenFrom: store.hiddenFrom)
        // Block ONLY when there are chats and this audience narrows to nobody — the post path's rule.
        // With no chats at all it is still my own story and still visible to me.
        if recipients.isEmpty && !contactIds.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            emptyAudienceAlert = true
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        posting = true

        let everyone = !multi && a.isPublic
        // Each audience's own exclusions and nobody else's — see `StoryAudience.appliesGlobalHide`.
        // A multi-list edit names people, so it carries none at all.
        let ownExcept: Set<String> = (!multi && a.kind == .myFriends && a.mode == .except)
                                     ? Set(a.members) : []
        let excluded: Set<String> = (!multi && a.appliesGlobalHide)
                                    ? ownExcept.union(store.hiddenFrom) : ownExcept
        let included: Set<String> = {
            if multi { return lists.reduce(into: Set<String>()) { $0.formUnion(Set($1.members)) } }
            if a.kind == .custom { return Set(a.members) }
            if a.kind == .myFriends && a.mode == .only { return Set(a.members) }
            return []
        }()
        // The strictest list wins when several are combined, the same direction every other privacy
        // rule in this sheet leans.
        let replies = multi ? lists.allSatisfy { $0.allowReplies } : a.allowReplies
        let tag: StoryAudienceTag = {
            if multi {
                return StoryAudienceTag(label: "custom",
                                        name: lists.map(\.name).joined(separator: ", "))
            }
            switch a.kind {
            case .everyone: return .everyone
            case .custom:   return StoryAudienceTag(label: "custom", name: a.name)
            default:        return .friends
            }
        }()

        // ⚠️ THE PILL IS CHANGED HERE, NOT BY THE RELOAD, AND THAT IS HIS "not chnaging real time".
        //
        // The old comment below promised the reload was what kept the header pill honest. It cannot
        // be: `StoryViewer` takes `let groups: [StoryGroup]`, an immutable snapshot captured when the
        // viewer was presented, so re-reading the repository changes nothing that is already on
        // screen. And the reconcile that DOES push fresh buckets into mounted pages is keyed on
        // `reconcileSignature`, which is bucket and item IDs only — an audience change moves no id,
        // so it never fires. That is why the new label only appeared after leaving the story and
        // coming back, which is a fresh snapshot.
        //
        // The title travels with it because the words are the audience's own (`a.title`, or the
        // joined list names when several are ticked) and the host would otherwise have to re-derive
        // them from a story it has not been told about yet.
        NotificationCenter.default.post(
            name: .init("storyAudienceUpdatedLocally"), object: nil,
            userInfo: ["id": story.id, "label": tag.label,
                       "title": multi ? lists.map(\.name).joined(separator: ", ") : a.title])
        // ⚠️ AND THE SHEET GOES NOW, NOT TWO ROUND TRIPS LATER — his "its taking time to close sheet".
        //
        // This used to await the write AND then a forced full reload of every story before it would
        // dismiss, so the sheet sat there for two networks in series after the tap. Nothing about
        // either was needed to CLOSE it: the choice is already made, the pill above is already
        // correct, and the write is the app's business rather than his.
        onPosted(); dismiss()
        Task {
            do {
                try await StoriesService.shared.updateStoryAudience(
                    story, excluded: excluded, included: included, everyone: everyone,
                    allowsReplies: replies, tag: tag)
                // Still worth doing, just not worth waiting for: it puts the repository in step for
                // the NEXT time the viewer is opened from a fresh snapshot.
                await StoriesRepository.shared.load(force: true)
            } catch {
                // ⚠️ THE FAILURE IS STILL SHOWN, and it has to be — the story goes on playing to its
                // old audience when this does not land, and the likeliest error here is a refusal
                // from the security rules, which is invisible by nature. The sheet is gone by now, so
                // it is the host that says so, the same way a failed delete does. The reload puts the
                // truthful label back underneath the toast.
                await StoriesRepository.shared.load(force: true)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .init("storyAudienceUpdateFailed"), object: nil,
                        userInfo: ["id": story.id,
                                   "message": (error as? LocalizedError)?.errorDescription
                                       ?? "Couldn't update who can see this — check your connection"])
                }
            }
        }
    }

    /// SEVERAL LISTS, ONE STORY — his 2026-08-09 answer, in his words: "one single story that all
    /// the selected lists can see. Do not create a separate story for each list." So the audience
    /// is the UNION, resolved per list exactly the way a single list is (live chats, hidden-from
    /// subtracted), then joined; the service still receives one included set and posts one story.
    ///
    /// Replies are allowed only when EVERY selected list allows them: combining lists must never
    /// hand reply rights to people whose own list has them switched off — the strictest list wins,
    /// the same direction every other privacy rule here leans.
    private func postToLists() {
        let lists = store.all.filter { $0.kind == .custom && multiCustom.contains($0.id) }
        guard !lists.isEmpty else {
            // Every ticked list was deleted from another screen while this sheet sat open.
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            emptyAudienceAlert = true
            return
        }
        let recipients = lists.reduce(into: Set<String>()) {
            $0.formUnion($1.recipients(contacts: contactIds, hiddenFrom: store.hiddenFrom))
        }
        if recipients.isEmpty && !contactIds.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            emptyAudienceAlert = true
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        posting = true

        let included = lists.reduce(into: Set<String>()) { $0.formUnion(Set($1.members)) }
        // A custom list is a set of names somebody typed. Everyone's hide list has no business in it
        // — see `StoryAudience.appliesGlobalHide`.
        let excluded: Set<String> = []
        let replies = lists.allSatisfy { $0.allowReplies }
        // The header badge reads every list it went to. Device-local, like every custom name.
        let tag = StoryAudienceTag(label: "custom",
                                   name: lists.map(\.name).joined(separator: ", "))

        if let video {
            StoriesService.shared.postVideoStoryBackground(
                videoURL: video.url, thumbnail: video.thumbnail, muted: video.muted,
                burn: video.burn, trim: video.trim, caption: caption, stickers: stickers,
                excluded: excluded, included: included, everyone: false, allowsReplies: replies,
                tag: tag, captureProtected: captureProtected)
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption, stickers: stickers,
                excluded: excluded, included: included, everyone: false, allowsReplies: replies,
                tag: tag, captureProtected: captureProtected)
        }
        // ⚠️ `stickers:` HAS TO BE PASSED ON EVERY CALL IN EVERY ONE OF THE THREE POST PATHS — the
        // first item's as well as the extras'. It defaults to empty, so an omission is silent: the
        // sticker is still DRAWN into the picture by the editor, and only the tap target is missing.
        // That is what a Link sticker to a custom list looked like for a while, a photograph of a
        // button that does nothing, while the same post to friends kept working. The extras were
        // repaired first and the first item was left behind, so check both halves, not one.
        for extra in extras {
            if let v = extra.video {
                StoriesService.shared.postVideoStoryBackground(
                    videoURL: v.url, thumbnail: v.thumbnail, muted: v.muted, burn: v.burn, trim: v.trim,
                    caption: extra.caption, stickers: extra.stickers,
                    excluded: excluded, included: included, everyone: false,
                    allowsReplies: replies, tag: tag, captureProtected: captureProtected)
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: extra.caption, stickers: extra.stickers,
                    excluded: excluded, included: included, everyone: false,
                    allowsReplies: replies, tag: tag, captureProtected: captureProtected)
            }
        }
        onPosted()
    }

    /// The one-time post. Same pipeline, same background upload, one flag different.
    ///
    /// The people are the ones just picked, full stop — no `recipients(contacts:)` resolve against an
    /// audience, because there is no audience. "Hide my stories from X" still applies: it is a
    /// standing instruction about a person, not a property of a list, and the owner's rule is that no
    /// list however it is built can put a hidden person back in.
    ///
    /// Empty is impossible from the UI (the picker's Done is disabled until somebody is ticked), but
    /// it is checked anyway rather than trusted, because this is the one path where an empty audience
    /// would post a story nobody can ever open and the author could not tell.
    private func postOneTime() {
        // ⛔ NOT SUBTRACTED BY THE HIDE LIST, AND THIS WAS THE BUG HE PHOTOGRAPHED. A one-time story
        // is addressed to people picked one at a time, by hand, in this sheet. Subtracting Everyone's
        // hide list from that could empty an audience of exactly the person just chosen, and the
        // sheet then refused to post with "No one will see this" — refusing an instruction it had
        // just watched him give. Picking somebody outranks a standing rule about crowds; a BLOCK
        // still beats everything and is removed from the pool long before this.
        let people = oneTimeViewers
        guard !people.isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            emptyAudienceAlert = true
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        posting = true

        if let video {
            StoriesService.shared.postVideoStoryBackground(
                videoURL: video.url, thumbnail: video.thumbnail, muted: video.muted,
                burn: video.burn, trim: video.trim, caption: caption, stickers: stickers,
                excluded: [], included: people, everyone: false,
                allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"), captureProtected: captureProtected)
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption, stickers: stickers,
                excluded: [], included: people, everyone: false,
                allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"), captureProtected: captureProtected)
        }
        for extra in extras {
            if let v = extra.video {
                StoriesService.shared.postVideoStoryBackground(
                    videoURL: v.url, thumbnail: v.thumbnail, muted: v.muted, burn: v.burn, trim: v.trim,
                    caption: extra.caption, stickers: extra.stickers,
                    excluded: [], included: people, everyone: false,
                    allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"), captureProtected: captureProtected)
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: extra.caption, stickers: extra.stickers,
                    excluded: [], included: people,
                    everyone: false, allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"), captureProtected: captureProtected)
            }
        }
        onPosted()
    }
}


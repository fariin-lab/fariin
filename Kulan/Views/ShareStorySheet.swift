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

    /// Nothing to do — so the caller can hand back nil and keep the untouched path.
    var isEmpty: Bool { overlay == nil && cropRect == nil && backdrop == nil && contentScale == 1 }
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
    let image: Data
    var caption: String = ""
    var video: StoryVideoPayload? = nil   // set → posts a video story instead of the photo
    /// Everything after the first item, in order. They post behind it and share this audience.
    var extras: [StoryExtra] = []
    /// The Link and Location stickers on the FIRST item. Each extra carries its own — see
    /// `StoryTapTarget` and the note on `StoryExtra.stickers`.
    var stickers: [StoryTapTarget] = []
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
        let rowH: CGFloat = 68        // badge 40 + two lines + vertical padding
        let chrome: CGFloat = 56      // the inline navigation bar
            + 44                      // "Who can see your story" + the New button
            + 76                      // Post Story and its padding
            + Self.bottomSafeInset    // the home indicator, which the button sits above
        let wanted = chrome + footerHeight + rowH * CGFloat(max(2, store.all.count))
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
                    if oneTimeActive { oneTimeRow }
                    ForEach(store.all) { a in
                        Button { tapAudience(a) } label: {
                            StoryAudienceRow(audience: a, contacts: contactIds) {
                                StoryTick(on: tickOn(a))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Who can see your story")
                        Spacer()
                        NewAudienceButton(onCustom: { creating = true },
                                          canAddCustom: store.canAddCustom,
                                          onOneTime: { oneTimePicking = true })
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
                        Text(store.selected.isPublic
                             ? "Anyone on Fariin who opens your profile can watch this. People you have chatted with also get it in their stories."
                             : "Only the people in this list can watch it.")
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
            .alert("No one will see this", isPresented: $emptyAudienceAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Everyone in this list has been excluded or is no longer a chat. Pick another audience or add people to this one.")
            }
        }
        .onAppear { if contacts.isEmpty { contacts = StoryContact.all() } }
        // A new list is SELECTED the moment it is made: he built it in the middle of posting, so it
        // is obviously the one he means. The reference app does the same.
        .sheet(isPresented: $creating) {
            CreateCustomStoryFlow(
                onCreated: { a in
                    oneTimeViewers = []
                    store.select(a.id)
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
            Text("Post Story").font(.headline).foregroundStyle(.white)
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
        guard a.kind == .custom else { multiCustom = []; store.select(a.id); return }
        var set = multiCustom
        // The single tick the store shows counts as one: tapping a SECOND list while "oky" is
        // ticked must read as adding to oky, not as replacing it silently.
        if set.isEmpty, store.selected.kind == .custom { set.insert(store.selected.id) }
        if set.contains(a.id) { set.remove(a.id) } else { set.insert(a.id) }
        multiCustom = set
        if set.isEmpty {
            // Unticking the last list cannot leave the post aimed at nothing — the same fallback
            // the store itself uses when a selected list is deleted.
            store.select(store.myFriends.id)
        } else if store.selected.kind != .custom || !set.contains(store.selectedId) {
            // The store remembers exactly ONE audience between posts; keep it on a ticked list.
            if let keep = store.all.first(where: { set.contains($0.id) }) { store.select(keep.id) }
        }
    }

    private func tickOn(_ a: StoryAudience) -> Bool {
        guard !oneTimeActive else { return false }
        if multiCustom.isEmpty { return store.selectedId == a.id }
        return a.kind == .custom && multiCustom.contains(a.id)
    }

    private func post() {
        guard !posting else { return }   // ignore a second tap while the first is in flight
        if oneTimeActive { postOneTime(); return }
        if !multiCustom.isEmpty { postToLists(); return }
        let a = store.selected
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
        // "Hide my stories from X" rides along as an exclusion, so it applies to EVERY audience —
        // Everyone and custom lists included, not just My Friends' own except-list.
        let excluded: Set<String> = ((a.kind == .myFriends && a.mode == .except)
                                     ? Set(a.members) : []).union(store.hiddenFrom)
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
                tag: tag)
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption, stickers: stickers,
                excluded: excluded, included: included, everyone: everyone, allowsReplies: replies,
                tag: tag)
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
                    allowsReplies: replies, tag: tag)
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: extra.caption, stickers: extra.stickers,
                    excluded: excluded, included: included, everyone: everyone,
                    allowsReplies: replies, tag: tag)
            }
        }
        onPosted()   // dismisses the editor -> back to chat; upload runs in the background
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
        let excluded = store.hiddenFrom
        let replies = lists.allSatisfy { $0.allowReplies }
        // The header badge reads every list it went to. Device-local, like every custom name.
        let tag = StoryAudienceTag(label: "custom",
                                   name: lists.map(\.name).joined(separator: ", "))

        if let video {
            StoriesService.shared.postVideoStoryBackground(
                videoURL: video.url, thumbnail: video.thumbnail, muted: video.muted,
                burn: video.burn, trim: video.trim, caption: caption,
                excluded: excluded, included: included, everyone: false, allowsReplies: replies,
                tag: tag)
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption,
                excluded: excluded, included: included, everyone: false, allowsReplies: replies,
                tag: tag)
        }
        // ⚠️ AND `stickers:` WAS NOT BEING PASSED AT ALL ON THIS PATH OR THE ONE-TIME ONE — only on
        // the first of the three. So a Link or Location sticker on the second picture of a post to a
        // custom list was silently dropped at post time, while the same post to friends kept it.
        // `StoryExtra`'s own note says why they are per item; two of the three callers never read it.
        for extra in extras {
            if let v = extra.video {
                StoriesService.shared.postVideoStoryBackground(
                    videoURL: v.url, thumbnail: v.thumbnail, muted: v.muted, burn: v.burn, trim: v.trim,
                    caption: extra.caption, stickers: extra.stickers,
                    excluded: excluded, included: included, everyone: false,
                    allowsReplies: replies, tag: tag)
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: extra.caption, stickers: extra.stickers,
                    excluded: excluded, included: included, everyone: false,
                    allowsReplies: replies, tag: tag)
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
        let people = oneTimeViewers.subtracting(store.hiddenFrom)
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
                burn: video.burn, trim: video.trim, caption: caption,
                excluded: store.hiddenFrom, included: people, everyone: false,
                allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"))
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption,
                excluded: store.hiddenFrom, included: people, everyone: false,
                allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"))
        }
        for extra in extras {
            if let v = extra.video {
                StoriesService.shared.postVideoStoryBackground(
                    videoURL: v.url, thumbnail: v.thumbnail, muted: v.muted, burn: v.burn, trim: v.trim,
                    caption: extra.caption, stickers: extra.stickers,
                    excluded: store.hiddenFrom, included: people, everyone: false,
                    allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"))
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: extra.caption, stickers: extra.stickers,
                    excluded: store.hiddenFrom, included: people,
                    everyone: false, allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"))
            }
        }
        onPosted()
    }
}


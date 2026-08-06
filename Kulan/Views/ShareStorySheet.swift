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
}

/// One more item posted behind the first, in the order the user arranged them. The audience sheet is
/// answered ONCE and every item inherits that answer — being asked who can see it seven times for one
/// post is the thing this avoids.
struct StoryExtra: Identifiable {
    let id = UUID()
    var photo: Data? = nil
    var video: StoryVideoPayload? = nil
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

    /// Nothing to do — so the caller can hand back nil and keep the untouched path.
    var isEmpty: Bool { overlay == nil && cropRect == nil }
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
/// it — yesterday's story cannot notice. Signal is built the same way for the same reason.
///
/// Posting kicks off a BACKGROUND upload (StoriesService.postStoryBackground) and pops to chat.
struct ShareStorySheet: View {
    let image: Data
    var caption: String = ""
    var video: StoryVideoPayload? = nil   // set → posts a video story instead of the photo
    /// Everything after the first item, in order. They post behind it and share this audience.
    var extras: [StoryExtra] = []
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
            + 44                      // the footer line under the list
            + 76                      // Post Story and its padding
        let wanted = chrome + rowH * CGFloat(max(2, store.all.count))
        return min(wanted, UIScreen.main.bounds.height * 0.88)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Only while it exists. A one-time story is this post and no other, so an empty
                    // row sitting here between posts would be an audience you cannot pick.
                    if oneTimeActive { oneTimeRow }
                    ForEach(store.all) { a in
                        Button { oneTimeViewers = []; store.select(a.id) } label: {
                            StoryAudienceRow(audience: a, contacts: contactIds) {
                                StoryTick(on: !oneTimeActive && store.selectedId == a.id)
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
        // is obviously the one he means. Signal does the same.
        .sheet(isPresented: $creating) {
            CreateCustomStoryFlow(
                onCreated: { a in oneTimeViewers = []; store.select(a.id); creating = false },
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

    private func post() {
        guard !posting else { return }   // ignore a second tap while the first is in flight
        if oneTimeActive { postOneTime(); return }
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
                burn: video.burn, trim: video.trim, caption: caption,
                excluded: excluded, included: included, everyone: everyone, allowsReplies: replies,
                tag: tag)
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption,
                excluded: excluded, included: included, everyone: everyone, allowsReplies: replies,
                tag: tag)
        }
        // The rest, in order, behind the first. The background posters already CHAIN rather than
        // cancel each other, so this queues instead of racing — which is what keeps a multi-item
        // post in the order the user arranged it.
        //
        // NO CAPTION ON THE EXTRAS: it belongs to the post, and repeating it on every item reads as
        // a stutter — the same rule the 90-second split follows.
        for extra in extras {
            if let v = extra.video {
                StoriesService.shared.postVideoStoryBackground(
                    videoURL: v.url, thumbnail: v.thumbnail, muted: v.muted, burn: v.burn, trim: v.trim,
                    caption: "", excluded: excluded, included: included, everyone: everyone,
                    allowsReplies: replies, tag: tag)
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: "", excluded: excluded, included: included, everyone: everyone,
                    allowsReplies: replies, tag: tag)
            }
        }
        onPosted()   // dismisses the editor -> back to chat; upload runs in the background
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
                    caption: "", excluded: store.hiddenFrom, included: people, everyone: false,
                    allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"))
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: "", excluded: store.hiddenFrom, included: people,
                    everyone: false, allowsReplies: true, tag: StoryAudienceTag(label: "oneTime"))
            }
        }
        onPosted()
    }
}


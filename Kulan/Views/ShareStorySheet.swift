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

    private var contactIds: Set<String> { StoryContact.ids(contacts) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.all) { a in
                        Button { store.select(a.id) } label: {
                            StoryAudienceRow(audience: a, contacts: contactIds) {
                                StoryTick(on: store.selectedId == a.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Who can see your story")
                        Spacer()
                        NewAudienceButton { creating = true }
                    }
                    // Sentence case, his reference. A section header uppercases its text by
                    // default, and the + New button is not a header at all.
                    .textCase(nil)
                } footer: {
                    Text(store.selected.isPublic
                         ? "Anyone on Fariin who opens your profile can watch this. People you have chatted with also get it in their stories."
                         : "Only the people in this list can watch it.")
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
                onCreated: { a in store.select(a.id); creating = false },
                onCancel: { creating = false })
        }
        // 60% shows the built-ins plus a couple of custom lists and the Post button. Drag up for more.
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        // SOLID background — the default translucent material let the story photo show through the
        // sheet ("looks different"); this makes it a normal opaque grouped-list sheet.
        .presentationBackground(Color(.systemGroupedBackground))
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
        let a = store.selected
        let recipients = a.recipients(contacts: contactIds)
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
        let excluded: Set<String> = (a.kind == .myFriends && a.mode == .except) ? Set(a.members) : []
        let included: Set<String> = {
            if a.kind == .custom { return Set(a.members) }
            if a.kind == .myFriends && a.mode == .only { return Set(a.members) }
            return []
        }()
        let replies = a.allowReplies

        if let video {
            StoriesService.shared.postVideoStoryBackground(
                videoURL: video.url, thumbnail: video.thumbnail, muted: video.muted,
                burn: video.burn, trim: video.trim, caption: caption,
                excluded: excluded, included: included, everyone: everyone, allowsReplies: replies)
        } else {
            StoriesService.shared.postStoryBackground(
                image: image, caption: caption,
                excluded: excluded, included: included, everyone: everyone, allowsReplies: replies)
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
                    allowsReplies: replies)
            } else if let p = extra.photo {
                StoriesService.shared.postStoryBackground(
                    image: p, caption: "", excluded: excluded, included: included, everyone: everyone,
                    allowsReplies: replies)
            }
        }
        onPosted()   // dismisses the editor -> back to chat; upload runs in the background
    }
}


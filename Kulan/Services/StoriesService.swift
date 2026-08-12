import Foundation
import Observation
import UIKit
import AVFoundation
import ImageIO   // CGImageSourceCreateThumbnailAtIndex, for the embedded story cover
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import StoryUI   // StoryVideoSeed / StoryImageSeed — the uploader warms the viewer's caches

// One story (photo or video). Rules-protected (v1, not E2EE); media is a plain file in Storage.
/// WHO A STORY WENT TO, as a label — not as a pointer to the list it came from.
///
/// The header shows this so an author with ten stories up can tell at a glance which went where
/// (his request, 2026-08-06, with three reference screens). It is a LABEL and nothing more: it says
/// what KIND of audience was chosen, never who was in it, because a recipient reads the whole story
/// document and anything on it is something they can see.
///
/// ⚠️ `name` IS NEVER WRITTEN TO FIRESTORE. A custom story's name is the author's own private note
/// for it — "only you can see the name of this story" — and he restated that rule with this very
/// request ("they should not see any private details beyond the audience type"). So the name is kept
/// on the author's own device, keyed by the story it belongs to, and other people see the plain word
/// "Custom".
///
/// It is also NOT a listId, deliberately. Nothing on a posted story points back at the list it came
/// from, which is what makes "changes never affect stories you've already sent" true by construction
/// rather than by care. A label is frozen at post time and cannot lead anywhere.
struct StoryAudienceTag {
    var label: String        // "everyone" | "friends" | "custom" | "oneTime"
    var name: String = ""    // custom lists only, device-local
    var oneTime: Bool { label == "oneTime" }
    static let friends = StoryAudienceTag(label: "friends")
    static let everyone = StoryAudienceTag(label: "everyone")
}

struct Story: Identifiable, Hashable, Codable {
    let id: String
    let authorUid: String
    let createdAt: Date
    let expiresAt: Date
    let mediaUrl: String
    let allowsReplies: Bool
    var caption: String = ""   // overlay caption (stored as text, rendered in the viewer)
    var isVideo: Bool = false
    var duration: Double = 0   // video length in seconds (photos: 0 → viewer uses the 5s standard)
    var thumbUrl: String = ""  // video poster frame (photos: empty)
    /// A base64 JPEG about 30px wide, carried in the story document itself. See `blurThumbBase64`
    /// and `StoryUI.Story.blurThumb` — this is the cover that cannot be missing.
    var blurThumb: String = ""
    /// Bytes of this clip worth fetching before it is watched, written at post time. Zero for
    /// anything posted before the field existed. See `StoryUI.Story.preloadPrefix`.
    var preloadPrefix: Int64 = 0
    /// The audience LABEL this story was posted with. See `StoryAudienceTag`.
    var audienceLabel: String = "friends"
    /// Each recipient may open it exactly once. Enforced on the server by removing them from
    /// `recipientUids` the moment they do — see `StoryPrefs.consumeOneTime` and `onStoryConsumed`.
    var oneTime: Bool = false
    /// How many of the people this story was sent to are still in its audience — and therefore, for
    /// a one-time story, how many of them have NOT used their single view yet. It counts down as
    /// each one opens it, because that is precisely what consuming a one-time story does: the
    /// server takes them out of `recipientUids`.
    ///
    /// MY OWN STORIES ONLY. Nobody else may read that field (it is the author's audience list), so
    /// for everybody else's stories this stays at -1, which means "not known" and never "nobody".
    var recipientsLeft: Int = -1

    // What card/ring/reply thumbnails should render: the photo itself, or the video's poster.
    // Every image consumer (row cards, morph carousel, reply quotes, archive) reads THIS, never
    // mediaUrl directly — a video's mediaUrl is an .mp4 and image-decodes to nothing.
    //
    // ⚠️ EMPTY, NEVER THE MP4, for a video with no thumb yet. The old fallback handed the .mp4 to
    // every image consumer, and the video poster path then read megabytes off disk on the main
    // thread, downloaded the whole clip a SECOND time in parallel with the player's own fetch, and
    // still had no picture at the end — his 2026-08-09 spinner-over-black screenshot. An empty url
    // draws a placeholder immediately, which is honest and free.
    var previewUrl: String { isVideo ? thumbUrl : mediaUrl }
}

extension StoriesService {
    /// A COVER SMALL ENOUGH TO PUT IN THE DOCUMENT, which is what makes it impossible to be missing.
    ///
    /// The reference implementation's approach: every story carries thumbnail bytes inside its own data,
    /// so the viewer draws a blurred cover on the first frame of the first visit with no cache and no
    /// network. Ours had only a URL — and for a video that URL is a separately uploaded `thumb.jpg`
    /// which may not have landed, or may never land at all. When it was missing the viewer had
    /// nothing to hold the screen with and showed the canvas or black, which is the report he has
    /// filed more than any other.
    ///
    /// 30px on the long edge at quality 0.4 lands around 400-700 bytes of base64 — nothing against
    /// Firestore's 1 MB document limit, and it is written with the document rather than after it, so
    /// there is no window where the story exists without a cover. It is never drawn sharp: the veil
    /// puts it through `StoryCanvas.loadingVeil`, the same blur the real poster gets, which is
    /// exactly how the reference app uses theirs.
    /// Takes the ENCODED bytes, never a `UIImage`, and that is deliberate on both call sites: the
    /// photo path holds the picked file's data and the video path holds its poster's data, so a
    /// `UIImage` here would mean decoding a full-size picture at post time to throw all but 30
    /// pixels of it away. `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size asked
    /// for, and honours the EXIF orientation while it does it, so a photo taken sideways gets a
    /// cover the right way up.
    static func blurThumbBase64(_ data: Data) -> String {
        guard !data.isEmpty,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 30,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return "" }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.4)?.base64EncodedString() ?? ""
    }
}

// A person's active (unexpired) stories — the unit behind a ring in the row + the viewer.
struct StoryGroup: Identifiable, Codable {
    let authorUid: String
    let name: String
    let photoUrl: String?
    var stories: [Story]          // oldest → newest
    var lastViewedAt: Date?
    var isMine: Bool

    var id: String { authorUid }

    // Unseen ⇔ ANY story I haven't watched yet (the standard rule: watching 1 of 5 no
    // longer greys the whole ring). A story counts as seen if I viewed that exact item on this
    // device (StoryPrefs flag) OR it's not newer than my synced watermark — `lastViewedAt` holds
    // the POST time of the newest story of theirs I've watched (covers reinstalls/other devices).
    // Applies to my own story too: colorful until I open it.
    var hasUnseen: Bool {
        stories.contains { !StoryPrefs.isStorySeen($0.id) && $0.createdAt > (lastViewedAt ?? .distantPast) }
    }
}

// One viewer of my story, for the "Seen by" sheet.
struct StoryViewerInfo: Identifiable {
    let id: String        // viewer uid
    let name: String
    let photoUrl: String?
    let viewedAt: Date
    let reaction: String?
}

@Observable
final class StoriesService {
    static let shared = StoriesService()
    private init() {}

    private let db = Firestore.firestore()
    private var uid: String { Auth.auth().currentUser?.uid ?? "" }

    // Optimistic upload state — drives the "Uploading…" indicator + spinner ring in the story row.
    var uploading = false

    /// WHICH HALF OF THE POST IS RUNNING, because they are not the same kind of wait and must not
    /// look the same.
    ///
    /// `.preparing` is work on THIS phone: squeezing the picture or transcoding the video. It has to
    /// block, because until it finishes there is no story — nothing to send and nothing to watch.
    /// This is another mainstream messenger's "Preparing…" box.
    ///
    /// `.sending` is the upload. It does NOT need the person, because their own copy is already
    /// finished and already playable from local bytes. That app shows a quiet "Adding status…" line
    /// here, with no spinner, and lets you open and watch it immediately.
    ///
    /// We used to run one spinning ring across BOTH, so a photo whose local work took ~0.3s still
    /// showed a busy ring for the ~2.9s the server took (owner measured it). The story was watchable
    /// that whole time; the ring was the only thing saying otherwise.
    enum UploadPhase { case preparing, sending }
    var uploadPhase: UploadPhase = .preparing

    /// A real `@MainActor` method rather than an inline `MainActor.run { self.… }`, because both
    /// callers are non-isolated `async` functions and one of them would have had to reach for `self`
    /// from inside a `@Sendable` closure to do it. Calling an isolated method on self is the version
    /// with no capture question at all.
    @MainActor private func markSending() { uploadPhase = .sending }

    var uploadError: String?   // set when a post fails so the UI can show it (was swallowed → "dead silent")
    private var uploadTask: Task<Void, Never>?

    /// ONE POST STILL IN THE AIR. There can be several, and that is the whole reason this type
    /// exists (owner 2026-08-07: "when I upload multiple images, every time I can see only the last
    /// one uploading — I need to see all, when I click right or left each one must be uploading").
    ///
    /// Posts have ALWAYS queued rather than replaced each other — the task chain below has done that
    /// since a second post silently destroyed the first — but the state describing them was a single
    /// image, a single url and a single start time, overwritten by whichever post was newest. So
    /// three pictures were three real uploads behind ONE placeholder: the two waiting their turn had
    /// nowhere to be drawn, and the viewer had nothing to page between.
    struct PendingUpload: Identifiable {
        let id: String                  // this post's synthetic story id — unique per post
        let image: UIImage?             // the picture, or a video's poster frame
        let url: String                 // the synthetic media url its bytes are cached under
        let startedAt: Date
        let tag: StoryAudienceTag
        // The caption rides on the placeholder from frame one (his report: a caption typed before
        // posting only appeared once the upload finished — the synthetic item simply never carried it).
        let caption: String
    }
    /// Oldest first, which is the order stories are read in — so the placeholders sit at the end of
    /// my bucket in the same order they will land as real stories.
    private(set) var inFlight: [PendingUpload] = []

    // Synthetic story items shown while an upload runs, so an uploading photo appears INSIDE the
    // real story viewer (real progress bars, header, swipe to my older posted stories) instead of a
    // separate placeholder screen. Its image is served from URLCache (pre-stored on upload start);
    // its id marks it so the viewer shows the "Uploading…" bar and blocks delete.
    ///
    /// A PREFIX, not the id itself, since there can be several at once. Everything that used to ask
    /// `id == uploadingStoryId` asks `isPending(id)` instead.
    static let uploadingStoryId = "story.uploading.placeholder"
    static func isPending(_ storyId: String) -> Bool { storyId.hasPrefix(uploadingStoryId) }

    /// The newest post's picture — what the story ROW draws on its single "Uploading…" card. The row
    /// has one slot for my story whatever is happening behind it; the viewer is where they are all
    /// visible.
    var uploadingImage: UIImage? { inFlight.last?.image }

    /// The custom list's device-local name for a placeholder: the real story's name is filed under
    /// its document id, which does not exist yet while it is uploading.
    func uploadingAudienceName(for storyId: String) -> String {
        inFlight.first { $0.id == storyId }?.tag.name ?? ""
    }

    /// Every post in the air, as story items. Each carries ITS OWN audience (a story posted to a
    /// custom list used to wear "My Friends" until the real document arrived) and its own picture.
    var uploadingStories: [Story] {
        inFlight.compactMap { p in
            guard p.image != nil else { return nil }
            return Story(id: p.id, authorUid: uid, createdAt: p.startedAt,
                         expiresAt: p.startedAt.addingTimeInterval(24 * 3600),
                         mediaUrl: p.url, allowsReplies: false,
                         caption: p.caption,
                         audienceLabel: p.tag.label, oneTime: p.tag.oneTime)
        }
    }

    // Fire-and-forget post: pop back to chat immediately, upload in the background, show progress.
    @MainActor func postStoryBackground(image: Data, caption: String = "", excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends) {
        // Don't cancel an in-flight post (that silently DESTROYED the 1st story when a 2nd was
        // posted) — QUEUE instead: the new task waits for the previous one, so both post in order.
        let previous = uploadTask
        // PER-POST, not a constant, and the url must be fresh per post as well as unique: StoryUI's
        // ImageLoader keeps decoded images in StoryMemoryCache keyed by absoluteString, so a reused
        // path could serve post A's picture as post B's placeholder (for a video, A's poster: his
        // "shows a different video that was already in my Story" report). A fresh path misses every
        // cache by construction. The PATH must vary, not a query — the disk cache ignores queries.
        let pending = PendingUpload(id: "\(Self.uploadingStoryId).\(UUID().uuidString)",
                                    image: UIImage(data: image),
                                    url: "https://fariin.local/uploading-\(UUID().uuidString).jpg",
                                    startedAt: Date(),
                                    tag: tag,   // the header says the chosen audience from frame one
                                    caption: caption)
        // Pre-store the picked bytes under the synthetic URL so the injected uploading item renders
        // instantly in the viewer. BOTH CACHES, not URLCache alone: nothing on any server answers a
        // `fariin.local` url, so an eviction has nowhere to fall back to. See `StoryImageSeed`.
        if let u = URL(string: pending.url) { StoryImageSeed.seed(image, for: u) }
        inFlight.append(pending)
        uploading = true
        uploadPhase = .preparing   // every post starts on the phone's half
        // Each post owns a token; the completion below only touches shared state if it's STILL the
        // owner. Without this, a cancel-then-repost (or a quick second post) let the FIRST task's
        // completion run last and wipe the SECOND upload's spinner + task handle (so it couldn't be
        // cancelled) — the "Uploading…" ring vanished mid-upload.
        let token = UUID()
        currentUploadToken = token
        uploadTask = Task {
            _ = await previous?.value   // chain behind any in-flight post (posts queue, never cancel each other)
            var failure: String?
            var cancelled = false
            do { try await postStory(image: image, caption: caption, excluded: excluded, included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag) }
            catch is CancellationError { cancelled = true }   // user hit cancel → postStory removed the doc
            catch { failure = error.localizedDescription }     // surface it instead of dying silently
            if !cancelled && failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run {
                self.queuedUploads.removeAll { $0.isCancelled }   // tidy finished/cancelled entries
                // ⚠️ OUTSIDE THE TOKEN GUARD, and that is the point of keeping them separate. This
                // post is finished whoever is newest, so its placeholder must go — under the guard,
                // an older post completing while a newer one is still uploading would never clear
                // its own entry and the row would show an upload that had already landed.
                self.inFlight.removeAll { $0.id == pending.id }
                self.uploading = !self.inFlight.isEmpty
                guard self.currentUploadToken == token else { return }   // a newer post owns the rest
                self.uploadTask = nil; self.uploadError = failure
            }
        }
        if let t = uploadTask { queuedUploads.append(t) }   // cancellable as part of the chain
    }
    private var currentUploadToken: UUID?

    @MainActor func cancelUpload() {
        currentUploadToken = nil   // invalidate any in-flight completion so it can't clobber a later post
        // Cancel the WHOLE chain, not just the newest task (audit). Posts queue behind each other,
        // so with A uploading and B queued, cancelling only B left A to finish and POST — while the
        // X the user tapped was sitting on B's image, so they watched the thing they cancelled go
        // up. Cancelling every queued task makes the button mean what it says.
        for t in queuedUploads { t.cancel() }
        queuedUploads.removeAll()
        uploadTask?.cancel(); uploadTask = nil
        uploading = false; inFlight.removeAll()
    }
    /// Every post task still in the queue (including the one currently uploading), so cancel can
    /// reach all of them. Entries are dropped as they finish.
    private var queuedUploads: [Task<Void, Never>] = []

    // Snapshot contacts on the MAIN actor (live-mutated there) and resolve the audience:
    //  • included non-empty -> only those; • excluded non-empty -> everyone minus those; • else everyone.
    // 1:1 contacts only (a group's otherUid is an arbitrary member → leak). Exclude anyone I've
    // BLOCKED — `isBlockedByMe`, NOT `leaksBlocked`: the latter is a chat-list freeze test (true only
    // if they messaged AFTER the block), so a quietly-blocked contact was slipping into the audience.
    private func resolveAudience(me: String, excluded: Set<String>, included: Set<String>) async -> (Set<String>, String) {
        // BLOCKING IS SYMMETRIC FOR BROADCAST CONTENT, and it was not.
        //
        // This filtered `isBlockedByMe` — chats where I blocked THEM — and never asked the other
        // question. `blockedBy` is a map keyed by whoever did the blocking, so somebody who blocked
        // ME was still in my audience and my stories kept arriving in their tray. Every other
        // messenger treats a block as ending the broadcast in both directions.
        // ⚠️ WAIT FOR THE CHAT LIST BEFORE ASKING IT WHO YOUR FRIENDS ARE.
        //
        // This read the array straight out, and the array is filled by a snapshot listener with no
        // synchronous seed. Post in the first moment after a cold launch — which is exactly when
        // somebody opens the app to post — and `conversations` is still empty, so `pool` is empty,
        // `recipients` comes back as the empty set, and `postStory` accepts that on purpose
        // ("Empty recipients is OK"). The story uploads, appears on your own row with a normal
        // ring, and reaches NOBODY. There is no error and no repair: `recipientUids` is pinned
        // immutable by the update rule, so the only cure is delete and post again, which requires
        // knowing it happened at all.
        //
        // `hasLoaded` is the same flag the chat list uses to stop showing its skeleton, and it is
        // guaranteed to flip: the repository sets it after 3s whether or not a snapshot arrived. So
        // the wait is bounded by the repository's own promise, and the cap below is only a belt
        // against that promise being changed later. Ten ticks of 0.5s reads as instant on a warm
        // launch, because the flag is already true and the loop never runs once.
        for _ in 0..<10 {
            if await MainActor.run(body: { ConversationsRepository.shared.hasLoaded }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let allContacts = await MainActor.run {
            Set(ConversationsRepository.shared.conversations
                .filter { c in
                    guard !c.isGroup else { return false }
                    let them = c.otherUid(me)
                    return !c.isBlockedByMe(me) && !c.isBlockedByMe(them) && !them.isEmpty
                }
                .map { $0.otherUid(me) })
        }
        // The global hide list, applied here as well as at the picker. This function is the one
        // place that resolves an audience against the LIVE chat list at upload time, so a story
        // queued before somebody was hidden must not reach them when it finally goes up.
        let hidden = await MainActor.run { StoryAudienceStore.shared.hiddenFrom }
        let pool = allContacts.subtracting(hidden)
        if !included.isEmpty { return (included.intersection(pool), "only") }
        if !excluded.isEmpty { return (pool.subtracting(excluded), "except") }
        return (pool, "all")
    }


    /// THE PUBLIC FACE OF AN "EVERYONE" STORY — media only, never the audience.
    ///
    /// The story document itself is no longer readable by strangers, because it carries
    /// `recipientUids` and a Firestore rule cannot grant a document while hiding one field of it. So
    /// one read of one public story used to hand over the author's whole contact list. This mirror
    /// is what a stranger reaching the profile actually reads: the picture, the caption, when it
    /// expires, and nothing about who else can see it.
    ///
    /// Written only for `public` stories, and only once the media URL is known — a mirror pointing
    /// at an empty url is a black card on somebody else's profile.
    private func writePublicMirror(storyId: String, me: String, mediaUrl: String, thumbUrl: String,
                                   blurThumb: String = "",
                                   type: String, caption: String, duration: Double,
                                   expiresAt: Date, allowsReplies: Bool) async {
        try? await db.collection("users").document(me)
            .collection("publicStories").document(storyId)
            .setData([
                "authorUid": me,
                "createdAt": FieldValue.serverTimestamp(),
                "expiresAt": Timestamp(date: expiresAt),
                "mediaUrl": mediaUrl,
                "thumbUrl": thumbUrl,
                // THE COVER TRAVELS WITH THE MIRROR TOO. `parse` reads the same field names for both
                // collections, so leaving it out was a stranger opening a public video story onto
                // nothing while a friend opening the very same story got a picture. See
                // `blurThumbBase64`.
                "blurThumb": blurThumb,
                "type": type,
                "caption": caption,
                "duration": duration,
                "allowsReplies": allowsReplies,
            ])
    }

    /// The mirror goes when the story does. Harmless if there never was one.
    private func deletePublicMirror(storyId: String, authorUid: String) async {
        try? await db.collection("users").document(authorUid)
            .collection("publicStories").document(storyId).delete()
    }

    // Post a photo to "My Status": chosen audience can see it for 24h.
    func postStory(image: Data, caption: String = "", expiryHours: Double = 24,
                   excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends) async throws {
        let me = uid
        guard !me.isEmpty else { return }
        try Task.checkCancellation()   // bail before any write if the user already cancelled
        let storyId = UUID().uuidString
        let path = "stories/\(storyId)/photo.jpg"   // {storyId}/ segment so Storage rules can audience-scope reads

        // THE PHOTO STARTS MOVING FIRST. Everything below used to be strictly serial — resolve the
        // audience, write the story doc, compress, and only THEN send the first byte — so two full
        // network round trips sat in front of the slowest step in the whole operation.
        //
        // The justification for that order was written in a comment here: "the Storage READ rule for
        // downloadURL() checks this doc's authorUid, so it must exist before we resolve the URL". THAT
        // IS NO LONGER TRUE, and storage.rules says so in as many words: "Writes happen at upload time
        // (before the story doc exists), so write is just auth + size + type", and read is now plain
        // `request.auth != null` with no Firestore lookup at all. The rule was relaxed because the
        // audience check was denying the AUTHOR's own getDownloadURL; the ordering here was never
        // updated to match, so the code kept paying for a constraint that had been removed.
        //
        // The UPLOAD now runs CONCURRENTLY with the audience resolve and the doc write, so the chain
        // is as long as its slowest branch rather than the sum of both. (Compression used to be in
        // that branch too; see the note on the hoist just below.)
        let docRef = db.collection("stories").document(storyId)
        let ref = Storage.storage().reference().child(path)

        // Decoding, resizing and re-encoding a 12MP photo is real work, and it belongs BEFORE the doc
        // write rather than after it. HOISTED OUT of the `async let` below on purpose: the phase flip
        // has to happen the instant this returns, and doing that from inside a `@Sendable` closure
        // would mean capturing `self` there. The cost is that ~0.3s of CPU no longer overlaps the
        // audience resolve, which is a local main-actor hop — nothing worth capturing a class for.
        let jpeg = ChatService.downscaledJPEG(image)
        // THE PHONE'S HALF IS OVER. Everything past this line is the network, and this person's own
        // copy is already complete — so the ring comes down here, not at the end.
        await markSending()

        async let uploadedJPEG: Void = {
            try Task.checkCancellation()
            let meta = StorageMetadata(); meta.contentType = "image/jpeg"
            _ = try await ref.putDataAsync(jpeg, metadata: meta)
        }()

        let (recipients, mode) = await resolveAudience(me: me, excluded: excluded, included: included)
        // Made once and used twice — the document and, for an "Everyone" story, the public mirror.
        // It is a resize and a JPEG encode, so asking for it twice is real work for one string.
        let cover = Self.blurThumbBase64(image)
        // ⚠️ ONE DEADLINE, EVALUATED ONCE. The mirror used to compute its own `Date()` AFTER the
        // upload finished, so it was stamped to die later than the story it mirrors — by exactly
        // however long the transfer took. On a slow connection that is minutes of a story that has
        // expired everywhere except on the author's public profile.
        let expiresAt = Date().addingTimeInterval(expiryHours * 3600)

        // Empty recipients is OK: it's still MY OWN story (the `mine` query loads by authorUid, so I
        // always see it) — just with no other viewers yet (e.g. a brand-new account with no contacts).
        // The audience sheet already warns when you HAVE contacts but narrowed the audience to none, so
        // reaching here with empty recipients means "own story only", which is valid — don't block it.
        do {
            try await docRef.setData([
                "authorUid": me,
                "createdAt": FieldValue.serverTimestamp(),
                "expiresAt": Timestamp(date: expiresAt),
                "type": "image",
                "mediaPath": path,
                "mediaUrl": "",
                // THE COVER THAT TRAVELS WITH THE STORY. See `blurThumbBase64`.
                "blurThumb": cover,
                "caption": caption,
                "audience": ["mode": everyone ? "everyone" : mode, "listId": "my-story"],
                // THE LABEL, and only the label. See StoryAudienceTag: the custom NAME never comes
                // here, because a recipient reads this document.
                "audienceLabel": tag.label,
                "oneTime": tag.oneTime,
                // Public ("Everyone") stories are viewable by anyone who finds your profile — the
                // read rules gate on this flag. Contacts still get it in their tray via
                // recipientUids below.
                "public": everyone,
                "allowsReplies": allowsReplies,
                "replyCount": 0,
                "recipientUids": Array(recipients),
            ])
            StoryPrefs.rememberAudienceName(storyId: storyId, tag: tag)

            // Both halves were in flight together; wait for the photo to land before asking for its
            // URL. If the doc write above threw, this child task is cancelled and awaited on the way
            // out, and the catch deletes whatever reached Storage.
            try await uploadedJPEG   // `jpeg` is already in scope; this only waits for the transfer
            try Task.checkCancellation()   // cancelled during upload → undo
            let url = try await ref.downloadURL().absoluteString
            try await docRef.updateData(["mediaUrl": url])
            // The stranger-facing copy, media only. See `writePublicMirror`.
            if everyone {
                await writePublicMirror(storyId: storyId, me: me, mediaUrl: url, thumbUrl: "",
                                        blurThumb: cover,
                                        type: "image", caption: caption, duration: 0,
                                        expiresAt: expiresAt,
                                        allowsReplies: allowsReplies)
            }
            // Warm the cache the My Story card reads from (DiskImageCache), so the final card shows the
            // image instantly as the "Uploading…" placeholder morphs into it — no blank-then-fetch.
            if let img = UIImage(data: jpeg) { DiskImageCache.shared.store(img, data: jpeg, for: url) }
            // ALSO warm URLCache — the STORY VIEWER (StoryUI's ImageLoader) reads from URLCache first,
            // NOT DiskImageCache. Without this, opening the just-posted story re-downloaded the image
            // from Storage (~3s of shimmer). The uploaded bytes ARE what the URL returns, so cache them
            // under that URL and the viewer shows it instantly.
            if let u = URL(string: url) {
                let resp = URLResponse(url: u, mimeType: "image/jpeg",
                                       expectedContentLength: jpeg.count, textEncodingName: nil)
                URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: jpeg),
                                                    for: URLRequest(url: u))
            }
        } catch {
            // Undo BOTH halves. Either can have got somewhere before the other failed, now that they
            // run together, so neither cleanup is optional. Storage deletes are `allow delete: if
            // false` for clients, so that one fails harmlessly and onStoryDeleted sweeps the bytes
            // when the doc goes; it stays here so the intent is on the record.
            try? await docRef.delete()
            try? await ref.delete()
            throw error
        }
    }

    // Fire-and-forget VIDEO post — same shape as postStoryBackground. `thumbnail` is the poster
    // frame the editor already generated; it drives the uploading ring/placeholder immediately
    // while the transcode + upload run in the background.
    @MainActor func postVideoStoryBackground(videoURL: URL, thumbnail: Data, muted: Bool = false,
                                             burn: StoryBurnIn? = nil,
                                             trim: ClosedRange<Double>? = nil, caption: String = "",
                                             excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends) {
        // Same queueing as postStoryBackground: never cancel an in-flight post, chain behind it.
        let previous = uploadTask
        // Its own entry in the queue, exactly as a photo post takes one — see `PendingUpload`.
        // THE PLACEHOLDER WEARS THE CANVAS THE EXPORT IS ABOUT TO BAKE. His report: "when is
        // uploading it's showing blur, when upload finished it's showing different color… use one is
        // better". The uploading card drew the raw poster, which letterboxes BLACK, while the file
        // that lands carries the gradient — so the story visibly changed colour at the hand-over.
        // Same sampler, same gradient, one function; a 9:16 clip is returned untouched.
        let placeholder = UIImage(data: thumbnail).map { VideoTranscoder.storyCanvasPoster($0) }
        let pending = PendingUpload(id: "\(Self.uploadingStoryId).\(UUID().uuidString)",
                                    image: placeholder,
                                    url: "https://fariin.local/uploading-\(UUID().uuidString).jpg",
                                    startedAt: Date(),
                                    tag: tag,
                                    caption: caption)
        // ⚠️ THE SAME BYTES, or the composed picture above is wasted. StoryUI's ImageLoader reads
        // URLCache FIRST, so seeding the raw poster here would win over `pending.image` and put the
        // black-letterboxed frame back on screen.
        if let u = URL(string: pending.url) {
            // BOTH CACHES — the url is invented, so URLCache evicting it leaves the card with
            // nothing to draw and no server to ask. See `StoryImageSeed`.
            StoryImageSeed.seed(placeholder?.jpegData(compressionQuality: 0.9) ?? thumbnail, for: u)
        }
        inFlight.append(pending)
        uploading = true
        uploadPhase = .preparing   // video starts on the phone's half too — and it is the long one
        let token = UUID()
        currentUploadToken = token
        uploadTask = Task {
            _ = await previous?.value   // chain behind any in-flight post (posts queue, never cancel each other)
            var failure: String?
            var cancelled = false
            do { try await postVideoStory(videoURL: videoURL, muted: muted, trim: trim, burn: burn, caption: caption, excluded: excluded, included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag) }
            catch is CancellationError { cancelled = true }
            catch { failure = error.localizedDescription }
            if !cancelled && failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run {
                self.queuedUploads.removeAll { $0.isCancelled }   // tidy finished/cancelled entries
                self.inFlight.removeAll { $0.id == pending.id }   // outside the guard — see the photo path
                self.uploading = !self.inFlight.isEmpty
                guard self.currentUploadToken == token else { return }
                self.uploadTask = nil; self.uploadError = failure
            }
        }
        // IN THE CANCEL CHAIN, like the photo path always was. This append was missing here, so
        // with video A uploading and B queued, the X reached only B — A finished and POSTED the
        // thing the user watched themselves cancel. The exact bug the photo path's comment says
        // was fixed once already; it had been re-introduced for video-first chains.
        if let t = uploadTask { queuedUploads.append(t) }
    }

    /// A long video becomes SEVERAL stories, in order, instead of being cut down to the first 90
    /// seconds (owner's spec, 2026-08-04, modelled on another mainstream messenger's status feature). 45s is one story; two minutes is
    /// 90 + 30; five minutes is four. Nothing the user picked is thrown away and they do nothing
    /// extra to get it.
    ///
    /// SEQUENTIAL ON PURPOSE, not parallel. Each story's place in the queue is its `createdAt`, and
    /// the only way to be sure segment 2 sorts after segment 1 is to write it after segment 1. Three
    /// uploads racing would land in whatever order the network felt like, which is a jumbled story.
    ///
    /// A FAILURE DOES NOT RESTART THE WHOLE THING. Each segment retries on its own, twice, and if one
    /// still will not go the error says which — the segments already posted stay posted, because
    /// making somebody re-upload four minutes because the fifth chunk timed out is the opposite of
    /// what this feature is for.
    func postVideoStory(videoURL: URL, muted: Bool = false, trim: ClosedRange<Double>? = nil, burn: StoryBurnIn? = nil,
                        caption: String = "", expiryHours: Double = 24,
                        excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends) async throws {
        let full = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0
        // A hand trim decides where the material starts and how much of it there is; the split then
        // works on THAT, not on the original file. Trim to 20s and you get one story, not the first
        // 90 seconds of something you already cut.
        let offset = max(0, trim?.lowerBound ?? 0)
        let total = max(0, min(trim?.upperBound ?? full, full) - offset)
        let cap = Double(Limits.storyVideoSeconds)
        guard total > cap + 0.5 else {
            let range = trim.map { _ in
                CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                            duration: CMTime(seconds: total, preferredTimescale: 600))
            }
            // Short enough to be one story: the ordinary path, no segmenting, no behaviour change.
            try await postVideoSegment(videoURL: videoURL, range: range, caption: caption, muted: muted, burn: burn,
                                       expiryHours: expiryHours, excluded: excluded,
                                       included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag)
            return
        }

        let count = Int(ceil(min(total, Double(Limits.storyVideoPickSeconds)) / cap))
        for i in 0..<count {
            try Task.checkCancellation()
            let start = offset + Double(i) * cap
            let len = min(cap, (offset + total) - start)
            guard len > 0.05 else { break }
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: len, preferredTimescale: 600))
            // The caption belongs to the story, not to every slice of it: repeating it on all seven
            // reads as a stutter. It rides the FIRST segment, which is the one people see first.
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    try await postVideoSegment(videoURL: videoURL, range: range,
                                               caption: i == 0 ? caption : "", muted: muted, burn: burn,
                                               expiryHours: expiryHours, excluded: excluded,
                                               included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag)
                    lastError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1))) }
                }
            }
            if let lastError {
                throw NSError(domain: "Fariin", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Part \(i + 1) of \(count) didn't upload. The parts before it were posted — try again to send the rest.",
                    NSUnderlyingErrorKey: lastError,
                ])
            }
        }
    }

    // Post ONE story from a video: transcode to 720p H.264 (optionally just the slice `range`),
    // upload the poster thumb + the mp4, then fill both URLs atomically (the repository skips docs
    // with an empty mediaUrl, so nobody sees a half-uploaded story).
    private func postVideoSegment(videoURL: URL, range: CMTimeRange?, caption: String, muted: Bool, burn: StoryBurnIn? = nil,
                                  expiryHours: Double, excluded: Set<String>, included: Set<String>,
                                  everyone: Bool, allowsReplies: Bool, tag: StoryAudienceTag) async throws {
        let me = uid
        guard !me.isEmpty else { return }
        try Task.checkCancellation()

        // Transcode BEFORE creating the doc — a failed/cancelled transcode leaves zero server state.
        // The editor's text, pen and crop ride the SAME export the trim and the 90-second split
        // already use, so a long edited clip is burned in once per segment rather than re-encoded a
        // second time on top of itself.
        // `storyBackdrop`: a square/landscape clip gets a gradient canvas BAKED into the
        // file, so the posted story looks like the editor everywhere. Costs those clips the fast
        // copy path (they re-encode); 9:16 clips are untouched. See `VideoTranscoder.prepare`.
        guard let prepared = await VideoTranscoder.prepare(videoURL, maxSeconds: Double(Limits.storyVideoSeconds), stripAudio: muted, range: range,
                                                           overlay: burn?.overlay, cropRect: burn?.cropRect,
                                                           canvasAspect: burn?.canvasAspect,
                                                           storyBackdrop: true) else {
            throw NSError(domain: "Fariin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't process this video"])
        }
        // THE PHONE'S HALF IS OVER — and on video it is the long half. Past here it is upload only,
        // and the clip is already playable from the local file, so the ring must stop. See
        // `uploadPhase`.
        await markSending()
        try Task.checkCancellation()

        let storyId = UUID().uuidString
        let videoPath = "stories/\(storyId)/video.mp4"
        let thumbPath = "stories/\(storyId)/thumb.jpg"
        let (recipients, mode) = await resolveAudience(me: me, excluded: excluded, included: included)
        // Made once and used twice — the document and, for an "Everyone" story, the public mirror.
        let cover = Self.blurThumbBase64(prepared.thumbnail)
        // ONE DEADLINE, EVALUATED ONCE — see the photo path for what two of them cost.
        let expiresAt = Date().addingTimeInterval(expiryHours * 3600)

        let docRef = db.collection("stories").document(storyId)
        try await docRef.setData([
            "authorUid": me,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: expiresAt),
            "type": "video",
            "mediaPath": videoPath,
            "mediaUrl": "",
            "thumbUrl": "",
            // ⚠️ THIS IS THE ONE THAT MATTERS MOST, because a video's `thumbUrl` stays empty until
            // its second upload finishes and can fail on its own. Written with the DOCUMENT, before
            // a single byte of media is uploaded, so a viewer reaching this story at any point after
            // it exists has a picture to show. See `blurThumbBase64`.
            "blurThumb": cover,
            "duration": prepared.duration,
            // ⚠️ THE CLIP'S OWN SHAPE AND SIZE, WHICH THIS DOCUMENT HAS NEVER CARRIED.
            //
            // The reference app ships all of this on the media itself (`w`, `h`, `duration`,
            // `supports_streaming` and a server-computed `preload_prefix_size`), and it is what lets
            // it size a placeholder correctly before a byte arrives and fetch a PREFIX of a
            // neighbour instead of the whole file. Ours discovers the size at runtime from
            // `AVPlayerItem.presentationSize` — which is to say, after the download.
            //
            // Written now even though nothing reads them yet, and that is deliberate rather than
            // sloppy: a story expires in 24 hours, so a field first written on the day the reader
            // ships would have no story to describe. `preloadPrefix` is the byte count worth
            // fetching to start playback — our exports are `shouldOptimizeForNetworkUse`, so the
            // moov atom is at the FRONT and a prefix is genuinely playable. Half a megabyte is a
            // couple of seconds at the bitrates the transcoder produces, and the whole file when
            // the file is smaller than that.
            "width": prepared.width,
            "height": prepared.height,
            "bytes": prepared.data.count,
            "preloadPrefix": min(prepared.data.count, 512 * 1024),
            "caption": caption,
            "audience": ["mode": everyone ? "everyone" : mode, "listId": "my-story"],
            // The label only — the custom name stays on this device. See StoryAudienceTag.
            "audienceLabel": tag.label,
            "oneTime": tag.oneTime,
            "public": everyone,
            "allowsReplies": allowsReplies,
            "replyCount": 0,
            "recipientUids": Array(recipients),
        ])
        StoryPrefs.rememberAudienceName(storyId: storyId, tag: tag)

        do {
            try Task.checkCancellation()
            // THE TWO PUTS RUN TOGETHER, and the URL asks run together after them. This chain was
            // strictly serial — thumb, then video, then two downloadURL round trips one at a time —
            // so every video story paid the thumb's upload and ~two extra round trips on top of the
            // one transfer that matters. Same relaxation the photo path already uses (storage.rules
            // stopped requiring the doc first; see the note there). The doc write above has already
            // happened, so recipients' listeners still see either the full story or nothing.
            let thumbRef = Storage.storage().reference().child(thumbPath)
            let videoRef = Storage.storage().reference().child(videoPath)
            async let thumbPut: Void = {
                let thumbMeta = StorageMetadata(); thumbMeta.contentType = "image/jpeg"
                _ = try await thumbRef.putDataAsync(prepared.thumbnail, metadata: thumbMeta)
            }()
            async let videoPut: Void = {
                let videoMeta = StorageMetadata(); videoMeta.contentType = "video/mp4"
                _ = try await videoRef.putDataAsync(prepared.data, metadata: videoMeta)
            }()
            _ = try await (thumbPut, videoPut)
            try Task.checkCancellation()
            async let tURL = thumbRef.downloadURL()
            async let vURL = videoRef.downloadURL()
            let (thumbUrl, videoUrl) = try await (tURL.absoluteString, vURL.absoluteString)
            // One atomic update: recipients' listeners either see the full story or nothing.
            try await docRef.updateData(["mediaUrl": videoUrl, "thumbUrl": thumbUrl])
            // The stranger-facing copy, media only. See `writePublicMirror`.
            if everyone {
                await writePublicMirror(storyId: storyId, me: me, mediaUrl: videoUrl,
                                        thumbUrl: thumbUrl,
                                        blurThumb: cover,
                                        type: "video", caption: caption,
                                        duration: prepared.duration,
                                        expiresAt: expiresAt,
                                        allowsReplies: allowsReplies)
            }
            // Warm both caches with the poster so my-story cards + the viewer's first frame are instant.
            if let img = UIImage(data: prepared.thumbnail) {
                DiskImageCache.shared.store(img, data: prepared.thumbnail, for: thumbUrl)
            }
            if let u = URL(string: thumbUrl) {
                let resp = URLResponse(url: u, mimeType: "image/jpeg",
                                       expectedContentLength: prepared.thumbnail.count, textEncodingName: nil)
                URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: prepared.thumbnail),
                                                    for: URLRequest(url: u))
            }
            // AND THE VIDEO ITSELF. Only the poster was warmed, so opening the just-posted story
            // re-downloaded the 4-23MB file the phone had JUST finished uploading, on the same
            // connection — the poster sat under a spinner for the whole round trip, which is his
            // "after the upload finishes it keeps showing the loading state". The uploaded bytes
            // ARE what the URL returns; put them where StoryUI's video cache looks and the story
            // plays with zero network.
            if let u = URL(string: videoUrl) { StoryVideoSeed.seed(prepared.data, for: u) }
        } catch {
            try? await docRef.delete()
            try? await Storage.storage().reference().child(videoPath).delete()
            try? await Storage.storage().reference().child(thumbPath).delete()
            throw error
        }
    }

    // Record that I viewed a story: always bump my own seen-ring marker; only send a
    // view receipt (so the author sees I viewed) if I have view receipts ON.
    func markViewed(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        // A demo person exists only on this device (see `demoGroups`). Their story ids match no
        // document, so a receipt or a watermark for one is a write that can only ever fail — and it
        // would fail against the REAL database, under the real account, for a story that is not there.
        guard !StoriesRepository.isDemoAuthor(story.authorUid) else { return }
        // Advance my per-author watermark to this story's POST time — never backwards, one write
        // per advance. (Was a wall-clock serverTimestamp, which made watching 1 of 5 stories mark
        // the whole ring seen; the watermark now means "the newest story of theirs I've watched".)
        if await StoriesRepository.shared.advanceServerWatermark(story.authorUid, to: story.createdAt) {
            try? await db.collection("users").document(me)
                .collection("storyContexts").document(story.authorUid)
                .setData(["lastViewedAt": Timestamp(date: story.createdAt)], merge: true)
        }

        let receiptsOn = UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true
        if receiptsOn {
            // merge: a re-view must NOT wipe a previously-set "reaction" off this receipt.
            try? await db.collection("stories").document(story.id)
                .collection("views").document(me)
                .setData(["viewedAt": FieldValue.serverTimestamp()], merge: true)
        }
        if story.oneTime { await consumeOneTime(story) }
    }

    /// BURN A ONE-TIME STORY, for me.
    ///
    /// ⚠️ A SEPARATE SUBCOLLECTION FROM THE VIEW RECEIPT, ON PURPOSE, AND NOT AN OPTIMISATION TO
    /// UNDO. A view receipt is optional — "Story View Receipts" is a setting, and with it off no
    /// receipt is written at all. Consumption cannot be optional, or turning that switch off would
    /// turn a one-time story into an ordinary one. And it must not be written INTO the receipt
    /// either, because that would put somebody with receipts off into the author's Seen-by list.
    ///
    /// This write is what the server watches. `onStoryConsumed` takes me out of the story's
    /// `recipientUids`, which is the actual enforcement: the tray query stops matching, a direct read
    /// is refused by the existing rule, and no client can put me back — the story update rule pins
    /// `recipientUids` to its current value for everybody.
    ///
    /// WHAT THIS DOES NOT DO, said plainly: the media file in Storage is readable by any signed-in
    /// user who already has its URL. Someone who captured the URL during their one view could fetch
    /// the file again outside the app. Closing that needs per-story Storage rules or signed URLs, and
    /// it is not this change.
    ///
    /// THE COST HE SHOULD KNOW: the author can tell who has opened a one-time story, because their
    /// uid leaves `recipientUids` and the author can read their own story. That is inherent to
    /// enforcing it at the audience — another mainstream app behaves the same way — and it is not affected by the
    /// viewer's receipt setting.
    func consumeOneTime(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.oneTime, story.authorUid != me else { return }
        await MainActor.run { StoryPrefs.markOneTimeUsed(story.id) }
        try? await db.collection("stories").document(story.id)
            .collection("consumed").document(me)
            .setData(["at": FieldValue.serverTimestamp()])
    }

    // Set my reaction emoji on my view receipt (shows in the author's "Seen by" list).
    func setStoryReaction(_ story: Story, emoji: String) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        let receiptsOn = UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true
        guard receiptsOn else { return }
        try? await db.collection("stories").document(story.id)
            .collection("views").document(me)
            .setData(["viewedAt": FieldValue.serverTimestamp(), "reaction": emoji], merge: true)
    }

    // Remove my reaction from my view receipt (un-like) so the author's "Seen by" stops
    // showing a heart I took back.
    func clearStoryReaction(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        try? await db.collection("stories").document(story.id)
            .collection("views").document(me)
            .updateData(["reaction": FieldValue.delete()])
    }

    // Who viewed a story I posted (author-only per rules) → for the "Seen by" sheet.
    func fetchViewers(storyId: String) async -> [StoryViewerInfo] {
        guard !uid.isEmpty else { return [] }
        // RECIPROCAL, as the Stories settings footer promises ("If disabled, you won't see when
        // others view your stories"). The gate existed only on the SENDING half — your views were
        // hidden from others while their full Seen-by list, timestamps and reactions still showed
        // to you (audit). the reference app's rule, and the one the copy already claims.
        guard UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true else { return [] }
        let snap = try? await db.collection("stories").document(storyId).collection("views").getDocuments()
        let docs = snap?.documents ?? []
        let (convs, me) = await MainActor.run { (ConversationsRepository.shared.conversations, uid) }
        return docs.map { d in
            let u = d.documentID
            let c = convs.first { $0.otherUid(me) == u }
            return StoryViewerInfo(
                id: u,
                name: c?.name(for: me) ?? "Someone",
                photoUrl: c?.photoUrl(for: me),
                viewedAt: (d.data()["viewedAt"] as? Timestamp)?.dateValue() ?? Date(),
                reaction: d.data()["reaction"] as? String
            )
        }.sorted { $0.viewedAt > $1.viewedAt }
    }

    func deleteStory(_ id: String) async {
        // Delete the Storage media FIRST (while the doc still exists, so rules pass), then the
        // doc — else an early delete (before expiry) leaks the media forever (cleanup only
        // handles EXPIRED docs). Read the doc's REAL mediaPath: videos live at video.mp4 +
        // thumb.jpg — the old hardcoded photo.jpg leaked both files on every video delete.
        let data = (try? await db.collection("stories").document(id).getDocument())?.data()
        let path = data?["mediaPath"] as? String ?? "stories/\(id)/photo.jpg"
        // The public mirror goes with it, or a deleted story keeps playing on the author's profile
        // to every stranger who opens it. No-op when there never was one.
        if let author = data?["authorUid"] as? String {
            await deletePublicMirror(storyId: id, authorUid: author)
        }
        try? await Storage.storage().reference().child(path).delete()
        if data?["type"] as? String == "video" {
            try? await Storage.storage().reference().child("stories/\(id)/thumb.jpg").delete()
        }
        try? await db.collection("stories").document(id).delete()
        // Drop it from the live row immediately — callers check "was that my last story?"
        // right after this, which must not race the listener's delete event.
        await StoriesRepository.shared.removeLocally(id)
    }

    /// Flag a story for review (App Store 1.2 — abuse reporting).
    func reportStory(_ story: Story) async {
        guard !uid.isEmpty else { return }
        try? await db.collection("reports").addDocument(data: [
            "type": "story",
            "storyId": story.id,
            "authorUid": story.authorUid,
            "reporterUid": uid,   // the rule requires reporterUid (was "reporter" → create denied)
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Delete EVERY story I've posted. Called on account deletion so nothing I shared
    /// stays visible after I'm gone (App Store 5.1.1(v) — deletion must remove my data).
    /// Removes the Storage image first (while the doc still exists, so the rules' author
    /// check passes), then the story doc itself.
    /// ⚠️ THE MIRRORS NOBODY WAS DELETING. A mirror is removed on an explicit delete and on account
    /// deletion, and on NOTHING ELSE — ordinary 24-hour expiry leaves it behind, readable by any
    /// signed-in account, carrying the author's uid, media url and caption for as long as the account
    /// exists. That is a privacy leak with an App Store rule attached to it, and a cost: every
    /// profile visit used to read the whole pile.
    ///
    /// Only the author can write here, so only the author can clean it. Run once per session, off
    /// the critical path, bounded, and failures are ignored — the reader already filters by expiry,
    /// so this is housekeeping rather than correctness.
    func sweepExpiredMirrors() async {
        let me = uid
        guard !me.isEmpty else { return }
        guard let snap = try? await db.collection("users").document(me)
            .collection("publicStories")
            .whereField("expiresAt", isLessThan: Timestamp(date: Date()))
            .limit(to: 40)
            .getDocuments() else { return }
        for d in snap.documents { try? await d.reference.delete() }
    }

    func deleteAllMine() async {
        let me = uid
        guard !me.isEmpty,
              let snap = try? await db.collection("stories")
                  .whereField("authorUid", isEqualTo: me).getDocuments() else { return }
        for d in snap.documents {
            if let path = d.data()["mediaPath"] as? String {
                try? await Storage.storage().reference().child(path).delete()
            }
            // Videos also have a poster thumb next to the mp4 — delete it too or it leaks.
            if d.data()["type"] as? String == "video" {
                try? await Storage.storage().reference().child("stories/\(d.documentID)/thumb.jpg").delete()
            }
            // AND THE PUBLIC MIRROR, which is a SEPARATE document in a subcollection and does not
            // go with the story. An "Everyone" story writes one at post time; nothing here removed
            // it, and its read rule is signed-in-only, so it outlived the story it mirrors.
            await deletePublicMirror(storyId: d.documentID, authorUid: me)
            try? await d.reference.delete()
        }
    }
}

// Cold-start warm cache for the stories ROW (the chat-list trick): the last BUILT row is
// persisted per-account and re-seeded synchronously on launch, so friends' cards render
// immediately instead of ~1.7s late — a cold rebuild otherwise blocks on unknown-author
// profile fetches over the network (user stopwatch, 2026-07-22). Listeners reconcile after.
private enum StoryRowCache {
    struct CachedProfile: Codable { let name: String; let photo: String? }
    struct Blob: Codable {
        let uid: String
        let mine: StoryGroup?
        let others: [StoryGroup]
        let profiles: [String: CachedProfile]
    }
    private static let key = "storyRowCache.v1"
    static func save(uid: String, mine: StoryGroup?, others: [StoryGroup],
                     profiles: [String: (String, String?)]) {
        let blob = Blob(uid: uid, mine: mine, others: others,
                        profiles: profiles.mapValues { CachedProfile(name: $0.0, photo: $0.1) })
        if let d = try? JSONEncoder().encode(blob) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func load(uid: String) -> Blob? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(Blob.self, from: d), b.uid == uid else { return nil }
        return b
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// Loads the stories I can see (mine + others' that include me), unexpired, grouped by
// person, with my seen-state attached. LIVE: snapshot listeners (same pattern as the chat
// list) push new/deleted stories and my seen-watermarks straight into the row — a friend's
// new ring slides in while you're sitting on the screen, no pull-to-refresh.
@Observable
final class StoriesRepository {
    static let shared = StoriesRepository()
    private init() {}

    private let db = Firestore.firestore()
    var mine: StoryGroup?            // my own story (the "My Status" cell)
    var others: [StoryGroup] = []    // friends' stories, unseen-first
    // True once rebuild() has PUBLISHED at least once — i.e. the groups above are real knowledge,
    // not just "nothing arrived yet". The story-reply card in a chat flips to "Story unavailable"
    // when a quoted story is absent from the groups, and absence is only meaningful after this:
    // an unloaded repo is empty too, and treating that as "deleted" would mark every quoted story
    // unavailable for the first beat of a cold start.
    private(set) var didLoad = false
    // Bumped on every publish. ThreadView keys its row-signature cache on it, so a story dying
    // (deleted or expired) re-signs and re-MEASURES the story-reply rows — the card (140pt) and
    // the "Story unavailable" line differ in height, and a hosted cell only re-measures through
    // the signature path.
    private(set) var storiesVersion = 0

    /// Is this exact story still live (visible to me, unexpired)? The same resolution the reply
    /// card's tap uses to open it — so what the card SHOWS and what the tap DOES cannot disagree.
    func hasLive(storyId: String, author: String) -> Bool {
        (others + [mine].compactMap { $0 })
            .contains { $0.authorUid == author && $0.stories.contains { $0.id == storyId } }
    }

    // Live inputs. Listener callbacks arrive on the MAIN queue (Firestore default); rebuild()
    // snapshots them there and regroups off-main.
    private var othersReg: ListenerRegistration?
    private var mineReg: ListenerRegistration?
    private var ctxReg: ListenerRegistration?
    private var listeningUid: String?               // re-attach when the signed-in user changes
    /// ⚠️ WHICH REBUILD IS ALLOWED TO PUBLISH. Bumped by every rebuild as it starts; a rebuild only
    /// writes its result if it is still the newest one when it finishes.
    ///
    /// All three snapshot listeners end with `Task { await rebuild() }`, so three of them race into
    /// the same function, and `rebuild` awaits a network fetch for authors who are not in my chats.
    /// That is a real round trip, so a rebuild that STARTED with older data can FINISH after a newer
    /// one — the newer one finds those profiles already cached and returns fast — and the stale
    /// result lands last and wins. Symptom: a story you just deleted flickering back, or one you just
    /// posted vanishing for a beat, and only when somebody outside your chats has a story, which is
    /// what would have made it look random.
    ///
    /// The account guard below is NOT this guard: it catches switching user, and both of these
    /// rebuilds belong to the same account.
    private var rebuildGeneration = 0
    private var othersStories: [Story] = []
    private var mineStories: [Story] = []
    /// ⚠️ HAS THE SERVER ANSWERED THIS LISTENER YET, in this session.
    ///
    /// The empty-cached-snapshot guard below exists for the COLD START and nothing else: offline at
    /// launch, Firestore answers from an empty cache and the row would blank out before the seeded
    /// one could be seen. Without knowing whether the server had ever spoken, that guard could not
    /// tell that opening case apart from a real emptying, so it swallowed both — and the one story
    /// that empties a query is the LAST one, which is exactly the case somebody notices. Delete your
    /// only story with a poor connection and the card stayed on the row.
    ///
    /// Once the server has answered once, an empty snapshot means empty. See `start`.
    private var mineFromServer = false
    private var othersFromServer = false
    private var profileCache: [String: (String, String?)] = [:]   // unknown-author name/photo
    private var expiryTask: Task<Void, Never>?      // wakes at the next expiresAt → drop that card

    /// Sign-out/delete: drop this account's story state; listeners re-attach for the
    /// next account on its first load().
    func reset() {
        othersReg?.remove(); othersReg = nil
        mineReg?.remove(); mineReg = nil
        ctxReg?.remove(); ctxReg = nil
        listeningUid = nil
        expiryTask?.cancel(); expiryTask = nil
        othersStories = []; mineStories = []
        profileCache = [:]
        mine = nil; others = []
        didLoad = false          // the next account starts unknown, not "everything deleted"
        // ⚠️ AND THE WATERMARKS, which were the one piece of story state this did not clear.
        //
        // `serverWatermarks` is "the newest item of X's I have already watched", keyed by author and
        // NOT by account. Signing out and into a second account on the same phone therefore handed
        // the new person the old person's history: any author they both know showed a grey
        // already-watched ring on stories the new account had never opened. Worse, it swallowed
        // their first real view — `advanceServerWatermark` refuses a date older than the one it
        // holds, so the `storyContexts` write never fired and their seen state never reached the
        // server or their other devices.
        serverWatermarks = [:]
        storiesVersion &+= 1
        StoryRowCache.clear()   // the next account must never see this account's story row
    }

    /// Drop `uid` from the audience of every story I currently have live. Called when I block them:
    /// the audience is written once at post time, so without this a freshly blocked person keeps
    /// seeing (and view-receipting) my active stories until they expire.
    func revokeAudience(for uid: String) async {
        let me = AuthService.shared.uid ?? ""
        guard !me.isEmpty, !uid.isEmpty else { return }
        guard let snap = try? await db.collection("stories")
            .whereField("authorUid", isEqualTo: me).getDocuments() else { return }
        let now = Date()
        for doc in snap.documents {
            // Only live ones — expired docs are cleaned up on their own schedule.
            if let exp = (doc.data()["expiresAt"] as? Timestamp)?.dateValue(), exp <= now { continue }
            // ONLY the audience list. NOT the `public` flag: clearing that would pull the story from
            // every other non-contact's profile ring as well, which is not what blocking one person
            // means. An "Everyone" story stays public, and the blocked person is turned away at read
            // time instead — see the block gate in publicStoryGroup.
            try? await doc.reference.updateData(["recipientUids": FieldValue.arrayRemove([uid])])
        }
    }

    // Fetch a specific user's active PUBLIC ("Everyone") story group — powers the story ring on their
    // PROFILE, so anyone who finds them can watch. Non-contacts are allowed this read because the query
    // is constrained to `public == true`, which is exactly what the Firestore read rule gates on.
    // Returns nil if they have no active public story. Name/photo are passed in (the profile has them).
    func publicStoryGroup(for uid: String, name: String, photoUrl: String?) async -> StoryGroup? {
        let me = AuthService.shared.uid ?? ""
        guard !uid.isEmpty, uid != me else { return nil }   // my own ring is handled by the tray, not the profile
        // BLOCK GATE (audit). resolveAudience deliberately strips people I've blocked from every
        // story I post, but an "Everyone" story also carries public == true, and this read gated
        // only on that flag — so someone the AUTHOR blocked could still watch it from the author's
        // profile, and a rules-refused view write means it need not land in Seen-by to be watched.
        // The block is recorded on the shared conversation doc, which both clients can read.
        let cid = ChatService.convId(me, uid)
        if let snap = try? await db.collection("conversations").document(cid).getDocument(),
           ((snap.data()?["blockedBy"] as? [String: Any])?[uid] as? Bool) == true {
            return nil   // the AUTHOR blocked me → no ring, no story
        }
        // READS THE MIRROR, NOT THE STORY COLLECTION. The story documents carry `recipientUids` and
        // are no longer readable by anyone outside the audience — because granting them to strangers
        // so this query could work is exactly what leaked the author's contact list. The mirror at
        // `users/{uid}/publicStories` holds the media and nothing about who else can see it, which
        // is all a profile visitor ever needed. `parse` reads the same field names either way.
        // ⚠️ BOUNDED, BECAUSE NOTHING DELETES A MIRROR WHEN ITS STORY EXPIRES.
        //
        // `deletePublicMirror` is reached only from an explicit delete or from account deletion, so
        // ordinary expiry leaves the mirror standing forever. This read had no `where` and no
        // `limit`, so a daily poster's mirror collection grew without end and EVERY profile visit
        // paid a document read per mirror that had ever existed, then threw almost all of them away
        // in the filter below. The filter stays as the belt; the query is what stops the bill.
        let now = Date()
        let snap = try? await db.collection("users").document(uid)
            .collection("publicStories")
            .whereField("expiresAt", isGreaterThan: Timestamp(date: now))
            .limit(to: 50)
            .getDocuments()
        let stories = parse(snap?.documents)
            .filter { $0.expiresAt > now }
            .sorted { $0.createdAt < $1.createdAt }
        guard !stories.isEmpty else { return nil }
        return StoryGroup(authorUid: uid, name: name, photoUrl: photoUrl,
                          stories: stories, lastViewedAt: nil, isMine: false)
    }

    private func parse(_ docs: [QueryDocumentSnapshot]?) -> [Story] {
        // WHOSE PHONE THIS IS, read once. `uid` is StoriesService's own private property and this is
        // StoriesRepository, which is what the compiler caught; asking Auth inside the loop would
        // also be one lookup per story rather than one per query.
        let me = Auth.auth().currentUser?.uid ?? ""
        return (docs ?? []).compactMap { d in
            let data = d.data()
            guard let author = data["authorUid"] as? String,
                  let url = data["mediaUrl"] as? String, !url.isEmpty,   // skip the pre-upload window (empty URL froze the viewer)
                  let exp = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
            // A ONE-TIME STORY I HAVE ALREADY OPENED IS GONE, and it goes here because this is the
            // one place every story list is built. The server is removing me from its recipients as
            // this runs; this is what makes "immediately" true on the tap rather than a beat later.
            // Never applied to my OWN stories — the author keeps theirs until it expires.
            if (data["oneTime"] as? Bool ?? false), author != me, StoryPrefs.isOneTimeUsed(d.documentID) {
                return nil
            }
            let created = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            return Story(id: d.documentID, authorUid: author, createdAt: created,
                         expiresAt: exp, mediaUrl: url,
                         allowsReplies: data["allowsReplies"] as? Bool ?? true,
                         caption: data["caption"] as? String ?? "",
                         isVideo: data["type"] as? String == "video",
                         duration: data["duration"] as? Double ?? 0,
                         thumbUrl: data["thumbUrl"] as? String ?? "",
                         blurThumb: data["blurThumb"] as? String ?? "",
                         // Written by the uploader since 2026-08-12; absent on everything older,
                         // which reads as zero and lets the lookahead use its own default.
                         preloadPrefix: (data["preloadPrefix"] as? NSNumber)?.int64Value ?? 0,
                         // Stories posted before this field existed fall back to "friends", which is
                         // what they were: the audience list is newer than the story collection, and
                         // a public story is caught by the `public` flag below it.
                         audienceLabel: data["audienceLabel"] as? String
                            ?? ((data["public"] as? Bool ?? false) ? "everyone" : "friends"),
                         oneTime: data["oneTime"] as? Bool ?? false,
                         // Only my own story hands this over — see the property.
                         recipientsLeft: author == me
                            ? ((data["recipientUids"] as? [String])?.count ?? -1)
                            : -1)
        }
    }

    // Optimistically advance my LOCAL per-author watermark to the story just shown, so the
    // ring/row re-sort instantly instead of waiting for the server write (H8). Monotonic: the
    // watermark is the POST time of the newest story I've watched — never wall clock — so a
    // person with newer unwatched stories keeps their colored ring.
    @MainActor func markSeenLocally(_ authorUid: String, upTo storyCreatedAt: Date) {
        // READ the current value into a local BEFORE writing. `x?.y = max(x?.y ?? …)` reads the
        // same @Observable property inside its own write access — a Swift exclusivity violation
        // that crashed (SIGABRT) the instant an own-story item was viewed (build 176).
        if let i = others.firstIndex(where: { $0.authorUid == authorUid }) {
            let cur = others[i].lastViewedAt ?? .distantPast
            if storyCreatedAt > cur { others[i].lastViewedAt = storyCreatedAt }
        }
        if let m = mine, m.authorUid == authorUid {
            let cur = m.lastViewedAt ?? .distantPast
            if storyCreatedAt > cur { mine?.lastViewedAt = storyCreatedAt }
        }
    }

    // Synchronous removal of one story from the live caches AND the visible groups (used by
    // deleteStory so "was that my last story?" checks never race the listener's delete event).
    @MainActor func removeLocally(_ storyId: String) {
        mineStories.removeAll { $0.id == storyId }
        othersStories.removeAll { $0.id == storyId }
        mine?.stories.removeAll { $0.id == storyId }
        if mine?.stories.isEmpty == true { mine = nil }
        for i in others.indices { others[i].stories.removeAll { $0.id == storyId } }
        others.removeAll { $0.stories.isEmpty }
    }

    // Server-side watermark dedupe: true = this view advances the synced watermark (caller then
    // writes it), false = already covered (no write). Seeded from storyContexts on load.
    private var serverWatermarks: [String: Date] = [:]
    @MainActor func advanceServerWatermark(_ authorUid: String, to date: Date) -> Bool {
        guard date > (serverWatermarks[authorUid] ?? .distantPast) else { return false }
        serverWatermarks[authorUid] = date
        return true
    }

    // Kept for every existing call site: first call goes LIVE (attaches the listeners); later
    // calls just regroup (refilter expiry, pick up renamed profiles) — no network round-trip.
    func load(force: Bool = false) async {
        #if DEBUG
        if DemoMode.active { return }   // demo stories injected; don't let Firebase overwrite them
        #endif
        guard let me = Auth.auth().currentUser?.uid else { return }
        if listeningUid != me {
            // ⚠️ THE OTHER HALF OF KEEPING STORY MEDIA PERMANENTLY. Its files moved out of `Caches`
            // so the OS stops deleting them (his "when i update the app story chache i loss"), and a
            // permanent directory with no lifetime rule is a leak. This is his "after Expired
            // delete": anything past two days goes, which is the retention the reference app gives its own
            // story category. Once per sign-in rather than per refresh — it walks two directories,
            // and doing that on every pull-to-refresh would be work nobody asked for.
            StoryStorage.purgeExpired()
            // The server-side equivalent, and the same once-per-sign-in cadence: mirrors of my own
            // expired stories, which nothing else deletes. See `sweepExpiredMirrors`. Detached so a
            // slow round trip cannot delay the row painting.
            // `StoriesService`, not `self` — this call site lives in `StoriesRepository`, and the
            // two share a file but not a type.
            Task.detached { await StoriesService.shared.sweepExpiredMirrors() }
            await MainActor.run {
                seedFromDisk(me)   // last-known row paints NOW; the listeners reconcile it silently
                start(me)          // first call, or the signed-in user changed
            }
        } else {
            await rebuild()
        }
    }

    // Cold-start seed: re-publish the persisted row (expired stories dropped) before the first
    // listener snapshot, so the stories row renders on the first frame like the chat list does.
    @MainActor private func seedFromDisk(_ me: String) {
        guard mine == nil, others.isEmpty, let blob = StoryRowCache.load(uid: me) else { return }
        let now = Date()
        var m = blob.mine
        m?.stories.removeAll { $0.expiresAt <= now }
        mine = (m?.stories.isEmpty == false) ? m : nil
        others = blob.others.compactMap { g -> StoryGroup? in
            var g = g
            g.stories.removeAll { $0.expiresAt <= now }
            return g.stories.isEmpty ? nil : g
        }
        for (u, p) in blob.profiles where profileCache[u] == nil { profileCache[u] = (p.name, p.photo) }
    }

    // Attach the three live queries (chat-list listener pattern).
    @MainActor private func start(_ me: String) {
        stop()
        listeningUid = me
        othersReg = db.collection("stories").whereField("recipientUids", arrayContains: me)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else { if let error { print("stories listen error:", error) }; return }
                if !snap.metadata.isFromCache { self.othersFromServer = true }
                if Self.ignoreColdEmpty(snap, serverHasSpoken: self.othersFromServer) { return }
                self.othersStories = self.parse(snap.documents)
                Task { await self.rebuild() }
            }
        mineReg = db.collection("stories").whereField("authorUid", isEqualTo: me)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else { if let error { print("my stories listen error:", error) }; return }
                if !snap.metadata.isFromCache { self.mineFromServer = true }
                if Self.ignoreColdEmpty(snap, serverHasSpoken: self.mineFromServer) { return }
                self.mineStories = self.parse(snap.documents)
                Task { await self.rebuild() }
            }
        // My per-author seen watermarks — live too, so watching on another device greys rings here.
        ctxReg = db.collection("users").document(me).collection("storyContexts")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                for d in snap.documents {
                    if let ts = (d.data()["lastViewedAt"] as? Timestamp)?.dateValue() {
                        // Merge FORWARD only — read into a local first (same-property read inside
                        // its own write access is an exclusivity crash, see markSeenLocally).
                        let cur = self.serverWatermarks[d.documentID] ?? .distantPast
                        if ts > cur { self.serverWatermarks[d.documentID] = ts }
                    }
                }
                Task { await self.rebuild() }
            }
    }

    /// THE OFFLINE COLD START, AND ONLY THAT: an empty snapshot out of the cache, before the server
    /// has ever answered this listener, with no unacknowledged write of ours to explain it.
    ///
    /// Everything else is a real emptying and has to be applied. The case this used to swallow is
    /// the one that matters: deleting your LAST story is the only delete that empties the query, and
    /// on a slow connection Firestore reports it from the cache first, so the guard threw the truth
    /// away and the card stayed on the row. `hasPendingWrites` is what names that snapshot as the
    /// consequence of my own delete rather than an empty cache, and it is true from the moment the
    /// local mutation lands until the server acknowledges it.
    ///
    /// Static, so it cannot read the flag it is being told about — a stored property passed into a
    /// method of its own owner is the exclusivity trap `markSeenLocally` already paid for once.
    private static func ignoreColdEmpty(_ snap: QuerySnapshot, serverHasSpoken: Bool) -> Bool {
        snap.metadata.isFromCache && snap.documents.isEmpty
            && !snap.metadata.hasPendingWrites && !serverHasSpoken
    }

    @MainActor private func stop() {
        othersReg?.remove(); othersReg = nil
        mineReg?.remove(); mineReg = nil
        ctxReg?.remove(); ctxReg = nil
        listeningUid = nil
        // A new account gets a new cold start. Left true, the first empty cached snapshot after a
        // sign-in would be applied as though the server had already confirmed the row was empty.
        mineFromServer = false
        othersFromServer = false
    }

    // Regroup the cached live inputs into the row's groups. Cheap (no story reads); only
    // unknown-author profiles are fetched, once each, then cached.
    private typealias RebuildInputs = (me: String, all: [Story], convs: [Conversation],
                                       myName: String, myPhoto: String?,
                                       cachedProfiles: [String: (String, String?)])

    private func rebuild() async {
        let now = Date()
        // Claimed on the main actor with the inputs, so the number and the data it describes are
        // taken in the same hop and cannot disagree.
        var generation = 0
        // Snapshot every live-mutated input on the main actor.
        let inputs: RebuildInputs? = await MainActor.run {
            guard let me = listeningUid else { return nil }
            rebuildGeneration &+= 1
            generation = rebuildGeneration
            // ⚠️ THE ONE-TIME FILTER RUNS HERE TOO, NOT ONLY IN `parse`.
            //
            // `parse` reads a SNAPSHOT, and a story I have just opened produces no snapshot for
            // several seconds: my consumption receipt has to reach Firestore, `onStoryConsumed` has
            // to fire, and only then does the recipients query stop matching. Until it did, the
            // parsed struct sat in `othersStories` and every regroup put it straight back in the
            // tray — so the card was still there and could be opened again and again. His report,
            // exactly: "a user can finish viewing the story and still see/open that same story".
            // Filtering the cached list as well makes the local flag bite immediately, on the
            // regroup the viewer's own close already asks for, without waiting for the server.
            return (me, (othersStories + mineStories)
                        .filter { $0.expiresAt > now }
                        .filter { !($0.oneTime && $0.authorUid != me && StoryPrefs.isOneTimeUsed($0.id)) },
                    ConversationsRepository.shared.conversations,
                    ProfileStore.shared.me?.name ?? "You",
                    ProfileStore.shared.me?.photoUrl,
                    profileCache)
        }
        guard let (me, all, convs, myName, myPhoto, cachedProfiles) = inputs else { return }

        // Authors NOT in my chats (a story can reach me from someone I've never messaged,
        // e.g. beta test accounts): fall back to their profile doc for name/photo instead of
        // rendering "User". Rules allow any signed-in user to read users/{uid}.
        let known = Set(convs.map { $0.otherUid(me) })
        let unknownAuthors = Set(all.map(\.authorUid)).subtracting(known).subtracting([me])
            .filter { cachedProfiles[$0] == nil }
        var profiles = cachedProfiles
        if !unknownAuthors.isEmpty {
            await withTaskGroup(of: (String, String, String?)?.self) { group in
                for u in unknownAuthors {
                    group.addTask { [db] in
                        let snap = try? await db.collection("users").document(u).getDocument()
                        if let snap, snap.exists, let f = snap.data() {
                            return (u, f["name"] as? String ?? "", f["photoUrl"] as? String)
                        }
                        // Doc genuinely doesn't exist → negative-cache ("", nil) so a profileless author
                        // isn't re-fetched on every listener tick. A NETWORK error (snap == nil) returns
                        // nil so it's retried next rebuild (don't cache a transient failure).
                        return snap != nil ? (u, "", nil) : nil
                    }
                }
                for await r in group { if let (u, n, p) = r { profiles[u] = (n, p) } }
            }
        }

        func display(_ uid: String) -> (String, String?) {
            if uid == me { return (myName, myPhoto) }
            if let c = convs.first(where: { $0.otherUid(me) == uid }) {
                return (c.name(for: me), c.photoUrl(for: me))
            }
            return profiles[uid] ?? ("", nil)
        }

        // Don't show stories from anyone I've blocked (C3, read side). isBlockedByMe, not
        // leaksBlocked — a quietly-blocked author's stories were still appearing in my row.
        let blockedAuthors = Set(convs.filter { $0.isBlockedByMe(me) }.map { $0.otherUid(me) })

        var myGroup: StoryGroup?
        var groups: [StoryGroup] = []
        for (author, list) in Dictionary(grouping: all, by: { $0.authorUid }) {
            let sorted = list.sorted { $0.createdAt < $1.createdAt }
            let (name, photo) = display(author)
            let g = StoryGroup(authorUid: author, name: name, photoUrl: photo,
                               stories: sorted, lastViewedAt: nil, isMine: author == me)
            if author == me { myGroup = g }
            else if !blockedAuthors.contains(author) { groups.append(g) }
        }
        if Self.injectDemoStories { groups.append(contentsOf: Self.demoGroups(now: now)) }   // TEMP test data

        // Unseen first, then by most-recent story. (Watermarks are applied on commit below,
        // so hasUnseen here can be pessimistic — the row re-sorts from live state anyway.)
        groups.sort {
            if $0.hasUnseen != $1.hasUnseen { return $0.hasUnseen }
            return ($0.stories.last?.createdAt ?? .distantPast) > ($1.stories.last?.createdAt ?? .distantPast)
        }

        let nextExpiry = all.map(\.expiresAt).min()
        await MainActor.run {
            // The account changed while this rebuild was awaiting profile fetches → publishing now
            // would repaint the previous account's story row for the next person, right after
            // reset() cleared it (audit). reset() nils listeningUid, so this is the test.
            guard self.listeningUid == me else { return }
            // AND ONLY IF NOTHING NEWER HAS STARTED. See `rebuildGeneration`. A rebuild that has
            // been overtaken while it waited on profile fetches is holding an older picture of the
            // world, and publishing it would undo whatever the newer one has already drawn.
            guard generation == self.rebuildGeneration else { return }
            for (u, p) in profiles where cachedProfiles[u] == nil { profileCache[u] = p }
            // Apply the freshest watermark to each group so a rebuild can never REGRESS a ring
            // to unseen while the view write is still in flight (H8, watermark edition).
            var mg = myGroup
            if let m = mg, let w = self.serverWatermarks[m.authorUid], w > (m.lastViewedAt ?? .distantPast) {
                mg?.lastViewedAt = w
            }
            var gs = groups
            for i in gs.indices {
                let cur = gs[i].lastViewedAt ?? .distantPast
                if let w = self.serverWatermarks[gs[i].authorUid], w > cur {
                    gs[i].lastViewedAt = w
                }
            }
            self.mine = mg; self.others = gs
            self.didLoad = true
            self.storiesVersion &+= 1
            // Persist the freshly built row so the NEXT cold start paints it on the first frame.
            StoryRowCache.save(uid: me, mine: mg, others: gs, profiles: self.profileCache)
            self.scheduleExpiryTick(nextExpiry)
        }
    }

    // A story crossing its 24h mark changes nothing in the database, so no listener fires —
    // wake up right after the soonest expiry and regroup so the card drops off by itself.
    @MainActor private func scheduleExpiryTick(_ next: Date?) {
        expiryTask?.cancel(); expiryTask = nil
        guard let next else { return }
        let delay = next.timeIntervalSinceNow + 1
        guard delay > 0 else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    // ===== Demo story people, for testing the viewer / carousel / rings / cube =====
    //
    // DEBUG ONLY, AND LOCAL ONLY. Every picture and every clip is drawn and encoded on this phone by
    // `DemoStoryMedia` and planted in the caches the real code reads, so these people work with the
    // network off and nothing about them ever reaches Firebase. Nobody else can see them because
    // they do not exist anywhere but this device.
    //
    // ⚠️ THE POINT OF THEM IS VIDEO. The previous version of this block pointed at `picsum.photos`
    // and every demo story was a still, which could not test one bug this app actually has — they
    // are all video bugs. The mixes below are chosen for the reports that keep coming back:
    // video→video→video for the preview-card flash, image→video→video for "the viewer closes when a
    // clip ends instead of advancing", and several people so the cube has somewhere to turn.
    //
    // Toggle at runtime with the switch in Settings (debug builds only) — no rebuild needed.
    /// ⚠️ NOT `#if DEBUG`. That gate shipped in build 550 and put the demo people in no build he can
    /// run: the TestFlight lane builds Release, and with no Mac in the picture every build that
    /// reaches his phone is a TestFlight build. `DemoStoryMedia.isAvailable` is debug OR TestFlight,
    /// never the App Store, which is the distinction that was actually wanted.
    static var injectDemoStories: Bool {
        DemoStoryMedia.isAvailable && UserDefaults.standard.bool(forKey: "demoStoryUsers")
    }

    /// True for a person who only exists on this device, so nothing tries to write a view receipt,
    /// a watermark or a reply for them.
    static func isDemoAuthor(_ uid: String) -> Bool { uid.hasPrefix("demo_") }

    /// Re-publish the row after the demo switch is flipped, so it takes effect without a relaunch.
    /// The first flip ON is also the encode, which is why it runs off the main actor.
    func refreshForDemo() { Task { await rebuild() } }

    static func demoGroups(now: Date) -> [StoryGroup] {
        // Ages, so the rings sort the way a real row would.
        func made(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-3600 * hoursAgo) }
        func expires() -> Date { now.addingTimeInterval(3600 * 20) }

        func videoStory(_ uid: String, _ n: Int, _ clip: DemoStoryMedia.Clip?, _ hoursAgo: Double) -> Story? {
            guard let clip else { return nil }
            return Story(id: "demo_\(uid)_\(n)", authorUid: uid, createdAt: made(hoursAgo),
                         expiresAt: expires(), mediaUrl: clip.mediaUrl, allowsReplies: true,
                         caption: "", isVideo: true, duration: clip.seconds, thumbUrl: clip.thumbUrl)
        }
        func imageStory(_ uid: String, _ n: Int, _ url: String, _ hoursAgo: Double) -> Story {
            Story(id: "demo_\(uid)_\(n)", authorUid: uid, createdAt: made(hoursAgo),
                  expiresAt: expires(), mediaUrl: url, allowsReplies: true)
        }

        // CABDI — three videos in a row. This is the set for the preview-card flash: open the
        // middle one, swipe up, then swipe the card row away and back.
        let cabdi = [
            videoStory("demo_cabdi", 1, DemoStoryMedia.video("cabdi-1", seconds: 6,
                                                             top: .systemIndigo, bottom: .systemBlue,
                                                             title: "Cabdi 1"), 5),
            videoStory("demo_cabdi", 2, DemoStoryMedia.video("cabdi-2", seconds: 4,
                                                             top: .systemPink, bottom: .systemRed,
                                                             title: "Cabdi 2"), 4),
            videoStory("demo_cabdi", 3, DemoStoryMedia.video("cabdi-3", seconds: 7,
                                                             top: .systemTeal, bottom: .systemGreen,
                                                             title: "Cabdi 3"), 3),
        ].compactMap { $0 }

        // HODAN — image, then two videos. The exact shape of the "B ends and the viewer closes
        // instead of going to C" report.
        let hodan = [
            imageStory("demo_hodan", 1, DemoStoryMedia.image("hodan-1", top: .systemOrange,
                                                             bottom: .systemYellow, title: "Hodan 1"), 6),
            videoStory("demo_hodan", 2, DemoStoryMedia.video("hodan-2", seconds: 5,
                                                             top: .systemPurple, bottom: .systemPink,
                                                             title: "Hodan 2"), 2),
            videoStory("demo_hodan", 3, DemoStoryMedia.video("hodan-3", seconds: 5,
                                                             top: .systemBrown, bottom: .systemOrange,
                                                             title: "Hodan 3"), 1),
        ].compactMap { $0 }

        // YASIN — a single long clip, so there is a person whose story does not advance internally.
        let yasin = [
            videoStory("demo_yasin", 1, DemoStoryMedia.video("yasin-1", seconds: 8,
                                                             top: .systemCyan, bottom: .systemIndigo,
                                                             title: "Yasin"), 7),
        ].compactMap { $0 }

        // SAGAL — stills only, as a control: whatever breaks on the video people must NOT break here.
        let sagal = [
            imageStory("demo_sagal", 1, DemoStoryMedia.image("sagal-1", top: .systemGreen,
                                                             bottom: .systemTeal, title: "Sagal 1"), 9),
            imageStory("demo_sagal", 2, DemoStoryMedia.image("sagal-2", top: .systemRed,
                                                             bottom: .systemPink, title: "Sagal 2"), 8),
        ]

        return [
            StoryGroup(authorUid: "demo_cabdi", name: "Cabdi (demo)",
                       photoUrl: DemoStoryMedia.avatar("cabdi", top: .systemIndigo,
                                                       bottom: .systemBlue, initial: "C"),
                       stories: cabdi, lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo_hodan", name: "Hodan (demo)",
                       photoUrl: DemoStoryMedia.avatar("hodan", top: .systemPurple,
                                                       bottom: .systemPink, initial: "H"),
                       stories: hodan, lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo_yasin", name: "Yasin (demo)",
                       photoUrl: DemoStoryMedia.avatar("yasin", top: .systemCyan,
                                                       bottom: .systemIndigo, initial: "Y"),
                       stories: yasin, lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo_sagal", name: "Sagal (demo)",
                       photoUrl: DemoStoryMedia.avatar("sagal", top: .systemGreen,
                                                       bottom: .systemTeal, initial: "S"),
                       stories: sagal, lastViewedAt: nil, isMine: false),
        ].filter { !$0.stories.isEmpty }
    }
}

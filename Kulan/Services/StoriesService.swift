import Foundation
import Observation
import UIKit
import AVFoundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import StoryUI   // StoryVideoSeed — the uploader warms the viewer's video cache

// One story (photo or video). Rules-protected (v1, not E2EE); media is a plain file in Storage.
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

    // What card/ring/reply thumbnails should render: the photo itself, or the video's poster.
    // Every image consumer (row cards, morph carousel, reply quotes, archive) reads THIS, never
    // mediaUrl directly — a video's mediaUrl is an .mp4 and image-decodes to nothing.
    var previewUrl: String { isVideo && !thumbUrl.isEmpty ? thumbUrl : mediaUrl }
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
    /// This is WhatsApp's "Preparing…" box.
    ///
    /// `.sending` is the upload. It does NOT need the person, because their own copy is already
    /// finished and already playable from local bytes. WhatsApp shows a quiet "Adding status…" line
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

    var uploadingImage: UIImage?
    var uploadError: String?   // set when a post fails so the UI can show it (was swallowed → "dead silent")
    private var uploadTask: Task<Void, Never>?
    private var uploadStartedAt = Date()

    // Synthetic "newest" story item shown while an upload runs, so the uploading photo appears INSIDE
    // the real story viewer (real progress bars, header, swipe to my older posted stories) instead of a
    // separate placeholder screen. Its image is served from URLCache (pre-stored on upload start); its
    // fixed id marks it so the viewer shows the "Uploading…" bar and blocks delete.
    static let uploadingStoryId = "story.uploading.placeholder"
    /// PER-POST, not a constant. It was one fixed URL, and StoryUI's ImageLoader keeps decoded
    /// images in StoryMemoryCache keyed by absoluteString — so the placeholder for post B could
    /// serve post A's picture out of that cache (for a video story, A's poster: his "shows a
    /// different video that was already in my Story" report). URLCache was refreshed each post;
    /// the memory cache in FRONT of it was not, and could not be from here. A fresh path per post
    /// misses every cache by construction. The path must vary, not a query — the disk cache's key
    /// ignores queries.
    private var uploadingURLString = "https://fariin.local/uploading-placeholder.jpg"
    var uploadingStory: Story? {
        guard uploading, uploadingImage != nil else { return nil }
        return Story(id: Self.uploadingStoryId, authorUid: uid, createdAt: uploadStartedAt,
                     expiresAt: uploadStartedAt.addingTimeInterval(24 * 3600),
                     mediaUrl: uploadingURLString, allowsReplies: false)
    }

    // Fire-and-forget post: pop back to chat immediately, upload in the background, show progress.
    @MainActor func postStoryBackground(image: Data, caption: String = "", excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false) {
        // Don't cancel an in-flight post (that silently DESTROYED the 1st story when a 2nd was
        // posted) — QUEUE instead: the new task waits for the previous one, so both post in order.
        let previous = uploadTask
        uploadingImage = UIImage(data: image)
        uploadStartedAt = Date()
        uploadingURLString = "https://fariin.local/uploading-\(UUID().uuidString).jpg"
        // Pre-store the picked bytes in URLCache under the synthetic URL so the injected uploading item
        // renders instantly in the viewer (StoryUI's ImageLoader reads URLCache first).
        if let u = URL(string: uploadingURLString) {
            let resp = URLResponse(url: u, mimeType: "image/jpeg", expectedContentLength: image.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: image), for: URLRequest(url: u))
        }
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
            do { try await postStory(image: image, caption: caption, excluded: excluded, included: included, everyone: everyone) }
            catch is CancellationError { cancelled = true }   // user hit cancel → postStory removed the doc
            catch { failure = error.localizedDescription }     // surface it instead of dying silently
            if !cancelled && failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run {
                self.queuedUploads.removeAll { $0.isCancelled }   // tidy finished/cancelled entries
                guard self.currentUploadToken == token else { return }   // a newer post owns the state now
                self.uploading = false; self.uploadingImage = nil; self.uploadTask = nil; self.uploadError = failure
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
        uploading = false; uploadingImage = nil
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
        let allContacts = await MainActor.run {
            Set(ConversationsRepository.shared.conversations
                .filter { !$0.isGroup && !$0.isBlockedByMe(me) }
                .map { $0.otherUid(me) }.filter { !$0.isEmpty })
        }
        if !included.isEmpty { return (included.intersection(allContacts), "only") }
        if !excluded.isEmpty { return (allContacts.subtracting(excluded), "except") }
        return (allContacts, "all")
    }

    // Post a photo to "My Status": chosen audience can see it for 24h.
    func postStory(image: Data, caption: String = "", expiryHours: Double = 24,
                   excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false) async throws {
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

        // Empty recipients is OK: it's still MY OWN story (the `mine` query loads by authorUid, so I
        // always see it) — just with no other viewers yet (e.g. a brand-new account with no contacts).
        // The audience sheet already warns when you HAVE contacts but narrowed the audience to none, so
        // reaching here with empty recipients means "own story only", which is valid — don't block it.
        do {
            try await docRef.setData([
                "authorUid": me,
                "createdAt": FieldValue.serverTimestamp(),
                "expiresAt": Timestamp(date: Date().addingTimeInterval(expiryHours * 3600)),
                "type": "image",
                "mediaPath": path,
                "mediaUrl": "",
                "caption": caption,
                "audience": ["mode": everyone ? "everyone" : mode, "listId": "my-story"],
                // Public ("Everyone") stories are viewable by anyone who finds your profile — the
                // read rules gate on this flag. Contacts still get it in their tray via
                // recipientUids below.
                "public": everyone,
                "allowsReplies": true,
                "replyCount": 0,
                "recipientUids": Array(recipients),
            ])

            // Both halves were in flight together; wait for the photo to land before asking for its
            // URL. If the doc write above threw, this child task is cancelled and awaited on the way
            // out, and the catch deletes whatever reached Storage.
            try await uploadedJPEG   // `jpeg` is already in scope; this only waits for the transfer
            try Task.checkCancellation()   // cancelled during upload → undo
            let url = try await ref.downloadURL().absoluteString
            try await docRef.updateData(["mediaUrl": url])
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
                                             excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false) {
        // Same queueing as postStoryBackground: never cancel an in-flight post, chain behind it.
        let previous = uploadTask
        uploadingImage = UIImage(data: thumbnail)
        uploadStartedAt = Date()
        uploadingURLString = "https://fariin.local/uploading-\(UUID().uuidString).jpg"
        if let u = URL(string: uploadingURLString) {
            let resp = URLResponse(url: u, mimeType: "image/jpeg", expectedContentLength: thumbnail.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: thumbnail), for: URLRequest(url: u))
        }
        uploading = true
        uploadPhase = .preparing   // video starts on the phone's half too — and it is the long one
        let token = UUID()
        currentUploadToken = token
        uploadTask = Task {
            _ = await previous?.value   // chain behind any in-flight post (posts queue, never cancel each other)
            var failure: String?
            var cancelled = false
            do { try await postVideoStory(videoURL: videoURL, muted: muted, trim: trim, burn: burn, caption: caption, excluded: excluded, included: included, everyone: everyone) }
            catch is CancellationError { cancelled = true }
            catch { failure = error.localizedDescription }
            if !cancelled && failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run {
                self.queuedUploads.removeAll { $0.isCancelled }   // tidy finished/cancelled entries
                guard self.currentUploadToken == token else { return }
                self.uploading = false; self.uploadingImage = nil; self.uploadTask = nil; self.uploadError = failure
            }
        }
        // IN THE CANCEL CHAIN, like the photo path always was. This append was missing here, so
        // with video A uploading and B queued, the X reached only B — A finished and POSTED the
        // thing the user watched themselves cancel. The exact bug the photo path's comment says
        // was fixed once already; it had been re-introduced for video-first chains.
        if let t = uploadTask { queuedUploads.append(t) }
    }

    /// A long video becomes SEVERAL stories, in order, instead of being cut down to the first 90
    /// seconds (owner's spec, 2026-08-04, WhatsApp Status' model). 45s is one story; two minutes is
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
                        excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false) async throws {
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
                                       included: included, everyone: everyone)
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
                                               included: included, everyone: everyone)
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
                                  everyone: Bool) async throws {
        let me = uid
        guard !me.isEmpty else { return }
        try Task.checkCancellation()

        // Transcode BEFORE creating the doc — a failed/cancelled transcode leaves zero server state.
        // The editor's text, pen and crop ride the SAME export the trim and the 90-second split
        // already use, so a long edited clip is burned in once per segment rather than re-encoded a
        // second time on top of itself.
        guard let prepared = await VideoTranscoder.prepare(videoURL, maxSeconds: Double(Limits.storyVideoSeconds), stripAudio: muted, range: range,
                                                           overlay: burn?.overlay, cropRect: burn?.cropRect,
                                                           canvasAspect: burn?.canvasAspect) else {
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

        let docRef = db.collection("stories").document(storyId)
        try await docRef.setData([
            "authorUid": me,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(expiryHours * 3600)),
            "type": "video",
            "mediaPath": videoPath,
            "mediaUrl": "",
            "thumbUrl": "",
            "duration": prepared.duration,
            "caption": caption,
            "audience": ["mode": everyone ? "everyone" : mode, "listId": "my-story"],
            "public": everyone,
            "allowsReplies": true,
            "replyCount": 0,
            "recipientUids": Array(recipients),
        ])

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
    private var othersStories: [Story] = []
    private var mineStories: [Story] = []
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
        let snap = try? await db.collection("stories")
            .whereField("authorUid", isEqualTo: uid)
            .whereField("public", isEqualTo: true)
            .getDocuments()
        let now = Date()
        let stories = parse(snap?.documents)
            .filter { $0.expiresAt > now }
            .sorted { $0.createdAt < $1.createdAt }
        guard !stories.isEmpty else { return nil }
        return StoryGroup(authorUid: uid, name: name, photoUrl: photoUrl,
                          stories: stories, lastViewedAt: nil, isMine: false)
    }

    private func parse(_ docs: [QueryDocumentSnapshot]?) -> [Story] {
        (docs ?? []).compactMap { d in
            let data = d.data()
            guard let author = data["authorUid"] as? String,
                  let url = data["mediaUrl"] as? String, !url.isEmpty,   // skip the pre-upload window (empty URL froze the viewer)
                  let exp = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
            let created = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            return Story(id: d.documentID, authorUid: author, createdAt: created,
                         expiresAt: exp, mediaUrl: url,
                         allowsReplies: data["allowsReplies"] as? Bool ?? true,
                         caption: data["caption"] as? String ?? "",
                         isVideo: data["type"] as? String == "video",
                         duration: data["duration"] as? Double ?? 0,
                         thumbUrl: data["thumbUrl"] as? String ?? "")
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
                // Offline cold-start: ignore an empty cached snapshot so the last-known row stays.
                if snap.metadata.isFromCache && snap.documents.isEmpty { return }
                self.othersStories = self.parse(snap.documents)
                Task { await self.rebuild() }
            }
        mineReg = db.collection("stories").whereField("authorUid", isEqualTo: me)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else { if let error { print("my stories listen error:", error) }; return }
                if snap.metadata.isFromCache && snap.documents.isEmpty { return }
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

    @MainActor private func stop() {
        othersReg?.remove(); othersReg = nil
        mineReg?.remove(); mineReg = nil
        ctxReg?.remove(); ctxReg = nil
        listeningUid = nil
    }

    // Regroup the cached live inputs into the row's groups. Cheap (no story reads); only
    // unknown-author profiles are fetched, once each, then cached.
    private typealias RebuildInputs = (me: String, all: [Story], convs: [Conversation],
                                       myName: String, myPhoto: String?,
                                       cachedProfiles: [String: (String, String?)])

    private func rebuild() async {
        let now = Date()
        // Snapshot every live-mutated input on the main actor.
        let inputs: RebuildInputs? = await MainActor.run {
            guard let me = listeningUid else { return nil }
            return (me, (othersStories + mineStories).filter { $0.expiresAt > now },
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

    // ===== TEMPORARY demo stories (real images) for testing the viewer/carousel/rings =====
    // Flip `injectDemoStories` to false (or delete this block) before production.
    static let injectDemoStories = false
    static func demoGroups(now: Date) -> [StoryGroup] {
        func story(_ uid: String, _ n: Int, _ seed: String) -> Story {
            Story(id: "demo_\(uid)_\(n)", authorUid: uid,
                  createdAt: now.addingTimeInterval(Double(-3600 * (5 - n))),   // a few hours apart
                  expiresAt: now.addingTimeInterval(3600 * 20),
                  mediaUrl: "https://picsum.photos/seed/\(seed)/1080/1920", allowsReplies: true)
        }
        func group(_ uid: String, _ name: String, _ avatar: Int, _ seeds: [String]) -> StoryGroup {
            StoryGroup(authorUid: uid, name: name, photoUrl: "https://i.pravatar.cc/150?img=\(avatar)",
                       stories: seeds.enumerated().map { story(uid, $0.offset + 1, $0.element) },
                       lastViewedAt: nil, isMine: false)
        }
        return [
            group("demo_alex",  "Alex (demo)",  12, ["alexa", "alexb", "alexc"]),
            group("demo_maya",  "Maya (demo)",  45, ["mayaa", "mayab"]),
            group("demo_sam",   "Sam (demo)",   33, ["sama", "samb", "samc", "samd"]),
            group("demo_lena",  "Lena (demo)",  5,  ["lenaa"]),
            group("demo_omar",  "Omar (demo)",  68, ["omara", "omarb", "omarc", "omard", "omare"]),
            group("demo_nina",  "Nina (demo)",  47, ["ninaa", "ninab"]),
            group("demo_jay",   "Jay (demo)",   15, ["jaya", "jayb", "jayc"]),
            group("demo_zoe",   "Zoe (demo)",   9,  ["zoea", "zoeb", "zoec", "zoed"]),
            group("demo_kofi",  "Kofi (demo)",  60, ["kofia", "kofib"]),
        ]
    }
}

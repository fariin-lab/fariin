import Foundation
import Observation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// One photo story. Rules-protected (v1, not E2EE); media is a plain image in Storage.
struct Story: Identifiable, Hashable {
    let id: String
    let authorUid: String
    let createdAt: Date
    let expiresAt: Date
    let mediaUrl: String
    let allowsReplies: Bool
    var caption: String = ""   // Telegram-style overlay caption (stored as text, rendered in the viewer)
}

// A person's active (unexpired) stories — the unit behind a ring in the row + the viewer.
struct StoryGroup: Identifiable {
    let authorUid: String
    let name: String
    let photoUrl: String?
    var stories: [Story]          // oldest → newest
    var lastViewedAt: Date?
    var isMine: Bool

    var id: String { authorUid }

    // Unseen ⇔ ANY story I haven't watched yet (WhatsApp/Instagram rule: watching 1 of 5 no
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
    var uploadingImage: UIImage?
    var uploadError: String?   // set when a post fails so the UI can show it (was swallowed → "dead silent")
    private var uploadTask: Task<Void, Never>?
    private var uploadStartedAt = Date()

    // Synthetic "newest" story item shown while an upload runs, so the uploading photo appears INSIDE
    // the real story viewer (real progress bars, header, swipe to my older posted stories) instead of a
    // separate placeholder screen. Its image is served from URLCache (pre-stored on upload start); its
    // fixed id marks it so the viewer shows the "Uploading…" bar and blocks delete.
    static let uploadingStoryId = "story.uploading.placeholder"
    private static let uploadingURLString = "https://kulan.local/uploading-placeholder.jpg"
    var uploadingStory: Story? {
        guard uploading, uploadingImage != nil else { return nil }
        return Story(id: Self.uploadingStoryId, authorUid: uid, createdAt: uploadStartedAt,
                     expiresAt: uploadStartedAt.addingTimeInterval(24 * 3600),
                     mediaUrl: Self.uploadingURLString, allowsReplies: false)
    }

    // Fire-and-forget post: pop back to chat immediately, upload in the background, show progress.
    @MainActor func postStoryBackground(image: Data, caption: String = "", excluded: Set<String> = [], included: Set<String> = []) {
        uploadTask?.cancel()
        uploadingImage = UIImage(data: image)
        uploadStartedAt = Date()
        // Pre-store the picked bytes in URLCache under the synthetic URL so the injected uploading item
        // renders instantly in the viewer (StoryUI's ImageLoader reads URLCache first).
        if let u = URL(string: Self.uploadingURLString) {
            let resp = URLResponse(url: u, mimeType: "image/jpeg", expectedContentLength: image.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: image), for: URLRequest(url: u))
        }
        uploading = true
        // Each post owns a token; the completion below only touches shared state if it's STILL the
        // owner. Without this, a cancel-then-repost (or a quick second post) let the FIRST task's
        // completion run last and wipe the SECOND upload's spinner + task handle (so it couldn't be
        // cancelled) — the "Uploading…" ring vanished mid-upload.
        let token = UUID()
        currentUploadToken = token
        uploadTask = Task {
            var failure: String?
            var cancelled = false
            do { try await postStory(image: image, caption: caption, excluded: excluded, included: included) }
            catch is CancellationError { cancelled = true }   // user hit cancel → postStory removed the doc
            catch { failure = error.localizedDescription }     // surface it instead of dying silently
            if !cancelled && failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run {
                guard self.currentUploadToken == token else { return }   // a newer post owns the state now
                self.uploading = false; self.uploadingImage = nil; self.uploadTask = nil; self.uploadError = failure
            }
        }
    }
    private var currentUploadToken: UUID?

    @MainActor func cancelUpload() {
        currentUploadToken = nil   // invalidate any in-flight completion so it can't clobber a later post
        uploadTask?.cancel(); uploadTask = nil
        uploading = false; uploadingImage = nil
    }

    // Post a photo to "My Status": chosen audience can see it for 24h.
    func postStory(image: Data, caption: String = "", expiryHours: Double = 24,
                   excluded: Set<String> = [], included: Set<String> = []) async throws {
        let me = uid
        guard !me.isEmpty else { return }
        try Task.checkCancellation()   // bail before any write if the user already cancelled
        let storyId = UUID().uuidString
        let path = "stories/\(storyId)/photo.jpg"   // {storyId}/ segment so Storage rules can audience-scope reads

        // Snapshot contacts on the MAIN actor (live-mutated there). Audience:
        //  • included non-empty -> only those; • excluded non-empty -> everyone minus those; • else everyone.
        let allContacts = await MainActor.run {
            Set(ConversationsRepository.shared.conversations
                // 1:1 contacts only (a group's otherUid is an arbitrary member → leak). Exclude
                // anyone I've BLOCKED — `isBlockedByMe`, NOT `leaksBlocked`: the latter is a
                // chat-list freeze test (true only if they messaged AFTER the block), so a quietly-
                // blocked contact was slipping into the audience and still getting my stories.
                .filter { !$0.isGroup && !$0.isBlockedByMe(me) }
                .map { $0.otherUid(me) }.filter { !$0.isEmpty })
        }
        let recipients: Set<String>
        let mode: String
        if !included.isEmpty { recipients = included.intersection(allContacts); mode = "only" }
        else if !excluded.isEmpty { recipients = allContacts.subtracting(excluded); mode = "except" }
        else { recipients = allContacts; mode = "all" }

        // Don't create a doc / upload bytes for a story literally no one can see (zero contacts, or a
        // stale "only share with" that resolved empty). Surface it instead of silently posting to no one.
        guard !recipients.isEmpty else {
            throw NSError(domain: "Kulan.Story", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No one to share this story with."])
        }

        // Create the story doc FIRST (mediaUrl filled in after upload). The Storage READ
        // rule for downloadURL() checks this doc's authorUid, so it must exist before we
        // resolve the URL — otherwise getDownloadURL() is denied and the post fails.
        let docRef = db.collection("stories").document(storyId)
        try await docRef.setData([
            "authorUid": me,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(expiryHours * 3600)),
            "type": "image",
            "mediaPath": path,
            "mediaUrl": "",
            "caption": caption,
            "audience": ["mode": mode, "listId": "my-story"],
            "allowsReplies": true,
            "replyCount": 0,
            "recipientUids": Array(recipients),
        ])

        // Upload the image, then resolve + persist its download URL. If anything fails OR the user cancels,
        // remove the doc (and any uploaded bytes) so we never leave a story with no image — or a story the
        // user explicitly cancelled — visible to the audience.
        do {
            try Task.checkCancellation()   // cancelled after the doc was created → undo it below
            let jpeg = ChatService.downscaledJPEG(image)
            let ref = Storage.storage().reference().child(path)
            let meta = StorageMetadata(); meta.contentType = "image/jpeg"
            _ = try await ref.putDataAsync(jpeg, metadata: meta)
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
            try? await docRef.delete()
            try? await Storage.storage().reference().child(path).delete()
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
        // Delete the Storage media FIRST (deterministic path), then the doc — else an early
        // delete (before expiry) leaks the image forever (cleanup only handles EXPIRED docs).
        try? await Storage.storage().reference().child("stories/\(id)/photo.jpg").delete()
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
            try? await d.reference.delete()
        }
    }
}

// Loads the stories I can see (mine + others' that include me), unexpired, grouped by
// person, with my seen-state attached. LIVE: snapshot listeners (same pattern as the chat
// list) push new/deleted stories and my seen-watermarks straight into the row — a friend's
// new ring slides in while you're sitting on the screen (WhatsApp), no pull-to-refresh.
@Observable
final class StoriesRepository {
    static let shared = StoriesRepository()
    private init() {}

    private let db = Firestore.firestore()
    var mine: StoryGroup?            // my own story (the "My Status" cell)
    var others: [StoryGroup] = []    // friends' stories, unseen-first

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
                         caption: data["caption"] as? String ?? "")
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
        guard let me = Auth.auth().currentUser?.uid else { return }
        if listeningUid != me {
            await MainActor.run { start(me) }   // first call, or the signed-in user changed
        } else {
            await rebuild()
        }
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
                        guard let f = try? await db.collection("users").document(u).getDocument().data()
                        else { return nil }   // fetch failed → not cached → retried next rebuild
                        return (u, f["name"] as? String ?? "", f["photoUrl"] as? String)
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

import Foundation
import Photos
import UIKit

// "Save to Photos" (Settings > Chats): copy the photos and videos you RECEIVE into the system
// Photos library, so you do not have to hit Save on each one.
//
// ONLY INCOMING MEDIA. Your own pictures are already in your camera roll, and saving them again
// would quietly duplicate every photo you ever send.
//
// VIEW-ONCE IS NEVER SAVED. The sender marked it to disappear; a setting they cannot see must not
// copy it to the roll behind their back. Same reason the manual Save action hides on those.
//
// It rides the media prefetch pass (`MediaAutoDownloader.sweep`), which already walks a chat's
// messages holding the network policy and the decryption keys, so nothing is downloaded twice for
// this. That also sets the honest limit of the feature: it saves the media of chats that reach
// this device, when they reach it, not media that has never been fetched.
enum AutoSaveToPhotos {
    /// The UserDefaults key the Settings toggle binds to, so there is one spelling of it.
    static let defaultsKey = "chats.saveToPhotos"
    private static let doneKey = "chats.saveToPhotos.done"
    // Audit L24: the ledger is id -> when it was claimed, kept for `ledgerKeep`. That outlives the
    // `window` below, so a message is remembered for as long as it could be offered again, and a
    // reopened chat never saves it twice (the old 600-id list forgot, then saved old media again).
    private static let doneCap = 3000
    private static let ledgerKeep: TimeInterval = 8 * 86_400
    /// Only media sent in the last 7 days is ever offered, so a phone back after a long time away
    /// does not pour a backlog into the roll.
    private static let window: TimeInterval = 7 * 86_400
    /// How far back the first start reaches for a switch that was already on before this build.
    private static let legacyGrace: TimeInterval = 15 * 60
    /// When the Settings switch was turned on (seconds since 1970). Media sent before it is history
    /// and stays out of the roll (audit L24: turning it on saved the whole chat history).
    static let sinceKey = defaultsKey + ".since"
    /// A chat set to Always keeps its own start, beside its choice (so the prefix wipe takes it too).
    private static func chatSinceKey(_ cid: String) -> String { chatKeyPrefix + cid + ".since" }

    /// The Settings switch was turned on: saving starts now.
    static func noteTurnedOn() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: sinceKey)
    }

    /// From when this chat saves. A switch that was on before this build has no stamp yet; it
    /// starts counting from the first look, so it never reaches back into the history. That first
    /// look is the arrival of the first new photo, sent a moment before it is checked, so the start
    /// is set a little earlier (`legacyGrace`) or that photo would be the one left out.
    private static func since(cid: String) -> Date {
        let d = UserDefaults.standard
        let key = choice(for: cid) == .always ? chatSinceKey(cid) : sinceKey
        var t = d.double(forKey: key)
        if t <= 0 {
            t = Date().timeIntervalSince1970 - legacyGrace
            d.set(t, forKey: key)
        }
        return Date(timeIntervalSince1970: t)
    }

    /// OFF by default. Writing into someone's camera roll is not a thing to assume.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    // MARK: - Per chat (owner 2026-10-18, group info page)
    //
    // A chat can follow the Settings switch (Default), or override it either way. Stored beside the
    // global key ("chats.saveToPhotos.chat.<cid>"), absent = Default, so an untouched chat costs
    // nothing and SessionWipe clears every override by the prefix.
    enum ChatChoice: String, CaseIterable { case standard = "default", always, never }
    static let chatKeyPrefix = defaultsKey + ".chat."
    static func choice(for cid: String) -> ChatChoice {
        ChatChoice(rawValue: UserDefaults.standard.string(forKey: chatKeyPrefix + cid) ?? "") ?? .standard
    }
    static func setChoice(_ c: ChatChoice, for cid: String) {
        let was = choice(for: cid)
        if c == .standard { UserDefaults.standard.removeObject(forKey: chatKeyPrefix + cid) }
        else { UserDefaults.standard.set(c.rawValue, forKey: chatKeyPrefix + cid) }
        // Switching to Always starts saving now; picking Always again keeps its start; any other
        // choice has no start of its own (audit L24).
        if c == .always {
            if was != .always { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: chatSinceKey(cid)) }
        } else {
            UserDefaults.standard.removeObject(forKey: chatSinceKey(cid))
        }
    }
    /// What this chat does in the end: its own choice, else the Settings switch.
    static func savesMedia(cid: String) -> Bool {
        switch choice(for: cid) {
        case .always: return true
        case .never: return false
        case .standard: return isOn
        }
    }
    /// Sign-out: every chat's override goes with the account.
    static func removeChatChoices() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix(chatKeyPrefix) { d.removeObject(forKey: k) }
    }

    // MARK: - Already-saved ledger
    //
    // Re-opening a chat runs the same sweep again, so without this every old photo would land in
    // the roll a second time. The id is claimed BEFORE the work and given back if the save fails,
    // so a failure retries next time but two passes cannot both save the same message.
    private static let lock = NSLock()

    /// The ledger as stored. The old build kept a plain list of ids under the same key; that reads
    /// as empty here, which is safe because `since` keeps everything older than the upgrade out.
    private static func ledger() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: doneKey) as? [String: Double]) ?? [:]
    }

    private static func claim(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var ids = ledger()
        guard ids[id] == nil else { return false }
        let now = Date().timeIntervalSince1970
        ids = ids.filter { now - $0.value < ledgerKeep }
        ids[id] = now
        if ids.count > doneCap {
            for (old, _) in ids.sorted(by: { $0.value < $1.value }).prefix(ids.count - doneCap) { ids[old] = nil }
        }
        UserDefaults.standard.set(ids, forKey: doneKey)
        return true
    }

    private static func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var ids = ledger()
        ids[id] = nil
        UserDefaults.standard.set(ids, forKey: doneKey)
    }

    // MARK: - Entry point

    /// Offer one message to the camera roll. Returns at once; the fetch and the write run off-main.
    static func consider(_ m: Message, cid: String) {
        guard savesMedia(cid: cid), !m.viewOnce else { return }   // the chat's own choice first (2026-10-18)
        guard m.authorId != (AuthService.shared.uid ?? "") else { return }   // incoming only
        guard m.isImage || m.isVideo || m.isAlbum else { return }
        // Audit L24: new media only. Nothing sent before saving was switched on, nothing older than
        // the window, so turning it on (or opening an old chat) never pours history into the roll.
        guard m.createdAt >= max(since(cid: cid), Date().addingTimeInterval(-window)) else { return }
        guard claim(m.id) else { return }
        Task.detached(priority: .utility) {
            // DISABLE SHARING › NO SAVING (owner, 2026-10-03; the reference's "can't save media from
            // this chat to their device gallery automatically"). The id stays claimed, so switching
            // the restriction off later does not pour the chat's old media into the roll.
            // Audit L24: nor from a message request nobody has accepted. A stranger's pictures do
            // not go into the roll before the chat is accepted; claimed, so accepting later does not
            // pour them in either.
            let skip = await MainActor.run(body: { () -> Bool in
                if ChatRestrictions.isOn(.noSaving, cid: cid) { return true }
                guard let c = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) else { return false }
                return MessageRequests.isUnansweredRequest(c)
            })
            if skip { return }
            // PERMISSION FIRST, bytes second. The other order downloads and decrypts the whole
            // photo and only then discovers the library is off limits — and since a refusal
            // releases the id so it can retry if you grant access later, that would re-download
            // every picture in every chat you open, forever, on a phone that said no once.
            guard await authorized() else { release(m.id); return }
            let saved: Bool
            if m.isAlbum      { saved = await saveAlbum(m, cid: cid) }
            else if m.isVideo { saved = await saveVideo(m, cid: cid) }
            else              { saved = await saveImage(m, cid: cid) }
            if !saved { release(m.id) }
        }
    }

    // MARK: - A Save the person asked for (multi-action swipe, 2026-11-08)

    enum ManualResult { case saved, denied, failed }

    /// One photo, video or album into the library, through the same three savers the automatic
    /// pass uses. No incoming-only rule and no ledger: the person asked for this one. View-once and
    /// No Saving are the caller's checks (the same ones the long-press Save makes).
    static func saveNow(_ m: Message, cid: String) async -> ManualResult {
        guard m.isImage || m.isVideo || m.isAlbum else { return .failed }
        guard await authorized() else { return .denied }
        let saved: Bool
        if m.isAlbum      { saved = await saveAlbum(m, cid: cid, manual: true) }
        else if m.isVideo { saved = await saveVideo(m, cid: cid, manual: true) }
        else              { saved = await saveImage(m, cid: cid, manual: true) }
        return saved ? .saved : .failed
    }

    // MARK: - The three shapes media arrives in

    private static func saveImage(_ m: Message, cid: String, manual: Bool = false) async -> Bool {
        guard let photo = await image(m.imageUrl, enc: m.enc, cid: cid, manual: manual) else { return false }
        return await write { _ = PHAssetChangeRequest.creationRequestForAsset(from: photo) }
    }

    private static func saveVideo(_ m: Message, cid: String, manual: Bool = false) async -> Bool {
        guard let file = await videoFile(m.videoUrl, enc: m.enc, cid: cid, cacheAs: m.id, manual: manual) else { return false }
        return await write { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }
    }

    /// An album is ONE message holding several items, so it is one authorization pass and one
    /// change block — the roll gets the whole set together instead of a burst of separate writes.
    private static func saveAlbum(_ m: Message, cid: String, manual: Bool = false) async -> Bool {
        var images: [UIImage] = []
        var videos: [URL] = []
        for (i, item) in m.album.enumerated() {
            if item.isVideo {
                // Album items have no message id of their own; key the cache off the parent + index.
                if let f = await videoFile(item.videoUrl, enc: item.videoEnc, cid: cid,
                                           cacheAs: "\(m.id)-\(i)", manual: manual) { videos.append(f) }
            } else if let img = await image(item.imageUrl, enc: item.enc, cid: cid, manual: manual) {
                images.append(img)
            }
        }
        guard !images.isEmpty || !videos.isEmpty else { return false }
        return await write {
            for photo in images { _ = PHAssetChangeRequest.creationRequestForAsset(from: photo) }
            for file in videos { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }
        }
    }

    // MARK: - Getting the bytes

    /// Cache first, network second — the same order the viewer uses, so an already-seen photo
    /// costs nothing to save.
    private static func image(_ url: String?, enc: EncMeta?, cid: String, manual: Bool = false) async -> UIImage? {
        guard let s = url, !s.isEmpty else { return nil }
        if let cached = await DiskImageCache.shared.image(for: s) { return cached }
        // 2026-09-24 audit: THE NETWORK HALF OBEYS Storage and Data > Photos, like every other
        // automatic download. It did not, so Save to Photos pulled every incoming photo over mobile
        // data with Photos set to Wi-Fi Only or Never. A refusal returns nil, the caller releases the
        // id, and the next sweep on an allowed network (or after the photo is viewed) saves it.
        // A Save the person asked for (`saveNow`) is not an automatic download: no network rule.
        guard manual || AutoDownloadPrefs.allowedNow(.photos) else { return nil }
        // The shared job (2026-09-26): the bubble is usually fetching this same photo right now, and
        // saving it used to download it a second time beside that. Joined, stored once, read back.
        guard await MediaDownloads.shared.download(s, priority: .auto,
                                                   finish: MediaFetch.photoFinisher(url: s, enc: enc, cid: cid))
        else { return nil }
        return await DiskImageCache.shared.image(for: s)
    }

    /// Photos needs a FILE for a video, so the decrypted bytes go through VideoCache — which is
    /// where the player wants them anyway, so the download is not wasted if the save then fails.
    private static func videoFile(_ url: String?, enc: EncMeta?, cid: String, cacheAs id: String,
                                  manual: Bool = false) async -> URL? {
        if let have = VideoCache.url(for: id) { return have }
        guard manual || AutoDownloadPrefs.allowedNow(.videos) else { return nil }   // 2026-09-24 audit, as for photos
        guard let s = url, !s.isEmpty else { return nil }
        // Joined with the sweep's and the bubble's job for the same clip rather than fetched again.
        _ = await MediaDownloads.shared.download(
            s, priority: .auto,
            finish: MediaFetch.dataFinisher(enc: enc, cid: cid) { VideoCache.store($0, for: id) })
        return VideoCache.url(for: id)
    }

    // MARK: - The library

    private static func authorized() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private static func write(_ changes: @escaping () -> Void) async -> Bool {
        do { try await PHPhotoLibrary.shared().performChanges(changes); return true }
        catch { return false }
    }
}

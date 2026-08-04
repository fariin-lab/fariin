import Foundation
import UIKit
import Observation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

/// My profile + lookups for other users. The header avatar reads `me` (loaded
/// once at launch) — native TabView keeps it mounted, so no re-fetch/blink.
@Observable
final class ProfileStore {
    static let shared = ProfileStore()
    private init() {}

    private let db = Firestore.firestore()
    var me: UserProfile?

    func loadMine() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Offline: fetch() returns nil after the server-timeout — keep the cached
        // profile instead of wiping `me` (which would bounce the user to onboarding).
        me = await fetch(uid) ?? me
        Self.adoptServerPrivacy(me?.privacy)
    }

    /// BRING MY OWN PRIVACY SETTINGS BACK WITH ME (owner 2026-08-04: "after I close the app and sign
    /// in again, all of my settings are reset").
    ///
    /// The settings screen reads UserDefaults, `setMine` writes BOTH there and to `users/{uid}.privacy`,
    /// and signing out wipes the local copy on purpose — the next person on this phone must not
    /// inherit the last one's choices, and one of those choices silently auto-declines calls. What was
    /// never built is the other half: putting YOUR OWN settings back when YOU sign in. SessionWipe's
    /// own comment says it outright — "privacy is also published to the server, and nothing ever
    /// imports it back".
    ///
    /// ONLY FILLS WHAT IS MISSING. After a sign-out every key is absent, so everything is restored;
    /// if a key is present it was set on this device and stays, which is what keeps a change made
    /// offline from being overwritten by a stale read a second later.
    static func adoptServerPrivacy(_ privacy: [String: String]?) {
        guard let privacy, !privacy.isEmpty else { return }
        let d = UserDefaults.standard
        for (key, value) in privacy {
            // The on/off switches live under their own plain keys as Bools, not under "priv." as
            // audience strings — that is where the settings screen already reads them, and moving
            // them would be a migration for no gain. One map on the server, two shapes locally.
            if PrivacyPrefs.flagKeys.contains(key) {
                if d.object(forKey: key) == nil { d.set(value == "true", forKey: key) }
            } else if d.string(forKey: "priv.\(key)") == nil {
                d.set(value, forKey: "priv.\(key)")
            }
        }
    }

    /// Instant boot path: my profile straight from Firestore's on-disk cache, no
    /// network. Returns true if a completed profile (has a handle) was cached —
    /// the signal that this user finished onboarding and can go straight to .main.
    func loadCachedMine() async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else { return false }
        guard let snap = try? await db.collection("users").document(uid).getDocument(source: .cache),
              let data = snap.data() else { return false }
        let cached = UserProfile(id: uid, data: data)
        guard !cached.handle.isEmpty else { return false }
        me = cached
        // The boot fast path reaches the app before loadMine's network round trip, so the settings
        // screen would show defaults for that whole moment. The cached doc already carries them.
        Self.adoptServerPrivacy(cached.privacy)
        return true
    }

    /// Another user's profile straight from Firestore's on-disk cache — LOCAL only, no network.
    /// Lets a profile paint its @handle and bio on the first frame for anyone we've loaded before,
    /// instead of the bio arriving a moment later and shoving the whole page down (most visible
    /// opening from the Calls tab, where nothing is warm). Same trick as `loadCachedMine`.
    func cachedPeer(_ uid: String) async -> UserProfile? {
        guard !uid.isEmpty,
              let snap = try? await db.collection("users").document(uid).getDocument(source: .cache),
              let data = snap.data() else { return nil }
        return Self.indexed(UserProfile(id: uid, data: data))
    }

    func fetch(_ uid: String) async -> UserProfile? {
        guard !uid.isEmpty else { return nil }
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            guard let data = snap.data() else { return nil }
            return Self.indexed(UserProfile(id: uid, data: data))
        } catch {
            print("profile fetch failed:", error)
            return nil
        }
    }

    /// EVERY read of a users document passes through here, so the profile header's synchronous index
    /// fills itself from work the app already does — building a conversation, opening a profile,
    /// listing a group's members. One hook, rather than a remember-to-call-it at each site.
    /// See [ProfilePhotoIndex] for why the header cannot ask the network this question.
    private static func indexed(_ p: UserProfile) -> UserProfile {
        ProfilePhotoIndex.record(uid: p.id, photo: p.photoUrl, poster: p.posterUrl, privacy: p.privacy)
        // The same one hook feeds the call-privacy answer, so pressing the call button has something
        // to read on the frame it is pressed. See CallPrivacyIndex.
        CallPrivacyIndex.record(uid: p.id, privacy: p.privacy)
        return p
    }

    func updateProfile(name: String, handle: String, about: String = "") async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let h = handle.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        try await db.collection("users").document(uid).setData([
            "name": n,
            "handle": h,
            "handleLower": h.lowercased(),
            "about": about.trimmingCharacters(in: .whitespacesAndNewlines),
        ], merge: true)

        // Fan the new name out to every conversation's names map (mirrors uploadPhoto's
        // photo fan-out) — chat lists read `names`, so contacts kept seeing the old name.
        let snap = try await db.collection("conversations")
            .whereField("users", arrayContains: uid).getDocuments()
        if !snap.documents.isEmpty {
            let batch = db.batch()
            for d in snap.documents { batch.updateData(["names.\(uid)": n], forDocument: d.reference) }
            try await batch.commit()
        }

        me = await fetch(uid)
    }

    /// How long a deleted account can still be brought back.
    static let gracePeriodDays = 30

    /// SOFT DELETE (the normal path). Marks the account for deletion in `gracePeriodDays` and signs
    /// out, destroying nothing: the profile, username, chats and encryption key all survive so signing
    /// back in can restore everything. A scheduled server job performs the real purge once the date
    /// passes, and `deleteAccount()` below is that purge (also reachable from "Delete It Now").
    ///
    /// Apple's in-app-deletion rule (5.1.1(v)) is satisfied by deletion being STARTED in the app; a
    /// grace period is allowed, which is how the reference app and the reference app do it.
    func scheduleDeletion() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.notSignedIn }
        let due = Calendar.current.date(byAdding: .day, value: Self.gracePeriodDays, to: Date()) ?? Date()
        try await db.collection("users").document(user.uid).setData([
            "deletionScheduledFor": Timestamp(date: due),
            // Denormalised so security rules and queries can hide the account without reading a date.
            "isHidden": true,
        ], merge: true)
        me?.deletionScheduledFor = due
    }

    /// Server-truth check used on the boot fast path. Returns the date when this account is scheduled
    /// for deletion, or nil. Read from the server rather than the cache on purpose: the deletion may
    /// have been scheduled on another device, and a stale cache would let the user straight in.
    func scheduledDeletionDate() async -> Date? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        guard let snap = try? await db.collection("users").document(uid).getDocument(),
              let ts = snap.data()?["deletionScheduledFor"] as? Timestamp else { return nil }
        let due = ts.dateValue()
        return due > Date() ? due : nil
    }

    /// Undo a scheduled deletion. Everything is still where it was, so this is just clearing the flags.
    func restoreAccount() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.notSignedIn }
        try await db.collection("users").document(user.uid).setData([
            "deletionScheduledFor": FieldValue.delete(),
            "isHidden": FieldValue.delete(),
        ], merge: true)
        me?.deletionScheduledFor = nil
        me = await fetch(user.uid)
    }

    /// PERMANENTLY delete the account: removes the profile doc and the Firebase auth user.
    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else { return }
        let uid = user.uid

        // ORDER MATTERS: Firebase refuses `user.delete()` unless the sign-in is recent, and this
        // used to be discovered only AFTER the stories/photo/profile doc were destroyed — leaving
        // the account half-deleted and unrecoverable (data gone, account alive, user stranded in
        // onboarding). DeleteAccountView now re-authenticates FIRST, so by the time we get here
        // the delete is expected to succeed. The guard stays as a backstop: bail while everything
        // is still intact rather than destroy data we can't finish deleting.
        guard !AuthService.shared.needsRecentLogin else {
            throw NSError(domain: "Fariin", code: 17014, userInfo: [NSLocalizedDescriptionKey:
                "Please verify it's you and try again — nothing has been deleted yet."])
        }

        // Remove the content I posted BEFORE the account goes away, so nothing of mine
        // stays visible to others (App Store 5.1.1(v) — deletion must remove my data).
        await StoriesService.shared.deleteAllMine()
        try? await Storage.storage().reference().child("profiles/\(uid).jpg").delete()
        // Clear my private sub-records (story seen-state + distribution lists) — Firestore
        // does not cascade subcollection deletes, so wipe them before the parent doc.
        // `devices` included (audit): it holds this account's push and VoIP tokens plus hardware
        // ids, and Firestore does not cascade, so a "permanently deleted" account was leaving those
        // records behind under a deleted parent doc.
        for sub in ["storyContexts", "storyLists", "devices"] {
            if let docs = try? await db.collection("users").document(uid).collection(sub).getDocuments() {
                for d in docs.documents { try? await d.reference.delete() }
            }
        }
        try? await db.collection("users").document(uid).delete()
        try await user.delete()
        // The account is gone for good, so its private key has nothing left to decrypt —
        // remove it rather than leaving it on the device. (Sign-out deliberately KEEPS the key;
        // only real deletion destroys it.)
        Crypto.shared.destroyIdentity(uid: uid)
        me = nil
    }

    /// Upload a profile photo. Native Data -> Firebase Storage (no Hermes blob
    /// crash). Propagates the URL to the user doc + each conversation's photo map.
    /// Downscale only. THE SHAPE THE USER FRAMED IS THE SHAPE THAT GETS UPLOADED.
    ///
    /// This used to centre-crop to a square, which was correct while the cropper only ever produced
    /// squares. It is not any more: the poster header is taller than it is wide, the cropper now
    /// frames that exact shape and shows which band will be blurred, and squaring it here would
    /// silently throw away the part he was just asked to choose. Cropping a second time, behind the
    /// user, after they have already cropped, is the bug — not the aspect ratio.
    ///
    /// The round avatar is unaffected: it centre-crops what it is given at DRAW time, so it takes the
    /// middle of a tall photo exactly as it took the middle of a square one.
    ///
    /// `maxSide` is generous now (was a 512 square): the same file is the small circle in a chat list
    /// AND a full-width header, and 512 across a whole screen is visibly soft.
    static func squareJPEG(_ data: Data, maxSide: CGFloat = 1280, quality: CGFloat = 0.85) -> Data {
        guard let img = UIImage(data: data), let cg = img.cgImage else { return data }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return data }
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1 else { return data }   // already small enough — do not re-encode for nothing
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let src = UIImage(cgImage: cg, scale: 1, orientation: img.imageOrientation)
        let out = UIGraphicsImageRenderer(size: size).image { _ in
            src.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: quality) ?? data
    }

    /// The TALL header framing, stored beside the avatar rather than instead of it.
    ///
    /// Two images, because they are two different crops of one picture and the user now chooses each
    /// separately: the circle for every list in the app, this for the profile header. One file cannot
    /// serve both without centre-cropping one of them badly.
    ///
    /// Written to `users/{uid}.posterUrl` AND to each conversation's `posters` map, mirroring exactly
    /// how the avatar is propagated. The conversation copy is what lets a profile decide on its FIRST
    /// frame whether it has a poster to draw — reading it from the user document would arrive after
    /// the page is on screen, which is the flicker that was already fixed once.
    // One blob → its download URL. The two profile crops ride this concurrently from
    // uploadProfileImages, which is most of why Save stopped taking so long.
    private func putJPEG(_ data: Data, path: String) async throws -> String {
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(data, metadata: meta)
        return try await ref.downloadURL().absoluteString
    }

    /// The photo half of Edit Profile's Save, as ONE pass. This replaced uploadPhoto +
    /// uploadPoster called in sequence, which was the owner's "save takes too long": two storage
    /// uploads one after the other, THREE separate conversation sweeps (photo batch, poster
    /// per-doc loop awaited one at a time, then the name's), and a profile re-fetch after each.
    /// Now the two blobs upload IN PARALLEL (wall time = the slower one, not the sum), the user
    /// doc takes both urls in one write, ONE conversation query feeds one combined fan-out, and
    /// the profile is re-fetched once.
    ///
    /// Fan-out shape: 1:1 conversations go in ONE fatal batch — the circle in every chat list is
    /// the point of the save, and 1:1 rules accept any field so the batch cannot be refused for a
    /// rules reason. GROUP docs are written per-doc, best-effort, concurrently: the rules now let
    /// a plain member touch their own names/photos/posters entry (own-uid map diff, deployed
    /// 2026-08-03), but a refusal there must degrade to "that group falls back on the user doc",
    /// never fail the save — and one refused group in a shared batch would have killed the 1:1
    /// writes with it.
    func uploadProfileImages(circle rawCircle: Data, poster rawPoster: Data?) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let circleData = Self.squareJPEG(rawCircle)
        let posterData = rawPoster.map { Self.squareJPEG($0) }

        let circleURL: String
        var posterURL: String?
        if let posterData {
            async let c = putJPEG(circleData, path: "profiles/\(uid).jpg")
            async let p = putJPEG(posterData, path: "profiles/\(uid)-poster.jpg")
            (circleURL, posterURL) = try await (c, p)
        } else {
            circleURL = try await putJPEG(circleData, path: "profiles/\(uid).jpg")
        }

        // Seed the cache BEFORE publishing the URLs: every AvatarView cache-hits the new
        // photo the instant photoUrl lands — no re-download, no placeholder blink. Also
        // covers the change-photo case where the URL stays identical (same storage path)
        // and a stale cached image would otherwise keep showing.
        if let ui = UIImage(data: circleData) { DiskImageCache.shared.store(ui, data: circleData, for: circleURL) }
        if let posterURL, let posterData, let ui = UIImage(data: posterData) {
            DiskImageCache.shared.store(ui, data: posterData, for: posterURL)
        }

        var userFields: [String: Any] = ["photoUrl": circleURL]
        if let posterURL { userFields["posterUrl"] = posterURL }
        try await db.collection("users").document(uid).setData(userFields, merge: true)

        var convFields: [String: Any] = ["photos.\(uid)": circleURL]
        if let posterURL { convFields["posters.\(uid)"] = posterURL }
        let snap = try await db.collection("conversations")
            .whereField("users", arrayContains: uid).getDocuments()
        let groups = snap.documents.filter { ($0.data()["type"] as? String) == "group" }
        let oneToOnes = snap.documents.filter { ($0.data()["type"] as? String) != "group" }
        if !oneToOnes.isEmpty {
            let batch = db.batch()
            for d in oneToOnes { batch.updateData(convFields, forDocument: d.reference) }
            try await batch.commit()
        }
        for d in groups { try? await d.reference.updateData(convFields) }

        me = await fetch(uid)
    }

    /// Notification preferences the PUSH SERVER reads per recipient (onNewMessage):
    /// preview = show sender name in the push; sound = bundled tone name ("default" = system).
    func setNotifPrefs(preview: Bool? = nil, sound: String? = nil) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        var data: [String: Any] = [:]
        if let preview { data["notifPreview"] = preview }
        if let sound { data["notifSound"] = sound }
        guard !data.isEmpty else { return }
        try await db.collection("users").document(uid).setData(data, merge: true)
    }

    /// Remove the profile photo entirely (back to the initials avatar) — the mirror of
    /// uploadPhoto: clear users.photoUrl, clear my photos.{uid} in every conversation,
    /// and delete the storage object so the old image is really gone, not just unlinked.
    func removePhoto() async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // BOTH CROPS, EVERYWHERE. This used to clear only `photoUrl` and `photos.{uid}`, and the
        // poster is a SECOND stored image with its own field, its own conversation mirror and its
        // own file — so removing your picture left a full `posterUrl` behind, and everyone else's
        // copy of your profile still described you as somebody with a photo. That is what opened the
        // tall header on people who had no picture at all, and the header then corrected itself a
        // beat later when the load came back empty (owner: "after a few seconds they switch back").
        // A half-cleared record is the bug; clearing all of it is the fix.
        try await db.collection("users").document(uid)
            .setData(["photoUrl": "", "posterUrl": ""], merge: true)

        let snap = try await db.collection("conversations")
            .whereField("users", arrayContains: uid).getDocuments()
        let fields: [String: Any] = ["photos.\(uid)": "", "posters.\(uid)": ""]
        // 1:1s in one batch (any-field rules, cannot be refused); GROUPS per document and
        // best-effort, because their rules whitelist fields and one refusal must not roll back the
        // 1:1 clears — the same split `uploadProfileImages` makes for the same reason.
        let groups = snap.documents.filter { ($0.data()["type"] as? String) == "group" }
        let oneToOnes = snap.documents.filter { ($0.data()["type"] as? String) != "group" }
        if !oneToOnes.isEmpty {
            let batch = db.batch()
            for d in oneToOnes { batch.updateData(fields, forDocument: d.reference) }
            try await batch.commit()
        }
        for d in groups { try? await d.reference.updateData(fields) }

        // Best-effort: a failed storage delete must not leave the profile half-updated.
        try? await Storage.storage().reference().child("profiles/\(uid).jpg").delete()
        try? await Storage.storage().reference().child("profiles/\(uid)-poster.jpg").delete()

        me = await fetch(uid)
    }
}

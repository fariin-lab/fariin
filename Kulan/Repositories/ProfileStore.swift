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
        return UserProfile(id: uid, data: data)
    }

    func fetch(_ uid: String) async -> UserProfile? {
        guard !uid.isEmpty else { return nil }
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            guard let data = snap.data() else { return nil }
            return UserProfile(id: uid, data: data)
        } catch {
            print("profile fetch failed:", error)
            return nil
        }
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
    /// grace period is allowed, which is how Instagram and WhatsApp do it.
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
            throw NSError(domain: "Kulan", code: 17014, userInfo: [NSLocalizedDescriptionKey:
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

    func uploadPhoto(_ rawData: Data) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let data = Self.squareJPEG(rawData)
        let ref = Storage.storage().reference().child("profiles/\(uid).jpg")
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(data, metadata: meta)
        let url = try await ref.downloadURL().absoluteString

        // Seed the cache BEFORE publishing the URL: every AvatarView cache-hits the new
        // photo the instant photoUrl lands — no re-download, no placeholder blink. Also
        // covers the change-photo case where the URL stays identical (same storage path)
        // and a stale cached image would otherwise keep showing.
        if let ui = UIImage(data: data) { DiskImageCache.shared.store(ui, data: data, for: url) }

        try await db.collection("users").document(uid).setData(["photoUrl": url], merge: true)

        let snap = try await db.collection("conversations")
            .whereField("users", arrayContains: uid).getDocuments()
        let batch = db.batch()
        for d in snap.documents { batch.updateData(["photos.\(uid)": url], forDocument: d.reference) }
        try await batch.commit()

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
        try await db.collection("users").document(uid).setData(["photoUrl": ""], merge: true)

        let snap = try await db.collection("conversations")
            .whereField("users", arrayContains: uid).getDocuments()
        let batch = db.batch()
        for d in snap.documents { batch.updateData(["photos.\(uid)": ""], forDocument: d.reference) }
        try await batch.commit()

        // Best-effort: a failed storage delete must not leave the profile half-updated.
        try? await Storage.storage().reference().child("profiles/\(uid).jpg").delete()

        me = await fetch(uid)
    }
}

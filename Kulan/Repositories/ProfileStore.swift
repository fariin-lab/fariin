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

    /// Permanently delete the account (Apple requires in-app deletion): removes
    /// the profile doc and the Firebase auth user.
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
        for sub in ["storyContexts", "storyLists"] {
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
    // Centre-crop to a square + downscale so avatars are small and uniform.
    static func squareJPEG(_ data: Data, side: CGFloat = 512, quality: CGFloat = 0.8) -> Data {
        guard let img = UIImage(data: data), let cg = img.cgImage else { return data }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), s = min(w, h)
        let rect = CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)
        guard let cropped = cg.cropping(to: rect) else { return data }
        let square = UIImage(cgImage: cropped, scale: 1, orientation: img.imageOrientation)
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            square.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
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

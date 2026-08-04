import Foundation
import Observation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// THE SENDING HALF of the official channel. Signal has no equivalent of this file: their release
// notes are a JSON file somebody edits by hand and uploads to a CDN, and there is no admin screen,
// no roles and no permissions anywhere in the app. This is the part we are adding, and everything it
// writes is shaped so the reading half stays exactly Signal's: one document, read by every phone,
// with the targeting decided on the phone.
//
// There are no Cloud Functions here on purpose. Permission is enforced by Firestore rules reading the
// `admins` collection, which is a server-side check with nothing to deploy — and this project's
// functions live in three separate folders where a careless deploy deletes the ones the other folders
// own. Fewer moving parts is worth more here than the elegance of a callable.

// MARK: - Who is allowed to do what

enum AdminPermission: String, CaseIterable, Identifiable {
    case send            // write and publish an announcement
    case schedule        // set a future publish time
    case edit            // change an announcement after it is out
    case remove          // take an announcement back
    case targetCountry   // send to particular countries rather than everyone
    case targetChosen    // send to hand-picked people
    case security        // send a Security announcement

    var id: String { rawValue }
    var label: String {
        switch self {
        case .send:          return "Send announcements"
        case .schedule:      return "Schedule for later"
        case .edit:          return "Edit after sending"
        case .remove:        return "Delete announcements"
        case .targetCountry: return "Choose countries"
        case .targetChosen:  return "Send to chosen people"
        case .security:      return "Send security alerts"
        }
    }
    var detail: String {
        switch self {
        case .send:          return "Write and send to everyone."
        case .schedule:      return "Set a date and time instead of sending now."
        case .edit:          return "Change the words of an announcement already sent."
        case .remove:        return "Remove an announcement from everybody's chat."
        case .targetCountry: return "Send to one or more countries instead of the whole world."
        case .targetChosen:  return "Pick individual people by username."
        case .security:      return "Send the alerts that break through the mute."
        }
    }
    /// What a brand-new admin gets. Deliberately not everything: an admin who can send is useful on
    /// day one, and the rest are handed over as trust is earned.
    static let starter: [AdminPermission] = [.send, .schedule]
}

struct AdminRecord: Identifiable, Equatable {
    let id: String            // uid
    var role: String          // "owner" | "admin"
    var perms: [String]
    var name: String
    var handle: String
    var addedBy: String
    var addedAt: Date?

    var isOwner: Bool { role == "owner" }
    /// The owner is never limited. Everybody else holds exactly the permissions they were given —
    /// an empty list is a real state (an admin who has been stood down without being removed), NOT a
    /// legacy "has everything", which is the mistake the group admin model made and had to carry.
    func can(_ p: AdminPermission) -> Bool { isOwner || perms.contains(p.rawValue) }

    init(id: String, data: [String: Any]) {
        self.id = id
        self.role = data["role"] as? String ?? "admin"
        self.perms = data["perms"] as? [String] ?? []
        self.name = data["name"] as? String ?? ""
        self.handle = data["handle"] as? String ?? ""
        self.addedBy = data["addedBy"] as? String ?? ""
        self.addedAt = (data["addedAt"] as? Timestamp)?.dateValue()
    }
}

/// Am I an admin, and what may I do? One document, watched live, so a permission taken away lands on
/// the phone at once rather than at the next launch.
@Observable
final class AdminStore {
    static let shared = AdminStore()
    private init() {}

    private var listener: ListenerRegistration?
    private(set) var me: AdminRecord?

    var isAdmin: Bool { me != nil }
    var isOwner: Bool { me?.isOwner ?? false }
    func can(_ p: AdminPermission) -> Bool { me?.can(p) ?? false }

    func start() {
        guard let uid = AuthService.shared.uid else { return }
        stop()
        listener = Firestore.firestore().collection("admins").document(uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                // The rules let anybody read their OWN admin document and nobody else's, so a normal
                // user gets a clean "does not exist" here rather than a permission error.
                self.me = (snap?.exists == true) ? AdminRecord(id: uid, data: snap?.data() ?? [:]) : nil
            }
    }

    func stop() { listener?.remove(); listener = nil }
    func reset() { stop(); me = nil }
}

// MARK: - Sending

enum AnnouncementAdmin {
    private static var db: Firestore { Firestore.firestore() }

    /// A draft on its way to becoming an announcement. Held as one value so the compose screen, the
    /// preview and the write all read the same thing.
    struct Draft {
        var id: String = UUID().uuidString.lowercased()
        var kind: AnnouncementKind = .news
        var title: String = ""
        var body: String = ""
        var buttons: [AnnouncementButton] = []
        var audience = AnnouncementAudience()
        var publishAt: Date = Date()
        var expiresAt: Date?
        var minBuildOverride: Int?
        /// Picked in the compose screen, uploaded at send time.
        var image: UIImage?
        /// Already-uploaded media, when editing an announcement that has a picture.
        var mediaUrl: String?
        var mediaWidth: Double?
        var mediaHeight: Double?
        /// Only for `.chosen`.
        var chosen: [UserProfile] = []

        var isScheduled: Bool { publishAt.timeIntervalSinceNow > 60 }

        /// What stops the Send button being tappable. Returns nil when the draft is sendable.
        var problem: String? {
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give it a title." }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write the message." }
            if audience.scope == .countries && audience.countries.isEmpty { return "Pick at least one country." }
            if audience.scope == .chosen && chosen.isEmpty { return "Pick at least one person." }
            if let bad = buttons.first(where: { !$0.isUsable }) {
                return bad.label.isEmpty ? "A button needs a label." : "Check the \"\(bad.label)\" button."
            }
            if buttons.contains(where: { $0.label.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "A button needs a label."
            }
            return nil
        }

        /// The document every phone will read. Note what is NOT here: the chosen list. Writing user
        /// ids onto a document the whole world reads would publish exactly the thing a private send
        /// is meant to keep private.
        func map(createdBy: String, editing: Bool) -> [String: Any] {
            var audienceMap = audience.asMap
            audienceMap["chosenCount"] = chosen.count
            if let minBuildOverride { audienceMap["minBuild"] = minBuildOverride }

            var m: [String: Any] = [
                "kind": kind.rawValue,
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "body": body.trimmingCharacters(in: .whitespacesAndNewlines),
                "buttons": buttons.filter(\.isUsable).map(\.asMap),
                "audience": audienceMap,
                "publishAt": Timestamp(date: publishAt),
                "deleted": false,
            ]
            if let mediaUrl { m["mediaUrl"] = mediaUrl }
            if let mediaWidth { m["mediaWidth"] = mediaWidth }
            if let mediaHeight { m["mediaHeight"] = mediaHeight }
            if let expiresAt { m["expiresAt"] = Timestamp(date: expiresAt) }
            if editing {
                m["editedAt"] = FieldValue.serverTimestamp()
            } else {
                m["createdBy"] = createdBy
                m["createdAt"] = FieldValue.serverTimestamp()
            }
            return m
        }
    }

    enum AdminError: LocalizedError {
        case notAllowed(String)
        var errorDescription: String? {
            switch self { case .notAllowed(let what): return what }
        }
    }

    // MARK: Publish

    /// Where an announcement's record lives depends on who it is for, and the split is a PRIVACY
    /// boundary, not a filing preference.
    ///
    /// `announcements` is read by every phone on earth, which is the whole trick that makes a
    /// broadcast cost one write. A send to CHOSEN PEOPLE must never be written there: the words would
    /// be readable by anybody who queries the collection, which is the exact opposite of what picking
    /// three people by name means. (Marking it `scope: chosen` and filtering on the phone hides it
    /// from the app and from nobody else.)
    ///
    /// So a chosen send writes a private copy per recipient plus ONE admin-only record in
    /// `announcementLog`, which is also the only place the recipient list is ever stored — and it has
    /// to be stored, or a withdrawal has no way to reach the copies it needs to strike.
    private static func collection(for scope: AnnouncementAudience.Scope) -> String {
        scope == .chosen ? "announcementLog" : "announcements"
    }

    /// Writes the announcement, and for a chosen send, one copy per recipient.
    ///
    /// The copies are written in batches because Firestore caps a batch at 500 writes. The record
    /// goes first, so a later batch failing leaves an announcement that partly went out visible in
    /// the history rather than lost.
    static func publish(_ draft: Draft, editing: Bool = false) async throws {
        guard let uid = AuthService.shared.uid else { throw AdminError.notAllowed("Sign in first.") }
        let store = AdminStore.shared
        guard store.can(.send) else { throw AdminError.notAllowed("You cannot send announcements.") }
        if draft.isScheduled && !store.can(.schedule) {
            throw AdminError.notAllowed("You cannot schedule announcements.")
        }
        if editing && !store.can(.edit) { throw AdminError.notAllowed("You cannot edit announcements.") }
        if draft.kind == .security && !store.can(.security) {
            throw AdminError.notAllowed("You cannot send security alerts.")
        }
        if draft.audience.scope == .countries && !store.can(.targetCountry) {
            throw AdminError.notAllowed("You cannot choose countries.")
        }
        if draft.audience.scope == .chosen && !store.can(.targetChosen) {
            throw AdminError.notAllowed("You cannot send to chosen people.")
        }

        var draft = draft
        if let image = draft.image {
            let (url, w, h) = try await uploadMedia(image, announcementId: draft.id)
            draft.mediaUrl = url
            draft.mediaWidth = w
            draft.mediaHeight = h
        }

        let payload = draft.map(createdBy: uid, editing: editing)
        let home = collection(for: draft.audience.scope)

        guard draft.audience.scope == .chosen else {
            try await db.collection(home).document(draft.id).setData(payload, merge: editing)
            return
        }

        // The admin-only record, carrying the recipient list so this can be taken back later.
        var record = payload
        record["recipients"] = draft.chosen.map(\.id)
        try await db.collection(home).document(draft.id).setData(record, merge: editing)

        // The personal copies. `createdAt` cannot be a server timestamp on these: the phone sorts the
        // chat by it, and a pending server timestamp reads as nil, which would put a brand-new
        // announcement at the very bottom of the channel until the write came back. The recipient
        // list is stripped — nobody needs to know who else was sent this.
        var copy = payload
        copy["createdAt"] = Timestamp(date: Date())
        copy["publishAt"] = Timestamp(date: draft.publishAt)
        copy["createdBy"] = uid

        for chunk in draft.chosen.chunked(into: 400) {
            let batch = db.batch()
            for person in chunk {
                let ref = db.collection("users").document(person.id)
                    .collection("announcements").document(draft.id)
                batch.setData(copy, forDocument: ref, merge: editing)
            }
            try await batch.commit()
        }
    }

    /// Takes an announcement back. A tombstone rather than a hard delete, because a phone that is
    /// offline right now has the old copy and will only ever learn the announcement is gone from a
    /// document that still exists to tell it so.
    static func remove(_ a: Announcement) async throws {
        guard AdminStore.shared.can(.remove) else {
            throw AdminError.notAllowed("You cannot delete announcements.")
        }
        try await db.collection(collection(for: a.audience.scope)).document(a.id)
            .setData(["deleted": true, "deletedAt": FieldValue.serverTimestamp()], merge: true)

        // A chosen send has no shared document for a phone to read, so the tombstone above reaches
        // nobody on its own. The recipient list on the admin-only record is what makes withdrawing
        // one of these possible at all — see the note on `collection(for:)`.
        for chunk in a.recipients.chunked(into: 400) {
            let batch = db.batch()
            for uid in chunk {
                let ref = db.collection("users").document(uid).collection("announcements").document(a.id)
                batch.setData(["deleted": true], forDocument: ref, merge: true)
            }
            try await batch.commit()
        }
    }

    // MARK: Media

    /// Announcement pictures are PLAIN, not sealed. A broadcast to everybody cannot be a secret, and
    /// encrypting something every phone holds the key to is a costume, not security. Same call the
    /// app already makes for GIFs and story photos.
    private static func uploadMedia(_ image: UIImage, announcementId: String) async throws -> (String, Double, Double) {
        let bounded = image.boundedForDisplay(maxPixels: 1600)
        guard let jpeg = bounded.jpegData(compressionQuality: 0.85) else {
            throw AdminError.notAllowed("That picture could not be prepared.")
        }
        let ref = Storage.storage().reference().child("announcements/\(announcementId)/image.jpg")
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(jpeg, metadata: meta)
        let url = try await ref.downloadURL().absoluteString
        return (url, Double(bounded.size.width), Double(bounded.size.height))
    }

    // MARK: Reading, for the admin screens

    /// Everything, including scheduled, expired and deleted ones — the opposite of what a phone sees.
    /// Both homes, merged: broadcasts from `announcements` and chosen sends from `announcementLog`.
    static func history(limit: Int = 60) async -> [Announcement] {
        async let broadcasts = db.collection("announcements")
            .order(by: "publishAt", descending: true).limit(to: limit).getDocuments()
        async let chosen = db.collection("announcementLog")
            .order(by: "publishAt", descending: true).limit(to: limit).getDocuments()

        let a = (try? await broadcasts)?.documents ?? []
        let b = (try? await chosen)?.documents ?? []
        return (a + b)
            .map { Announcement(id: $0.documentID, data: $0.data()) }
            .sorted { $0.sortAt > $1.sortAt }
            .prefix(limit)
            .map { $0 }
    }

    static func admins() async -> [AdminRecord] {
        let snap = try? await db.collection("admins").getDocuments()
        return (snap?.documents ?? [])
            .map { AdminRecord(id: $0.documentID, data: $0.data()) }
            .sorted { a, b in
                if a.isOwner != b.isOwner { return a.isOwner }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// The admin picker's own search. `ChatService.searchUsers` hides YOU from its results, which is
    /// right when starting a chat and wrong here: sending a test announcement to yourself before it
    /// goes to everybody is the most useful thing this screen can do.
    static func searchPeople(_ prefix: String) async -> [UserProfile] {
        var q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("@") { q.removeFirst() }
        guard q.count >= 2 else { return [] }
        let snap = try? await db.collection("users")
            .order(by: "handleLower")
            .start(at: [q]).end(at: [q + "\u{f8ff}"])
            .limit(to: 20).getDocuments()
        return (snap?.documents ?? []).compactMap { d in
            let u = UserProfile(id: d.documentID, data: d.data())
            return u.isAwaitingDeletion ? nil : u
        }
    }

    // MARK: The admin team (owner only)

    static func addAdmin(_ person: UserProfile, perms: [AdminPermission]) async throws {
        guard let uid = AuthService.shared.uid, AdminStore.shared.isOwner else {
            throw AdminError.notAllowed("Only the owner can add admins.")
        }
        try await db.collection("admins").document(person.id).setData([
            "role": "admin",
            "perms": perms.map(\.rawValue),
            "name": person.name,
            "handle": person.handle,
            "addedBy": uid,
            "addedAt": FieldValue.serverTimestamp(),
        ])
    }

    static func setPermissions(_ record: AdminRecord, perms: [AdminPermission]) async throws {
        guard AdminStore.shared.isOwner else {
            throw AdminError.notAllowed("Only the owner can change permissions.")
        }
        guard !record.isOwner else { throw AdminError.notAllowed("The owner always has every permission.") }
        try await db.collection("admins").document(record.id)
            .setData(["perms": perms.map(\.rawValue)], merge: true)
    }

    static func removeAdmin(_ record: AdminRecord) async throws {
        guard AdminStore.shared.isOwner else {
            throw AdminError.notAllowed("Only the owner can remove admins.")
        }
        // The owner cannot be removed, by anybody, including the owner. A channel with nobody who can
        // appoint anybody is a channel that needs the Firebase console to come back.
        guard !record.isOwner else { throw AdminError.notAllowed("The owner cannot be removed.") }
        try await db.collection("admins").document(record.id).delete()
    }
}

extension Array {
    /// Firestore takes at most 500 writes in one batch.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

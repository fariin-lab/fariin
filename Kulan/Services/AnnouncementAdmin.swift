import Foundation
import Observation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// THE SENDING HALF of the official channel. The reference app has no equivalent of this file: their
// release notes are a JSON file somebody edits by hand and uploads to a CDN, and there is no admin
// screen, no roles and no permissions anywhere in the app. This is the part we are adding, and
// everything it writes is shaped so the reading half stays exactly the reference app's: one
// document, read by every phone, with the targeting decided on the phone.
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
    /// Review abuse reports, remove a public story, ban an account. Used by the web console at
    /// fariin.com/console, not by any screen in the app — moderation is desk work, and shipping the
    /// screens for it inside the app would put them in every user's copy. The permission lives here
    /// because this is where the owner hands permissions out.
    case moderate
    /// Grant, change, suspend and withdraw verification. Held apart from `moderate` on purpose:
    /// moderation is about accounts behaving badly, verification is about vouching for who somebody
    /// is, and the person trusted to remove a story is not automatically the person trusted to put
    /// the app's name behind a stranger's identity. It is also the capability the rules check before
    /// letting anything write a `verification` map, so it is the whole of the write access.
    case verify

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
        case .moderate:      return "Review reports"
        case .verify:        return "Verify accounts"
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
        case .moderate:      return "Handle abuse reports at fariin.com/console: remove a story, ban an account."
        case .verify:        return "Give, change or withdraw a verified badge."
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

        /// Whether sending this will actually knock on anybody's phone, and in plain words why not
        /// when it will not.
        ///
        /// ⚠️ THIS MUST AGREE WITH `skipReason()` IN `functions-announcements/functions/index.js`.
        /// Two copies of one rule, in two languages, because the compose screen has to say what the
        /// server is going to do before Send is tapped rather than leave the sender wondering
        /// afterwards. If you change one, change the other.
        ///
        /// The rule itself follows from the channel's architecture and is not a limitation to be
        /// engineered away later. The PHONE decides who an announcement is for: a partial rollout is
        /// SHA256(id + uid) and a minimum build is the build number, and neither of those exists on
        /// the server, deliberately, because that is what stops it knowing who saw what. A push has
        /// to be addressed before it leaves. So for those two the server sends nothing, because
        /// waking somebody for a chat that then shows them nothing is worse than staying quiet.
        var pushNote: String {
            if audience.ppm < 1_000_000 {
                return "No notification. A partial rollout is decided on each phone, so there is no way to notify only the people who will see it."
            }
            let minBuild = minBuildOverride ?? audience.minBuild
            if minBuild > 0 {
                return "No notification. A minimum build is checked on each phone, so there is no way to notify only the people who will see it."
            }
            if kind == .security {
                return "Notifies everyone it reaches, including people who muted or blocked this chat. Security alerts are the one thing that breaks through."
            }
            return "Notifies the people it reaches who have turned this chat's bell on. It is off for everybody by default."
        }

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
        func map(createdBy: String, editing: Bool, publishNow: Bool) -> [String: Any] {
            var audienceMap = audience.asMap
            audienceMap["chosenCount"] = chosen.count
            if let minBuildOverride { audienceMap["minBuild"] = minBuildOverride }

            var m: [String: Any] = [
                "kind": kind.rawValue,
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "body": body.trimmingCharacters(in: .whitespacesAndNewlines),
                "buttons": buttons.filter(\.isUsable).map(\.asMap),
                "audience": audienceMap,
                // 2026-09-24 decision D-admin-clock: a send-now takes the SERVER's time, not this
                // phone's. A fast phone clock used to hide the announcement from every reader and
                // push it to the 5-minute sweeper until real time caught up. A scheduled time is the
                // admin's pick and stays as picked.
                "publishAt": publishNow ? FieldValue.serverTimestamp() : Timestamp(date: publishAt),
            ]
            // 2026-09-24 decision D-admin-resurrect: `deleted` is written on a NEW announcement only.
            // An edit is a merge, and `deleted: false` in it silently undid a withdrawal made while
            // the editor was open (on the shared record and on every recipient's copy). Withdrawing
            // goes through `remove()` alone.
            if !editing { m["deleted"] = false }
            if let mediaUrl { m["mediaUrl"] = mediaUrl }
            if let mediaWidth { m["mediaWidth"] = mediaWidth }
            if let mediaHeight { m["mediaHeight"] = mediaHeight }
            if let expiresAt { m["expiresAt"] = Timestamp(date: expiresAt) }
            if editing {
                m["editedAt"] = FieldValue.serverTimestamp()
                // 2026-09-24 decision D-admin-resurrect: an edit is a merge, so a field left out is a
                // field KEPT. Removing the picture or the end date on an edit has to say so.
                if mediaUrl == nil { m["mediaUrl"] = FieldValue.delete() }
                if mediaWidth == nil { m["mediaWidth"] = FieldValue.delete() }
                if mediaHeight == nil { m["mediaHeight"] = FieldValue.delete() }
                if expiresAt == nil { m["expiresAt"] = FieldValue.delete() }
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
        try checkPermissions(draft, editing: editing)

        var draft = draft
        if let image = draft.image {
            let (url, w, h) = try await uploadMedia(image, announcementId: draft.id)
            draft.mediaUrl = url
            draft.mediaWidth = w
            draft.mediaHeight = h
        }
        // 2026-09-24 decision D-admin-recheck: checked again at write time. A demotion during the
        // upload now fails here, before any document is touched, instead of at the rules.
        try checkPermissions(draft, editing: editing)

        // "Now" is the server's clock (see `Draft.map`). An edit keeps an announcement's original
        // time unless the edit itself moved it to now (switching "Send later" off sets it to now).
        let publishNow = !draft.isScheduled
            && (!editing || draft.publishAt > Date().addingTimeInterval(-120))
        let payload = draft.map(createdBy: uid, editing: editing, publishNow: publishNow)
        let home = collection(for: draft.audience.scope)
        let homeRef = db.collection(home).document(draft.id)

        // The record. For a chosen send it is the admin-only record carrying the recipient list, so
        // this can be taken back later, and a count of the copies written so far.
        var record = payload
        if draft.audience.scope == .chosen {
            record["recipients"] = draft.chosen.map(\.id)
            record["deliveredCount"] = 0
        }
        try await writeGuarded(homeRef, record, editing: editing, kind: draft.kind,
                               scope: draft.audience.scope, canSecurity: AdminStore.shared.can(.security))

        guard draft.audience.scope == .chosen else { return }

        // The personal copies. `createdAt` cannot be a server timestamp on these: the phone sorts the
        // chat by it, and a pending server timestamp reads as nil, which would put a brand-new
        // announcement at the very bottom of the channel until the write came back. The recipient
        // list is stripped — nobody needs to know who else was sent this.
        // 2026-09-24 decision D-admin-resurrect: an edit leaves `createdAt` alone (it used to re-date
        // the message in every recipient's chat) and carries no `deleted` (see `Draft.map`), and the
        // rules refuse an edit onto a withdrawn copy, so a withdrawal that lands mid-fan-out stops
        // the edit instead of being undone by it.
        var copy = payload
        if !editing {
            copy["createdAt"] = Timestamp(date: Date())
            copy["createdBy"] = uid
        }

        // 2026-09-24 decision D-admin-fanout: each batch also counts its copies onto the record, in
        // the same commit, so a send that fails part way shows as "Partly sent" in the history
        // instead of "Sent". Sending again (or Save on an edit) finishes it.
        for chunk in draft.chosen.chunked(into: 400) {
            let batch = db.batch()
            for person in chunk {
                let ref = db.collection("users").document(person.id)
                    .collection("announcements").document(draft.id)
                batch.setData(copy, forDocument: ref, merge: editing)
            }
            batch.updateData(["deliveredCount": FieldValue.increment(Int64(chunk.count))], forDocument: homeRef)
            try await batch.commit()
        }
    }

    /// Every permission a publish needs, from the live admin record.
    private static func checkPermissions(_ draft: Draft, editing: Bool) throws {
        let store = AdminStore.shared
        guard store.can(.send) else { throw AdminError.notAllowed("You cannot send announcements.") }
        if draft.isScheduled && !store.can(.schedule) {
            throw AdminError.notAllowed("You cannot schedule announcements.")
        }
        if editing && !store.can(.edit) { throw AdminError.notAllowed("You cannot edit announcements.") }
        // 2026-09-24 decision D-admin-security: an edit may KEEP a security alert's kind without the
        // `security` permission (fixing a typo), never add or remove it. Which of those an edit is
        // depends on the stored kind, so `writeGuarded` checks it against the server copy.
        if draft.kind == .security && !store.can(.security) && !editing {
            throw AdminError.notAllowed("You cannot send security alerts.")
        }
        if draft.audience.scope == .countries && !store.can(.targetCountry) {
            throw AdminError.notAllowed("You cannot choose countries.")
        }
        if draft.audience.scope == .chosen && !store.can(.targetChosen) {
            throw AdminError.notAllowed("You cannot send to chosen people.")
        }
    }

    /// 2026-09-24 decision D-admin-resurrect: the record is written in a TRANSACTION that reads the
    /// stored copy first. It was a blind `setData(merge:)`, so Save on an edit that had been open
    /// while another admin withdrew the announcement brought it back for everybody. Now an edit
    /// refuses when the stored announcement is withdrawn or gone, when it would change the audience
    /// type, or when it would add or strip the Security kind without that permission. The rules
    /// refuse the same three.
    private static func writeGuarded(_ ref: DocumentReference, _ data: [String: Any], editing: Bool,
                                     kind: AnnouncementKind, scope: AnnouncementAudience.Scope,
                                     canSecurity: Bool) async throws {
        func refusal(_ why: String) -> NSError {
            NSError(domain: "Fariin", code: 409, userInfo: [NSLocalizedDescriptionKey: why])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            db.runTransaction({ txn, errPtr -> Any? in
                let snap: DocumentSnapshot
                do { snap = try txn.getDocument(ref) } catch {
                    errPtr?.pointee = error as NSError
                    return nil
                }
                let stored = snap.data()
                let withdrawn = stored?["deleted"] as? Bool == true
                if withdrawn || (editing && stored == nil) {
                    errPtr?.pointee = refusal("This announcement has been taken back. It no longer shows in anybody's chat.")
                    return nil
                }
                if editing, let stored {
                    let was = Announcement(id: ref.documentID, data: stored)
                    if was.audience.scope != scope {
                        errPtr?.pointee = refusal("Who an announcement goes to cannot be changed after it is sent.")
                        return nil
                    }
                    if (was.kind == .security) != (kind == .security) && !canSecurity {
                        errPtr?.pointee = refusal("You cannot send security alerts.")
                        return nil
                    }
                }
                txn.setData(data, forDocument: ref, merge: editing)
                return nil
            }, completion: { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
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
        // 2026-09-24 decision D-admin-media: a NEW file per upload. The fixed `image.jpg` meant a
        // picture change on a live announcement replaced what its url served before the edit was
        // saved (and the create-only storage rule refused the replacement anyway). The old file stays
        // until the saved edit points away from it.
        let version = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let ref = Storage.storage().reference().child("announcements/\(announcementId)/image-\(version).jpg")
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(jpeg, metadata: meta)
        let url = try await ref.downloadURL().absoluteString
        return (url, Double(bounded.size.width), Double(bounded.size.height))
    }

    // MARK: Reading, for the admin screens

    /// Everything, including scheduled, expired and deleted ones — the opposite of what a phone sees.
    /// Both homes, merged: broadcasts from `announcements` and chosen sends from `announcementLog`.
    /// Throws when either read fails (audit 2026-09-24): both used to be `try?`, so no internet or a
    /// refused read drew "Nothing sent yet." and the admin was told the channel was empty.
    static func history(limit: Int = 60) async throws -> [Announcement] {
        async let broadcasts = db.collection("announcements")
            .order(by: "publishAt", descending: true).limit(to: limit).getDocuments()
        async let chosen = db.collection("announcementLog")
            .order(by: "publishAt", descending: true).limit(to: limit).getDocuments()

        let a = (try await broadcasts).documents
        let b = (try await chosen).documents
        return (a + b)
            .map { Announcement(id: $0.documentID, data: $0.data()) }
            .sorted { $0.sortAt > $1.sortAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Throws on a failed read (audit 2026-09-24): `try?` here showed a failed load as a team with
    /// nobody on it, not even the owner.
    static func admins() async throws -> [AdminRecord] {
        let snap = try await db.collection("admins").getDocuments()
        return snap.documents
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

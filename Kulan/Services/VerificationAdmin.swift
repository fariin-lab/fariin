import Foundation
import FirebaseFirestore

// VERIFICATION, THE WRITE SIDE.
//
// Nothing in this file is reachable by a normal user, and nothing in it is reachable by an admin
// without the `verify` capability. That is enforced twice on purpose: here, so the app does not
// offer an action it cannot complete, and in firestore.rules, so the enforcement survives somebody
// replacing the app. The rules are the real gate. This is manners.
//
// THE SHAPE OF A VERIFICATION, in three pieces, split by who is allowed to read them:
//
//   1. THE MARK, on the peer document. Public, tiny, arrives with data every client already fetches.
//      This is what draws a badge, and it is the ONLY piece a user's phone ever sees.
//   2. THE CASE FILE, in `verifications/{peerKey}`. Admin-only. Why it was granted, what was
//      checked, what the reviewer wrote. Never leaves the console.
//   3. THE TRAIL, in `verificationAudit`. Admin-only, append-only, one entry per decision, forever.
//
// Every change writes all three in a SINGLE BATCH. A mark without a trail is an unexplained badge;
// a trail without a mark is a decision that silently did not happen. They commit together or the
// change did not occur.

enum VerificationAdmin {
    private static var db: Firestore { Firestore.firestore() }

    enum VerifyError: LocalizedError {
        case notAllowed
        case noSuchPeer
        case notSignedIn
        var errorDescription: String? {
            switch self {
            case .notAllowed:  return "You do not have permission to verify accounts."
            case .noSuchPeer:  return "That account no longer exists."
            case .notSignedIn: return "You are signed out."
            }
        }
    }

    /// WHAT HAPPENED, as one word, stored on every audit entry. Kept separate from `Status` because a
    /// status is where a peer STANDS and an action is what somebody DID: granting a badge to a peer
    /// that never had one and restoring a badge that was withdrawn both end at `active`, and the
    /// difference between them is the entire reason anyone reads an audit log.
    enum Action: String {
        case granted
        case typeChanged = "type_changed"
        case suspended
        case restored
        case withdrawn
        case noteAdded = "note_added"

        var label: String {
            switch self {
            case .granted:     return "Verified"
            case .typeChanged: return "Type changed"
            case .suspended:   return "Suspended"
            case .restored:    return "Restored"
            case .withdrawn:   return "Verification removed"
            case .noteAdded:   return "Note added"
            }
        }
    }

    // MARK: - Reading

    /// The case file. Admin-only by rule, so a normal user calling this gets a permission error
    /// rather than an empty document, which is the correct outcome.
    struct CaseFile {
        var reason: String = ""        // why it was granted
        var notes: String = ""         // running internal notes
        var updatedBy: String = ""
        var updatedAt: Date?

        init() {}
        init(_ data: [String: Any]) {
            reason = data["reason"] as? String ?? ""
            notes = data["notes"] as? String ?? ""
            updatedBy = data["updatedBy"] as? String ?? ""
            updatedAt = (data["updatedAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    static func caseFile(for peer: PeerRef) async throws -> CaseFile {
        guard AdminStore.shared.can(.verify) else { throw VerifyError.notAllowed }
        let snap = try await db.collection("verifications").document(peer.key).getDocument()
        guard let data = snap.data() else { return CaseFile() }
        return CaseFile(data)
    }

    /// One peer's history, newest first. The audit is append-only, so this is the complete story of
    /// a badge from the day it was granted.
    static func history(for peer: PeerRef, limit: Int = 100) async throws -> [AuditEntry] {
        guard AdminStore.shared.can(.verify) else { throw VerifyError.notAllowed }
        let snap = try await db.collection("verificationAudit")
            .whereField("peerKey", isEqualTo: peer.key)
            .order(by: "at", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snap.documents.map { AuditEntry(id: $0.documentID, data: $0.data()) }
    }

    /// Everything anybody has done lately, across all peers. The console's front page: an admin
    /// arriving cold should see what the team has been doing without searching for a name first.
    static func recentActivity(limit: Int = 50) async throws -> [AuditEntry] {
        guard AdminStore.shared.can(.verify) else { throw VerifyError.notAllowed }
        let snap = try await db.collection("verificationAudit")
            .order(by: "at", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snap.documents.map { AuditEntry(id: $0.documentID, data: $0.data()) }
    }

    struct AuditEntry: Identifiable {
        let id: String
        var peerKey: String
        var action: Action?
        var fromStatus: String
        var toStatus: String
        var kind: String
        var reason: String
        var adminUid: String
        var adminHandle: String
        var at: Date?
        /// The name and handle the peer was wearing when the decision was taken. An audit entry that
        /// only stores a uid is unreadable a year later; storing the name at the time means the trail
        /// still makes sense after somebody renames themselves, which is exactly when it is read.
        var peerName: String
        var peerHandle: String

        init(id: String, data: [String: Any]) {
            self.id = id
            peerKey = data["peerKey"] as? String ?? ""
            action = (data["action"] as? String).flatMap(Action.init(rawValue:))
            fromStatus = data["fromStatus"] as? String ?? ""
            toStatus = data["toStatus"] as? String ?? ""
            kind = data["type"] as? String ?? ""
            reason = data["reason"] as? String ?? ""
            adminUid = data["adminUid"] as? String ?? ""
            adminHandle = data["adminHandle"] as? String ?? ""
            peerName = data["peerName"] as? String ?? ""
            peerHandle = data["peerHandle"] as? String ?? ""
            at = (data["at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    // MARK: - Writing

    /// GRANT, CHANGE, SUSPEND, RESTORE, WITHDRAW — one function, because they are one operation with
    /// a different destination, and writing five of them would be writing five places for the audit
    /// entry to be forgotten.
    ///
    /// `reason` is required for every change and is never shown to the verified person. It is the
    /// answer to "why does this account have a badge", asked by whoever inherits this job.
    static func apply(
        _ action: Action,
        to peer: PeerRef,
        status: Verification.Status,
        kind: Verification.Kind?,
        reason: String,
        peerName: String,
        peerHandle: String
    ) async throws {
        guard AdminStore.shared.can(.verify) else { throw VerifyError.notAllowed }
        guard let adminUid = AuthService.shared.uid else { throw VerifyError.notSignedIn }

        let peerDoc = db.collection(peer.kind.collection).document(peer.id)
        let existing = try await peerDoc.getDocument()
        guard existing.exists else { throw VerifyError.noSuchPeer }

        let before = Verification((existing.data()?["verification"] as? [String: Any]))
        let now = Date().timeIntervalSince1970 * 1000
        let adminHandle = AdminStore.shared.me?.handle ?? ""

        // THE MARK. `isVerified` is written alongside `status` even though it is derivable, because it
        // is the field the rules and any future server-side query can read without parsing a string.
        var mark: [String: Any] = [
            "isVerified": status == .active,
            "status": status.rawValue,
            "verifiedBy": adminUid,
            "lastUpdated": now,
            "version": 1,
        ]
        // THIS WHOLE MAP REPLACES THE OLD ONE. `updateData` with a map value does not merge into the
        // nested fields, it overwrites the field — so anything not written here is GONE, and every
        // value that must outlive a status change has to be carried forward explicitly below. (It is
        // also why `FieldValue.delete()` has no place in here: a key that should not exist is a key
        // simply left out, and a nested delete would be rejected by the SDK anyway.)
        if let kind { mark["type"] = kind.rawValue }

        // The grant date is set once and never moved. A suspension and a restoration are events in a
        // badge's life, not a new badge, and overwriting the original date would erase how long an
        // account has actually been verified.
        mark["verifiedAt"] = before?.verifiedAt.map { $0.timeIntervalSince1970 * 1000 } ?? now
        // Likewise the admin who originally granted it. Who made THIS change is on the audit entry;
        // this field answers the different question of who put the badge there in the first place.
        if let priorGranter = before?.verifiedBy, !priorGranter.isEmpty {
            mark["verifiedBy"] = priorGranter
        }

        // WHAT WE ACTUALLY REVIEWED. Stamped on a grant, and CARRIED FORWARD on every later change —
        // not merely left unwritten, because unwritten means erased here. Dropping it on a
        // suspension would quietly destroy the only record of which name a human actually approved,
        // which is the one thing that makes a rename detectable afterwards.
        if action == .granted || before == nil {
            mark["verifiedName"] = peerName
            mark["verifiedHandle"] = peerHandle
        } else {
            mark["verifiedName"] = before?.verifiedName ?? ""
            mark["verifiedHandle"] = before?.verifiedHandle ?? ""
        }

        let batch = db.batch()
        batch.updateData(["verification": mark], forDocument: peerDoc)

        // THE CASE FILE.
        batch.setData([
            "peerKey": peer.key,
            "reason": reason,
            "updatedBy": adminUid,
            "updatedAt": now,
        ], forDocument: db.collection("verifications").document(peer.key), merge: true)

        // THE TRAIL. Its id is generated here rather than by the server so the batch stays a batch.
        batch.setData([
            "peerKey": peer.key,
            "action": action.rawValue,
            "fromStatus": before?.status.rawValue ?? "",
            "toStatus": status.rawValue,
            "type": kind?.rawValue ?? "",
            "reason": reason,
            "adminUid": adminUid,
            "adminHandle": adminHandle,
            "peerName": peerName,
            "peerHandle": peerHandle,
            "at": now,
        ], forDocument: db.collection("verificationAudit").document(UUID().uuidString.lowercased()))

        try await batch.commit()

        // Reflect it locally at once. The peer's own listener will deliver the same value moments
        // later; this is so the admin sees the badge change on the row they just acted on rather
        // than wondering whether it worked.
        //
        // Parsed back out of the EXACT map that was just written, through the same reader every
        // other screen uses. Rebuilding it field by field here would be a second set of rules that
        // starts out looking identical and drifts, and a mirror that disagrees with what was stored
        // is worse than no mirror: the admin sees one thing, the next reader sees another, and
        // nothing on screen says which is real.
        let applied = Verification(mark)
        VerificationIndex.record(peer, applied)
    }

    /// A note with no change of state. Sometimes the useful thing to record is that somebody looked
    /// and decided to do nothing, which is invisible unless it can be written down.
    static func addNote(_ note: String, to peer: PeerRef, peerName: String, peerHandle: String) async throws {
        guard AdminStore.shared.can(.verify) else { throw VerifyError.notAllowed }
        guard let adminUid = AuthService.shared.uid else { throw VerifyError.notSignedIn }
        let now = Date().timeIntervalSince1970 * 1000
        let batch = db.batch()
        batch.setData([
            "peerKey": peer.key,
            "notes": note,
            "updatedBy": adminUid,
            "updatedAt": now,
        ], forDocument: db.collection("verifications").document(peer.key), merge: true)
        batch.setData([
            "peerKey": peer.key,
            "action": Action.noteAdded.rawValue,
            "fromStatus": "", "toStatus": "", "type": "",
            "reason": note,
            "adminUid": adminUid,
            "adminHandle": AdminStore.shared.me?.handle ?? "",
            "peerName": peerName,
            "peerHandle": peerHandle,
            "at": now,
        ], forDocument: db.collection("verificationAudit").document(UUID().uuidString.lowercased()))
        try await batch.commit()
    }

    // MARK: - Finding somebody

    /// Look a peer up to act on it. By handle, because that is what an admin will have been sent, and
    /// by raw id, because that is what a bug report will contain.
    ///
    /// Handle search is a PREFIX range on `handleLower`, the same shape the app's own user search
    /// uses. It is an index scan, not a table scan, so it costs the same at ten users as at ten
    /// million — which is the only property that matters here.
    static func search(_ query: String, limit: Int = 25) async throws -> [FoundPeer] {
        guard AdminStore.shared.can(.verify) else { throw VerifyError.notAllowed }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
        guard !q.isEmpty else { return [] }

        // An exact id first: an admin pasting a uid wants that one account, not everything starting
        // with those characters.
        if q.count > 20, let doc = try? await db.collection("users").document(query).getDocument(),
           doc.exists {
            return [FoundPeer(peer: .user(doc.documentID), data: doc.data() ?? [:])]
        }

        let snap = try await db.collection("users")
            .order(by: "handleLower")
            .start(at: [q])
            .end(at: [q + "\u{f8ff}"])
            .limit(to: limit)
            .getDocuments()
        return snap.documents.map { FoundPeer(peer: .user($0.documentID), data: $0.data()) }
    }

    /// A search hit. It carries a whole `UserProfile` rather than a hand-picked set of fields,
    /// because `UserProfile` is already the one place that knows how to read a user document — a
    /// second parser here would be a second thing to update the next time a field is added, and the
    /// two would disagree quietly.
    struct FoundPeer: Identifiable {
        let peer: PeerRef
        var profile: UserProfile

        var id: String { peer.key }
        var name: String { profile.name }
        var handle: String { profile.handle }
        var verification: Verification? { profile.verification }

        /// The name a verified peer was wearing when a human approved it is not always the name it
        /// wears now. When those disagree, somebody should look again — this is what surfaces that.
        ///
        /// This is the quiet failure a badge alone cannot catch: a business verified honestly,
        /// renamed six months later to a bank, still wearing a tick that vouches for a claim nobody
        /// reviewed. The mark keeps saying "we checked", and it did — it checked something else.
        var hasDriftedSinceVerification: Bool {
            guard let v = verification, v.showsBadge, !v.verifiedHandle.isEmpty else { return false }
            return v.verifiedHandle.caseInsensitiveCompare(profile.handle) != .orderedSame
                || (!v.verifiedName.isEmpty && v.verifiedName != profile.name)
        }

        /// Through `ProfileStore.indexed`, so the console's rows can draw the SAME `VerifiedMark`
        /// every other screen draws instead of hand-rolling a second tick. A console that renders
        /// the badge its own way is a console that can disagree with the app about who is verified,
        /// which is the one thing it exists to be certain about.
        init(peer: PeerRef, data: [String: Any]) {
            self.peer = peer
            self.profile = ProfileStore.indexed(UserProfile(id: peer.id, data: data))
        }
    }
}

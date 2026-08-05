import Foundation
import SwiftUI

/// A verified account, as it is stored and as the app reads it.
///
/// WHAT THIS IS MODELLED ON. Telegram carries verification as a FLAG ON THE PEER ITSELF, delivered
/// with the user object — `TelegramUser.isVerified` alongside `isScam`, `isFake` and, in newer
/// builds, a `VerificationStatus` value that travels in the same payload. There is no separate
/// endpoint and no second round trip: if you have the user, you have the badge. That single decision
/// is what makes their badge appear everywhere at once and never flicker in late, and it is the one
/// worth copying.
///
/// SO THIS IS ONE NESTED MAP ON `users/{uid}`. It arrives with every profile the app already reads —
/// opening a chat, opening a profile, listing group members — so no screen anywhere makes a request
/// to find out whether to draw a badge, and the existing profile cache carries it offline for free.
///
/// IT HANGS OFF THE UID AND NOTHING ELSE. Not the handle, not the display name, not the photo. A
/// person can rename themselves, take a new username, change their picture or connect a different
/// sign-in method, and none of it touches this, because none of it is what the badge is about.
struct Verification: Equatable, Hashable {

    /// WHAT KIND of account this is. Stored as a string rather than an integer so a value added in
    /// two years is readable in the console and cannot collide with a number somebody reused, and so
    /// an OLD client meeting a NEW type degrades to "verified, kind unknown" instead of guessing.
    /// New kinds need no migration: they are new strings.
    enum Kind: String, CaseIterable {
        case official      // us
        case business
        case publicFigure  = "public_figure"
        case organization
        case government
        case media
        case creator

        var label: String {
            switch self {
            case .official:     return "Official"
            case .business:     return "Business"
            case .publicFigure: return "Public Figure"
            case .organization: return "Organization"
            case .government:   return "Government"
            case .media:        return "Media"
            case .creator:      return "Creator"
            }
        }
    }

    /// WHERE it stands. Suspension is deliberately not deletion: an account under review keeps its
    /// record, its history and its reason, and only stops showing a badge. Removing the record would
    /// destroy the audit trail at exactly the moment somebody needs to read it.
    enum Status: String {
        case active
        case suspended
        case revoked
    }

    var kind: Kind?
    var status: Status
    var verifiedAt: Date?
    var verifiedBy: String       // admin uid
    var reason: String           // internal note, never shown to the verified person
    var lastUpdated: Date?
    /// Schema version of this record. Lets a future shape be told apart from this one without
    /// guessing from which keys happen to be present.
    var version: Int

    /// THE ONLY QUESTION THE UI EVER ASKS. A badge is drawn when, and only when, this is true — one
    /// definition, read from one place, so no screen can invent its own rule about who is verified.
    /// An unknown `kind` still counts: the account IS verified, we simply do not know what sort yet,
    /// and refusing the badge because a newer client used a newer word would be the wrong failure.
    var showsBadge: Bool { status == .active }

    init(kind: Kind? = nil, status: Status = .active, verifiedAt: Date? = nil,
         verifiedBy: String = "", reason: String = "", lastUpdated: Date? = nil, version: Int = 1) {
        self.kind = kind
        self.status = status
        self.verifiedAt = verifiedAt
        self.verifiedBy = verifiedBy
        self.reason = reason
        self.lastUpdated = lastUpdated
        self.version = version
    }

    /// Read from the `verification` map on a users document. Returns nil when there is no record at
    /// all, which is the overwhelmingly common case and must cost nothing.
    init?(_ data: [String: Any]?) {
        guard let data, !data.isEmpty else { return nil }
        // `isVerified` is stored as well as derived. It is what the SERVER and the rules can index and
        // query on without parsing a status string, and it is what a future "list every verified
        // account" screen will page over.
        let flag = data["isVerified"] as? Bool ?? false
        let rawStatus = data["status"] as? String ?? (flag ? Status.active.rawValue : Status.revoked.rawValue)
        guard let status = Status(rawValue: rawStatus) else { return nil }
        self.status = status
        self.kind = (data["type"] as? String).flatMap(Kind.init(rawValue:))
        self.verifiedBy = data["verifiedBy"] as? String ?? ""
        self.reason = data["reason"] as? String ?? ""
        self.version = data["version"] as? Int ?? 1
        self.verifiedAt = (data["verifiedAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0 / 1000) }
        self.lastUpdated = (data["lastUpdated"] as? TimeInterval).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Who is verified, answered SYNCHRONOUSLY and from memory.
///
/// The same shape as `CallPrivacyIndex` and `ProfilePhotoIndex`, and for the same reason: a badge is
/// drawn during a layout pass, on the frame a row appears. It cannot await a document, and a screen
/// that fetched one per row would issue a request per visible chat.
///
/// It is filled by work the app already does. Every users document the app reads passes through
/// `ProfileStore.indexed`, which hands the map straight here — so opening a chat, opening a profile
/// or listing members all warm it, and nothing is fetched for the sake of a badge.
///
/// A MISS MEANS NO BADGE. If we have not seen an account's record we draw nothing, which is the
/// honest failure: showing a badge we are not sure about is the one outcome a verification system
/// must never produce.
enum VerificationIndex {
    private static var records: [String: Verification] = [:]
    private static let lock = NSLock()

    /// Takes the DECODED value, not the raw map: `UserProfile` has already parsed it once, and
    /// parsing it a second time here would be a second place for the two answers to differ.
    static func record(uid: String, verification: Verification?) {
        guard !uid.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let verification { records[uid] = verification } else { records.removeValue(forKey: uid) }
    }

    /// The record for an account, or nil. Cheap enough to call from a row body.
    static func of(_ uid: String) -> Verification? {
        lock.lock(); defer { lock.unlock() }
        return records[uid]
    }

    /// THE ONE CALL EVERY BADGE SITE MAKES. Chat list, conversation header, profile, search results,
    /// mentions, forwards, story header, viewers, shared media, call screen — all of them ask this
    /// and none of them decide anything for themselves.
    static func isVerified(_ uid: String) -> Bool { of(uid)?.showsBadge == true }

    /// Sign-out: the next account must not inherit a map of who was verified.
    static func clear() {
        lock.lock(); records.removeAll(); lock.unlock()
    }
}

/// THE badge. One view, one source, drawn the same size and colour everywhere it appears.
///
/// His requirement was that it show up on the chat list, the conversation header, profiles, group
/// member lists, search results, mentions, forwarded messages, the story header and viewers, shared
/// media, user cards, the call screen and contact info — from the SAME source, with no duplicated
/// logic. So the rule lives in `VerificationIndex.isVerified` and the drawing lives here, and a call
/// site does neither: it says `VerifiedBadge(uid:)` and gets whatever we have decided a badge is.
///
/// It draws NOTHING when the account is not verified, so it can be placed unconditionally beside any
/// name without the caller writing an `if`. That is deliberate: an `if` at a call site is a place for
/// somebody to write a slightly different condition.
struct VerifiedBadge: View {
    let uid: String
    var size: CGFloat = 15

    var body: some View {
        if VerificationIndex.isVerified(uid) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: size))
                .foregroundStyle(.white, Color(hex: 0x3DA1FD))
                .symbolRenderingMode(.palette)
                .accessibilityLabel("Verified")
        }
    }
}

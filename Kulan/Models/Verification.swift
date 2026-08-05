import SwiftUI
import Foundation

// MARK: - Who a verification is about

/// WHAT GETS VERIFIED. Not a user — a PEER, meaning anything that can own a name and a picture and
/// sit in a chat list. Today that is a person. When groups arrive it is also a group, and the whole
/// of the rest of this file, the admin console, the audit trail and the badge already work, because
/// none of them were ever written against a uid.
///
/// This is the one decision worth taking early. Verification keyed to `uid` reads fine right up to
/// the day a group needs a badge, and then it needs a second collection, a second index, a second
/// badge view and a second admin screen — two systems that have to agree forever and slowly stop
/// agreeing. Telegram does not have that problem because their flag lives on a PEER: the same
/// `isVerified` bit is read off a user, a group and a channel by the same drawing code.
///
/// The wire format is `"user:abc123"` / `"group:xyz789"`. A prefix rather than two collections,
/// because it makes one document id that can name anything, and an audit entry from 2029 stays
/// readable without knowing which table it came from.
struct PeerRef: Hashable, Identifiable {
    enum Kind: String, CaseIterable {
        case user
        case group

        /// Where this peer's own document lives. The verification mark is written here, ON the peer,
        /// which is what makes reading it free for every client.
        var collection: String {
            switch self {
            case .user:  return "users"
            case .group: return "groups"
            }
        }
    }

    let kind: Kind
    let id: String

    var key: String { "\(kind.rawValue):\(id)" }
    var identifier: String { key }

    static func user(_ uid: String) -> PeerRef { PeerRef(kind: .user, id: uid) }
    static func group(_ gid: String) -> PeerRef { PeerRef(kind: .group, id: gid) }

    /// Parse a stored key back. Fails closed on anything malformed rather than guessing a kind,
    /// because guessing here would attach somebody's verification to the wrong peer.
    init?(key: String) {
        guard let sep = key.firstIndex(of: ":") else { return nil }
        guard let kind = Kind(rawValue: String(key[key.startIndex..<sep])) else { return nil }
        let id = String(key[key.index(after: sep)...])
        guard !id.isEmpty else { return nil }
        self.kind = kind
        self.id = id
    }

    private init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

// MARK: - The record

/// A verified peer, as it is stored and as the app reads it.
///
/// WHAT THIS IS MODELLED ON. Telegram carries verification as a FLAG ON THE PEER ITSELF, delivered
/// with the peer object — `TelegramUser.isVerified`, and the same bit on a chat. There is no separate
/// endpoint and no second round trip: if you have the peer, you have the badge. That single decision
/// is what makes their badge appear everywhere at once and never flicker in late, and it is the one
/// worth copying.
///
/// SO THIS IS ONE NESTED MAP ON THE PEER DOCUMENT. It arrives with every profile the app already
/// reads — opening a chat, opening a profile, listing members — so no screen anywhere makes a
/// request to find out whether to draw a badge, and the existing profile cache carries it offline
/// for free. At any number of users, drawing a name costs zero extra reads.
///
/// This is the PUBLIC half. Why a peer was verified, who approved it and what the reviewer wrote
/// live in `verifications/{peerKey}`, which only admins can read. A client is told the verdict and
/// nothing else, because everything else is somebody's case file.
///
/// IT HANGS OFF THE PEER ID AND NOTHING ELSE. Not the handle, not the display name, not the photo.
/// A person can rename themselves, take a new username or change their picture, and none of it
/// touches this, because none of it is what the badge is about.
struct Verification: Equatable, Hashable {

    /// WHAT KIND of peer this is. Stored as a string rather than an integer so a value added in
    /// two years is readable in the console and cannot collide with a number somebody reused, and so
    /// an OLD client meeting a NEW type degrades to "verified, kind unknown" instead of guessing.
    /// New kinds need no migration: they are new strings.
    ///
    /// The kind never changes the tick. It is one mark, and it means one thing — this peer is who it
    /// says it is. The kind is for the console, for the info sheet, and for answering "how many
    /// government accounts do we carry" without reading every record by hand.
    enum Kind: String, CaseIterable, Identifiable {
        case official      // us
        case business
        case publicFigure  = "public_figure"
        case organization
        case government
        case media
        case creator

        var id: String { rawValue }

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

        /// Shown on the info sheet, so the tick can say what it actually claims rather than leaving
        /// the reader to assume. Deliberately plain: it describes the check we did, not a status.
        var explanation: String {
            switch self {
            case .official:     return "This is an official Fariin account."
            case .business:     return "This business has been verified as genuine."
            case .publicFigure: return "This person's identity has been verified."
            case .organization: return "This organization has been verified as genuine."
            case .government:   return "This is a verified government account."
            case .media:        return "This news organization has been verified as genuine."
            case .creator:      return "This creator's identity has been verified."
            }
        }
    }

    /// WHERE IT STANDS. Suspension is deliberately not deletion: a peer under review keeps its
    /// record, its history and its reason, and only stops showing a badge. Removing the record would
    /// destroy the audit trail at exactly the moment somebody needs to read it.
    enum Status: String, CaseIterable, Identifiable {
        case active
        case suspended
        case revoked

        var id: String { rawValue }
        var label: String {
            switch self {
            case .active:    return "Verified"
            case .suspended: return "Suspended"
            case .revoked:   return "Removed"
            }
        }
    }

    var kind: Kind?
    var status: Status
    var verifiedAt: Date?
    var verifiedBy: String       // admin uid
    var lastUpdated: Date?

    /// WHAT WAS ACTUALLY VERIFIED, recorded at the moment it was granted.
    ///
    /// This is the difference between a verification system and a badge. A tick says "this peer is
    /// who it claims" — but the claim was checked against a name and a handle on one particular day.
    /// If a verified account later renames itself to a bank, the tick keeps vouching for a claim
    /// nobody ever reviewed, and it now vouches for the impersonation. Recording the reviewed name
    /// lets the console show every peer whose name has drifted since approval, which turns that
    /// attack from invisible into a list somebody can work through.
    ///
    /// It is never shown to users. A name is not evidence to a stranger, and printing an old name
    /// beside a new one would leak a rename to everybody who opens a profile.
    var verifiedName: String
    var verifiedHandle: String

    /// Schema version of this record. Lets a future shape be told apart from this one without
    /// guessing from which keys happen to be present.
    var version: Int

    /// THE ONLY QUESTION THE UI EVER ASKS. A badge is drawn when, and only when, this is true — one
    /// definition, read from one place, so no screen can invent its own rule about who is verified.
    /// An unknown `kind` still counts: the peer IS verified, we simply do not know what sort yet,
    /// and refusing the badge because a newer client used a newer word would be the wrong failure.
    var showsBadge: Bool { status == .active }

    init(kind: Kind? = nil, status: Status = .active, verifiedAt: Date? = nil,
         verifiedBy: String = "", lastUpdated: Date? = nil,
         verifiedName: String = "", verifiedHandle: String = "", version: Int = 1) {
        self.kind = kind
        self.status = status
        self.verifiedAt = verifiedAt
        self.verifiedBy = verifiedBy
        self.lastUpdated = lastUpdated
        self.verifiedName = verifiedName
        self.verifiedHandle = verifiedHandle
        self.version = version
    }

    /// Read from the `verification` map on a peer document. Returns nil when there is no record at
    /// all, which is the overwhelmingly common case and must cost nothing.
    init?(_ data: [String: Any]?) {
        guard let data, !data.isEmpty else { return nil }
        // `isVerified` is stored as well as derived. It is what the SERVER and the rules can index and
        // query on without parsing a status string, and it is what a future "list every verified
        // peer" screen will page over.
        let flag = data["isVerified"] as? Bool ?? false
        let rawStatus = data["status"] as? String ?? (flag ? Status.active.rawValue : Status.revoked.rawValue)
        guard let status = Status(rawValue: rawStatus) else { return nil }
        self.status = status
        self.kind = (data["type"] as? String).flatMap(Kind.init(rawValue:))
        self.verifiedBy = data["verifiedBy"] as? String ?? ""
        self.verifiedName = data["verifiedName"] as? String ?? ""
        self.verifiedHandle = data["verifiedHandle"] as? String ?? ""
        self.version = data["version"] as? Int ?? 1
        self.verifiedAt = (data["verifiedAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0 / 1000) }
        self.lastUpdated = (data["lastUpdated"] as? TimeInterval).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

// MARK: - The index

/// Who is verified, answered SYNCHRONOUSLY and from memory.
///
/// The same shape as `CallPrivacyIndex` and `ProfilePhotoIndex`, and for the same reason: a badge is
/// drawn during a layout pass, on the frame a row appears. It cannot await a document, and a screen
/// that fetched one per row would issue a request per visible chat.
///
/// It is filled by work the app already does. Every peer document the app reads passes through its
/// store, which hands the map straight here — so opening a chat, opening a profile or listing
/// members all warm it, and nothing is fetched for the sake of a badge. It holds only peers this
/// device has actually seen, so it is bounded by the size of one person's world, not the app's.
///
/// A MISS MEANS NO BADGE. If we have not seen a peer's record we draw nothing, which is the honest
/// failure: showing a badge we are not sure about is the one outcome a verification system must
/// never produce.
enum VerificationIndex {
    private static var records: [String: Verification] = [:]
    private static let lock = NSLock()

    /// Takes the DECODED value, not the raw map: the profile has already parsed it once, and parsing
    /// it a second time here would be a second place for the two answers to differ.
    static func record(_ peer: PeerRef, _ verification: Verification?) {
        guard !peer.id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let verification { records[peer.key] = verification } else { records.removeValue(forKey: peer.key) }
    }

    /// Convenience for the user path, which is every caller today.
    static func record(uid: String, verification: Verification?) {
        record(.user(uid), verification)
    }

    /// The record for a peer, or nil. Cheap enough to call from a row body.
    static func of(_ peer: PeerRef) -> Verification? {
        lock.lock(); defer { lock.unlock() }
        return records[peer.key]
    }

    static func of(_ uid: String) -> Verification? { of(.user(uid)) }

    /// THE ONE CALL EVERY BADGE SITE MAKES. Chat list, conversation header, profile, member lists,
    /// search results, mentions, forwards, story header, viewers, shared media, call screen — all of
    /// them ask this and none of them decide anything for themselves.
    static func isVerified(_ peer: PeerRef) -> Bool { of(peer)?.showsBadge == true }
    static func isVerified(_ uid: String) -> Bool { isVerified(.user(uid)) }

    /// Sign-out: the next account must not inherit a map of who was verified.
    static func clear() {
        lock.lock(); records.removeAll(); lock.unlock()
    }
}

// MARK: - The mark

/// THE badge. One view, one source, drawn the same size and colour everywhere it appears.
///
/// It shows up on the chat list, the conversation header, profiles, member lists, search results,
/// mentions, forwarded messages, the story header and viewers, shared media, user cards, the call
/// screen and contact info — from the SAME source, with no duplicated logic. The rule lives in
/// `VerificationIndex.isVerified` and the drawing lives here, and a call site does neither: it says
/// `VerifiedMark(peer:)` and gets whatever we have decided a badge is.
///
/// It draws NOTHING when the peer is not verified, so it can be placed unconditionally beside any
/// name without the caller writing an `if`. That is deliberate: an `if` at a call site is a place for
/// somebody to write a slightly different condition.
struct VerifiedMark: View {
    let peer: PeerRef
    var size: CGFloat = 15
    /// Tappable, opening the sheet that says what the mark claims. TRUE only where there is nothing
    /// else the tap could have meant — a profile. In a chat list row the tap belongs to the row, and
    /// stealing it to explain a badge would be a worse app.
    var explains: Bool = false

    @State private var showingInfo = false

    init(peer: PeerRef, size: CGFloat = 15, explains: Bool = false) {
        self.peer = peer
        self.size = size
        self.explains = explains
    }

    init(uid: String, size: CGFloat = 15, explains: Bool = false) {
        self.init(peer: .user(uid), size: size, explains: explains)
    }

    var body: some View {
        if let record = VerificationIndex.of(peer), record.showsBadge {
            mark
                .accessibilityLabel("Verified")
                .accessibilityAddTraits(explains ? .isButton : [])
                .contentShape(Rectangle())
                .onTapGesture { if explains { showingInfo = true } }
                .allowsHitTesting(explains)
                .sheet(isPresented: $showingInfo) {
                    VerificationInfoSheet(record: record, peer: peer)
                }
        }
    }

    private var mark: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .foregroundStyle(.white, Color(hex: 0x3DA1FD))
            .symbolRenderingMode(.palette)
    }
}

/// WHAT THE TICK CLAIMS, in words, one tap away.
///
/// This is the part that stops the mark being decoration. A symbol alone is unfalsifiable to the
/// person looking at it: anybody can put a tick character in their display name, and a user with no
/// way to interrogate the badge has no way to tell the two apart. A real mark can be tapped and will
/// explain itself; a tick typed into a name cannot.
struct VerificationInfoSheet: View {
    let record: Verification
    let peer: PeerRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white, Color(hex: 0x3DA1FD))
                    .symbolRenderingMode(.palette)
                    .padding(.top, 28)

                Text("Verified")
                    .font(.system(size: 22, weight: .semibold))

                Text(record.kind?.explanation ?? defaultExplanation)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text("Fariin reviewed this account and confirmed it is genuine. Verification is granted by Fariin only. It can never be bought or requested.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(380)])
    }

    /// An older record, or one whose kind this build has not heard of. The mark still means the one
    /// thing every mark means, so say that rather than nothing.
    private var defaultExplanation: String {
        peer.kind == .group
            ? "This group has been verified as genuine."
            : "This account has been verified as genuine."
    }
}

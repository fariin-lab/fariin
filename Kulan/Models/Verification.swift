import SwiftUI
import Foundation
import Observation

// MARK: - Who a verification is about

/// WHAT GETS VERIFIED. Not a user — a PEER, meaning anything that can own a name and a picture and
/// sit in a chat list. Today that is a person. When groups arrive it is also a group, and the whole
/// of the rest of this file, the admin console, the audit trail and the badge already work, because
/// none of them were ever written against a uid.
///
/// This is the one decision worth taking early. Verification keyed to `uid` reads fine right up to
/// the day a group needs a badge, and then it needs a second collection, a second index, a second
/// badge view and a second admin screen — two systems that have to agree forever and slowly stop
/// agreeing. The reference app does not have that problem because their flag lives on a PEER: the same
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
/// WHAT THIS IS MODELLED ON. The reference app carries verification as a FLAG ON THE PEER ITSELF, delivered
/// with the peer object itself, and the same bit is read on a chat. There is no separate
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
        /// ⛔ GOLD FOR COMPANIES — owner 2026-10-13 ("only companies like Facebook, Meta, Hormuud"):
        /// a Business or Organization verification draws the gold seal; every other kind, our own
        /// channel included, stays blue. Same seal, same size; only the colour says "company".
        var isGold: Bool { self == .business || self == .organization }

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
    /// ⛔ SEEDED FROM THE PHONE, NOT EMPTY AT LAUNCH — owner 2026-10-16: on the Stories list the tick
    /// arrived after the cards, every time. This table lived in memory only, so each launch started
    /// it blank and a row's tick waited for that person's profile to be read again, which the Stories
    /// list does late or not at all. It is now saved to a small file (the same map the server sends,
    /// so `Verification.init?(_:)` reads it back) and loaded on first use, so a tick this phone has
    /// seen before is there on the first frame; a fresh server answer still corrects it as before.
    /// The file goes with `clear()` on sign-out.
    private static var records: [String: Verification] = loadFromDisk()
    private static let lock = NSLock()
    private static var saveScheduled = false

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("verification-index.plist")
    }

    private static func loadFromDisk() -> [String: Verification] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]]
        else { return [:] }
        var out: [String: Verification] = [:]
        for (key, map) in raw { if let v = Verification(map) { out[key] = v } }
        return out
    }

    /// Written a second after the last change, off the main thread, so a screen that records forty
    /// rows costs one write.
    private static func scheduleSave() {
        lock.lock()
        if saveScheduled { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            lock.lock()
            saveScheduled = false
            let snapshot = records
            lock.unlock()
            guard let url = fileURL else { return }
            var raw: [String: [String: Any]] = [:]
            for (key, v) in snapshot {
                var m: [String: Any] = ["status": v.status.rawValue, "isVerified": v.showsBadge,
                                        "verifiedBy": v.verifiedBy, "verifiedName": v.verifiedName,
                                        "verifiedHandle": v.verifiedHandle, "version": v.version]
                if let k = v.kind { m["type"] = k.rawValue }
                if let d = v.verifiedAt { m["verifiedAt"] = d.timeIntervalSince1970 * 1000 }
                if let d = v.lastUpdated { m["lastUpdated"] = d.timeIntervalSince1970 * 1000 }
                raw[key] = m
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Takes the DECODED value, not the raw map: the profile has already parsed it once, and parsing
    /// it a second time here would be a second place for the two answers to differ.
    ///
    /// ⛔ 2026-10-12, owner: "I give @kream verification, sometimes it appears, sometimes not." Two
    /// causes, both fixed here:
    ///  1. A profile is read TWICE when a page opens: `cachedPeer` from the phone's on-disk copy (which
    ///     can predate the badge) and `fetch` from the server. Both landed here and the LAST one won, so
    ///     an old cached copy finishing second wiped a badge the server had just delivered. Now a copy
    ///     that is not fresh from the server (`fresh: false`) may only fill a gap: it never removes or
    ///     replaces what is known. And between two records, the one changed later (`lastUpdated`) wins,
    ///     so two server answers arriving out of order cannot undo each other either.
    ///  2. `VerifiedMark` read this table once and never redrew, so a row drawn before its profile
    ///     arrived stayed bare. Every change now bumps `VerificationSignal`, which the mark observes.
    static func record(_ peer: PeerRef, _ verification: Verification?, fresh: Bool = true) {
        guard !peer.id.isEmpty else { return }
        lock.lock()
        let before = records[peer.key]
        if !fresh {
            if before == nil, let verification { records[peer.key] = verification }
        } else if let verification {
            if let b = before, let bt = b.lastUpdated, let nt = verification.lastUpdated, nt < bt {
                // An older answer arriving late: keep the newer one.
            } else {
                records[peer.key] = verification
            }
        } else if before?.lastUpdated == nil {
            records.removeValue(forKey: peer.key)
        }
        // Audit 2026-10-12: a fresh read with NO verification map is never allowed to erase a record
        // that has a change time. The server never deletes the map (removing a badge writes
        // status: revoked), so "no map" after we have seen one can only be a reply that left before
        // the grant and arrived after it.
        let after = records[peer.key]
        lock.unlock()
        if before?.showsBadge != after?.showsBadge || before?.status != after?.status || before?.kind != after?.kind {
            VerificationSignal.bump()
        }
        if before != after { scheduleSave() }
    }

    /// Convenience for the user path, which is every caller today.
    static func record(uid: String, verification: Verification?, fresh: Bool = true) {
        record(.user(uid), verification, fresh: fresh)
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
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        VerificationSignal.bump()
    }
}

/// The redraw signal for every `VerifiedMark`. The index itself is a plain locked table (it is read
/// from layout passes on any thread); this is the one observable thing a mark reads, so SwiftUI
/// redraws the marks when a badge appears, changes or goes. Bumped on the main actor.
@MainActor @Observable
final class VerificationSignal {
    static let shared = VerificationSignal()
    private(set) var tick = 0
    nonisolated static func bump() {
        Task { @MainActor in shared.tick &+= 1 }
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
/// ⛔ A GROUP'S BADGE (owner 2026-10-26: shown in the chat list, the group page, search and the join
/// page, not only the chat header). Set by the admin panel's Verify on the group (`verified`); a
/// Scam / Fake label outranks it, so callers pass `on` already false for a labelled group.
/// The same picture as a person's tick.
struct GroupVerifiedMark: View {
    let on: Bool
    var size: CGFloat = 15
    /// Tappable, opening the same sheet a person's tick opens (owner 2026-10-26). Only on the group
    /// page, for the reason `VerifiedMark.explains` gives.
    var explains: Bool = false

    @State private var showingInfo = false

    var body: some View {
        if on {
            Image(uiImage: VerifiedMark.badge(size: size * VerifiedMark.scale, blue: VerifiedMark.blue,
                                              weight: VerifiedMark.weight))
                .frame(width: size, height: size)
                .accessibilityLabel("Verified group")
                .accessibilityAddTraits(explains ? .isButton : [])
                .contentShape(Rectangle())
                .onTapGesture { if explains { showingInfo = true } }
                .allowsHitTesting(explains)
                .sheet(isPresented: $showingInfo) {
                    VerificationInfoSheet(record: nil, peer: .group(""))
                }
        }
    }
}

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
        // Read so this mark redraws when the index changes (see VerificationSignal).
        let _ = VerificationSignal.shared.tick
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

    /// ⛔ A PLAIN BITMAP, NOT A SYMBOL — owner, 2026-10-04: "on iOS 26 the verified badge looks
    /// white in the chat list". iOS 26 can re-render a symbol as one colour, palette or not (the
    /// chat header hit this on 09-27, `ChatHeaderView.verifiedMark`). Drawn once into a picture,
    /// there is no symbol left to recolour, so it stays a white tick on blue everywhere.
    private var mark: some View {
        let record = VerificationIndex.of(peer)
        return Image(uiImage: Self.badge(size: size * Self.scale, blue: Self.color(for: record), weight: Self.weight))
            .frame(width: size, height: size)
    }

    /// Gold for a company's verification, blue for everyone else (see `Verification.Kind.isGold`).
    static let gold = UIColor(Color(hex: 0xE8B21E))
    static func color(for record: Verification?) -> UIColor {
        record?.kind?.isGold == true ? gold : blue
    }
    static func color(for uid: String) -> UIColor { color(for: VerificationIndex.of(uid)) }

    /// ⛔ ONE BADGE FOR EVERYBODY, THE OFFICIAL CHANNEL INCLUDED — owner 2026-10-13: the Fariin tick
    /// and a person's tick sat side by side in the chat list at two sizes and two blues (official
    /// 82% of its box, #0A84FF, semibold; a person 100%, #3DA1FD, regular). He asked for the middle
    /// of both. `VerifiedTick` and the info sheet read these three, so they cannot drift again.
    static let blue = UIColor(Color(hex: 0x2392FE))
    static let scale: CGFloat = 0.91
    static let weight: UIImage.SymbolWeight = .medium

    /// The seal as a flat picture at `size` points.
    static func badge(size: CGFloat, blue: UIColor, weight: UIImage.SymbolWeight) -> UIImage {
        let config = UIImage.SymbolConfiguration(paletteColors: [.white, blue])
            .applying(UIImage.SymbolConfiguration(pointSize: size, weight: weight))
        guard let symbol = UIImage(systemName: "checkmark.seal.fill", withConfiguration: config) else { return UIImage() }
        let fmt = UIGraphicsImageRendererFormat.preferred()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: symbol.size, format: fmt)
            .image { _ in symbol.draw(at: .zero) }
            .withRenderingMode(.alwaysOriginal)
    }
}

/// WHAT THE TICK CLAIMS, in words, one tap away.
///
/// This is the part that stops the mark being decoration. A symbol alone is unfalsifiable to the
/// person looking at it: anybody can put a tick character in their display name, and a user with no
/// way to interrogate the badge has no way to tell the two apart. A real mark can be tapped and will
/// explain itself; a tick typed into a name cannot.
struct VerificationInfoSheet: View {
    /// Nil for a group: its badge is a flag on the group, with no record behind it.
    let record: Verification?
    let peer: PeerRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // No NavigationStack (2026-10-18): it had no title or buttons, only a bar height the fitted
        // detent below could not see.
        VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white, Color(uiColor: VerifiedMark.color(for: record)))
                    .symbolRenderingMode(.palette)
                    .padding(.top, 28)

                Text("Verified")
                    .font(.system(size: 22, weight: .semibold))

                Text(record?.kind?.explanation ?? defaultExplanation)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text("Fariin reviewed this \(peer.kind == .group ? "group" : "account") and confirmed it is genuine. Verification is granted by Fariin only. It can never be bought or requested.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Owner 2026-10-17: no Done in the corner; one blue "Got it" bar at the bottom.
                // 2026-10-18 (owner): it was too tall and too far from the text. `.borderedProminent`
                // put its own padding round the 50 pt label; a plain 50 pt capsule now, 24 pt under
                // the words, and the sheet is as tall as what it holds instead of a fixed 420.
                Button { dismiss() } label: {
                    Text("Got it")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(Color(hex: 0x2392FE)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(max(300, contentHeight))])
    }

    @State private var contentHeight: CGFloat = 380

    /// An older record, or one whose kind this build has not heard of. The mark still means the one
    /// thing every mark means, so say that rather than nothing.
    private var defaultExplanation: String {
        peer.kind == .group
            ? "This group has been verified as genuine."
            : "This account has been verified as genuine."
    }
}

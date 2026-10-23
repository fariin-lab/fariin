import Foundation

// ===== WHEN A VOICE NOTE DOWNLOADS BY ITSELF =====
//
// Owner, 2026-10-23: voice notes should arrive the way they do in the reference app, read from its
// source rather than guessed. What its source does (file:line in
// `Documents/Kulan voice auto-download 2026-10-23/REPORT.md`):
//
//   - There is NO separate voice category. A voice note is filed under "files", but two rules are
//     special-cased for it: the per-chat-type switches (contacts / other private / groups / channels)
//     are skipped, and its size ceiling is never below 2 MB (`max(2 MB, file limit)`). The default
//     file limit is 1 MB on cellular and 3 MB on Wi-Fi, so a voice note downloads by itself up to
//     2 MB on cellular and 3 MB on Wi-Fi, in every kind of chat.
//   - The only thing that can stop it is the network switch for the current connection
//     (auto-download on cellular / on Wi-Fi). "No network" counts as cellular.
//   - In an open chat: every bubble that is laid out fetches at once, and the list asks for the next
//     3 media items past the visible ones, in the direction the reader is scrolling (toward older
//     history until he scrolls the other way). Not the whole history.
//
// Ours maps the reference's network switch onto the existing Audio row of Settings › Storage and
// Data (Wi-Fi and Cellular / Wi-Fi / Never). Low Data Mode counts as cellular, a rule the reference
// does not have (owner asked for it). A one-time note never downloads by itself here: its plaintext
// must exist only for its single listen.
//
// Everything in this enum is pure: no network, no disk, no clock, so `VoiceAutoDownloadTests` can
// cover every combination.
enum VoiceAutoDownload {
    enum Network: Equatable { case wifi, cellular }

    /// The reference splits private chats by contact and groups by kind; for a voice note none of
    /// that matters (the chat-type switches are skipped for voice), so ours only names the two kinds
    /// it has, to make that explicit at the call sites and in the tests.
    enum ChatKind: Equatable { case oneToOne, group }

    /// The Audio row in Storage and Data.
    enum Policy: String { case always, wifi, never }

    private static let mb: Int64 = 1024 * 1024
    /// The voice floor in the reference: a voice note's ceiling is never below this.
    static let floorBytes: Int64 = 2 * mb
    /// The reference's default file ceilings: 1 MB on cellular (its medium preset), 3 MB on Wi-Fi
    /// (its high preset).
    static func fileLimit(_ n: Network) -> Int64 { n == .wifi ? 3 * mb : 1 * mb }
    /// The voice ceiling = max(floor, file ceiling): 2 MB on cellular, 3 MB on Wi-Fi.
    static func sizeLimit(_ n: Network) -> Int64 { max(floorBytes, fileLimit(n)) }

    /// Our recorder writes AAC at 40 kbit/s (`AudioRecorder`), 5,000 bytes a second. Notes carry
    /// their length but not their size, so the size is estimated from the length, with room for the
    /// container, the seal and a forwarded note recorded a little richer. The real ceiling is still
    /// enforced on the bytes: the download job stops at the response headers when the server's length
    /// is over it (`MediaDownloads.autoLimit`).
    static func estimatedBytes(duration: Double?) -> Int64? {
        guard let d = duration, d.isFinite, d > 0 else { return nil }
        return Int64(d * 5_000 * 1.1) + 4_096
    }

    static func network(isWifi: Bool, isConstrained: Bool) -> Network {
        (isWifi && !isConstrained) ? .wifi : .cellular
    }

    struct Note: Equatable {
        var viewOnce = false
        var deleted = false
        /// There is an uploaded file to fetch (a note still uploading has none yet).
        var hasRemote = true
        /// Already on this phone.
        var cached = false
        /// A group file sealed for the members of the day, without me, and no released key.
        var sealedWithoutMe = false
        var duration: Double?
    }

    enum Skip: Equatable { case viewOnce, deleted, noFile, cached, unreadable, policy, tooLarge }
    enum Decision: Equatable {
        /// Download automatically; the job is held for a tap if the real size turns out over `limit`.
        case download(limit: Int64)
        case skip(Skip)
    }

    static func decide(_ n: Note, network: Network, policy: Policy, chat: ChatKind) -> Decision {
        _ = chat   // see ChatKind: the reference skips the chat-type switches for voice
        if n.viewOnce { return .skip(.viewOnce) }
        if n.deleted { return .skip(.deleted) }
        if !n.hasRemote { return .skip(.noFile) }
        if n.cached { return .skip(.cached) }
        if n.sealedWithoutMe { return .skip(.unreadable) }
        switch policy {
        case .never: return .skip(.policy)
        case .wifi where network != .wifi: return .skip(.policy)
        default: break
        }
        let limit = sizeLimit(network)
        if let est = estimatedBytes(duration: n.duration), est > limit { return .skip(.tooLarge) }
        return .download(limit: limit)
    }

    /// The reference asks for this many media items beyond the visible ones.
    static let ahead = 3

    /// Which rows to consider, by index into the chat's rows (oldest first).
    ///
    /// - `visible`: the rows on screen, nil before the list has reported any.
    /// - `followsNewest`: the newest row was on screen at the last report, so rows that arrived since
    ///   are on screen too (the list keeps a reader at the newest pinned there).
    /// - `towardOlder`: the reading direction; the reference's default is toward older history.
    /// - `isVoice`: whether a row is a voice note. `ahead` counts voice notes only, because this
    ///   pass downloads nothing else (photos and the rest have their own paths).
    static func window(count: Int, visible: ClosedRange<Int>?, followsNewest: Bool,
                       towardOlder: Bool, isVoice: (Int) -> Bool) -> [Int] {
        guard count > 0 else { return [] }
        var out: [Int] = []
        guard let v = visible else {
            // Nothing reported yet (the chat is still landing): the newest notes, the place a chat
            // opens at by default.
            var i = count - 1
            while i >= 0, out.count < ahead { if isVoice(i) { out.append(i) }; i -= 1 }
            return out
        }
        let lo = max(0, min(v.lowerBound, count - 1))
        var hi = max(lo, min(v.upperBound, count - 1))
        if followsNewest { hi = count - 1 }
        for i in lo...hi where isVoice(i) { out.append(i) }
        var found = 0
        if towardOlder {
            var i = lo - 1
            while i >= 0, found < ahead { if isVoice(i) { out.append(i); found += 1 }; i -= 1 }
        } else {
            var i = hi + 1
            while i < count, found < ahead { if isVoice(i) { out.append(i); found += 1 }; i += 1 }
        }
        return out
    }
}

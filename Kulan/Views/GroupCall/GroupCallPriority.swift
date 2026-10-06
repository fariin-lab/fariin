import Foundation

/// Who gets a place on screen (owner spec §13) and in what order. Pure ordering, no UI.
enum GroupCallPriority {
    /// Spec §13: "recently speaking" window.
    static let recentWindow: TimeInterval = 30

    /// Splits the self view from everyone else. The self view is a separate pip when others are
    /// present (the reference app), so it never competes for a grid place. Alone, local is the
    /// only tile and comes back in `local` with `remotes` empty.
    static func remotesFirst(_ tiles: [CallTile]) -> (local: CallTile?, remotes: [CallTile]) {
        let local = tiles.first(where: { $0.isLocal })
        let remotes = tiles.filter { !$0.isLocal }
        return (local, remotes)
    }

    /// Spec §13 order: screen-share presenter, focused, active speaker, recently speaking
    /// (lastSpokeAt within 30s, newest first), other video (by joinedAt), audio-only (by joinedAt).
    /// The local tile is left out whenever other participants exist; when alone it is returned
    /// by itself so callers always have something to show.
    static func ranked(_ tiles: [CallTile], focusedId: String?, speakerId: String?, now: Date) -> [CallTile] {
        let split = remotesFirst(tiles)
        if split.remotes.isEmpty { return split.local.map { [$0] } ?? [] }

        func tier(_ t: CallTile) -> Int {
            if t.isScreenShare { return 0 }
            if let f = focusedId, t.id == f { return 1 }
            if let s = speakerId, t.id == s { return 2 }
            if let last = t.lastSpokeAt, now.timeIntervalSince(last) <= recentWindow { return 3 }
            return t.hasVideo ? 4 : 5
        }

        return split.remotes.sorted { a, b in
            let ta = tier(a), tb = tier(b)
            if ta != tb { return ta < tb }
            if ta == 3, let la = a.lastSpokeAt, let lb = b.lastSpokeAt, la != lb { return la > lb }
            return joinOrder(a, b)
        }
    }

    /// The shown set re-sorted by join time (then id) so tiles keep their cells when ranks change.
    static func stableForGrid(_ shown: [CallTile]) -> [CallTile] {
        shown.sorted(by: joinOrder)
    }

    /// The strip's order (owner, 2026-10-06, the reference app's): the newest joiner first, so a
    /// person who just arrived is at the visible start. Still a stable order: it only moves when
    /// someone joins or leaves, never when ranks change.
    static func newestFirst(_ tiles: [CallTile]) -> [CallTile] {
        tiles.sorted { a, b in joinOrder(b, a) }
    }

    /// Join time, then identity, then id: the one stable order every list falls back to.
    static func joinOrder(_ a: CallTile, _ b: CallTile) -> Bool {
        if a.joinedAt != b.joinedAt { return a.joinedAt < b.joinedAt }
        if a.uid != b.uid { return a.uid < b.uid }
        return a.id < b.id
    }
}

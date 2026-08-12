//
//  StoryPartialFile.swift
//  StoryUI
//
//  A CLIP THAT IS ONLY PARTLY HERE, AND THE RECORD OF WHICH BYTES THOSE ARE.
//
//  ⚠️ THIS IS THE PIECE THAT MAKES A PREFIX WORTH FETCHING. Until now a story video was all-or-
//  nothing: `CacheManager` downloaded the whole object to a file and only then handed it to a player.
//  That is why the lookahead has to pull up to three WHOLE clips — the app has no way to use half of
//  one — and it is the single largest thing the app spends mobile data on without being asked, on a
//  user base that is mostly on mobile data.
//
//  The reference app's answer is a byte prefix per neighbour, sized by the server. A prefix is only
//  useful if something can play from it, which needs two things: a file that can hold arbitrary
//  ranges, and a reader that knows which ranges it holds. This is the first; `StoryVideoStream` is
//  the second.
//
//  WHY RANGES AND NOT JUST A LENGTH. A contiguous head would be simpler and would be wrong. AVPlayer
//  does not read an mp4 front to back: it reads the header, then jumps to the moov atom, then starts
//  streaming media data — and even for a faststart file (ours are: `shouldOptimizeForNetworkUse` is
//  set on every export) it issues ranges that are not in order. A reader that could only answer "the
//  first N bytes" would have to download everything up to whatever it was asked for, which is the
//  behaviour this replaces.
//

import Foundation

/// The bytes we hold for one remote object, and where.
///
/// Thread-safety is the caller's: every method here runs on `StoryVideoStream`'s own serial queue.
/// It is deliberately not internally locked — two locks around one state machine is how you get a
/// deadlock in a resource loader, which reads on screen as a story that never starts.
final class StoryPartialFile {

    /// Half-open byte ranges we have, kept sorted and non-overlapping.
    private(set) var have: [Range<Int64>] = []
    /// The object's full size once the server has told us, or nil.
    private(set) var total: Int64?
    /// The MIME type the server reported, for the content-information request.
    private(set) var contentType: String?

    private let remote: URL
    private let dataURL: URL
    private let metaURL: URL
    private var handle: FileHandle?

    init(remote: URL) {
        let dir = StoryStorage.directory("VideoCache")
        let name = CacheManager.cacheFileName(for: remote)
        self.remote = remote
        self.dataURL = dir.appendingPathComponent(name + ".part")
        self.metaURL = dir.appendingPathComponent(name + ".partmeta")
        loadMeta()
    }

    /// Where a completed download would live — the same path `CacheManager.cachedFileIfUsable`
    /// answers with, so a promoted file is indistinguishable from one that was downloaded whole.
    static func completedURL(for remote: URL) -> URL {
        StoryStorage.directory("VideoCache")
            .appendingPathComponent(CacheManager.cacheFileName(for: remote))
    }

    // MARK: - Reading

    /// TRUE when every byte of `range` is on disk.
    func holds(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        for r in have where r.lowerBound <= range.lowerBound {
            if r.upperBound >= range.upperBound { return true }
        }
        return false
    }

    /// The longest run we hold starting at `offset`, capped at `limit`. Zero when we hold nothing
    /// there — which is the reader's signal to go and fetch.
    func contiguousLength(from offset: Int64, limit: Int64) -> Int64 {
        for r in have where r.contains(offset) {
            return min(limit, r.upperBound - offset)
        }
        return 0
    }

    func read(offset: Int64, length: Int64) -> Data? {
        guard length > 0, let h = openHandle() else { return nil }
        do {
            try h.seek(toOffset: UInt64(offset))
            return try h.read(upToCount: Int(length))
        } catch {
            return nil
        }
    }

    // MARK: - Writing

    func note(total: Int64, contentType: String?) {
        if self.total != total { self.total = total }
        if let contentType { self.contentType = contentType }
        saveMeta()
    }

    func write(offset: Int64, data: Data) {
        guard !data.isEmpty, let h = openHandle() else { return }
        do {
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: data)
            merge(offset ..< (offset + Int64(data.count)))
            saveMeta()
        } catch {
            // A write that fails leaves the range unrecorded, so the reader simply fetches it again.
            // Recording it anyway is the one thing that would be unrecoverable: a hole the reader
            // believes is filled is a clip that decodes garbage.
        }
    }

    /// Every byte is here. Move it to the plain cache path so the next open needs no reader at all,
    /// and so `StoryStorage`'s existing purge and 300MB ceiling manage it like any other clip.
    @discardableResult
    func promoteIfComplete() -> URL? {
        guard let total, total > 0, holds(0 ..< total) else { return nil }
        closeHandle()
        let dest = Self.completedURL(for: remote)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: dataURL, to: dest)
            try? FileManager.default.removeItem(at: metaURL)
            have = []
            return dest
        } catch {
            return nil
        }
    }

    /// Throw the partial away — a truncated or mis-recorded file is worse than no file, because it
    /// is found by every later open and never re-fetched.
    func discard() {
        closeHandle()
        try? FileManager.default.removeItem(at: dataURL)
        try? FileManager.default.removeItem(at: metaURL)
        have = []
        total = nil
    }

    // MARK: - Internals

    private func merge(_ new: Range<Int64>) {
        var out: [Range<Int64>] = []
        var cur = new
        for r in have.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if r.upperBound < cur.lowerBound { out.append(r); continue }
            if r.lowerBound > cur.upperBound { out.append(cur); cur = r; continue }
            cur = min(r.lowerBound, cur.lowerBound) ..< max(r.upperBound, cur.upperBound)
        }
        out.append(cur)
        have = out.sorted { $0.lowerBound < $1.lowerBound }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dataURL.path) {
            fm.createFile(atPath: dataURL.path, contents: nil)
        }
        handle = try? FileHandle(forUpdating: dataURL)
        return handle
    }

    private func closeHandle() {
        if let handle { try? handle.close() }
        handle = nil
    }

    private struct Meta: Codable {
        var total: Int64?
        var contentType: String?
        var ranges: [[Int64]]
    }

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let m = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        // ⚠️ THE FILE HAS TO STILL BE THERE. A meta that outlives its data — the purge takes files by
        // age and does not know these two belong together — would have the reader answer from a hole.
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            try? FileManager.default.removeItem(at: metaURL)
            return
        }
        total = m.total
        contentType = m.contentType
        have = m.ranges.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0] ..< $0[1] : nil }
    }

    private func saveMeta() {
        let m = Meta(total: total, contentType: contentType, ranges: have.map { [$0.lowerBound, $0.upperBound] })
        guard let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}

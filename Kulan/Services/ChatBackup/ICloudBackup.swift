import Foundation
import CloudKit
import Sodium

/// CHAT BACKUP TO THE PERSON'S OWN iCLOUD (phase 3, D6 / D13 of the device-storage plan). The archive
/// (BackupArchive, format v1, same bytes as Android's Google Drive copy) goes to the PRIVATE CloudKit
/// database of the default container: it counts against the person's iCloud space, we never see it,
/// and nothing in it is readable without the archive key.
///
/// Layout, in one zone "FariinBackup":
/// - one `BackupFile` record per archive file, named "<set>-<file name>", fields `name`, `set`,
///   `file` (CKAsset);
/// - one `BackupHeader` record named "header", fields `json` (header.json), `set`, `names` (the
///   file names of that set), `made` (ms), `size` (bytes of every file).
///
/// Records are fetched by name only (no queries), so the CloudKit schema needs no indexes.
/// A new backup is uploaded in full under a new set id; only then does "header" switch to it, and
/// only after that are the old set's files deleted. A backup cut off halfway leaves the old one
/// whole, and its loose files are swept at the start of the next backup.
///
/// ⛔ Refuses to run while `ChatBackup.enabled` is false. CloudKit itself also needs the iCloud
/// entitlement, which this build does not have: `CKContainer.default()` must not be touched before
/// that (it stops the app), which is why every path checks the switch first.
actor ICloudBackup {
    static let shared = ICloudBackup()

    enum Failure: LocalizedError {
        case off
        case noICloud
        case noBackup
        case busy
        case damaged
        case cloud(String)

        var errorDescription: String? {
            switch self {
            case .off: return "Chat backup is not available yet."
            case .noICloud: return "Sign in to iCloud in Settings to back up your chats."
            case .noBackup: return "There is no chat backup in your iCloud."
            case .busy: return "A backup is already running."
            case .damaged: return "The backup in your iCloud could not be opened."
            case .cloud(let s): return s
            }
        }
    }

    struct Info {
        let made: Date
        /// Bytes of every file of the backup, as stored in iCloud.
        let size: Int64
    }

    private static let zoneName = "FariinBackup"
    private static let fileType = "BackupFile"
    private static let headerType = "BackupHeader"
    private static let headerRecordName = "header"
    /// Files per CloudKit request (each at most ~2 MiB).
    private static let batch = 10

    private var busy = false
    private var zoneReady = false

    private var database: CKDatabase { CKContainer.default().privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName) }
    private var headerID: CKRecord.ID { CKRecord.ID(recordName: Self.headerRecordName, zoneID: zoneID) }

    // MARK: - Public

    /// Backs up `uid`'s whole local database now. `password` (optional, at least 8 characters, or the
    /// 64-digit key) adds a second lock beside the iCloud Keychain one. Returns the new backup.
    @discardableResult
    func backupNow(uid: String, password: String? = nil) async throws -> Info {
        guard ChatBackup.enabled else { throw Failure.off }
        guard !uid.isEmpty else { throw Failure.damaged }
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }

        try await checkAccount()
        try await ensureZone()
        guard let storeKey = BackupStoreKey.getOrCreate(uid: uid),
              let archiveKey = BackupArchive.newKey() else { throw BackupArchive.Failure.crypto }

        let old = try await headerRecord()
        try await sweepPending(uid: uid, keep: old.map(Self.recordNames) ?? [])

        let made = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fariin-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Reading the database and sealing the files: plain blocking work, off this actor.
        let names = try await Task.detached(priority: .utility) { () throws -> [String] in
            try BackupArchive.writeFiles(uid: uid, archiveKey: archiveKey, made: made, to: dir)
        }.value
        let header = try await BackupArchive.makeHeader(archiveKey: archiveKey, storeKey: storeKey,
                                                        password: password, made: made)
        let headerJSON = try BackupArchive.encodeHeader(header)

        let set = UUID().uuidString.lowercased()
        var size = Int64(headerJSON.count)
        var records: [CKRecord] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            size += bytes
            let r = CKRecord(recordType: Self.fileType,
                             recordID: CKRecord.ID(recordName: Self.recordName(set: set, file: name), zoneID: zoneID))
            r["name"] = name
            r["set"] = set
            r["file"] = CKAsset(fileURL: url)
            records.append(r)
        }

        // 1. Every file of the new set. Remembered first, so a cut-off upload is swept next time.
        Self.setPending(uid: uid, records.map { $0.recordID.recordName })
        for start in stride(from: 0, to: records.count, by: Self.batch) {
            try await save(Array(records[start..<min(start + Self.batch, records.count)]))
        }

        // 2. The header switches to the new set: from here on, restore reads the new backup.
        let h = CKRecord(recordType: Self.headerType, recordID: headerID)
        h["json"] = headerJSON
        h["set"] = set
        h["names"] = names
        h["made"] = made
        h["size"] = size
        try await save([h])
        Self.setPending(uid: uid, nil)

        // 3. Only now the old set goes.
        if let old {
            let fresh = Set(records.map { $0.recordID.recordName })
            let gone = Self.recordNames(old).filter { !fresh.contains($0) }
            await deleteQuietly(gone)
        }
        return Info(made: Date(timeIntervalSince1970: Double(made) / 1000), size: size)
    }

    /// The backup now in iCloud (when it was made, how big), or nil when there is none.
    func latestBackup() async throws -> Info? {
        guard ChatBackup.enabled else { throw Failure.off }
        try await checkAccount()
        guard let h = try await headerRecord() else { return nil }
        let made = (h["made"] as? NSNumber)?.int64Value ?? 0
        let size = (h["size"] as? NSNumber)?.int64Value ?? 0
        return Info(made: Date(timeIntervalSince1970: Double(made) / 1000), size: size)
    }

    /// Downloads the backup and files its rows into `uid`'s local database. Opens it with this
    /// phone's iCloud Keychain key, or with `password` when the key is not here. Throws
    /// `BackupArchive.Failure.needsPassword` when only a password can open it, `.wrongPassword`,
    /// `.otherAccount` for another account's backup. Returns how many messages were filed.
    @discardableResult
    func restore(uid: String, password: String? = nil) async throws -> Int {
        guard ChatBackup.enabled else { throw Failure.off }
        guard !uid.isEmpty else { throw Failure.damaged }
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }

        try await checkAccount()
        guard let h = try await headerRecord() else { throw Failure.noBackup }
        guard let json = h["json"] as? Data, let set = h["set"] as? String else { throw Failure.damaged }
        let header = try BackupArchive.parseHeader(json)
        let archiveKey = try await BackupArchive.unwrap(header, storeKey: BackupStoreKey.get(uid: uid),
                                                        password: password)

        let manifestFile = try await download([BackupArchive.manifestName], set: set)
        guard let mf = manifestFile[BackupArchive.manifestName] else { throw Failure.damaged }
        let manifest = try BackupArchive.readManifest(mf, key: archiveKey)
        guard manifest.uid == uid else { throw BackupArchive.Failure.otherAccount }

        var filed = 0
        for start in stride(from: 0, to: manifest.chunks.count, by: Self.batch) {
            let names = Array(manifest.chunks[start..<min(start + Self.batch, manifest.chunks.count)])
            let files = try await download(names, set: set)
            for name in names {
                guard let file = files[name] else { throw Failure.damaged }
                filed += try await Task.detached(priority: .utility) { () throws -> Int in
                    let rows = try BackupArchive.readRows(file, key: archiveKey)
                    return LocalMessageDB.shared.insertRows(uid: uid, rows: rows)
                }.value
            }
        }

        let chatsFile = try await download([BackupArchive.chatsName], set: set)
        if let cf = chatsFile[BackupArchive.chatsName] {
            try await Task.detached(priority: .utility) { () throws -> Void in
                let rows = try BackupArchive.readRows(cf, key: archiveKey)
                LocalMessageDB.shared.insertChatRows(uid: uid, rows: rows)
            }.value
        }
        return filed
    }

    // MARK: - CloudKit

    private func checkAccount() async throws {
        let status: CKAccountStatus
        do {
            status = try await CKContainer.default().accountStatus()
        } catch {
            throw Failure.cloud(error.localizedDescription)
        }
        guard status == .available else { throw Failure.noICloud }
    }

    private func ensureZone() async throws {
        if zoneReady { return }
        let zone = CKRecordZone(zoneID: zoneID)
        let result = try await retrying {
            try await self.database.modifyRecordZones(saving: [zone], deleting: [])
        }
        if case .failure(let e)? = result.saveResults[zoneID] { throw Failure.cloud(e.localizedDescription) }
        zoneReady = true
    }

    /// The "header" record, or nil when there is no backup (or no zone yet).
    private func headerRecord() async throws -> CKRecord? {
        do {
            return try await retrying { try await self.database.record(for: self.headerID) }
        } catch let e as CKError where e.code == .unknownItem || e.code == .zoneNotFound {
            return nil
        }
    }

    /// Saves records, overwriting what is there. Throws on the first record that failed.
    private func save(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        let result = try await retrying {
            try await self.database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        }
        for (_, r) in result.saveResults {
            if case .failure(let e) = r { throw Failure.cloud(e.localizedDescription) }
        }
    }

    /// The files of `set` with these names, as bytes. A missing record is missing from the result.
    private func download(_ names: [String], set: String) async throws -> [String: Data] {
        let ids = names.map { CKRecord.ID(recordName: Self.recordName(set: set, file: $0), zoneID: zoneID) }
        let fetched = try await retrying { try await self.database.records(for: ids) }
        var out: [String: Data] = [:]
        for (name, id) in zip(names, ids) {
            guard case .success(let r)? = fetched[id] else { continue }
            if let asset = r["file"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) {
                out[name] = data
            }
        }
        return out
    }

    /// Deletes records by name; failures (already gone, offline) are left for the next sweep.
    private func deleteQuietly(_ recordNames: [String]) async {
        let ids = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        for start in stride(from: 0, to: ids.count, by: 100) {
            let part = Array(ids[start..<min(start + 100, ids.count)])
            _ = try? await database.modifyRecords(saving: [], deleting: part, savePolicy: .allKeys, atomically: false)
        }
    }

    /// Files a cut-off backup left behind (remembered on this phone), except those `keep` still uses.
    private func sweepPending(uid: String, keep: [String]) async throws {
        guard let pending = Self.pending(uid: uid), !pending.isEmpty else { return }
        let keepSet = Set(keep)
        await deleteQuietly(pending.filter { !keepSet.contains($0) })
        Self.setPending(uid: uid, nil)
    }

    /// Runs a CloudKit call again (up to 3 tries) when CloudKit says to wait or the network dropped.
    private func retrying<T>(_ work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch let e as CKError where attempt < 2 && Self.isTransient(e) {
                attempt += 1
                let wait = e.retryAfterSeconds ?? Double(attempt * 2)
                try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
            }
        }
    }

    private static func isTransient(_ e: CKError) -> Bool {
        switch e.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }

    // MARK: - Names

    private static func recordName(set: String, file: String) -> String { "\(set)-\(file)" }

    private static func recordNames(_ header: CKRecord) -> [String] {
        guard let set = header["set"] as? String, let names = header["names"] as? [String] else { return [] }
        return names.map { recordName(set: set, file: $0) }
    }

    private static func pending(uid: String) -> [String]? {
        UserDefaults.standard.stringArray(forKey: "chatBackup.pending.\(uid)")
    }

    private static func setPending(uid: String, _ names: [String]?) {
        if let names {
            UserDefaults.standard.set(names, forKey: "chatBackup.pending.\(uid)")
        } else {
            UserDefaults.standard.removeObject(forKey: "chatBackup.pending.\(uid)")
        }
    }
}

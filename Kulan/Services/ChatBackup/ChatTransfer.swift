import Foundation
import Security
import Sodium
import FirebaseStorage

/// ⛔ PHONE-TO-PHONE CHAT TRANSFER IS OFF. Phase 4 of the device-storage plan (Documents/fariin-plans/
/// 2026-11-12-device-storage-plan.md, "Phase 4 phone-to-phone transfer by QR"; the Android app does
/// the same, byte for byte). Nothing in the app shows it while this is false.
///
/// How it works:
/// - OLD phone: a one-time 32-byte TRANSFER key and a backup archive v1 (BackupArchive) whose
///   header.json has `kdf: null` and `wrapped.store` = nonce||secretbox(archive key) under the
///   transfer key (no password wrap). Every file goes to Firebase Storage
///   `transfer/{uid}/{tid}/<file name>`, header.json last, then the QR shows
///   `fariin-transfer:v1:<tid>:<key>:<file count>`.
/// - The key lives only in the QR, never on the server: the files are useless without it.
/// - NEW phone (same account): scans, downloads, opens the archive with the transfer key, files the
///   rows through the wire converter, sets meta "restored" = made, then deletes the files (header.json
///   last). The old phone sees the folder empty and says so.
/// - The server deletes transfer folders older than an hour (and a 1-day lifecycle rule backs it up).
enum ChatTransfer {
    /// ON for test builds (owner 2026-11-12). Server kill switch: config/features.chatTransfer = false.
    static var enabled: Bool { RemoteFeatures.offOnly("chatTransfer", default: true) }

    static let scheme = "fariin-transfer"
    static let version = "v1"
    /// The code works for this long after it is made (the server sweeps older folders).
    static let lifetime: TimeInterval = 3600
    static let tidBytes = 16
    /// Storage rule: files under 20 MB.
    static let maxFileBytes: Int64 = 20 * 1024 * 1024
    /// header.json + manifest.bin + chats.bin at the least.
    static let minFiles = 3
    static let maxFiles = 99_999

    /// The QR text: `fariin-transfer:v1:<tid>:<key>:<files>`.
    /// - `tid`: 16 random bytes, base64url without padding (22 characters), the Storage folder name.
    /// - `key`: the 32-byte transfer key, base64url without padding (43 characters).
    /// - `files`: how many files are in the folder, header.json included (decimal, no sign).
    struct Code: Equatable {
        let tid: String
        let key: Bytes
        let files: Int

        var text: String { "\(ChatTransfer.scheme):\(ChatTransfer.version):\(tid):\(ChatTransfer.b64url(key)):\(files)" }

        /// Strict: exactly five parts, the agreed scheme and version, canonical base64url of the right
        /// lengths, a plain decimal count. Anything else is not a transfer code.
        static func parse(_ text: String) -> Code? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts[0] == ChatTransfer.scheme, parts[1] == ChatTransfer.version else { return nil }
            let tid = parts[2], keyText = parts[3], count = parts[4]
            guard let t = ChatTransfer.unb64url(tid), t.count == ChatTransfer.tidBytes,
                  ChatTransfer.b64url(t) == tid,
                  let k = ChatTransfer.unb64url(keyText), k.count == BackupArchive.keyBytes,
                  ChatTransfer.b64url(k) == keyText,
                  !count.isEmpty, count.count <= 5,
                  count.unicodeScalars.allSatisfy(ChatTransfer.isDigit),
                  !(count.count > 1 && count.hasPrefix("0")),
                  let n = Int(count), (ChatTransfer.minFiles...ChatTransfer.maxFiles).contains(n) else { return nil }
            return Code(tid: tid, key: k, files: n)
        }
    }

    enum Failure: LocalizedError, Equatable {
        case off
        case expired
        case notACode
        case otherAccount
        case noConnection
        case newerVersion
        case notReady

        var errorDescription: String? {
            switch self {
            case .off: return "Chat transfer is not available yet."
            case .expired: return "This code has expired"
            case .notACode: return "That's not a Fariin transfer code"
            case .otherAccount: return "This code is for another account"
            case .noConnection: return "No connection. Try again."
            case .newerVersion: return "This code was made by a newer Fariin. Update the app first."
            case .notReady: return "Couldn't get your chats ready. Try again."
            }
        }
    }

    // MARK: - Old phone

    /// Makes the archive, uploads it, and returns the code to show. `progress(done, total)` counts
    /// uploaded files. Throws `Failure`.
    static func send(uid: String, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Code {
        guard enabled else { throw Failure.off }
        guard !uid.isEmpty,
              let transferKey = BackupArchive.newKey(),
              let archiveKey = BackupArchive.newKey(),
              let tidRaw = randomBytes(tidBytes) else { throw Failure.notReady }
        let tid = b64url(tidRaw)
        let made = Int64((Date().timeIntervalSince1970 * 1000).rounded())

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fariin-transfer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw Failure.notReady
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let names: [String]
        let headerJSON: Data
        do {
            // Reading the database and sealing the files: blocking work, off the main thread.
            names = try await Task.detached(priority: .userInitiated) { () throws -> [String] in
                try BackupArchive.writeFiles(uid: uid, archiveKey: archiveKey, made: made, to: dir)
            }.value
            let header = try await BackupArchive.makeHeader(archiveKey: archiveKey, storeKey: transferKey,
                                                            password: nil, made: made)
            headerJSON = try BackupArchive.encodeHeader(header)
        } catch {
            throw Failure.notReady
        }
        try Task.checkCancellation()

        // header.json goes LAST: while it is missing the new phone reads "expired", never half a folder.
        let all = names + [BackupArchive.headerName]
        let folder = folderRef(uid: uid, tid: tid)
        let meta = StorageMetadata()
        meta.contentType = "application/octet-stream"
        var uploaded: [String] = []
        await progress(0, all.count)
        do {
            for name in all {
                try Task.checkCancellation()
                let data = name == BackupArchive.headerName
                    ? headerJSON
                    : try Data(contentsOf: dir.appendingPathComponent(name))
                guard Int64(data.count) < maxFileBytes else { throw Failure.notReady }
                _ = try await folder.child(name).putDataAsync(data, metadata: meta)
                uploaded.append(name)
                await progress(uploaded.count, all.count)
            }
        } catch {
            // Half a transfer is no use to anyone: take back what went up (the server sweeps the rest).
            for name in uploaded { try? await folder.child(name).delete() }
            if error is CancellationError { throw error }
            throw plain(error)
        }
        return Code(tid: tid, key: transferKey, files: all.count)
    }

    /// Has the new phone taken the files? true = the folder is empty, false = still there, nil = can't
    /// tell right now (offline, or this phone was signed out by the new one).
    static func pickedUp(uid: String, tid: String) async -> Bool? {
        let folder = folderRef(uid: uid, tid: tid)
        if let list = try? await folder.listAll() {
            return list.items.isEmpty
        }
        // Listing refused or failed: header.json is deleted last, so its absence says the same.
        do {
            _ = try await folder.child(BackupArchive.headerName).getMetadata()
            return false
        } catch {
            return isNotFound(error) ? true : nil
        }
    }

    // MARK: - New phone

    /// Downloads the transfer, files its rows into `uid`'s local database, sets meta "restored", and
    /// deletes the files. `progress(done, total)` counts downloaded files. Returns how many messages
    /// were filed. Throws `Failure`.
    @discardableResult
    static func receive(_ code: Code, uid: String, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Int {
        guard enabled else { throw Failure.off }
        guard !uid.isEmpty else { throw Failure.notACode }
        let folder = folderRef(uid: uid, tid: code.tid)
        var total = code.files
        var done = 0
        await progress(done, total)

        // 1. header.json, opened with the transfer key.
        let headerData = try await download(folder, BackupArchive.headerName)
        done += 1
        await progress(done, total)
        let archiveKey: Bytes
        do {
            let header = try BackupArchive.parseHeader(headerData)
            archiveKey = try await BackupArchive.unwrap(header, storeKey: code.key, password: nil)
        } catch BackupArchive.Failure.newerVersion {
            throw Failure.newerVersion
        } catch {
            throw Failure.notACode
        }

        // 2. manifest.bin: whose chats, and which chunks.
        let manifestData = try await download(folder, BackupArchive.manifestName)
        done += 1
        let manifest: BackupArchive.Manifest
        do {
            manifest = try BackupArchive.readManifest(manifestData, key: archiveKey)
        } catch {
            throw Failure.notACode
        }
        guard manifest.uid == uid else { throw Failure.otherAccount }
        total = manifest.chunks.count + 3
        await progress(done, total)

        // 3. The message chunks, filed one at a time.
        var filed = 0
        // safety review 2026-11-12: a chat with any row that did not convert or file gets no mark.
        var lost = LocalMessageDB.RowLoss()
        for name in manifest.chunks {
            try Task.checkCancellation()
            let file = try await download(folder, name)
            let got = try await Task.detached(priority: .userInitiated) { () throws -> (Int, LocalMessageDB.RowLoss) in
                let read = try BackupArchive.readMessageRows(file, key: archiveKey)
                let put = LocalMessageDB.shared.insertRows(uid: uid, rows: read.rows)
                var loss = read.lost
                loss.merge(put.lost)
                return (put.written, loss)
            }.value
            filed += got.0
            lost.merge(got.1)
            done += 1
            await progress(done, total)
        }

        // 4. chats.bin last: filing it rebuilds every chat's list row from the messages now here.
        let chatsData = try await download(folder, BackupArchive.chatsName)
        let lostRows = lost
        try await Task.detached(priority: .userInitiated) { () throws -> Void in
            let rows = try BackupArchive.readRows(chatsData, key: archiveKey)
            LocalMessageDB.shared.insertChatRows(uid: uid, rows: lostRows.withoutMarks(rows))
        }.value
        done += 1
        await progress(done, total)

        // ⛔ safety review 2026-11-12: "restored" only when every row of the archive was filed. A
        // partial transfer leaves the restore question open for a better source.
        if filed > 0, filed == manifest.count {
            let made = manifest.made > 0 ? manifest.made : Int64((Date().timeIntervalSince1970 * 1000).rounded())
            LocalMessageDB.shared.setMeta(uid: uid, key: "restored", String(made))
        }

        // 5. The files go; header.json last (the old phone watches for the folder to empty).
        let names = [BackupArchive.manifestName] + manifest.chunks + [BackupArchive.chatsName, BackupArchive.headerName]
        for name in names { try? await folder.child(name).delete() }
        return filed
    }

    // MARK: - Helpers

    static func folderRef(uid: String, tid: String) -> StorageReference {
        Storage.storage().reference().child("transfer/\(uid)/\(tid)")
    }

    private static func download(_ folder: StorageReference, _ name: String) async throws -> Data {
        do {
            return try await folder.child(name).data(maxSize: maxFileBytes)
        } catch {
            throw plain(error)
        }
    }

    /// Any error in the agreed plain words.
    static func plain(_ error: Error) -> Failure {
        if let f = error as? Failure { return f }
        if isNotFound(error) { return .expired }
        return .noConnection
    }

    private static func isNotFound(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == StorageErrorDomain && ns.code == StorageErrorCode.objectNotFound.rawValue
    }

    private static func randomBytes(_ n: Int) -> Bytes? {
        var b = Bytes(repeating: 0, count: n)
        guard SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess else { return nil }
        return b
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "0"..."9": return true
        default: return false
        }
    }

    private static func isB64urlScalar(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
        default: return false
        }
    }

    /// base64url without padding (RFC 4648 section 5).
    static func b64url(_ b: Bytes) -> String {
        Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unb64url(_ s: String) -> Bytes? {
        guard !s.isEmpty, s.unicodeScalars.allSatisfy(isB64urlScalar) else { return nil }
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        guard let d = Data(base64Encoded: t) else { return nil }
        return Bytes(d)
    }
}

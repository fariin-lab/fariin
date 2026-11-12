import Foundation
import FirebaseFunctions

/// Chat media on Cloudflare R2 (agreed iOS + Android 2026-11-12; server `mediaSign`).
///
/// A media url field that starts with "r2:" names an object in the private bucket:
/// "r2:chat/{cid}/{file}". It is never fetched as it is: `downloadURL` asks the server for a short
/// presigned link first. New uploads go to R2 only while config/features.r2Media is on; until then
/// everything stays on Firebase Storage, and r2: links (from the other app) are still read.
///
/// Link previews and wallpapers stay on Storage (their rules want https links).
/// Deleting: the author's own delete-for-everyone removes R2 files through `delete` (server checks
/// the author). TODO: the server's cursor delete and sweeps do not remove R2 objects yet.
enum R2Media {
    static var uploadsOn: Bool { RemoteFeatures.value("r2Media", default: false) }

    static func isRef(_ s: String?) -> Bool { s?.hasPrefix("r2:") == true }

    /// Storage path → whether a new upload to it goes to R2 now.
    static func takes(path: String) -> Bool {
        uploadsOn && path.hasPrefix("chat/") && !path.hasSuffix("-lp.enc")
    }

    enum Failure: LocalizedError {
        case badReply
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .badReply: return "The media server gave no link."
            case .http(let code): return "Media upload failed (\(code))."
            }
        }
    }

    private struct Signed { let url: URL; let until: Date }

    /// Presigned GET links last 15 minutes on the server; reused here for 12.
    private actor Links {
        var map: [String: Signed] = [:]
        func get(_ key: String) -> URL? {
            guard let s = map[key], s.until > Date() else { map[key] = nil; return nil }
            return s.url
        }
        func put(_ key: String, _ url: URL) {
            if map.count > 500 { map.removeAll() }
            map[key] = Signed(url: url, until: Date().addingTimeInterval(12 * 60))
        }
    }
    private static let links = Links()

    private static var callable: HTTPSCallable {
        Functions.functions(region: "me-central1").httpsCallable("mediaSign")
    }

    /// A fetchable https link for an "r2:" reference.
    static func downloadURL(_ ref: String) async throws -> URL {
        let key = String(ref.dropFirst(3))
        if let u = await links.get(key) { return u }
        let res = try await callable.call(["op": "get", "key": key])
        guard let d = res.data as? [String: Any], let s = d["url"] as? String, let u = URL(string: s) else {
            throw Failure.badReply
        }
        await links.put(key, u)
        return u
    }

    /// Any media url field → a fetchable URL (https as it is; r2: through the server).
    static func fetchable(_ s: String) async throws -> URL {
        if isRef(s) { return try await downloadURL(s) }
        guard let u = URL(string: s) else { throw Failure.badReply }
        return u
    }

    /// Removes one "r2:" file; the server allows only the message's author.
    static func delete(_ ref: String) async throws {
        _ = try await callable.call(["op": "delete", "key": String(ref.dropFirst(3))])
    }

    /// Uploads the (already encrypted) bytes to `path` and returns the "r2:" reference to store.
    static func upload(_ bytes: Data, path: String, contentType: String) async throws -> String {
        let res: HTTPSCallableResult
        do {
            res = try await callable.call(["op": "put", "key": path, "size": bytes.count,
                                           "contentType": contentType])
        } catch let e as NSError where e.domain == FunctionsErrorDomain
                    && e.code == FunctionsErrorCode.alreadyExists.rawValue {
            // A retry whose first try landed (create-only, like Storage's same-bytes retry).
            return "r2:" + path
        }
        guard let d = res.data as? [String: Any], let s = d["url"] as? String, let u = URL(string: s) else {
            throw Failure.badReply
        }
        var req = URLRequest(url: u)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: req, from: bytes)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return "r2:" + path
    }
}

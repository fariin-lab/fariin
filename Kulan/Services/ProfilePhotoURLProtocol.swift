import Foundation
import FirebaseStorage

/// Profile photos are named `fariin-photo://profiles/<uid>.jpg?v=<ms>` and fetched through here.
///
/// ⛔ WHY NOT A DOWNLOAD URL — owner, 2026-09-25: a photo set to "No One" still showed in other
/// people's chat lists. A Firebase download URL carries a token that skips the storage rules, and it
/// was copied into the user record and every conversation, so the privacy setting could only ever be
/// a screen-level hide. This fetches with the signed-in Storage SDK instead, so `storage.rules`
/// (`canSeePhoto`) decides per viewer, on every download.
///
/// Registered on `MediaSession.shared`, which is what every avatar, poster and palette loader already
/// downloads with, so none of those call sites had to change. A refusal comes back as HTTP 403 with
/// no body: `UIImage(data:)` is nil and each loader falls back to the initial, as it does for a
/// person with no photo.
///
/// `v` changes whenever the photo, the audience or the Hide From list changes (see
/// `ProfileStore.republishPhoto`), so a new name misses every cache and the rules are asked again.
final class ProfilePhotoURLProtocol: URLProtocol {
    static let scheme = "fariin-photo"

    /// `fariin-photo://profiles/abc.jpg?v=1` → `profiles/abc.jpg`. Nil for anything else.
    static func storagePath(_ url: URL) -> String? {
        guard url.scheme == scheme, let host = url.host, !host.isEmpty else { return nil }
        let path = host + url.path
        guard path.hasPrefix("profiles/"), !path.contains("..") else { return nil }
        return path
    }

    static func reference(path: String, version: Int64) -> String {
        "\(scheme)://\(path)?v=\(version)"
    }

    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == scheme
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let path = Self.storagePath(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Storage.storage().reference(withPath: path).getData(maxSize: 12 * 1024 * 1024) { [weak self] data, error in
            guard let self, !self.cancelled else { return }
            if let data, error == nil {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "image/jpeg"])!
                self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            let code = (error as NSError?).flatMap { StorageErrorCode(rawValue: $0.code) }
            if code == .unauthorized || code == .objectNotFound {
                // Not allowed to see it, or there is nothing there: an empty 403/404, which every
                // loader already treats as "no picture".
                let status = code == .unauthorized ? 403 : 404
                let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.client?.urlProtocol(self, didFailWithError: error ?? URLError(.unknown))
            }
        }
    }

    override func stopLoading() { cancelled = true }
}

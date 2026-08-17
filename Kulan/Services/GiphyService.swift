import Foundation
import FirebaseFunctions

// Custom (lightweight) Giphy client — calls Giphy's REST API directly. The API key is fetched
// once from the `giphyKey` Cloud Function (kept out of this public repo), then cached.
@MainActor
final class GiphyService {
    static let shared = GiphyService()
    private init() {}

    struct Gif: Identifiable, Hashable {
        let id: String
        let url: String       // animated GIF url (fixed_width)
        let width: Double
        let height: Double
    }

    /// ⚠️ KEPT ACROSS LAUNCHES, not just for the session.
    ///
    /// This was memory-only, so the FIRST tap on GIF after every launch paid a Cloud Function round
    /// trip before Giphy was even contacted — and only then a second round trip for the pictures.
    /// Two waits, in series, every launch, for a key that does not change.
    ///
    /// It is a Giphy content key, not a user secret: it is rate-limit scoped, carries nothing about
    /// anybody, and is already handed to every client that opens the picker. The Cloud Function
    /// exists to keep it out of a public repo, and it still does — this only stops us asking for the
    /// same answer on every launch.
    private static let keyDefault = "giphy.key.v1"

    private var apiKey: String? {
        get { UserDefaults.standard.string(forKey: Self.keyDefault) }
        set { UserDefaults.standard.set(newValue, forKey: Self.keyDefault) }
    }

    private func key() async -> String? {
        if let apiKey, !apiKey.isEmpty { return apiKey }
        let res = try? await Functions.functions(region: "me-central1").httpsCallable("giphyKey").call()
        let fetched = (res?.data as? [String: Any])?["key"] as? String
        if let fetched, !fetched.isEmpty { apiKey = fetched }
        return fetched
    }

    /// Fetch the key WITHOUT asking for any pictures, so the composer can pay that cost quietly
    /// before the GIF button is ever pressed. No-op once it is on the phone.
    func warmKey() async { _ = await key() }

    func search(_ q: String) async -> [Gif] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        return await fetch(path: trimmed.isEmpty ? "trending" : "search", query: trimmed.isEmpty ? nil : trimmed)
    }

    /// STICKERS, WHICH ARE A DIFFERENT ENDPOINT AND NOT A DIFFERENT SEARCH — `/v1/stickers/…` rather
    /// than `/v1/gifs/…`.
    ///
    /// ⚠️ THE DIFFERENCE THAT MATTERS IS THE ALPHA CHANNEL. Everything under `stickers` is drawn on
    /// transparency; everything under `gifs` is a rectangle, usually on white. Searching the GIF
    /// endpoint for "sticker" returns pictures OF stickers with a white box round them, which on a
    /// story is a white box on somebody's photograph. There is no way to get one from the other.
    func searchStickers(_ q: String) async -> [Gif] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        return await fetch(path: trimmed.isEmpty ? "trending" : "search",
                           query: trimmed.isEmpty ? nil : trimmed, stickers: true)
    }

    private func fetch(path: String, query: String?, stickers: Bool = false) async -> [Gif] {
        let kind = stickers ? "stickers" : "gifs"
        guard let key = await key(), var c = URLComponents(string: "https://api.giphy.com/v1/\(kind)/\(path)") else { return [] }
        var items = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "rating", value: "pg-13"),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        c.queryItems = items
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { g in
            guard let id = g["id"] as? String,
                  let images = g["images"] as? [String: Any],
                  let fixed = images["fixed_width"] as? [String: Any],
                  let gurl = fixed["url"] as? String else { return nil }
            let w = Double(fixed["width"] as? String ?? "200") ?? 200
            let h = Double(fixed["height"] as? String ?? "200") ?? 200
            return Gif(id: id, url: gurl, width: w, height: h)
        }
    }
}

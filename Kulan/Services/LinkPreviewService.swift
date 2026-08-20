import Foundation
import UIKit

// Open-Graph link previews, SENDER-SIDE (the reference app's model, adopted 2026-07-29 with the user's reference
// screenshots). The sender's device fetches the page once while composing; the preview — title,
// description, image — travels INSIDE the encrypted message. The recipient never contacts the site:
// no IP leak to whoever runs the link, and the card renders instantly from the message itself.
//
// This file started as a VIEWER-side fetcher (every reader's phone pinged the URL at display time).
// That was both the privacy leak the reference app's design exists to avoid, and the reason cards often failed
// to appear at all — sites like x.com serve an empty JS shell to in-app fetchers, so the reader saw
// nothing. When even the sender's fetch fails, the message simply carries no preview — exactly
// the reference app's behaviour.
actor LinkPreviewService {
    static let shared = LinkPreviewService()

    /// A composer draft: everything the card needs, still plaintext, still local.
    struct LinkDraft: Equatable {
        let url: URL
        let title: String
        let desc: String
        let image: UIImage?
        var host: String { url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
        /// The bytes that travel (re-encoded, bounded) — nil when the page had no usable image.
        var imageJPEG: Data? { image?.jpegData(compressionQuality: 0.75) }
    }

    private var cache: [String: LinkDraft?] = [:]     // value nil = fetched, no usable preview
    private var inFlight: [String: Task<LinkDraft?, Never>] = [:]

    func draft(for url: URL) async -> LinkDraft? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }
        // ⛔ OUR OWN PROFILE LINKS ARE ANSWERED FROM THE ACCOUNT, NOT FROM THE WEB PAGE. Scraping
        // fariin.com/u/<handle> gets whatever the site serves, which knows nothing about the person
        // — so a shared profile arrived as a bare link. The card is built here, on the SENDER's
        // device, and travels with the message like every other preview in this app: a snapshot, so
        // a name or photo changed next week does not rewrite what was sent today.
        let task = Task<LinkDraft?, Never> {
            if let handle = Self.profileHandle(in: url) {
                return await Self.profileDraft(url: url, handle: handle)
            }
            return await Self.fetch(url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    /// The handle in one of OUR profile links, or nil for every other url on the internet.
    ///
    /// Only `https://fariin.com/u/<handle>`. `kulan://u/<handle>` is deliberately not matched: the
    /// detector that feeds this only ever offers https links, and a custom scheme in a message is
    /// dead text on a phone without the app anyway.
    static func profileHandle(in url: URL) -> String? {
        guard let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: ""),
              host == "fariin.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "u" else { return nil }
        let handle = parts[1].trimmingCharacters(in: .whitespaces)
        return handle.isEmpty ? nil : handle
    }

    /// The card for a profile link. `title` carries the name, `desc` the @handle, and the image is
    /// their photograph — the same three fields every other preview uses, so nothing downstream
    /// needed a new shape. `LinkPreviewCard` recognises a profile link by its URL and draws the
    /// person layout instead of the article one.
    ///
    /// An unresolvable handle still produces a card. A deleted account, a released name or a typo
    /// should SAY so rather than leaving a bare link that looks like it might work.
    private static func profileDraft(url: URL, handle: String) async -> LinkDraft? {
        guard let user = await ChatService.findByHandle(handle, allowSelf: true) else {
            return LinkDraft(url: url, title: "Unavailable", desc: "", image: nil)
        }
        var photo: UIImage?
        if let p = user.photoUrl, !p.isEmpty {
            // `??` takes an autoclosure, which cannot carry an await — the two steps have to be
            // written out.
            if let warm = DiskImageCache.shared.memoryImage(p) {
                photo = warm
            } else {
                photo = await DiskImageCache.shared.image(for: p)
            }
            if photo == nil, let u = URL(string: p),
               let (data, _) = try? await URLSession.shared.data(from: u) {
                photo = UIImage(data: data)
            }
        }
        let name = user.name.trimmingCharacters(in: .whitespaces)
        return LinkDraft(url: url,
                         title: name.isEmpty ? handle : name,
                         desc: user.handle.isEmpty ? "" : "@\(user.handle)",
                         image: photo)
    }

    /// First https URL in a text, if any — the one the preview is built for.
    static func firstURL(in text: String) -> URL? {
        guard text.contains("http"),
              let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let r = NSRange(text.startIndex..., in: text)
        return d.matches(in: text, range: r).compactMap(\.url).first { $0.scheme == "https" }
    }

    // Fetch the first ~300 KB of the page and scrape og:title / og:description / og:image
    // (twitter:* and <title> as fallbacks). Bounded: https only, 8s timeout, image capped at 3 MB and
    // downscaled to ≤800px before it ever touches a message.
    private static func fetch(_ url: URL) async -> LinkDraft? {
        guard url.scheme == "https" else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").contains("html") else { return nil }
        let html = String(decoding: data.prefix(300_000), as: UTF8.self)

        let title = metaContent(html, property: "og:title")
            ?? metaContent(html, property: "twitter:title")
            ?? tagTitle(html)
        guard let title, !title.isEmpty else { return nil }
        let desc = metaContent(html, property: "og:description")
            ?? metaContent(html, property: "twitter:description")
            ?? metaContent(html, property: "description")
            ?? ""

        var image: UIImage?
        if let raw = metaContent(html, property: "og:image") ?? metaContent(html, property: "twitter:image"),
           let imgUrl = URL(string: raw, relativeTo: url)?.absoluteURL, imgUrl.scheme == "https" {
            image = await fetchImage(imgUrl, pageURL: url)
        }
        return LinkDraft(url: url, title: decodeEntities(title), desc: decodeEntities(desc), image: image)
    }

    /// A real Safari UA. The old "KulanBot/1.0" was honest but got us treated as an unknown scraper:
    /// the page came back (title/description parsed) while the og:image CDN — Facebook's scontent in
    /// the user's screenshot — answered 403, so cards arrived TEXT-ONLY. Every link-preview fetcher
    /// ships a browser UA for exactly this reason.
    private static let browserUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func fetchImage(_ url: URL, pageURL: URL) async -> UIImage? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        // Some CDNs only serve the image to a request that looks like it came from the page.
        req.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 3 * 1024 * 1024,
              let raw = UIImage(data: data) else { return nil }
        // Downscale to a card-sized image so the message payload stays small.
        let maxSide: CGFloat = 800
        let scale = min(1, maxSide / max(raw.size.width, raw.size.height))
        guard scale < 1 else { return raw }
        let size = CGSize(width: raw.size.width * scale, height: raw.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in raw.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // <meta property="og:title" content="..."> — tolerant of attribute order and name= vs property=.
    private static func metaContent(_ html: String, property: String) -> String? {
        for attr in ["property", "name"] {
            let pattern = "<meta[^>]*\(attr)=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*content=[\"']([^\"']*)[\"']"
            if let m = firstGroup(html, pattern) { return m }
            // content may appear before property
            let pattern2 = "<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*\(attr)=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"']"
            if let m = firstGroup(html, pattern2) { return m }
        }
        return nil
    }

    private static func tagTitle(_ html: String) -> String? {
        firstGroup(html, "<title[^>]*>([^<]*)</title>")
    }

    private static func firstGroup(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        // NUMERIC entities first (&#xb7; / &#183;) — the named-only version printed raw "&#xb7;" in the
        // middle of a real card on device (user screenshot: "22K views &#xb7; 988 reactions").
        // Facebook and X title tags are full of them.
        if out.contains("&#"), let re = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let body = ns.substring(with: m.range(at: 1))
                let value: UInt32? = body.lowercased().hasPrefix("x")
                    ? UInt32(body.dropFirst(), radix: 16)
                    : UInt32(body)
                if let value, let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                } else {
                    result += ns.substring(with: m.range)   // leave anything unparseable as-is
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        for (e, c) in ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out
    }
}

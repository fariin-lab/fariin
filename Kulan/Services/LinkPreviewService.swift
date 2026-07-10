import Foundation

// Open-Graph link previews, generated ON-DEVICE at display time. Nothing about the link is ever sent
// to our server (E2EE stays intact) — each client fetches the page's OG tags itself and caches the
// result. Bounded (https only, small byte cap, short timeout) so it can't hang or run away.
struct LinkPreview: Equatable {
    let url: URL
    let title: String
    let imageUrl: URL?
    var host: String { url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
}

actor LinkPreviewService {
    static let shared = LinkPreviewService()

    private var cache: [String: LinkPreview?] = [:]   // value nil = fetched, no usable preview
    private var inFlight: [String: Task<LinkPreview?, Never>] = [:]

    func preview(for url: URL) async -> LinkPreview? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task<LinkPreview?, Never> { await Self.fetch(url) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    // Fetch the first ~200 KB of the page and scrape og:title / og:image (falling back to <title>).
    private static func fetch(_ url: URL) async -> LinkPreview? {
        guard url.scheme == "https" else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (compatible; KulanBot/1.0)", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").contains("html") else { return nil }
        let html = String(decoding: data.prefix(200_000), as: UTF8.self)

        let title = metaContent(html, property: "og:title")
            ?? metaContent(html, property: "twitter:title")
            ?? tagTitle(html)
        guard let title, !title.isEmpty else { return nil }

        var image: URL?
        if let raw = metaContent(html, property: "og:image") ?? metaContent(html, property: "twitter:image") {
            image = URL(string: raw, relativeTo: url)?.absoluteURL
            if image?.scheme != "https" { image = nil }   // don't load insecure images
        }
        return LinkPreview(url: url, title: decodeEntities(title), imageUrl: image)
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
        for (e, c) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out
    }
}

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
/// ⛔ AN OLD STORY'S ID, SHORT IN A LINK (owner, 2026-10-11: "the link is too long"). Stories posted
/// before 2026-10-11 have a 36-character UUID id; in a link it is written as its 16 bytes in base 62,
/// always 22 characters (the call-link scheme, `CallLinkKey.compact`), and read back to the UUID.
/// New stories already have 10-character ids and pass through unchanged; 22 never collides with 10.
enum StoryLinkId {
    private static let base62 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func short(_ id: String) -> String {
        guard let u = UUID(uuidString: id) else { return id }
        var num = withUnsafeBytes(of: u.uuid) { Array($0) }
        var digits = [Character](repeating: "0", count: 22)
        for pos in stride(from: 21, through: 0, by: -1) {
            var rem = 0
            for i in num.indices {
                let cur = rem << 8 | Int(num[i])
                num[i] = UInt8(cur / 62)
                rem = cur % 62
            }
            digits[pos] = base62[rem]
        }
        return String(digits)
    }

    static func full(_ s: String) -> String {
        guard s.count == 22 else { return s }
        var num = [UInt8](repeating: 0, count: 16)
        for ch in s {
            guard let d = base62.firstIndex(of: ch) else { return s }
            var carry = d
            for i in stride(from: 15, through: 0, by: -1) {
                let cur = Int(num[i]) * 62 + carry
                num[i] = UInt8(cur & 0xff)
                carry = cur >> 8
            }
            guard carry == 0 else { return s }
        }
        let u = UUID(uuid: (num[0], num[1], num[2], num[3], num[4], num[5], num[6], num[7],
                            num[8], num[9], num[10], num[11], num[12], num[13], num[14], num[15]))
        return u.uuidString
    }
}

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
    private var missAt: [String: Date] = [:]           // key → when a fetch last came back empty

    func draft(for url: URL) async -> LinkDraft? {
        // ⛔ OUR OWN CALL LINKS ARE NEVER FETCHED (2026-10-07). The bubble builds their card itself
        // (MessageRowModelBuilder.callLinkPreview), and the path form carries the link's KEY in the
        // address, so fetching it would hand the key to the web server from the sender's phone on
        // every send. The old form's /call/ page did not exist, so a call link never had a fetched
        // preview; same answer, now on purpose.
        if Self.isCallLink(url) { return nil }
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let t = missAt[key], Date().timeIntervalSince(t) < 60 { return nil }
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
            if let link = Self.storyLink(in: url) {
                return await Self.storyDraft(url: url, id: link.id, handle: link.handle)
            }
            if let vid = Self.youtubeID(in: url), let yt = await Self.youtubeDraft(url: url, id: vid) {
                return yt
            }
            return await Self.fetch(url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        // A miss is only remembered for a minute (audit, 2026-09-24). Cached for the session, a link
        // typed with no signal never got its card, even after the connection came back, because
        // "no network" and "page has no preview" both come back as nil.
        if result == nil { missAt[key] = Date() } else { cache[key] = result }
        return result
    }

    /// One of OUR call links, either spelling: anything on call.fariin.com, or /call, /voice,
    /// /video on the main host. A host-and-path test only: the real router (`KulanApp.route`) is
    /// main-actor and this is not, and a false positive here costs a preview for an address nobody
    /// could open anyway.
    static func isCallLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == CallLinkKey.linkHost { return true }
        guard host == "fariin.com" || host == "www.fariin.com",
              let first = url.pathComponents.first(where: { $0 != "/" }) else { return false }
        return first == "call" || first == "voice" || first == "video"
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

    /// The story in one of OUR story links: fariin.com/<username>/s/<id>, or the older /s/<id>.
    static func storyLink(in url: URL) -> (id: String, handle: String?)? {
        guard let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: ""),
              host == "fariin.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[1] == "s", !parts[0].isEmpty, !parts[2].isEmpty {
            return (StoryLinkId.full(parts[2]), parts[0])
        }
        if parts.count == 2, parts[0] == "s", !parts[1].isEmpty { return (StoryLinkId.full(parts[1]), nil) }
        return nil
    }

    /// THE CARD FOR A STORY LINK (owner, 2026-10-11, the reference app's card): the author's name,
    /// the picture, the caption. Built on the sender's phone from the story it already holds, or from
    /// the author's public stories, and sent as a snapshot like every other preview. A video's length
    /// is drawn onto the picture, so the card needs no new field in the message. Nil when the story
    /// cannot be found: the link stays a plain link, which still opens it.
    private static func storyDraft(url: URL, id: String, handle: String?) async -> LinkDraft? {
        let held: (String, Story)? = await MainActor.run {
            let repo = StoriesRepository.shared
            for g in repo.others + [repo.mine].compactMap({ $0 }) {
                if let s = g.stories.first(where: { $0.id == id }) {
                    return (g.isMine ? (ProfileStore.shared.me?.name ?? g.name) : g.name, s)
                }
            }
            return nil
        }
        var found = held
        if found == nil, let handle, let user = await ChatService.findByHandle(handle, allowSelf: true),
           let g = await StoriesRepository.shared.publicStoryGroup(for: user.id, name: user.name,
                                                                   photoUrl: user.photoUrl),
           let s = g.stories.first(where: { $0.id == id }) {
            found = (user.name, s)
        }
        guard let hit = found else { return nil }
        let (name, story) = hit
        let picture = story.isVideo ? story.thumbUrl : story.mediaUrl
        var image = await StoryViewer.storyImage(picture)
        if let img = image { image = storyCardImage(img, duration: story.isVideo ? story.duration : nil) }
        return LinkDraft(url: url, title: name.trimmingCharacters(in: .whitespaces),
                         desc: story.caption, image: image)
    }

    /// The story picture at most 600 points tall, and for a video its length in a small dark pill in
    /// the lower left corner, the way the reference card marks one.
    private static func storyCardImage(_ img: UIImage, duration: Double?) -> UIImage {
        let scale = min(1, 600 / max(img.size.height, 1))
        let size = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
            guard let d = duration, d > 0 else { return }
            let secs = Int(d.rounded())
            let text = String(format: "%d:%02d", secs / 60, secs % 60) as NSString
            let font = UIFont.systemFont(ofSize: max(14, size.height * 0.04), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let t = text.size(withAttributes: attrs)
            let pad = font.pointSize * 0.5
            let pill = CGRect(x: pad, y: size.height - pad - t.height - pad * 0.6,
                              width: t.width + pad * 1.4, height: t.height + pad * 0.6)
            UIColor.black.withAlphaComponent(0.5).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            text.draw(at: CGPoint(x: pill.minX + pad * 0.7, y: pill.minY + pad * 0.3), withAttributes: attrs)
        }
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
    // MARK: - YouTube

    /// ⛔ A YOUTUBE LINK GETS THE VIDEO'S OWN CARD — owner 2026-10-13, with the reference app's card: the
    /// video's real cover with a play button, "YouTube", and the video's title. The page scrape below
    /// often gets YouTube's generic consent or app page instead of the video's tags, so the title and
    /// channel come from YouTube's public oEmbed endpoint and the cover straight from its thumbnail
    /// host (the HD cover when the video has one, else the standard one). Nil hands over to the
    /// ordinary scrape, so a failure here never leaves a link without whatever card it had before.
    static func youtubeID(in url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if parts.first == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
                id = parts[1]
            }
        }
        guard let id, id.count == 11,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              id.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return id
    }

    private static func youtubeDraft(url: URL, id: String) async -> LinkDraft? {
        let watch = "https://www.youtube.com/watch?v=\(id)"
        var title = "", channel = ""
        if var c = URLComponents(string: "https://www.youtube.com/oembed") {
            c.queryItems = [URLQueryItem(name: "url", value: watch), URLQueryItem(name: "format", value: "json")]
            if let u = c.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 8)),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                title = j["title"] as? String ?? ""
                channel = j["author_name"] as? String ?? ""
            }
        }
        guard !title.isEmpty else { return nil }   // private, removed or unreachable: the scrape decides
        var cover: UIImage?
        for name in ["maxresdefault", "hqdefault"] {
            if let u = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg"),
               let img = await fetchImage(u, pageURL: url),
               img.size.width > 200 {   // the "no HD cover" answer is a tiny grey placeholder
                cover = img
                break
            }
        }
        return LinkDraft(url: url, title: title, desc: channel, image: cover.map(withPlayButton))
    }

    /// The play button the reference card draws on a video's cover: a dark translucent disc with a white
    /// triangle, centred. Baked into the picture that travels, as the story card bakes its own marks.
    private static func withPlayButton(_ img: UIImage) -> UIImage {
        let size = img.size
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = img.scale; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            img.draw(in: CGRect(origin: .zero, size: size))
            let d = min(size.width, size.height) * 0.22
            let disc = CGRect(x: (size.width - d) / 2, y: (size.height - d) / 2, width: d, height: d)
            UIColor.black.withAlphaComponent(0.45).setFill()
            ctx.cgContext.fillEllipse(in: disc)
            let t = d * 0.36
            let path = UIBezierPath()
            path.move(to: CGPoint(x: disc.midX - t * 0.38, y: disc.midY - t / 2))
            path.addLine(to: CGPoint(x: disc.midX - t * 0.38, y: disc.midY + t / 2))
            path.addLine(to: CGPoint(x: disc.midX + t * 0.55, y: disc.midY))
            path.close()
            UIColor.white.setFill()
            path.fill()
        }
    }

    private static func fetch(_ url: URL) async -> LinkDraft? {
        guard url.scheme == "https", !isPrivateHost(url) else { return nil }
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
           let imgUrl = URL(string: raw, relativeTo: url)?.absoluteURL, imgUrl.scheme == "https",
           !isPrivateHost(imgUrl) {   // 2026-09-24 decision D-composer-6: a page cannot aim us inward
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

    /// 2026-09-24 decision D-composer-6: no preview fetch to this phone's own network. A link (or a
    /// page's og:image) naming localhost, a private, loopback, link-local or carrier-shared address
    /// would otherwise make the sender's device call a router or printer on the local network just
    /// because a message was typed. Only literal hosts are judged; nothing is resolved here.
    static func isPrivateHost(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return true }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return true
        }
        // IPv4 literal (also the tail of an IPv4-mapped IPv6 address, ::ffff:a.b.c.d).
        let v4 = host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
        let parts = v4.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let o = parts.compactMap { Int($0) }
            if o.count == 4, o.allSatisfy({ (0...255).contains($0) }) {
                switch (o[0], o[1]) {
                case (0, _), (10, _), (127, _): return true
                case (169, 254), (192, 168): return true
                case (172, 16...31): return true
                case (100, 64...127): return true   // carrier-grade NAT
                default: return false
                }
            }
        }
        // IPv6 literal: loopback, unspecified, link-local fe80::/10, unique-local fc00::/7.
        if host.contains(":") {
            if host == "::1" || host == "::" { return true }
            if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") { return true }
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        }
        return false
    }

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

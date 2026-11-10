import Foundation

/// ⛔ A TEXT OR MARKDOWN FILE OPENS AS A READ PAGE (owner 2026-11-10, with the reference app's
/// screen beside ours: ours showed the raw "# | ** |---|" characters). The file is turned into a
/// small HTML page here, with our own stylesheet, and shown in the in-app browser sheet
/// (`InAppBrowserViewController(document:)`). Pure string work: no script runs in the page, and
/// every character of the file is HTML-escaped before any tag is added, so a file cannot inject
/// markup or code.
///
/// Covers what people write in notes and reports: # headings, paragraphs, **bold**, *italic*,
/// `code`, ``` fences, > quotes, - / * / 1. lists (one nesting level by indent), | tables |,
/// --- rules, [links](https://...) and bare https:// addresses. Anything else stays as text.
enum MarkdownHTML {

    /// The largest file drawn this way; a bigger one goes to the system preview instead.
    static let maxBytes = 2_000_000

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    static func isPlainText(_ url: URL) -> Bool {
        ["txt", "text", "log"].contains(url.pathExtension.lowercased())
    }

    /// The page for a file, and the title the sheet shows: the first # heading, else the file name.
    static func page(for url: URL) -> (html: String, title: String)? {
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        let fallback = url.deletingPathExtension().lastPathComponent
        if isMarkdown(url) {
            let (body, h1) = render(text)
            return (wrap(body, title: h1 ?? fallback), h1 ?? fallback)
        }
        let body = "<pre class=\"plain\">" + linkify(escape(text)) + "</pre>"
        return (wrap(body, title: fallback), fallback)
    }

    // MARK: - Blocks

    static func render(_ source: String) -> (String, String?) {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out = ""
        var firstH1: String?
        var para: [String] = []
        var i = 0

        func flushPara() {
            guard !para.isEmpty else { return }
            out += "<p>" + para.map(inline).joined(separator: "<br>") + "</p>\n"
            para.removeAll()
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flushPara(); i += 1; continue }

            // ``` fenced code: everything up to the closing fence, untouched.
            if line.hasPrefix("```") {
                flushPara()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1   // the closing fence (or the end)
                out += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }

            // # Heading
            if let level = headingLevel(line) {
                flushPara()
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
                if level == 1, firstH1 == nil { firstH1 = plain(text) }
                out += "<h\(level)>" + inline(text) + "</h\(level)>\n"
                i += 1; continue
            }

            // --- rule
            if isRule(line) { flushPara(); out += "<hr>\n"; i += 1; continue }

            // | table |
            if line.hasPrefix("|"), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
                flushPara()
                let head = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i])); i += 1
                }
                out += "<div class=\"table\"><table><thead><tr>"
                    + head.map { "<th>" + inline($0) + "</th>" }.joined() + "</tr></thead><tbody>"
                for r in rows {
                    let padded = r + Array(repeating: "", count: max(0, head.count - r.count))
                    out += "<tr>" + padded.prefix(max(head.count, 1)).map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>"
                }
                out += "</tbody></table></div>\n"
                continue
            }

            // > quote (consecutive lines)
            if line.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    q.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out += "<blockquote>" + q.map(inline).joined(separator: "<br>") + "</blockquote>\n"
                continue
            }

            // - item / 1. item
            if listMarker(line) != nil {
                flushPara()
                out += list(lines, &i)
                continue
            }

            para.append(line)
            i += 1
        }
        flushPara()
        return (out, firstH1)
    }

    /// A run of list lines from `i`; a line indented 2+ spaces deeper opens one nested list.
    private static func list(_ lines: [String], _ i: inout Int) -> String {
        guard let first = listMarker(lines[i].trimmingCharacters(in: .whitespaces)) else { return "" }
        let tag = first.ordered ? "ol" : "ul"
        let baseIndent = indent(lines[i])
        var html = "<\(tag)>"
        var open = false
        while i < lines.count {
            let rawLine = lines[i]
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                // A blank line ends the list unless the next line carries on with an item.
                if i + 1 < lines.count, listMarker(lines[i + 1].trimmingCharacters(in: .whitespaces)) != nil { i += 1; continue }
                break
            }
            let ind = indent(rawLine)
            if let m = listMarker(t) {
                if ind >= baseIndent + 2, open {
                    html += list(lines, &i)   // nested; leaves `i` on the first line after it
                    continue
                }
                if ind < baseIndent { break }
                if m.ordered != first.ordered { break }
                if open { html += "</li>" }
                html += "<li>" + inline(m.rest)
                open = true
                i += 1
            } else if open, ind > baseIndent {
                html += "<br>" + inline(t)   // a wrapped continuation of the item
                i += 1
            } else {
                break
            }
        }
        if open { html += "</li>" }
        return html + "</\(tag)>\n"
    }

    private static func indent(_ s: String) -> Int {
        var n = 0
        for c in s { if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break } }
        return n
    }

    private static func listMarker(_ t: String) -> (ordered: Bool, rest: String)? {
        for m in ["- ", "* ", "+ "] where t.hasPrefix(m) {
            return (false, String(t.dropFirst(2)))
        }
        // 1. item  /  1) item
        var digits = 0
        for c in t { if c.isNumber { digits += 1 } else { break } }
        guard digits > 0, digits <= 4, t.count > digits + 1 else { return nil }
        let after = t.index(t.startIndex, offsetBy: digits)
        guard t[after] == "." || t[after] == ")" else { return nil }
        let next = t.index(after: after)
        guard next < t.endIndex, t[next] == " " else { return nil }
        return (true, String(t[t.index(after: next)...]))
    }

    private static func headingLevel(_ t: String) -> Int? {
        var n = 0
        for c in t { if c == "#" { n += 1 } else { break } }
        guard (1...6).contains(n), t.count > n, t[t.index(t.startIndex, offsetBy: n)] == " " else { return nil }
        return n
    }

    private static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    private static func isTableDivider(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ raw: String) -> [String] {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline

    /// Escapes the text, then adds code spans, links, bold and italic. Code spans are cut out first
    /// so nothing inside them is touched.
    static func inline(_ s: String) -> String {
        var codes: [String] = []
        var work = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "`") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "`") else { break }
            work += rest[..<open]
            codes.append(String(rest[after..<close]))
            work += "\u{1}\(codes.count - 1)\u{2}"
            rest = rest[rest.index(after: close)...]
        }
        work += rest

        var h = escape(work)
        h = links(h)
        h = replacePairs(h, "**", "<strong>", "</strong>")
        h = replacePairs(h, "__", "<strong>", "</strong>")
        h = replacePairs(h, "*", "<em>", "</em>")
        h = replacePairs(h, "~~", "<del>", "</del>")
        for (n, c) in codes.enumerated() {
            h = h.replacingOccurrences(of: "\u{1}\(n)\u{2}", with: "<code>" + escape(c) + "</code>")
        }
        return h
    }

    /// `[text](https://...)` and bare https:// addresses, on already-escaped text. Only web
    /// addresses become links.
    private static func links(_ h: String) -> String {
        var out = ""
        var rest = Substring(h)
        while let lb = rest.firstIndex(of: "[") {
            guard let rb = rest[lb...].firstIndex(of: "]"),
                  rest.index(after: rb) < rest.endIndex, rest[rest.index(after: rb)] == "(",
                  let rp = rest[rb...].firstIndex(of: ")") else { break }
            let text = rest[rest.index(after: lb)..<rb]
            let href = rest[rest.index(rb, offsetBy: 2)..<rp]
            out += linkify(String(rest[..<lb]))
            if href.hasPrefix("https://") || href.hasPrefix("http://") {
                out += "<a href=\"\(href)\">\(text)</a>"
            } else {
                out += rest[lb...rp]
            }
            rest = rest[rest.index(after: rp)...]
        }
        return out + linkify(String(rest))
    }

    /// Bare web addresses in escaped text become links.
    static func linkify(_ h: String) -> String {
        guard h.contains("http://") || h.contains("https://") else { return h }
        var out = ""
        var rest = Substring(h)
        while let r = rest.range(of: "https://") ?? rest.range(of: "http://") {
            out += rest[..<r.lowerBound]
            var end = r.upperBound
            while end < rest.endIndex, !" \n\t<\"'".contains(rest[end]) { end = rest.index(after: end) }
            var url = String(rest[r.lowerBound..<end])
            var trail = ""
            while let last = url.last, ".,;:!?)".contains(last) { trail = String(last) + trail; url.removeLast() }
            out += "<a href=\"\(url)\">\(url)</a>" + trail
            rest = rest[end...]
        }
        return out + rest
    }

    /// `**a**` -> `<strong>a</strong>`, only for a marker that has a partner on the same line and
    /// is not touching a space on the inside (so "2 * 3 * 4" stays as it is).
    private static func replacePairs(_ s: String, _ m: String, _ open: String, _ close: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let a = rest.range(of: m) {
            let afterA = a.upperBound
            guard afterA < rest.endIndex, !rest[afterA].isWhitespace,
                  let b = rest[afterA...].range(of: m) else { break }
            let inner = rest[afterA..<b.lowerBound]
            guard !inner.isEmpty, let lastInner = inner.last, !lastInner.isWhitespace else {
                out += rest[..<afterA]; rest = rest[afterA...]; continue
            }
            out += rest[..<a.lowerBound] + open + inner + close
            rest = rest[b.upperBound...]
        }
        return out + rest
    }

    static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(c)
            }
        }
        return o
    }

    /// The heading as plain words for the sheet's title (markers dropped).
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")
    }

    // MARK: - Page

    private static func wrap(_ body: String, title: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <title>\(escape(title))</title>
        <style>\(css)</style></head><body><article>\(body)</article></body></html>
        """
    }

    /// Serif headings and plain system text, the read-page look of his reference; light and dark
    /// follow the phone. Room at the top for the sheet's close circle and at the foot for its bar.
    private static let css = """
    :root{color-scheme:light dark;--fg:#000;--muted:#6b6b70;--line:#e3e3e8;--fill:#f4f4f6;--code:#f2f2f5;--link:#000}
    @media (prefers-color-scheme:dark){:root{--fg:#fff;--muted:#9a9aa0;--line:#2c2c2e;--fill:#1c1c1e;--code:#1c1c1e;--link:#fff}}
    html{-webkit-text-size-adjust:100%}
    body{margin:0;background:transparent;color:var(--fg);font:17px/1.5 -apple-system,system-ui,sans-serif;word-wrap:break-word}
    article{padding:76px 20px 120px;max-width:720px;margin:0 auto}
    h1,h2,h3,h4{font-family:ui-serif,"New York",Georgia,serif;font-weight:700;line-height:1.2;margin:1.1em 0 .5em}
    h1{font-size:30px;margin-top:.2em}h2{font-size:24px}h3{font-size:20px}h4,h5,h6{font-size:17px}
    p{margin:0 0 1em}
    a{color:var(--link);text-decoration:underline;text-underline-offset:2px}
    strong{font-weight:600}
    ul,ol{margin:0 0 1em;padding-left:1.4em}li{margin:.35em 0}li>ul,li>ol{margin:.3em 0}
    blockquote{margin:0 0 1em;padding:.2em 0 .2em 14px;border-left:3px solid var(--line);color:var(--muted)}
    hr{border:0;border-top:1px solid var(--line);margin:1.5em 0}
    code{font:15px ui-monospace,Menlo,monospace;background:var(--code);border-radius:6px;padding:1px 5px}
    pre{background:var(--code);border-radius:12px;padding:12px 14px;overflow-x:auto;margin:0 0 1em}
    pre code{background:none;padding:0;font-size:14px}
    pre.plain{background:none;padding:0;white-space:pre-wrap;font:16px/1.5 -apple-system,system-ui,sans-serif;overflow:visible}
    .table{overflow-x:auto;margin:0 0 1.2em;border:1px solid var(--line);border-radius:12px}
    table{border-collapse:collapse;width:100%;font-size:16px}
    th,td{padding:12px 14px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}
    th+th,td+td{border-left:1px solid var(--line)}
    tr:last-child td{border-bottom:0}
    th{background:var(--fill);font-weight:500}
    """
}

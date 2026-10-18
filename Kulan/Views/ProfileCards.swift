import SwiftUI

// The profile page's own pieces, shared so a person's profile, a group's info page and the Fariin
// official chat draw ONE row, ONE All Media card and ONE About card (owner 2026-10-18: the group page
// "exactly the design the user profile is using"). Moved here unchanged from ContactInfoView and
// OfficialChatView; their notes on why each number is what it is stay with those pages.

/// One tappable row: icon, title, optional trailing value, chevron. `tint` colours icon and title.
/// (Was `ContactInfoView.infoRow`.)
struct ProfileInfoRow: View {
    let title: String
    let icon: String
    var value: String? = nil
    var tint: Color = .primary
    var chevron: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // "ic_" names an asset-catalog glyph, anything else an SF Symbol. Same 26pt slot
                // either way so the titles stay on one line no matter which kind a row uses.
                Group {
                    if icon.hasPrefix("ic_") {
                        Image(icon).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 21, height: 21)
                    } else {
                        Image(systemName: icon).font(.system(size: 17))
                    }
                }
                .frame(width: 26)
                .foregroundStyle(tint)
                Text(title).foregroundStyle(tint)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                if chevron {
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)   // the reference app's tall profile rows (~58pt)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The About card's content: the heading and the text. The caller draws the card it sits in.
/// (Was `OfficialChatView.aboutCard`'s inside.)
struct ProfileAboutContent: View {
    let text: String
    /// The text is a prompt ("Add a description"), not content: drawn in the secondary colour.
    var placeholder = false
    /// Web links and @usernames in the text can be tapped (owner 2026-10-18: a group's description).
    var linked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("About", systemImage: "text.alignleft").font(.body)
            if linked && !placeholder {
                Text(Self.linkedText(text))
                    .tint(Color(hex: 0x0A84FF))
                    // A web link opens in the in-app browser, an @username on that person's profile
                    // (our own kulan://u/ link, which the app's deep link routing opens).
                    .environment(\.openURL, OpenURLAction { url in
                        switch url.scheme?.lowercased() {
                        case "http", "https": WebLink.open(url)
                        case "kulan": UIApplication.shared.open(url)
                        default: return .discarded
                        }
                        return .handled
                    })
            } else {
                Text(text).foregroundStyle(placeholder ? .secondary : .primary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Plain text with its web addresses and @usernames made links. No markdown: a description is
    /// what the person typed, so a `*` stays a `*`. An address without a scheme opens as https; an
    /// @ counts only at the start or after a space, so an email address is not a username.
    static func linkedText(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        func mark(_ r: NSRange, _ url: URL) {
            guard let sr = Range(r, in: text),
                  let lo = AttributedString.Index(sr.lowerBound, within: out),
                  let hi = AttributedString.Index(sr.upperBound, within: out),
                  out[lo..<hi].link == nil else { return }
            out[lo..<hi].link = url
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, range: all) {
                guard var url = m.url else { continue }
                let scheme = url.scheme?.lowercased() ?? ""
                guard scheme == "http" || scheme == "https" else { continue }
                if scheme == "http", !ns.substring(with: m.range).lowercased().hasPrefix("http://"),
                   var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    parts.scheme = "https"
                    if let secure = parts.url { url = secure }
                }
                mark(m.range, url)
            }
        }
        if let re = try? NSRegularExpression(pattern: "(?<![^\\s])@([A-Za-z0-9_.]{1,32})") {
            for m in re.matches(in: text, range: all) {
                let handle = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !handle.isEmpty, KulanApp.safeSegment(handle),
                      let url = URL(string: "kulan://u/\(handle.lowercased())") else { continue }
                mark(m.range, url)
            }
        }
        return out
    }
}

/// ALL MEDIA AS ONE CONTAINER: the heading and "See All ›" on one line, one row of thumbnails under
/// them running off the card's right edge. Tap a thumbnail to open it, anywhere else for the gallery.
/// (Was `ContactInfoView.mediaCard`.)
struct ProfileMediaCard: View {
    let cid: String
    let media: [Message]
    /// How many placeholder tiles to hold while the media loads, so nothing moves when it lands.
    var hint: Int = 0
    var cardColor: Color = Color(uiColor: .secondarySystemGroupedBackground)
    /// Where the open/close flight registers its tiles (`MediaOpenRects`).
    var scope: MediaOpenRects.Scope = .profile
    let onOpen: (Message) -> Void
    let onSeeAll: () -> Void

    static let tile: CGFloat = 84
    static let tileRadius: CGFloat = 12
    static let gap: CGFloat = 8
    static let inset: CGFloat = 14

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("All Media").font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("See All").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, Self.inset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.gap) {
                    if media.isEmpty {
                        ForEach(0..<min(hint, 12), id: \.self) { _ in
                            tileShape
                                .fill(Color.primary.opacity(0.07))
                                .frame(width: Self.tile, height: Self.tile)
                        }
                    }
                    ForEach(media.prefix(12)) { m in
                        // Videos carry thumbUrl/thumbEnc (no imageUrl).
                        if let url = m.imageUrl ?? m.thumbUrl {
                            SecureImageView(imageUrl: url, enc: m.imageUrl != nil ? m.enc : m.thumbEnc, cid: cid)
                                .frame(width: Self.tile, height: Self.tile)
                                .clipShape(tileShape)
                                .contentShape(tileShape)
                                .modifier(MediaRectReporter(id: m.id, scope: scope))
                                // Fly the thumb's media out of its tile, as the chat does, falling
                                // back to a plain presentation.
                                .onTapGesture {
                                    let key = MediaOpenRects.key(scope, m.id)
                                    MediaOpen.flyOrPresent(
                                        imageUrl: url, rectKey: key,
                                        present: { MediaPresentGate.present { onOpen(m) } })
                                }
                        }
                    }
                }
                .padding(.horizontal, Self.inset)
            }
            .padding(.bottom, Self.inset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .profileSurface(plain: cardColor)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { onSeeAll() }
    }
}

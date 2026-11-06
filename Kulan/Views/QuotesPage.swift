import SwiftUI
import FirebaseFunctions

/// One quote of a channel post, sent in a PUBLIC channel (`getPostQuotes`).
struct QuotedInItem: Identifiable, Equatable {
    var cid: String
    var mid: String
    var title: String
    var photoUrl: String
    var username: String
    var verified: Bool
    var followers: Int
    var text: String
    var at: Date
    var views: Int
    var id: String { cid + "/" + mid }

    init?(_ d: [String: Any]) {
        guard let cid = d["cid"] as? String, let mid = d["mid"] as? String else { return nil }
        self.cid = cid
        self.mid = mid
        title = d["title"] as? String ?? "Channel"
        photoUrl = d["photoUrl"] as? String ?? ""
        username = d["username"] as? String ?? ""
        verified = d["verified"] as? Bool ?? false
        followers = (d["followers"] as? NSNumber)?.intValue ?? 0
        text = d["text"] as? String ?? ""
        at = Date(timeIntervalSince1970: ((d["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        views = (d["views"] as? NSNumber)?.intValue ?? 0
    }
}

/// ⛔ WHO QUOTED A POST (owner 2026-11-06). Laid out after his reference (about two thirds of it, his
/// words): a plain page, each quote as the quoting channel's photo and name, its words, and under them
/// an outlined card of MY post (my channel's name, the post's picture and text, when it was quoted,
/// the quote's views). A short count line on top; quotes in private chats, groups and private
/// channels are only a number at the bottom, the server never names them (`getPostQuotes`).
struct QuotesPage: View {
    /// The card's soft grey. In dark mode the sheet itself is that grey, so the card goes one step
    /// lighter there or it vanishes (owner 2026-11-06 screenshot).
    static let cardGrey = UIColor { $0.userInterfaceStyle == .dark ? .tertiarySystemBackground : .secondarySystemBackground }
    let cid: String
    let mid: String
    let post: Message?
    /// My channel as the card shows it.
    var sourceTitle: String
    var sourcePhoto: String?
    var sourceVerified: Bool
    /// The post's picture, made on this phone (channel media is sealed).
    var picture: () async -> UIImage?
    var onOpen: (QuotedInItem) -> Void
    /// Inside the Replies / Quotes sheet (`PostThreadSheet`): no navigation bar of its own.
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @State private var items: [QuotedInItem] = []
    @State private var total = 0
    @State private var hidden = 0
    @State private var publicTotal = 0
    @State private var next = ""
    @State private var loadingMore = false
    @State private var loaded = false
    @State private var failed = false
    @State private var thumb: UIImage?

    var body: some View {
        if embedded {
            page
        } else {
            NavigationStack {
                page
                    .navigationTitle("Quotes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            }
        }
    }

    private var page: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if loaded {
                        Text(summary)
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        ForEach(items) { it in
                            Button { onOpen(it) } label: { quote(it) }
                                .buttonStyle(.plain)
                            Divider().padding(.leading, 16 + indent)
                        }
                        if !next.isEmpty {
                            // A button as well as the auto-load, so a failed or empty page can be asked again.
                            Button { Task { await loadMore() } } label: {
                                Text(loadingMore ? "Loading…" : "Show more")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .onAppear { Task { await loadMore() } }
                        }
                        if hidden > 0 {
                            Label("\(hidden.formatted()) in private chats and groups", systemImage: "lock.fill")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                }
            }
            .overlay { overlay }
            .task { await load() }
            .task { thumb = await picture() }
    }

    @ViewBuilder private var overlay: some View {
        if failed {
            ContentUnavailableView {
                Label("Couldn't load quotes", image: "ic_quote")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { failed = false; await load() } }
            }
        } else if !loaded {
            QuotesSkeleton()
        } else if items.isEmpty && hidden == 0 {
            ContentUnavailableView("No quotes yet", image: "ic_quote")
        }
    }

    /// The post's own count, and how many of them are in public channels (the ones listed). Never a
    /// sum over the rows on screen, which is only a page (2026-11-06 audit).
    private var summary: String {
        let q = "\(total.formatted()) \(total == 1 ? "quote" : "quotes")"
        return publicTotal > 0 ? q + " · \(publicTotal.formatted()) in public channels" : q
    }

    /// ⛔ THE OWNER'S PICK, OPTION 1 "SOFT GREY CARD" (2026-11-06): his layout kept, made quiet. One
    /// quote: a 32pt photo with the name and the time on one line; under the name, what they wrote;
    /// then my post in a soft grey card; the quote's views last. Everything after the first line starts under the name (`indent`).
    private let indent: CGFloat = 41

    private func quote(_ it: QuotedInItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AvatarView(name: it.title, photoUrl: it.photoUrl.isEmpty ? nil : it.photoUrl, size: 32)
                    .environment(\.avatarSquircle, true)
                Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if it.verified {
                    Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue)
                }
                Spacer(minLength: 6)
                Text(Calendar.current.isDateInToday(it.at) ? it.at.formatted(date: .omitted, time: .shortened)
                                                           : it.at.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !it.text.isEmpty {
                Text(it.text).font(.subheadline).lineLimit(4)
                    .padding(.leading, indent).padding(.top, 4)
            }
            card
                .padding(.leading, indent).padding(.top, 8)
            Label(it.views.formatted(.number.notation(.compactName)) + (it.views == 1 ? " view" : " views"),
                  systemImage: "eye")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, indent).padding(.top, 6)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// My post, the same in every row: a soft grey card with no border (the owner's option 1,
    /// 2026-11-06), its channel, its picture and words.
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AvatarView(name: sourceTitle, photoUrl: sourcePhoto, size: 16)
                    .environment(\.avatarSquircle, true)
                Text(sourceTitle).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                if sourceVerified {
                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue)
                }
            }
            HStack(alignment: .center, spacing: 9) {
                cardPicture
                Text(postText).font(.footnote).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(Self.cardGrey), in: RoundedRectangle(cornerRadius: 18, style: .continuous))   // the bubble's corners
    }

    @ViewBuilder private var cardPicture: some View {
        if let thumb {
            Image(uiImage: thumb).resizable().scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let post, hasPicture(post) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: kindIcon(post)).font(.caption).foregroundStyle(.secondary))
        }
    }

    private var postText: String {
        guard let post else { return "Channel post" }
        return post.text.isEmpty ? kindName(post) : post.text
    }

    private func hasPicture(_ m: Message) -> Bool { !m.album.isEmpty || m.type == "image" || m.type == "video" }

    private func kindIcon(_ m: Message) -> String {
        if !m.album.isEmpty { return "photo.on.rectangle" }
        switch m.type {
        case "image": return "photo"
        case "video": return "video"
        default: return "text.alignleft"
        }
    }

    private func kindName(_ m: Message) -> String {
        if !m.album.isEmpty { return "Album" }
        switch m.type {
        case "image": return "Photo"
        case "video": return "Video"
        default: return "Post"
        }
    }

    private func load() async {
        do {
            let r = try await Functions.functions(region: "me-central1").httpsCallable("getPostQuotes")
                .call(["cid": cid, "mid": mid])
            let d = r.data as? [String: Any] ?? [:]
            items = ((d["items"] as? [[String: Any]]) ?? []).compactMap(QuotedInItem.init)
            apply(d)
            loaded = true
        } catch {
            failed = true
        }
    }

    private func apply(_ d: [String: Any]) {
        total = (d["total"] as? NSNumber)?.intValue ?? items.count
        hidden = (d["hidden"] as? NSNumber)?.intValue ?? 0
        publicTotal = (d["publicTotal"] as? NSNumber)?.intValue ?? 0
        next = d["next"] as? String ?? ""
    }

    /// The next page (20), when the end of the list comes into view.
    private func loadMore() async {
        guard !next.isEmpty, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let r = try? await Functions.functions(region: "me-central1").httpsCallable("getPostQuotes")
            .call(["cid": cid, "mid": mid, "cursor": next]) else { return }
        let d = r.data as? [String: Any] ?? [:]
        let more = ((d["items"] as? [[String: Any]]) ?? []).compactMap(QuotedInItem.init)
        items += more.filter { m in !items.contains { $0.id == m.id } }
        apply(d)
    }
}

/// ⛔ SKELETON, NOT A SPINNER (owner 2026-11-06: "use skeleton loading"). Three quotes' shapes, the
/// layout the page is about to show (photo and name, a line of words, the outlined card with its
/// picture and lines), pulsing softly until the answer lands. Top-aligned like the real rows.
private struct QuotesSkeleton: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar(width: 180, height: 12).padding(.horizontal, 16).padding(.vertical, 14)
            ForEach(0..<3, id: \.self) { _ in
                row
                Divider().padding(.leading, 16)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .opacity(dim ? 0.45 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityLabel("Loading quotes")
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 130, height: 12)
                    bar(width: 80, height: 10)
                }
            }
            bar(width: 220, height: 12)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill).frame(width: 20, height: 20)
                    bar(width: 90, height: 10)
                    Spacer()
                    bar(width: 44, height: 10)
                }
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        bar(width: nil, height: 10)
                        bar(width: 140, height: 10)
                    }
                }
                bar(width: 60, height: 9)
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var fill: Color { Color.secondary.opacity(0.16) }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        Capsule().fill(fill).frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

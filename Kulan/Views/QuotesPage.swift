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

    @Environment(\.dismiss) private var dismiss
    @State private var items: [QuotedInItem] = []
    @State private var total = 0
    @State private var hidden = 0
    @State private var loaded = false
    @State private var failed = false
    @State private var thumb: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if loaded {
                        Text(summary)
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        ForEach(items) { it in
                            Button { onOpen(it) } label: { quote(it) }
                                .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                        if hidden > 0 {
                            Label("\(hidden) more in private chats and groups", systemImage: "lock.fill")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                }
            }
            .overlay { overlay }
            .navigationTitle("Quotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
            .task { thumb = await picture() }
        }
    }

    @ViewBuilder private var overlay: some View {
        if failed {
            ContentUnavailableView("Couldn't load quotes", image: "ic_quote",
                                   description: Text("Check your connection and try again."))
        } else if !loaded {
            ProgressView()
        } else if items.isEmpty && hidden == 0 {
            ContentUnavailableView("No quotes yet", image: "ic_quote")
        }
    }

    private var summary: String {
        let channels = Set(items.map(\.cid)).count
        let views = items.reduce(0) { $0 + $1.views }
        let q = "\(total.formatted()) \(total == 1 ? "quote" : "quotes")"
        let c = "\(channels) \(channels == 1 ? "channel" : "channels")"
        let v = views.formatted(.number.notation(.compactName)) + (views == 1 ? " view" : " views")
        return q + " · " + c + " · " + v
    }

    /// One quote: who, what they wrote, then my post as an outlined card.
    private func quote(_ it: QuotedInItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(name: it.title, photoUrl: it.photoUrl.isEmpty ? nil : it.photoUrl, size: 40)
                    .environment(\.avatarSquircle, true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(it.title).font(.body.weight(.semibold)).lineLimit(1)
                        if it.verified {
                            Image(systemName: "checkmark.seal.fill").font(.subheadline).foregroundStyle(.blue)
                        }
                    }
                    Text(it.followers.formatted(.number.notation(.compactName))
                         + (it.followers == 1 ? " follower" : " followers"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !it.text.isEmpty {
                Text(it.text).font(.body).lineLimit(4)
            }
            card(it)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func card(_ it: QuotedInItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AvatarView(name: sourceTitle, photoUrl: sourcePhoto, size: 20)
                    .environment(\.avatarSquircle, true)
                Text(sourceTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                if sourceVerified {
                    Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue)
                }
                Spacer(minLength: 6)
                Text(it.at.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                cardPicture
                Text(postText).font(.subheadline).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Label(it.views.formatted(.number.notation(.compactName)) + (it.views == 1 ? " view" : " views"),
                  systemImage: "eye")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder private var cardPicture: some View {
        if let thumb {
            Image(uiImage: thumb).resizable().scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let post, hasPicture(post) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: kindIcon(post)).foregroundStyle(.secondary))
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
            total = (d["total"] as? NSNumber)?.intValue ?? items.count
            hidden = (d["hidden"] as? NSNumber)?.intValue ?? 0
            loaded = true
        } catch {
            failed = true
        }
    }
}

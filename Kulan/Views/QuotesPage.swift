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

/// ⛔ WHO QUOTED A POST (owner 2026-11-06, his pick of the previews): the post on top, its numbers,
/// then each quote in a public channel as a card with its views, most seen first. Quotes in private
/// chats, groups and private channels are only a number: the server never names them
/// (`getPostQuotes`). Opens from the "N Quotes" bar under a channel post.
struct QuotesPage: View {
    let cid: String
    let mid: String
    let post: Message?
    var onOpen: (QuotedInItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [QuotedInItem] = []
    @State private var total = 0
    @State private var hidden = 0
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let post { Section { header(post) } }
                if loaded {
                    Section { numbers }
                    if !items.isEmpty {
                        Section("Public channels") {
                            ForEach(items) { it in
                                Button { onOpen(it) } label: { row(it) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if hidden > 0 {
                        Section {
                            Label("\(hidden) more in private chats and groups", systemImage: "lock.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if failed {
                    ContentUnavailableView("Couldn't load quotes", systemImage: "quote.opening",
                                           description: Text("Check your connection and try again."))
                } else if !loaded {
                    ProgressView()
                }
            }
            .navigationTitle("Quotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func header(_ m: Message) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kindIcon(m))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(m.text.isEmpty ? kindName(m) : m.text).lineLimit(2)
                Text("Posted \(m.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var numbers: some View {
        HStack {
            stat(total, total == 1 ? "quote" : "quotes")
            stat(Set(items.map(\.cid)).count, "channels")
            stat(items.reduce(0) { $0 + $1.views }, "views")
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(n.formatted(.number.notation(.compactName))).font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ it: QuotedInItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: it.title, photoUrl: it.photoUrl.isEmpty ? nil : it.photoUrl, size: 36)
                .environment(\.avatarSquircle, true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if it.verified {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue)
                    }
                    Spacer(minLength: 6)
                    Text(it.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if it.text.isEmpty {
                    Text("Quote with no text").font(.subheadline).italic().foregroundStyle(.secondary)
                } else {
                    Text(it.text).font(.subheadline).lineLimit(3)
                }
                Label(it.views.formatted(.number.notation(.compactName)) + (it.views == 1 ? " view" : " views"),
                      systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

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

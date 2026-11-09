import SwiftUI
import FirebaseFunctions

/// ⛔ WHO REACTED TO MY COMMENT (owner 2026-11-09, design 3 "emoji tabs", as a sheet). A reaction
/// row with more than one person opens this over the Activity page: my comment and its post at the
/// top, All / one tab per emoji, then the people (face with their emoji, name, @handle, how long
/// ago). A person is shown only (no profile opens); the comment line opens the comment in the post's Replies.
/// The list comes from groups:getReplyReactors, which only the comment's author may call.
struct ActivityReactorsSheet: View {
    let item: ActivityItem
    var onOpenComment: () -> Void

    struct Person: Identifiable, Hashable {
        let uid: String
        let name: String
        let photo: String
        let handle: String
        let emoji: String
        let at: Date
        var id: String { uid.isEmpty ? "ch-\(name)" : uid }
    }

    @State private var tab = ""              // "" = All, else one emoji
    @State private var people: [Person] = []
    @State private var next = ""
    @State private var loading = true   // the first page is asked for at once (no "No reactions" flash)
    @State private var failed = false
    /// The comment is gone (the server answered not-found): no retry, say so.
    @State private var gone = false
    /// Bumped by every fresh load (a tab change, Try Again): an answer for an older one is dropped.
    @State private var generation = 0
    @State private var counts: [ActivityItem.Count] = []
    @State private var total = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                tabs
                list
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
            // A standard sheet (owner 2026-11-09 "make it real apple sheet"): title bar with a close X.
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            counts = item.rx
            total = item.rx.reduce(0) { $0 + $1.count }
            await load(reset: true)
        }
    }

    // The comment and its post, as a card (owner 2026-11-09: the old one-line preview looked small);
    // a tap opens the comment where it is.
    private var header: some View {
        Button(action: onOpenComment) {
            HStack(alignment: .center, spacing: 14) {
                if !item.thumb.isEmpty {
                    ActivityThumb(url: item.thumb, video: item.thumbIsVideo)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text((item.mineIsAnswer ? "Your reply in " : "Your comment in ") + (item.chTitle.isEmpty ? "a channel" : item.chTitle))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Text(item.mineText.isEmpty ? " " : item.mineText)
                        .font(.system(size: 17)).foregroundStyle(.primary)
                        .lineLimit(3).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
    }

    // All, then one tab per emoji, most used first; the look of the Replies sheet's Top / Newest.
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All \(total)", "")
                ForEach(counts, id: \.emoji) { c in chip("\(c.emoji) \(c.count)", c.emoji) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func chip(_ title: String, _ key: String) -> some View {
        let on = tab == key
        return Button {
            guard tab != key else { return }
            tab = key
            people = []   // the old tab's people never stand under the new chip
            Task { await load(reset: true) }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(on ? Color(.tertiarySystemFill) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var list: some View {
        if gone {
            Text("This comment was deleted")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else if failed && people.isEmpty {
            VStack(spacing: 6) {
                Text("Couldn't load reactions").font(.system(size: 15, weight: .semibold))
                Text("Check your connection and try again.").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("Try Again") { Task { await load(reset: true) } }
                    .font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            }
            .frame(maxWidth: .infinity).padding(.top, 40)
        } else if loading && people.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if people.isEmpty {
            Text("No reactions")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(people) { p in
                        // A person here is only shown, not opened (owner 2026-11-09: "when i click
                        // that profile avatar plz dont open profile").
                        row(p)
                            .onAppear { if p == people.last, !next.isEmpty { Task { await load(reset: false) } } }
                    }
                }
            }
        }
    }

    private func row(_ p: Person) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: p.name, photoUrl: p.photo.isEmpty ? nil : p.photo, size: 48)
                .frame(width: 48, height: 48)
                .overlay(alignment: .bottomTrailing) {
                    Text(p.emoji)
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .background(Color(.systemGray5), in: Circle())
                        .padding(2)
                        .background(Color(.systemBackground), in: Circle())
                        .offset(x: 5, y: 5)
                }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    if !p.handle.isEmpty {
                        Text("@" + p.handle).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(ActivityTime.age(p.at)).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .contentShape(Rectangle())
    }

    /// ⛔ ONE ANSWER PER TAB (audit A8): a tab tapped while a page was loading used to be dropped
    /// (`guard !loading`), and the old tab's people then filled the new tab. A fresh load always
    /// starts and bumps `generation`; an answer whose generation is no longer current is thrown away.
    /// ⛔ AND A PAGE WITH NOBODY IN IT IS NOT THE END (audit A7): the server reads a page of
    /// reactions and then keeps one emoji's, so a tab can get an empty page with more behind it.
    /// More rows load only from the last row's `onAppear`, which never fires with no rows, so the
    /// pages are walked here until someone shows up or there are no more.
    private func load(reset: Bool) async {
        if reset {
            generation += 1
        } else if loading || next.isEmpty {
            return
        }
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        let aid = item.mine.aid == item.mine.rid ? "" : item.mine.aid
        var cursor = reset ? "" : next
        var found: [Person] = []
        do {
            for _ in 0..<20 {
                let args: [String: Any] = ["cid": item.cid, "mid": item.mid, "rid": item.mine.rid, "aid": aid,
                                           "emoji": tab, "cursor": cursor]
                let res = try await Functions.functions(region: "me-central1")
                    .httpsCallable("getReplyReactors").call(args)
                guard gen == generation else { return }
                let d = res.data as? [String: Any] ?? [:]
                let page: [Person] = (d["people"] as? [[String: Any]] ?? []).map { r in
                    Person(uid: r["u"] as? String ?? "", name: r["n"] as? String ?? "Someone",
                           photo: r["p"] as? String ?? "", handle: r["h"] as? String ?? "",
                           emoji: r["e"] as? String ?? "❤️",
                           at: Date(timeIntervalSince1970: ((r["at"] as? NSNumber)?.doubleValue ?? 0) / 1000))
                }
                if let rx = d["rx"] as? [String: Any] {
                    counts = rx.compactMap { k, v in (v as? NSNumber).map { ActivityItem.Count(emoji: k, count: $0.intValue) } }
                        .filter { $0.count > 0 }.sorted { $0.count > $1.count }
                }
                if let t = (d["total"] as? NSNumber)?.intValue { total = t }
                found += page
                cursor = d["next"] as? String ?? ""
                if !page.isEmpty || cursor.isEmpty { break }
            }
            next = cursor
            let base = reset ? [] : people
            var seen = Set(base.map(\.id))
            people = base + found.filter { seen.insert($0.id).inserted }
            failed = false
            gone = false
        } catch {
            guard gen == generation else { return }
            // The comment was deleted since the row was written (getReplyReactors: not-found).
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain, ns.code == FunctionsErrorCode.notFound.rawValue {
                gone = true
            }
            failed = true
        }
    }
}

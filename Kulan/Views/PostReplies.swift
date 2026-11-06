import SwiftUI
import FirebaseFunctions

/// One reply under a channel post, as `getReplies` / `addReply` answer it.
struct PostReply: Identifiable, Equatable {
    var id: String
    var uid: String
    var name: String
    var photoUrl: String
    var verified: Bool
    var text: String
    var at: Date
    var mine: Bool
    var canDelete: Bool

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let uid = d["uid"] as? String else { return nil }
        self.id = id
        self.uid = uid
        name = d["name"] as? String ?? "Someone"
        photoUrl = d["photoUrl"] as? String ?? ""
        verified = d["verified"] as? Bool ?? false
        text = d["text"] as? String ?? ""
        at = Date(timeIntervalSince1970: ((d["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        mine = d["mine"] as? Bool ?? false
        canDelete = d["canDelete"] as? Bool ?? false
    }
}

/// ⛔ REPLIES AND QUOTES UNDER A CHANNEL POST (owner 2026-11-06: "this bottom bar: Replies, Quotes;
/// it opens a sheet where people send replies, with tabs, Quotes shows the quotes"). Opens on
/// Replies. The channel's admins turn replies off here, for this post or for the whole channel.
struct PostThreadSheet: View {
    enum Tab: Hashable { case replies, quotes }

    let cid: String
    let mid: String
    let post: Message?
    var sourceTitle: String
    var sourcePhoto: String?
    var sourceVerified: Bool
    var picture: () async -> UIImage?
    var onOpen: (QuotedInItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .replies
    @State private var replies: [PostReply] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var off = false
    @State private var channelOff = false
    @State private var postOff = false
    @State private var staff = false
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Replies").tag(Tab.replies)
                    Text("Quotes").tag(Tab.quotes)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                if tab == .replies {
                    repliesTab
                } else {
                    QuotesPage(cid: cid, mid: mid, post: post, sourceTitle: sourceTitle, sourcePhoto: sourcePhoto,
                               sourceVerified: sourceVerified, picture: picture, onOpen: onOpen, embedded: true)
                }
            }
            .navigationTitle(tab == .replies ? "Replies" : "Quotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if staff {
                    ToolbarItem(placement: .topBarLeading) { adminMenu }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
        // While the sheet is open, new replies arrive every few seconds.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if tab == .replies { await load() }
            }
        }
    }

    // MARK: Replies

    private var repliesTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(replies) { r in
                            row(r).id(r.id)
                            Divider().padding(.leading, 57)
                        }
                    }
                }
                .overlay { repliesOverlay }
                .onChange(of: replies.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            composer
        }
    }

    @ViewBuilder private var repliesOverlay: some View {
        if failed && replies.isEmpty {
            ContentUnavailableView("Couldn't load replies", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Check your connection and try again."))
        } else if !loaded {
            ProgressView()
        } else if replies.isEmpty {
            ContentUnavailableView(off ? "Replies are off" : "No replies yet",
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text(off ? "The channel turned off replies for this post."
                                                         : "Be the first to reply."))
        }
    }

    private func row(_ r: PostReply) -> some View {
        HStack(alignment: .top, spacing: 9) {
            AvatarView(name: r.name, photoUrl: r.photoUrl.isEmpty ? nil : r.photoUrl, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if r.verified {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue)
                    }
                    Spacer(minLength: 6)
                    Text(r.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(r.text).font(.subheadline).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button { UIPasteboard.general.string = r.text } label: { Label("Copy", systemImage: "doc.on.doc") }
            if r.canDelete {
                Button(role: .destructive) { Task { await delete(r) } } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder private var composer: some View {
        if off {
            Text("Replies are turned off for this post.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(14)
        } else if loaded {
            HStack(spacing: 8) {
                TextField("Reply", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($fieldFocused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var adminMenu: some View {
        Menu {
            Button {
                Task { await setOff(post: true, off: !postOff) }
            } label: {
                Label(postOff ? "Turn On Replies for This Post" : "Turn Off Replies for This Post",
                      systemImage: postOff ? "bubble.left" : "bubble.left.slash")
            }
            Button {
                Task { await setOff(post: false, off: !channelOff) }
            } label: {
                Label(channelOff ? "Turn On Replies in Channel" : "Turn Off Replies in Channel",
                      systemImage: channelOff ? "bubble.left.and.bubble.right" : "bubble.left.and.bubble.right.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    // MARK: Server

    private var fn: Functions { Functions.functions(region: "me-central1") }

    private func load() async {
        do {
            let r = try await fn.httpsCallable("getReplies").call(["cid": cid, "mid": mid])
            let d = r.data as? [String: Any] ?? [:]
            let list = ((d["replies"] as? [[String: Any]]) ?? []).compactMap(PostReply.init)
            if list != replies { replies = list }
            off = d["off"] as? Bool ?? false
            channelOff = d["channelOff"] as? Bool ?? false
            postOff = d["postOff"] as? Bool ?? false
            staff = d["staff"] as? Bool ?? false
            loaded = true
            failed = false
        } catch {
            failed = true
            loaded = true
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        draft = ""
        defer { sending = false }
        do {
            let r = try await fn.httpsCallable("addReply").call(["cid": cid, "mid": mid, "text": text])
            if let d = (r.data as? [String: Any])?["reply"] as? [String: Any], let reply = PostReply(d) {
                replies.append(reply)
            }
        } catch {
            if draft.isEmpty { draft = text }   // the words come back to try again
        }
    }

    private func delete(_ r: PostReply) async {
        let before = replies
        replies.removeAll { $0.id == r.id }
        do {
            _ = try await fn.httpsCallable("deleteReply").call(["cid": cid, "mid": mid, "rid": r.id])
        } catch {
            replies = before
        }
    }

    private func setOff(post: Bool, off newValue: Bool) async {
        var args: [String: Any] = ["cid": cid, "off": newValue]
        if post { args["mid"] = mid }
        do {
            _ = try await fn.httpsCallable("setReplies").call(args)
            await load()
        } catch {}
    }
}

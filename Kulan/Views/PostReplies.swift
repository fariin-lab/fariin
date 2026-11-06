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
    /// The reply this one answers ("" = it starts a thread). One level deep (server `addReply`).
    var parentId: String
    var likes: Int
    var liked: Bool

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
        parentId = d["parentId"] as? String ?? ""
        likes = (d["likes"] as? NSNumber)?.intValue ?? 0
        liked = d["liked"] as? Bool ?? false
    }
}

/// ⛔ REPLIES AND QUOTES UNDER A CHANNEL POST (owner 2026-11-06). A sheet with two tabs, opening on
/// Replies. Replies are bubbles with the person's photo beside them and their name and age above;
/// a heart on each (tap the heart, or double-tap the bubble), and answers to a reply gathered under
/// it behind "View N replies". The field at the bottom answers the post, or the reply picked with
/// Reply. The channel's admins turn replies off here, for this post or the whole channel.
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
    @State private var answering: PostReply?
    @State private var open: Set<String> = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker("", selection: $tab) {
                    Text("Replies").tag(Tab.replies)
                    Text("Quotes").tag(Tab.quotes)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 8)
                if tab == .replies {
                    repliesTab
                } else {
                    QuotesPage(cid: cid, mid: mid, post: post, sourceTitle: sourceTitle, sourcePhoto: sourcePhoto,
                               sourceVerified: sourceVerified, picture: picture, onOpen: onOpen, embedded: true)
                }
            }
            .toolbar {
                if staff {
                    ToolbarItem(placement: .topBarLeading) { adminMenu }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
        // While the sheet is open, new replies and hearts arrive every few seconds.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if tab == .replies, !sending { await load() }
            }
        }
    }

    /// The channel's photo, the tab's name and the post's opening words in quotes.
    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: sourceTitle, photoUrl: sourcePhoto, size: 36)
                .environment(\.avatarSquircle, true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab == .replies ? "Replies" : "Quotes").font(.headline)
                if let t = post?.text, !t.isEmpty {
                    Text("\u{201C}\(t)\u{201D}").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Replies

    private var threads: [PostReply] { replies.filter { $0.parentId.isEmpty } }
    private func answers(_ id: String) -> [PostReply] { replies.filter { $0.parentId == id } }

    private var repliesTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(threads) { r in
                            thread(r).id(r.id)
                        }
                        Color.clear.frame(height: 8).id("end")
                    }
                    .padding(.top, 4)
                }
                .scrollDismissesKeyboard(.interactively)
                .overlay { repliesOverlay }
                .onChange(of: replies.count) { old, new in
                    guard new > old, loaded else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            composer
        }
    }

    @ViewBuilder private func thread(_ r: PostReply) -> some View {
        let kids = answers(r.id)
        VStack(alignment: .leading, spacing: 0) {
            row(r, small: false)
            if !kids.isEmpty {
                if open.contains(r.id) {
                    ForEach(kids) { k in row(k, small: true).padding(.leading, 46) }
                    threadToggle("Hide replies", r.id)
                } else {
                    threadToggle("View \(kids.count) \(kids.count == 1 ? "reply" : "replies")", r.id)
                }
            }
        }
    }

    private func threadToggle(_ title: String, _ id: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if open.contains(id) { open.remove(id) } else { open.insert(id) }
            }
        } label: {
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 20, height: 1)
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 62).padding(.bottom, 10)
    }

    private func row(_ r: PostReply, small: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: r.name, photoUrl: r.photoUrl.isEmpty ? nil : r.photoUrl, size: small ? 26 : 34)
                .padding(.top, 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(r.name).font(.footnote.weight(.semibold)).lineLimit(1)
                    if r.verified {
                        Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue)
                    }
                    Text(Self.age(r.at)).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
                Text(r.text)
                    .font(small ? .subheadline : .body)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture(count: 2) { Task { await toggleLike(r) } }
                    .contextMenu {
                        if !off { Button { startAnswer(r) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") } }
                        Button { UIPasteboard.general.string = r.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if r.canDelete {
                            Button(role: .destructive) { Task { await delete(r) } } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                HStack(spacing: 14) {
                    Button { Task { await toggleLike(r) } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: r.liked ? "heart.fill" : "heart")
                                .foregroundStyle(r.liked ? Color.red : Color.secondary)
                            if r.likes > 0 { Text(r.likes.formatted()).foregroundStyle(.secondary) }
                        }
                        .font(.caption.weight(.semibold))
                    }
                    if !off {
                        Button { startAnswer(r) } label: {
                            Text("Reply").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 6).padding(.top, 2)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    /// "now", "5m", "3h", "2d", "6w": the age of a reply, short.
    private static func age(_ d: Date) -> String {
        let s = max(0, Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        return "\(Int(s / (7 * 86_400)))w"
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

    @ViewBuilder private var composer: some View {
        if off {
            Text("Replies are turned off for this post.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(14)
        } else if loaded {
            VStack(spacing: 6) {
                if let a = answering {
                    HStack {
                        Text("Replying to \(a.name)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { answering = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                }
                HStack(spacing: 8) {
                    TextField("Add a reply…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($fieldFocused)
                    Button("Send") { Task { await send() } }
                        .font(.body.weight(.semibold))
                        .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
        }
    }

    private func startAnswer(_ r: PostReply) {
        answering = r
        // Its thread opens, so the answer is seen landing under it.
        open.insert(r.parentId.isEmpty ? r.id : r.parentId)
        fieldFocused = true
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
        let parent = answering
        draft = ""
        answering = nil
        defer { sending = false }
        do {
            var args: [String: Any] = ["cid": cid, "mid": mid, "text": text]
            if let parent { args["parentId"] = parent.id }
            let r = try await fn.httpsCallable("addReply").call(args)
            if let d = (r.data as? [String: Any])?["reply"] as? [String: Any], let reply = PostReply(d) {
                replies.append(reply)
                if !reply.parentId.isEmpty { open.insert(reply.parentId) }
            }
        } catch {
            if draft.isEmpty { draft = text }   // the words come back to try again
            answering = parent
        }
    }

    private func toggleLike(_ r: PostReply) async {
        guard let i = replies.firstIndex(where: { $0.id == r.id }) else { return }
        let before = replies[i]
        let on = !before.liked
        replies[i].liked = on
        replies[i].likes = max(0, before.likes + (on ? 1 : -1))
        if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        do {
            _ = try await fn.httpsCallable("likeReply").call(["cid": cid, "mid": mid, "rid": r.id, "on": on])
        } catch {
            if let j = replies.firstIndex(where: { $0.id == r.id }) { replies[j] = before }
        }
    }

    private func delete(_ r: PostReply) async {
        let before = replies
        replies.removeAll { $0.id == r.id || $0.parentId == r.id }
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

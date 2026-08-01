import SwiftUI

// Forward a message to one or more chats. Pick chats (multi-select), optionally add your own
// text, tap Send — the sheet closes INSTANTLY (owner's pick, WhatsApp model) and the re-sends
// run behind: each message re-encrypts for its target via ChatService.forwardMessage, then the
// added text follows as its own message. onQueued fires a "Sent to …" toast at close;
// onFailed reports a partial failure honestly instead of holding the sheet hostage.
struct ForwardPicker: View {
    let messages: [Message]           // one or many (bulk forward)
    let sourceCid: String
    var onSent: () -> Void = {}       // fired at close (e.g. exit selection mode)
    var onQueued: (String) -> Void = { _ in }   // toast label ("Sent to Adnan")
    var onFailed: () -> Void = {}     // something didn't arrive after the background run

    // Single-message convenience (unchanged call sites).
    init(message: Message, sourceCid: String, onSent: @escaping () -> Void = {},
         onQueued: @escaping (String) -> Void = { _ in }, onFailed: @escaping () -> Void = {}) {
        self.messages = [message]; self.sourceCid = sourceCid
        self.onSent = onSent; self.onQueued = onQueued; self.onFailed = onFailed
    }
    init(messages: [Message], sourceCid: String, onSent: @escaping () -> Void = {},
         onQueued: @escaping (String) -> Void = { _ in }, onFailed: @escaping () -> Void = {}) {
        self.messages = messages; self.sourceCid = sourceCid
        self.onSent = onSent; self.onQueued = onQueued; self.onFailed = onFailed
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme   // send button tint matches the bubble colour
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var comment = ""

    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // The SOURCE chat is offered too (owner's 416 report: "app won't show him to send since am
        // sending from he's chat") — forwarding back into the same chat re-surfaces an old photo,
        // and the references both allow it.
        let list = repo.conversations.filter { ((Flags.groupsEnabled && $0.isGroup) || !$0.otherUid(me).isEmpty) && (Flags.groupsEnabled || !$0.isGroup) }
        return (q.isEmpty ? list : list.filter { $0.displayName(me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    private var snippet: String {
        if messages.count > 1 { return "\(messages.count) messages" }
        let message = messages[0]
        if message.isAlbum { return "Album · \(message.album.count) items" }
        if message.isImage { return "Photo" }
        if message.isVideo { return "Video" }
        if message.isAudio { return "Voice message" }
        if message.isGif { return "GIF" }
        if message.isSticker { return message.stickerEmoji.map { "\($0) Sticker" } ?? "Sticker" }
        return message.safeText   // never leak a raw kulan-…: marker (contact/location card)
    }

    // WHAT you're forwarding, visibly (owner's 416 report vs WhatsApp: "won't show what u
    // forwarding?"): real decrypted thumbnails for media — the same SecureImageView the chat
    // renders with — as an overlapping stack, with a quote line for text-only forwards.
    private struct Thumb { let url: String; let enc: EncMeta?; let isVideo: Bool; var isSticker = false }
    private var previewThumbs: [Thumb] {
        var out: [Thumb] = []
        for m in messages {
            if m.isAlbum {
                for it in m.album {
                    out.append(Thumb(url: it.imageUrl, enc: it.enc, isVideo: it.isVideo))
                    if out.count >= 3 { return out }
                }
            } else if m.isImage, let u = m.imageUrl {
                out.append(Thumb(url: u, enc: m.enc, isVideo: false))
            } else if m.isVideo, let t = m.thumbUrl {
                out.append(Thumb(url: t, enc: m.thumbEnc, isVideo: true))
            } else if m.isGif, let u = m.imageUrl {
                out.append(Thumb(url: u, enc: nil, isVideo: false))
            } else if m.isSticker, let u = m.imageUrl {
                // Not a SecureImageView url: a sticker is public and unsealed, so it is flagged with
                // a nil enc and drawn by the sticker path instead of the decrypting one.
                out.append(Thumb(url: u, enc: nil, isVideo: false, isSticker: true))
            }
            if out.count >= 3 { return out }
        }
        return out
    }

    @ViewBuilder private var forwardingPreview: some View {
        let thumbs = previewThumbs
        HStack(spacing: 12) {
            if !thumbs.isEmpty {
                HStack(spacing: -14) {   // overlapping stack — the reference feel, our drawing
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { i, t in
                        Group {
                            if t.isSticker {
                                // Padded, because a sticker is see-through: drawn edge to edge in a
                                // 48pt tile it reads as a crop of itself rather than as a sticker.
                                StickerImageView(url: t.url, fadeIn: false).padding(4)
                            } else {
                                SecureImageView(imageUrl: t.url, enc: t.enc, cid: sourceCid)
                            }
                        }
                            .frame(width: 48, height: 48)
                            .background(t.isSticker ? Color(uiColor: .secondarySystemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                                if t.isVideo {
                                    Image(systemName: "play.circle.fill").font(.system(size: 16))
                                        .foregroundStyle(.white).shadow(radius: 2)
                                }
                            }
                            .zIndex(Double(thumbs.count - i))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Forwarding").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(snippet).font(.system(size: 15)).foregroundStyle(.primary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// The bottom bar IS the chat composer, on purpose.
    ///
    /// Send used to live in the top-right toolbar while the text field sat at the bottom, so you
    /// typed down here and then reached the whole height of the screen to send. WhatsApp and the
    /// apps copying it put send beside the text, and on that one detail they are simply right: your
    /// thumb is already there.
    ///
    /// But rather than reproduce their bar, this reuses OURS. Same capsule, same round glass send
    /// button, same tint as the message bubbles. A forward is you writing a message, so it should
    /// look like writing a message, and anyone who has used the app already knows this control.
    @ViewBuilder private var forwardComposer: some View {
        VStack(spacing: 8) {
            // WHO it is going to, as faces rather than a list of names. Every person already has a
            // colour of their own, so a row of circles is read at a glance where names have to be
            // read one at a time. It also survives picking eight people, which names do not.
            if selected.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: -8) {
                        ForEach(people.filter { selected.contains($0.id) }) { c in
                            AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 28)
                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 30)
            }
            HStack(spacing: 10) {
                TextField("Add a message…", text: $comment, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    // A filled capsule on the bar's own material, with a hairline, so it reads as a
                    // composer rather than a search field. A plain material capsule is exactly what
                    // iOS search looks like, and with search sitting under it the two were
                    // indistinguishable (owner screenshot).
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                Button { sendAll() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(scheme == .dark))
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // Split out of `body`. With the composer and its avatar strip added, the whole thing in one
    // expression pushed the SwiftUI type-checker past giving up: it stopped inferring `Group`'s
    // content and reported that it could not convert a ContentUnavailableView to a TableColumn,
    // which says nothing about the real problem. Same reason ContactInfoView is split into layers.
    @ViewBuilder private var peopleList: some View {
        List {
            Section {
                ForEach(people) { c in
                    Button { toggle(c.id) } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 44)
                            Text(c.displayName(me))
                                .font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(selected.contains(c.id) ? Color.accentColor : Color.secondary)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            } header: {
                forwardingPreview.textCase(nil)
            }
        }
        .listStyle(.plain)
        // SWIPE THE LIST TO PUT THE KEYBOARD AWAY. There was no way out of it: this screen has no
        // Done button, and tapping a row picks that person rather than dismissing, so once the
        // message box had focus the keyboard stayed up over half the list (owner screenshot).
        // Interactive, so it follows the finger, the same gesture the chat itself uses.
        .scrollDismissesKeyboard(.interactively)
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView("No other chats", systemImage: "paperplane",
                                           description: Text("Start another chat to forward into it."))
                } else {
                    peopleList
                }
            }
            // PINNED UNDER THE TITLE. iOS 26 puts search at the BOTTOM by default, which landed it
            // directly beneath the message box and gave the screen two stacked input fields, so the
            // one you type into read as a second search bar (owner screenshot). Search belongs at the
            // top with the list it filters; the bottom belongs to the message you are sending.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search")
            // Add-your-own-text (owner's pick): appears once a chat is chosen; lands as its OWN
            // message right after the forwards, in every picked chat — never glued to a caption.
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty { forwardComposer }
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
                // Send lives in the composer now, next to the text. Kept here ONLY for the moment
                // before anyone is picked, when there is no composer on screen to hold it, so the
                // screen still explains what it is for.
                ToolbarItem(placement: .topBarTrailing) {
                    if selected.isEmpty {
                        Button("Send") { }.disabled(true).fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func sendAll() {
        let targets = selected
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        // Oldest first so forwarded messages land in the same order they were sent.
        let ordered = messages.sorted { $0.createdAt < $1.createdAt }
        let src = sourceCid
        let queued = onQueued, failed = onFailed
        onSent()
        dismiss()
        // Telegram model (owner's 416 report: "i still land on where i sent from"): forwarding to
        // ONE chat lands you IN that chat — watching your forward arrive IS the confirmation, so no
        // toast there. Several chats can't all be landed in → stay put, the toast confirms instead.
        // Same route a banner tap uses; MainShell foregrounds Chats and pushes.
        // OPTIMISTIC BUBBLES FIRST, before the navigation below, so the target chat's repository
        // finds them the moment it starts and the forward is on screen in the first frame.
        //
        // Why a forward needed this at all: a normal send shows its bubble instantly from the bytes
        // already on the phone, but a forward went straight to ChatService and showed NOTHING until a
        // download, a decrypt, a re-encrypt and an upload had all finished. You landed in the chat and
        // watched an empty space (owner report). The bubble now appears immediately and the real
        // message replaces it in place, matched on this clientId.
        var ids: [String: [String]] = [:]   // cid -> clientIds, so a failure can clear the right ones
        for cid in targets where cid != src {
            for m in ordered {
                let clientId = UUID().uuidString
                var p = m
                p.clientId = clientId
                p.authorId = me
                p.createdAt = Date()
                p.sendState = .sending
                p.forwarded = true
                p.reactions = [:]     // reactions belong to the ORIGINAL message, not this copy
                p.replyTo = nil       // and so does whatever it was replying to over there
                PendingOutbox.add(p, to: cid)
                ids[cid, default: []].append(clientId)
            }
        }

        if targets.count == 1, let cid = targets.first {
            // Forwarding back into the chat you're standing in needs no navigation and no toast —
            // the sheet closes and the forward lands in front of you.
            if cid != src, let c = repo.conversations.first(where: { $0.id == cid }) {
                AppRouter.shared.pendingChatName = c.displayName(me)
                AppRouter.shared.pendingChatPhoto = c.displayPhoto(me)
                AppRouter.shared.pendingChatId = cid
            }
        } else {
            queued("Sent to \(targets.count) chats")
        }
        Task {
            var anyFailed = false
            for cid in targets {
                for (i, m) in ordered.enumerated() {
                    // Same clientId the bubble above carries, so the echo lands ON it.
                    let clientId = ids[cid]?[i]
                    do { try await ChatService.forwardMessage(m, from: src, to: cid, clientId: clientId) }
                    catch {
                        anyFailed = true
                        // Nothing is coming to replace this one. Clear it from BOTH places: the chat
                        // if it is already open, and the outbox if it has never been opened, or the
                        // user would meet a bubble stuck on "sending" whenever they got there.
                        if let clientId { PendingOutbox.markFailed(clientId: clientId) }
                    }
                }
                if !note.isEmpty {
                    do { try await ChatService.sendText(cid: cid, text: note) }
                    catch { anyFailed = true }
                }
            }
            if anyFailed { await MainActor.run { failed() } }
        }
    }
}

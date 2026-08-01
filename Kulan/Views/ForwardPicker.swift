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
        return message.safeText   // never leak a raw kulan-…: marker (contact/location card)
    }

    // WHAT you're forwarding, visibly (owner's 416 report vs WhatsApp: "won't show what u
    // forwarding?"): real decrypted thumbnails for media — the same SecureImageView the chat
    // renders with — as an overlapping stack, with a quote line for text-only forwards.
    private struct Thumb { let url: String; let enc: EncMeta?; let isVideo: Bool }
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
                        SecureImageView(imageUrl: t.url, enc: t.enc, cid: sourceCid)
                            .frame(width: 48, height: 48)
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

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView("No other chats", systemImage: "paperplane",
                                           description: Text("Start another chat to forward into it."))
                } else {
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
                }
            }
            .searchable(text: $query, prompt: "Search")
            // Add-your-own-text (owner's pick): appears once a chat is chosen; lands as its OWN
            // message right after the forwards, in every picked chat — never glued to a caption.
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    TextField("Add a message…", text: $comment, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { sendAll() }
                        .disabled(selected.isEmpty)
                        .fontWeight(.semibold)
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

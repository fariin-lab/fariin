import SwiftUI

// Forward a message to one or more chats. Pick chats (multi-select), optionally add your own
// text, tap Send — the sheet closes INSTANTLY (owner's pick, the reference app model) and the re-sends
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
            // Not a person I have blocked, and not a demo chat (audit, 2026-09-24). The thread takes
            // the composer away from a blocked chat, but this list still offered it, so a forward
            // walked round the block; a demo id is not a real conversation and every send to it fails.
            .filter { !$0.isBlockedByMe(me) && !DemoMode.isDemoConversation($0.id) }
            // 2026-09-24 decision D10: not an incoming request I have not answered. Sending into it
            // would accept it silently, and those chats are kept out of the main list anyway.
            .filter { MessageRequests.stance($0, myUid: me) != .incoming }
        return (q.isEmpty ? list : list.filter { $0.displayName(me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    // ⛔ NO "FORWARDING" PREVIEW — owner, 2026-09-29, with the reference's "Send to" sheet: "remove
    // the forwarding preview". The thumbnails-and-snippet header (his 416 ask) is gone; the sheet
    // is the people list alone.

    /// Second lines: the person's @handle from the on-disk cache (same source and rule as
    /// `NewChatView.loadHandles`: no network read, no handle = one-line row).
    @State private var handles: [String: String] = [:]

    /// ⛔ TWO SECTIONS — owner, 2026-09-29, the reference's "Frequently contacted" over "Recent
    /// chats". Same rule `NewChatView.frequent` uses for its own "Frequently contacted" (the most
    /// recent people; the app keeps no per-chat message count), five of them, and never the same
    /// chat twice: Recent chats starts where they stop. Only with enough chats for it to be a
    /// shortcut, and not while searching (one list of matches then).
    private var frequent: [Conversation] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty, people.count >= 8 else { return [] }
        return Array(people.filter { !$0.isGroup }.prefix(5))
    }
    private var recent: [Conversation] {
        let top = Set(frequent.map(\.id))
        return people.filter { !top.contains($0.id) }
    }

    /// The bottom bar IS the chat composer, on purpose.
    ///
    /// Send used to live in the top-right toolbar while the text field sat at the bottom, so you
    /// typed down here and then reached the whole height of the screen to send. the reference app and the
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
        // Rounded cards with inset separators, grey section titles above them: the reference's
        // sheet is the system's own inset-grouped list, so this is that list, not a drawing of it.
        List {
            if !frequent.isEmpty {
                Section { ForEach(frequent) { row($0) } } header: { sectionTitle("Frequently contacted") }
            }
            Section {
                ForEach(recent) { row($0) }
            } header: {
                if !frequent.isEmpty { sectionTitle("Recent chats") }
            }
        }
        .listStyle(.insetGrouped)
        .task { await loadHandles() }
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
            // "Send to", ✕ on the left — the reference's sheet (owner, 2026-09-29). Its right-hand
            // "New group" is not here: groups are switched off in this app (`Flags.groupsEnabled`),
            // and a button that leads nowhere is worse than none. The greyed "Send" that used to
            // sit there went with the preview; Send is the composer's, beside the text.
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary).textCase(nil)
    }

    private func row(_ c: Conversation) -> some View {
        let on = selected.contains(c.id)
        let handle = c.isGroup ? nil : handles[c.otherUid(me)]
        return Button { toggle(c.id) } label: {
            HStack(spacing: 12) {
                AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(c.displayName(me)).font(.system(size: 17)).foregroundStyle(.primary)
                        if !c.isGroup { VerifiedMark(uid: c.otherUid(me), size: 13) }
                    }
                    .lineLimit(1)
                    if let handle {
                        Text("@\(handle)").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // `Color.primary`, NOT `Color.accentColor`: the accent reads the environment's
                // TINT, which anything up the tree can pull grey (owner's rule, 2026-08-16).
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The separator starts at the name, not under the photo (the reference's rows).
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
    }

    private func loadHandles() async {
        var found: [String: String] = [:]
        for c in people where !c.isGroup {
            let uid = c.otherUid(me)
            guard !uid.isEmpty, found[uid] == nil else { continue }
            if let p = await ProfileStore.shared.cachedPeer(uid), !p.handle.isEmpty { found[uid] = p.handle }
        }
        if !found.isEmpty { handles = found }
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
        // the reference app model (owner's 416 report: "i still land on where i sent from"): forwarding to
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
        // THE POSTER, RESOLVED ONCE, BEFORE THE BUBBLES ARE BUILT.
        //
        // A forwarded copy carries the ORIGINAL message's `thumbUrl` and `thumbEnc`, and those were
        // sealed for the SOURCE conversation. The bubble renders with `SecureImageView(..., cid: cid)`
        // where cid is the TARGET chat, so it tries to open the source chat's thumbnail with the
        // target chat's key and cannot. The picture only appeared if the bytes happened to be sitting
        // in the cache already, and otherwise the bubble stayed blank until the real message came
        // back — which is the late draw the owner saw when forwarding a video.
        //
        // Handing the copy a LOCAL thumbnail sidesteps the key entirely, and it is what every other
        // optimistic bubble in the app already does: draw from bytes the phone is holding. A cache
        // miss changes nothing, so this can only ever make the bubble earlier.
        var posters: [String: Data] = [:]        // message id -> jpeg for the pending bubble
        var albumPosters: [String: [Data]] = [:] // message id -> one jpeg per album tile
        for m in ordered {
            // AN ALBUM HITS THE SAME WALL ONCE PER TILE. Every AlbumItem carries its own `enc`,
            // sealed for the source conversation, so a forwarded four-photo album had four thumbnails
            // it could not open and sat blank until the server echo — the owner timed it at 10.65s.
            // The single-message fix above did nothing for these, because an album's pictures are in
            // `album[i].imageUrl`, not in `thumbUrl`/`imageUrl`.
            if m.isAlbum, m.localAlbum.isEmpty, !m.album.isEmpty {
                var tiles: [Data] = []
                var gotAny = false
                for item in m.album {
                    if let ui = DiskImageCache.shared.smallImageSync(item.imageUrl),
                       let jpeg = ui.jpegData(compressionQuality: 0.8) {
                        tiles.append(jpeg); gotAny = true
                    } else {
                        // A miss stays a hole of the RIGHT LENGTH. The grid sizes itself from
                        // localAlbum.count once that array exists, and the tile falls through to the
                        // encrypted path on its own because UIImage(data:) of nothing is nil. So a
                        // partly-cached album draws the tiles it has and waits only for the rest.
                        tiles.append(Data())
                    }
                }
                if gotAny { albumPosters[m.id] = tiles }
                continue
            }
            guard m.localImageData == nil,
                  let url = m.thumbUrl ?? m.imageUrl, !url.isEmpty,
                  let ui = DiskImageCache.shared.smallImageSync(url),
                  let jpeg = ui.jpegData(compressionQuality: 0.8) else { continue }
            posters[m.id] = jpeg
        }

        var ids: [String: [String]] = [:]   // cid -> clientIds, so a failure can clear the right ones
        // The SOURCE chat used to be skipped here. The outbox is drained once when a repository
        // starts, so a bubble parked for the chat you are already standing in was never claimed and
        // a forward back into your own chat drew only when the server echoed — the one case where a
        // forward felt slower than a normal photo send, and the case people hit most, because the
        // chat you are reading is the obvious thing to forward into. PendingOutbox.didAdd now tells
        // an open chat to claim it, so every target is treated the same.
        for cid in targets {
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
                if p.localImageData == nil { p.localImageData = posters[m.id] }
                if p.localAlbum.isEmpty, let tiles = albumPosters[m.id] { p.localAlbum = tiles }
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

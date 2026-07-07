import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Telegram-style profile screen: hero avatar, quick-action tiles, bio card, and a
// shared-media card. Real where the data exists (name/@handle, mute, block, clear,
// shared media, bio); honest "coming soon" for features not built yet (calls live
// on a separate branch; in-chat search isn't built). No fabricated data — the title
// is the @handle (Kulan has no phone numbers).
// Where this profile was opened from — the action row + a call-log card adapt to it.
// From a chat: you're already chatting, so offer Search (not Message). From the Calls
// tab: offer Message (jump into the chat) + show the recent call with this person.
enum ProfileSource { case chat, calls }

struct ContactInfoView: View {
    let cid: String
    let name: String
    let photoUrl: String?
    var source: ProfileSource = .chat
    var isSelf: Bool = false   // your OWN profile (opened from your own story) → no call-yourself buttons

    @State private var handle = ""
    @State private var about = ""
    @State private var muted = false
    @State private var blocked = false
    @State private var loaded = false
    @State private var media: [Message] = []
    @State private var viewerImage: Message?
    @State private var showClear = false
    @State private var showBlock = false
    @State private var showReport = false
    @State private var showShare = false
    @State private var showCallSoon = false
    @State private var showSearchSoon = false
    @State private var showVideoSoon = false
    @State private var openChat = false
    @State private var showAllMedia = false
    @State private var showMuteOptions = false
    @State private var showDisappear = false
    @State private var disappearSeconds = 0
    @State private var pendingDisappear: Int?   // chosen timer awaiting the "for both of you" confirm
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var cardColor: Color { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF2F2F7) }
    private var otherUid: String {
        let me = AuthService.shared.uid ?? ""
        return cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                quickActions
                if source == .calls, lastCall != nil { callLogCard }
                if !about.isEmpty { bioCard }
                if !media.isEmpty { mediaCard }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("")   // name + @handle already show in the hero below
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)   // show nav bar (back + title) below the notch
        .toolbar(.hidden, for: .tabBar)           // hide the Chats/Calls/Settings bar — match
                                                  // the chat-opened profile (was still showing
                                                  // when opened from the Calls tab)
        .navigationBarBackButtonHidden(false)
        .task {
            await load()
            disappearSeconds = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.disappearSeconds ?? 0
        }
        .fullScreenCover(item: $viewerImage) { msg in ImageViewerView(message: msg, cid: cid) }
        .sheet(isPresented: $showAllMedia) { SharedMediaGridView(cid: cid, media: media) }
        .sheet(isPresented: $showShare) { ActivityView(items: [shareText]) }
        // Options for the "Disappearing Messages" row (was a dead button — no dialog was attached).
        .confirmationDialog("Disappearing Messages", isPresented: $showDisappear, titleVisibility: .visible) {
            Button("Off")     { requestDisappear(0) }
            Button("1 Day")   { requestDisappear(86_400) }
            Button("1 Week")  { requestDisappear(604_800) }
            Button("1 Month") { requestDisappear(2_592_000) }
            Button("1 Year")  { requestDisappear(31_536_000) }
            Button("Cancel", role: .cancel) {}
        }
        // Turning it ON destroys history for BOTH people — never on a single accidental tap.
        .alert("Turn on disappearing messages?", isPresented: Binding(
            get: { pendingDisappear != nil },
            set: { if !$0 { pendingDisappear = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDisappear = nil }
            Button("Turn On") { if let s = pendingDisappear { applyDisappear(s); pendingDisappear = nil } }
        } message: {
            Text("New messages in this chat will be deleted for both you and \(name) after \(ChatService.disappearLabel(pendingDisappear ?? 86_400)). \(name) will see that you turned this on.")
        }
        .alert("Clear your messages?", isPresented: $showClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await ChatService.clearMyMessages(cid); media = await ChatService.sharedMedia(cid) }
            }
        } message: {
            Text("This deletes the messages you sent in this chat. It can't be undone.")
        }
        .alert("Block \(name)?", isPresented: $showBlock) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                Task { await ChatService.setBlocked(cid, true); blocked = true }
            }
        } message: {
            Text("You won't be able to send messages in this chat until you unblock. \(name) won't be told they were blocked.")
        }
        .alert("Report \(name)?", isPresented: $showReport) {
            Button("Cancel", role: .cancel) {}
            Button("Report", role: .destructive) {
                Task { await ChatService.report(reportedUid: otherUid, cid: cid, reason: "user") }
            }
            Button("Report and Block", role: .destructive) {
                Task {
                    await ChatService.report(reportedUid: otherUid, cid: cid, reason: "user")
                    await ChatService.setBlocked(cid, true); blocked = true
                }
            }
        } message: {
            Text("Our team will review this account within 24 hours. \(name) won't be told.")
        }
        .alert("Voice calls", isPresented: $showCallSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("Voice calling is coming soon.") }
        .alert("Search", isPresented: $showSearchSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("In-chat search is coming soon.") }
        .alert("Video calls", isPresented: $showVideoSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("Video calling is coming soon.") }
        .navigationDestination(isPresented: $openChat) {
            ThreadView(cid: cid, title: name, photoUrl: photoUrl)
        }
    }

    private var disappearLabel: String {
        disappearSeconds == 0 ? "Off" : ChatService.disappearLabel(disappearSeconds)
    }
    // Turning ON asks first (it deletes for both people); turning OFF is always safe → applies directly.
    private func requestDisappear(_ s: Int) {
        guard s != disappearSeconds else { return }
        if s == 0 { applyDisappear(0) } else { pendingDisappear = s }
    }
    private func applyDisappear(_ s: Int) {
        disappearSeconds = s
        Task { await ChatService.setDisappear(cid, seconds: s) }
    }
    private var disappearRow: some View {
        Button { showDisappear = true } label: {
            HStack {
                Label("Disappearing Messages", systemImage: "timer")
                Spacer()
                Text(disappearLabel).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 6) {
            AvatarView(name: name, photoUrl: photoUrl, size: 88)
            Text(name).font(.title.weight(.bold))
            // Always reserve the @handle line (a space when it hasn't loaded yet) so the
            // async profile fetch fills it in WITHOUT pushing the action tiles down — that
            // height change was the up/down "jump" when opening a profile from Calls (cold
            // data) vs from a chat (warm). Reserving the row makes both equally smooth.
            Text(handle.isEmpty ? " " : "@\(handle)")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(minHeight: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // Context-aware row. From Calls: Message (open the chat) leads. From a chat: Search
    // trails (you're already here). Video is an honest "coming soon"; Voice always calls.
    private var quickActions: some View {
        HStack(spacing: 12) {
            if source == .calls {
                actionTile("message", "message.fill") { openChat = true }
            }
            // Your OWN profile: no call-yourself buttons, and NO message-self yet (opening a self-chat crashed —
            // that's the upcoming "My Space" feature, built separately). Friends keep video/voice.
            if !isSelf {
                actionTile("video", "video.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl, video: true) }
                actionTile("voice", "phone.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl) }
            }
            // Native menu (pops up) instead of a custom action sheet.
            Menu {
                if muted { Button("Unmute") { muted = false; Task { await ChatService.setMute(cid, until: 0) } } }
                Button("1 hour") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(1)) } }
                Button("8 hours") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(8)) } }
                Button("1 day") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(24)) } }
                Button("1 week") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(168)) } }
                Button("Always") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(nil)) } }
            } label: {
                tileLabel(muted ? "unmute" : "mute", muted ? "bell.fill" : "bell.slash.fill")
            }
            .tint(.primary)
            if source == .chat {
                actionTile("search", "magnifyingglass") { showSearchSoon = true }
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            // Auto-delete (disappearing messages) — native submenu, Off up to 1 year.
            // Goes through requestDisappear: enabling always confirms first (this menu was
            // exactly the accidental-tap path that silently wiped a chat's history).
            Menu {
                Button("Off") { requestDisappear(0) }
                Button("1 Day") { requestDisappear(86_400) }
                Button("1 Week") { requestDisappear(604_800) }
                Button("1 Month") { requestDisappear(2_592_000) }
                Button("1 Year") { requestDisappear(31_536_000) }
            } label: { Label("Disappearing Messages", systemImage: "timer") }

            Button { showShare = true } label: {
                Label("Share Contact", systemImage: "square.and.arrow.up")
            }

            Divider()

            // Clear is a normal (non-red) action; only Block is destructive/red.
            Button { showClear = true } label: {
                Label("Clear my messages", systemImage: "trash")
            }
            Button(role: .destructive) { showReport = true } label: {
                Label("Report \(name)", systemImage: "flag")
            }
            if blocked {
                Button { Task { await ChatService.setBlocked(cid, false); blocked = false } } label: {
                    Label("Unblock", systemImage: "hand.raised.slash")
                }
            } else {
                Button(role: .destructive) { showBlock = true } label: {
                    Label("Block \(name)", systemImage: "hand.raised")
                }
            }
        } label: { tileLabel("more", "ellipsis") }
            .tint(.primary)
    }

    // Shareable contact link (opens/starts a chat with this user in Kulan).
    private var shareText: String {
        handle.isEmpty ? "Chat with \(name) on Kulan"
                       : "Chat with \(name) on Kulan: kulan://u/\(handle)"
    }

    // The most recent real call with this person (nil if none) — drives the call-log card.
    private var lastCall: CallEntry? {
        CallsRepository.shared.calls.filter { $0.cid == cid }.max { $0.date < $1.date }
    }

    private var callLogCard: some View {
        Group {
            if let call = lastCall {
                VStack(alignment: .leading, spacing: 8) {
                    Text(call.date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Image(systemName: call.mine ? "phone.arrow.up.right" : "phone.arrow.down.left")
                            .foregroundStyle(call.missed ? .red : .secondary)
                        Text(call.missed ? "Missed voice call"
                                         : (call.mine ? "Outgoing voice call" : "Incoming voice call"))
                        Spacer()
                        Text(call.date.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func actionTile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon) }.tint(.primary)
    }

    private func tileLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(cardColor, in: Capsule())   // pill tile, icon only
            Text(title).font(.caption).foregroundStyle(.primary)   // label below the tile
        }
    }

    private var bioCard: some View {
        Text(about)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(media.prefix(12)) { m in
                        if let url = m.imageUrl {
                            SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { viewerImage = m }
                        }
                    }
                }
            }
            Button("See All") { showAllMedia = true }
                .font(.subheadline.weight(.medium))
                .tint(.primary)
        }
        .padding(14)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Logic

    private func toggleMute() {
        muted.toggle()
        let v = muted
        Task { await ChatService.setMuted(cid, v) }
    }

    private func load() async {
        if let p = await ProfileStore.shared.fetch(otherUid) { handle = p.handle; about = p.about }
        if let snap = try? await Firestore.firestore().collection("conversations").document(cid).getDocument(),
           let d = snap.data() {
            let me = AuthService.shared.uid ?? ""
            let muteUntil = ((d["mutedBy"] as? [String: Any])?[me] as? NSNumber)?.doubleValue ?? 0
            muted = muteUntil > Date().timeIntervalSince1970 * 1000
            blocked = (d["blockedBy"] as? [String: Any])?[me] as? Bool ?? false
        }
        media = await ChatService.sharedMedia(cid)
        loaded = true
    }
}

// Full shared-media gallery (reached via "See All").
struct SharedMediaGridView: View {
    let cid: String
    let media: [Message]
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: Message?
    private let cols = [GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 3) {
                    ForEach(media) { m in
                        if let url = m.imageUrl {
                            SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                .frame(height: 116)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .onTapGesture { viewer = m }
                        }
                    }
                }
                .padding(2)
            }
            .navigationTitle("Shared Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $viewer) { ImageViewerView(message: $0, cid: cid) }
        }
    }
}

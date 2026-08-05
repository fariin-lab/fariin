import SwiftUI
import UIKit

// THE OFFICIAL CHAT, as the person reading it sees it.
//
// A separate screen from ThreadView on purpose. ThreadView is 400KB of composer, attach panel, calls,
// typing, reactions, replies, selection and media pipeline, and every one of those is meaningless
// here — this chat cannot be typed in. Threading an `isOfficial` flag through all of it would put a
// dead branch in the most-touched file in the project. What IS shared is everything that decides how
// it LOOKS: the same message list, the same wallpaper, the same bubble colour, the same corner
// geometry, the same header shape. It should be indistinguishable from a normal chat except for the
// two things that are deliberately different: the tick, and the bar where the composer would be.
struct OfficialChatView: View {
    private var store = OfficialChannelStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var isAtBottom = true
    @State private var scrollTarget: String?
    @State private var zoomedImage: String?
    @State private var confirmBlock = false
    @State private var confirmClear = false
    @State private var pendingLink: URL?
    @State private var pushedScreen: AnnouncementButton.Screen?
    @State private var shareInvite = false
    @State private var barHeight: CGFloat = 0
    @State private var showInfo = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        list
            .background { ChatWallpaperBackground(cid: OfficialChannel.cid).ignoresSafeArea() }
            .safeAreaInset(edge: .bottom, spacing: 0) { cannotReplyBar }
            // Tapping the header opens the info screen, the same as every other chat. It used to do
            // nothing at all — I left the closure empty when this screen was built, so the one chat
            // people are most likely to be suspicious of was the one that would not tell them
            // anything about itself. Owner caught it.
            .background(NavTitleView(onTap: { showInfo = true }) { headerLabel })
            .navigationDestination(isPresented: $showInfo) { OfficialChatInfoView() }
            .toolbar(.hidden, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { officialToolbar }
            .navigationDestination(item: $pushedScreen) { screen in
                switch screen {
                case .appearance:    AppearanceSettingsView()
                case .chats:         ChatsSettingsView()
                case .stories:       StorySettingsView()
                case .privacy:       PrivacySettingsView()
                case .storage:       StorageDataView()
                case .notifications: NotificationsSettingsView()
                case .invite:        EmptyView()   // handled by the share sheet, never pushed
                }
            }
            .fullScreenCover(item: Binding(get: { zoomedImage.map(ZoomTarget.init) },
                                           set: { zoomedImage = $0?.url })) { target in
                AnnouncementImageViewer(url: target.url)
            }
            .sheet(isPresented: $shareInvite) { InviteShareSheet() }
            .alert("Open this link?", isPresented: Binding(get: { pendingLink != nil },
                                                          set: { if !$0 { pendingLink = nil } })) {
                Button("Open") { if let pendingLink { openURL(pendingLink) }; pendingLink = nil }
                Button("Cancel", role: .cancel) { pendingLink = nil }
            } message: {
                Text(pendingLink?.absoluteString ?? "")
            }
            // ALERT, NOT confirmationDialog. On iOS 26 a confirmationDialog renders as an anchored
            // popover with a tail pointing at the toolbar, and it DROPS the cancel button, because a
            // popover expects you to dismiss it by tapping outside. So the owner got a floating bubble
            // over the header offering only "Block". MainShell already learned this and says so in a
            // comment next to its own delete alert; I walked into the same trap building this screen.
            .alert("Block this chat?", isPresented: $confirmBlock) {
                Button("Block", role: .destructive) { store.setBlocked(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will stop getting updates from Fariin. Security alerts about your own account still come through. Nothing is lost and you can unblock it later.")
            }
            .alert("Clear this chat?", isPresented: $confirmClear) {
                Button("Clear", role: .destructive) { store.clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes these messages from this phone. New updates will still arrive.")
            }
            .onAppear {
                AppRouter.shared.activeChatId = OfficialChannel.cid
                store.markRead()
                NotificationCleaner.clear(cid: OfficialChannel.cid)
            }
            .onDisappear {
                if AppRouter.shared.activeChatId == OfficialChannel.cid { AppRouter.shared.activeChatId = nil }
            }
            // A new announcement landing while the chat is open is read the moment it is on screen —
            // but only if the reader is actually at the bottom looking at it.
            .onChange(of: store.visible.count) { if isAtBottom { store.markRead() } }
    }

    // MARK: The list

    private var list: some View {
        NativeMessageList(
            rowIds: store.visible.map(\.id),
            rowSignatures: Dictionary(uniqueKeysWithValues: store.visible.map { ($0.id, signature($0)) }),
            row: { id in
                guard let a = store.visible.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
                return AnyView(AnnouncementRow(
                    announcement: a,
                    dark: dark,
                    onImageTap: { zoomedImage = $0 },
                    onButtonTap: { tap($0) },
                    countsAsRead: true
                ).padding(.horizontal, 12))
            },
            // Nothing to page: the channel holds the most recent hundred announcements and that is the
            // whole history there is. Signal trims the same way.
            onReachedTop: {},
            loadingOlder: false,
            composerBarHeight: barHeight,
            isAtBottom: $isAtBottom,
            scrollTarget: $scrollTarget,
            dayLabelFor: { id in store.visible.first(where: { $0.id == id }).map { dayLabel($0.sortAt) } }
        )
    }

    /// Changes that must redraw a row. Edited announcements are the reason this exists — an admin
    /// fixing a typo has to reach a phone that already has the old words on screen.
    private func signature(_ a: Announcement) -> String {
        "\(a.title.count)|\(a.body.count)|\(a.mediaUrl ?? "")|\(a.buttons.count)|\(a.editedAt?.timeIntervalSince1970 ?? 0)"
    }

    private static let cal = Calendar.current
    private func dayLabel(_ d: Date) -> String {
        if Self.cal.isDateInToday(d) { return "Today" }
        if Self.cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: Header

    /// Same measurements as a normal chat header (40pt avatar, 12pt gap, .headline name, .caption2
    /// subtitle, a 16x16 icon at 5pt in the title row) so this reads as the same app. The tick sits in
    /// the exact slot the disappearing-messages timer uses over there.
    private var headerLabel: some View {
        HStack(spacing: 12) {
            OfficialAvatar(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(OfficialChannel.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    VerifiedTick(size: 16)
                }
                Text(OfficialChannel.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .fixedSize()
        }
    }

    /// Not named `toolbar`: `.toolbar { toolbar }` reads a property with the same name as the
    /// modifier it is being handed to, which is exactly the kind of thing the type-checker resolves
    /// differently on a bad day.
    @ToolbarContentBuilder private var officialToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // The bell IS the state, the way Signal's screenshot shows it: a struck-through bell means
            // this chat is quiet. It starts struck through for everybody and stays that way unless
            // somebody deliberately turns it on.
            Button { store.setMuted(!store.state.muted) } label: {
                Image(store.state.muted ? "ic_bell_off" : "ic_bell")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .tint(.primary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    store.setMuted(!store.state.muted)
                } label: {
                    Label(store.state.muted ? "Unmute" : "Mute", systemImage: store.state.muted ? "bell" : "bell.slash")
                }
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear Chat", systemImage: "trash")
                }
                Button(role: .destructive) { confirmBlock = true } label: {
                    Label("Block", systemImage: "hand.raised")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .tint(.primary)
        }
    }

    // MARK: The bar where the composer would be

    /// Signal replaces the composer with a `BlockingErrorBottomPanelView` reading "The only official
    /// chat from Signal"; WhatsApp's says "Only WhatsApp can send messages". Ours says the same thing
    /// in our own words. It is NOT a disabled text field — a greyed-out box invites tapping, and the
    /// point is that there is nothing to tap.
    private var cannotReplyBar: some View {
        Text(OfficialChannel.cannotReply)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .background(GeometryReader { g in
                Color.clear.preference(key: OfficialBarHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(OfficialBarHeightKey.self) { barHeight = $0 }
    }

    // MARK: Buttons

    private func tap(_ button: AnnouncementButton) {
        switch button.action {
        case .link:
            // Same confirm a link inside a normal message gets. An official chat is exactly where
            // somebody stops reading addresses, so it does not get to skip the step.
            if let url = URL(string: button.value) { pendingLink = url }
        case .appStore:
            if let url = URL(string: OfficialConfig.shared.appStoreUrl) { openURL(url) }
        case .screen:
            guard let screen = AnnouncementButton.Screen(rawValue: button.value) else { return }
            if screen == .invite { shareInvite = true } else { pushedScreen = screen }
        }
    }
}

private struct OfficialBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ZoomTarget: Identifiable {
    let url: String
    var id: String { url }
    init(_ url: String) { self.url = url }
}

// MARK: - Chat info

/// What you get when you tap the header, the same as tapping any other chat's header.
///
/// The one screen a suspicious person opens. So it is written for THEM: it says what this chat is,
/// what it will never do, and gives the way out. Everything else on it is the ordinary per-chat
/// state, in the ordinary places.
struct OfficialChatInfoView: View {
    private var store = OfficialChannelStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmBlock = false
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    OfficialAvatar(size: 96)
                    HStack(spacing: 6) {
                        Text(OfficialChannel.name).font(.title2.weight(.semibold))
                        VerifiedTick(size: 20)
                    }
                    Text(OfficialChannel.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("This is where we tell you about new things, fixes and updates.")
                // THE LINE THAT ACTUALLY PROTECTS SOMEBODY. Read from WhatsApp's official chat, which
                // spends its welcome teaching you how to spot a fake rather than greeting you: "we'll
                // never ask for your personal information".
                //
                // It matters more here than it does for them. The people this app is for are targeted
                // with mobile-money and remittance scams, and somebody pretending to be Fariin support
                // asking for a login code is the likeliest attack this app will ever face. A rule they
                // can apply forever, against a scammer neither of us has seen yet, costs one sentence.
                Text("We will never ask you for your password, your login code, or money. Nobody from Fariin will ever ask you for those, anywhere.")
                    .fontWeight(.medium)
            } header: {
                Text("What this is")
            }

            Section {
                Label {
                    Text("There is no Fariin account. This chat is built into the app itself, so it cannot be copied. Anyone claiming to be Fariin is not.")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.white, Color(hex: 0x0A84FF))
                }
            } header: {
                Text("Why you can trust this one")
            }

            Section {
                Toggle("Notifications", isOn: Binding(
                    get: { !store.state.muted },
                    set: { store.setMuted(!$0) }))
            } footer: {
                Text("Off by default. We are here to tell you what is new, not to fill your phone.")
            }

            Section {
                Button("Clear Chat", role: .destructive) { confirmClear = true }
                Button("Block", role: .destructive) { confirmBlock = true }
            } footer: {
                Text("Blocking stops the updates. It does not stop us telling you if something happens to your account.")
            }
        }
        .navigationTitle("Chat Info")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear this chat?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes these messages from this phone. New updates will still arrive.")
        }
        .alert("Block this chat?", isPresented: $confirmBlock) {
            Button("Block", role: .destructive) { store.setBlocked(true); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will stop getting updates from Fariin. Security alerts about your own account still come through. Nothing is lost and you can unblock it later.")
        }
    }
}

// MARK: - The channel's face

/// The app's own icon on a circle. Signal renders `ic_signal_logo_large` into the release channel's
/// avatar for the same reason: the one identity nobody else can wear is the app's own.
struct OfficialAvatar: View {
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let ui = UIImage(named: "welcome-mark") {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                // The mark is compiled into the app, so this cannot happen in a shipped build. It is
                // here so a missing asset degrades to a letter instead of an empty hole.
                ZStack {
                    Color.accentColor
                    Text("F").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// The tick. Drawn ONLY here and only ever for the one channel — there is no verified flag on any
/// user document, and there is not meant to be, because a flag is a thing that can be written.
struct VerifiedTick: View {
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size * 0.82, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(.white, Color(hex: 0x0A84FF))
            .accessibilityLabel("Verified official account")
    }
}

// MARK: - One announcement

/// Not private: the chat list's long-press peek renders the channel with these same bubbles, because
/// the generic peek reads `conversations/{cid}/messages` and the official channel has no such
/// collection — it would have shown "No messages yet" over a chat that plainly has messages.
struct AnnouncementRow: View {
    let announcement: Announcement
    let dark: Bool
    var onImageTap: (String) -> Void
    var onButtonTap: (AnnouncementButton) -> Void
    /// True ONLY in the real chat. The previews (the chat list's long-press peek, the admin compose
    /// preview, the admin history detail) draw the same bubble and must not tell the server that
    /// anybody read anything — an admin checking their own draft would otherwise be counted as a
    /// reader of it.
    var countsAsRead: Bool = false

    /// Received-side cluster geometry, matching a normal chat bubble: 18pt outer corners, and the
    /// small 6pt corner is the one that fuses a run together. Every announcement stands alone, so
    /// they are all 18.
    private var corners: RectangleCornerRadii {
        RectangleCornerRadii(topLeading: 18, bottomLeading: 18, bottomTrailing: 18, topTrailing: 18)
    }

    private var usableButtons: [AnnouncementButton] { announcement.buttons.filter(\.isUsable) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                if let url = announcement.mediaUrl {
                    AnnouncementImage(url: url,
                                      width: announcement.mediaWidth,
                                      height: announcement.mediaHeight)
                        .onTapGesture { onImageTap(url) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    kindLabel
                    if !announcement.title.isEmpty {
                        Text(announcement.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The body carries real links people are meant to tap, so it is parsed markdown
                    // rather than a plain string. `.init(_:)` is what turns a String into
                    // LocalizedStringKey, which is what makes SwiftUI detect addresses.
                    Text(.init(announcement.body))
                        .font(.system(size: 17))
                        .foregroundStyle(.primary)
                        .tint(Color(hex: 0x0A84FF))
                        .fixedSize(horizontal: false, vertical: true)
                    timeRow
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if !usableButtons.isEmpty { buttonStack }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .background(Theme.received(dark))
            .clipShape(UnevenRoundedRectangle(cornerRadii: corners, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .onAppear { if countsAsRead { AnnouncementStats.countRead(announcement) } }
    }

    private var kindLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: announcement.kind.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(announcement.kind.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(announcement.kind.isUrgent ? Color.red : Color.secondary)
    }

    private var timeRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if announcement.editedAt != nil {
                Text("edited").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(announcement.sortAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// Buttons live INSIDE the bubble under a hairline, which is what WhatsApp's official account
    /// does and what an iOS alert does. A row of pills floating under the bubble was the other option
    /// and it reads as a web page.
    private var buttonStack: some View {
        VStack(spacing: 0) {
            ForEach(usableButtons) { button in
                Divider()
                Button { onButtonTap(button) } label: {
                    Text(button.label)
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: 0x0A84FF))
            }
        }
    }
}

// MARK: - Media

/// Announcement pictures are PLAIN urls, like GIFs and story photos — see the note in
/// AnnouncementAdmin.uploadMedia for why sealing a worldwide broadcast would be a costume.
private struct AnnouncementImage: View {
    let url: String
    var width: Double?
    var height: Double?

    @State private var image: UIImage?

    /// Reserve the real shape before the bytes land so the bubble does not jump when it loads. The
    /// admin screen records the size at upload, so this is known, not guessed.
    private var ratio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 4.0 / 3.0 }
        return CGFloat(width / height)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(ratio, contentMode: .fit)
        .clipped()
        .task(id: url) {
            if let cached = DiskImageCache.shared.memoryImage(for: url) { image = cached; return }
            image = await DiskImageCache.shared.image(for: url)
        }
    }
}

private struct AnnouncementImageViewer: View {
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture()
                        .onChanged { zoom = max(1, min(4, $0.magnification)) }
                        .onEnded { _ in withAnimation(.spring(duration: 0.25)) { zoom = max(1, zoom) } })
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            CloseXButton { dismiss() }.padding(.leading, 16).padding(.top, 8)
        }
        .task { image = await DiskImageCache.shared.image(for: url) }
    }
}

/// The Invite Friends button opens the same share sheet Settings does, with the same text.
private struct InviteShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared

    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }

    var body: some View {
        ShareSheet(items: [inviteText])
    }
}

/// UIActivityViewController bridge. SwiftUI's ShareLink is a button, not something a code path can
/// present, and this screen needs to present one from a tap on a message.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

import SwiftUI

// "Go to Chat" event: the open ThreadView for `cid` pops back to itself (out of the profile/gallery
// push) and scrolls to + flashes `messageId`. The standard behavior — return to the conversation at
// that message, not open a duplicate chat.
struct GoToMessage { let cid: String; let messageId: String }
extension Notification.Name { static let goToMessage = Notification.Name("goToMessage") }

// Process-lifetime cache of each conversation's gallery content, kept OUTSIDE the view so it survives
// every open/close of "See All Media" — a stability trick (the gallery model is retained and only
// loaded once; reopen renders the cached sections synchronously with no spinner). @MainActor so the
// SwiftUI views that read/write it stay data-race free.
@MainActor enum GalleryCache { static var store: [String: [Message]] = [:] }

// Full-screen shared-content gallery, PUSHED (not a sheet). An "All Media" header with a live
// photo/video count and a filter button, then five tabs — Media, Files, Voice, Links, GIFs — with
// time-grouped sections, long-press context menus, and a selection mode with a bottom Share / count /
// Delete toolbar.
struct MediaGalleryView: View {
    let cid: String
    let title: String
    let photoUrl: String?

    enum Tab: Hashable, CaseIterable {
        case media, files, voice, links, gifs
        var label: String {
            switch self {
            case .media: return "Media"
            case .files: return "Files"
            case .voice: return "Voice"
            case .links: return "Links"
            case .gifs:  return "GIFs"
            }
        }
    }
    enum MediaFilter: Hashable { case all, photos, videos }

    @State private var all: [Message] = []
    @State private var loaded = false
    @State private var tab: Tab = .media
    @State private var mediaFilter: MediaFilter = .all
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?
    @State private var shareItems: [Any]?
    @State private var confirmDelete = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    // Same zoom hero as the profile photo / chat bubbles: the viewer grows out of the tapped
    // tile and the drag-down close shrinks back into it.
    @Namespace private var mediaNS
    private var dark: Bool { scheme == .dark }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    // MARK: - Derived lists (gifs get their own tab, so they're excluded from Media)

    private var mediaItems: [Message] {
        all.filter { ($0.isImage || $0.isVideo) && !$0.isGif }.filter { m in
            switch mediaFilter {
            case .all:    return true
            case .photos: return m.isImage
            case .videos: return m.isVideo
            }
        }
    }
    private var gifItems: [Message]  { all.filter { $0.isGif } }
    private var voiceItems: [Message] { all.filter { $0.isAudio } }
    private var fileItems: [Message]  { all.filter { $0.isFile } }
    private var linkItems: [Message] {
        all.filter { !$0.isImage && !$0.isVideo && !$0.isGif && !$0.isAudio && !$0.isFile && Self.firstURL(in: $0.text) != nil }
    }

    private var photoCount: Int { all.filter { $0.isImage && !$0.isGif }.count }
    private var videoCount: Int { all.filter { $0.isVideo }.count }

    // The count line under "All Media" reflects the visible tab.
    private var subtitle: String {
        func n(_ c: Int, _ one: String) -> String { "\(c) \(one)\(c == 1 ? "" : "s")" }
        switch tab {
        case .media: return "\(n(photoCount, "photo")), \(n(videoCount, "video"))"
        case .files: return n(fileItems.count, "file")
        case .voice: return n(voiceItems.count, "voice message")
        case .links: return n(linkItems.count, "link")
        case .gifs:  return n(gifItems.count, "GIF")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !selecting { tabBar }
            content
                .overlay { loadingOverlay }   // spinner until the first load finishes (no empty flash)
        }
        // NATIVE nav bar (user spec): centred "All Media" with the live count as the system
        // subtitle, the standard circular back button, and a "..." menu on the right — instead of
        // a custom left-aligned header.
        .navigationTitle("All Media")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)   // selection mode → only the X, no back
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if selecting { selectionToolbar } }
        .task {
            // STABLE via a persistent-backed store, so reopen is instant: render the cached list
            // synchronously first — no full-screen spinner on reopen — then refresh in the background
            // and update the cache. The spinner shows only on the very first load.
            if let cached = GalleryCache.store[cid] { all = cached; loaded = true }
            let fresh = await ChatService.galleryContent(cid)
            all = fresh
            GalleryCache.store[cid] = fresh
            loaded = true
        }
        .fullScreenCover(item: $viewerImage) { msg in
            ImageViewerView(message: msg, in: mediaItems.filter { $0.isImage && !$0.isGif },
                            cid: cid, suppressDismissPan: false)
                .navigationTransition(.zoom(sourceID: msg.id, in: mediaNS))
        }
        .fullScreenCover(item: $viewerVideo) { msg in
            VideoPlayerScreen(message: msg, cid: cid, suppressDismissPan: false)
                .navigationTransition(.zoom(sourceID: msg.id, in: mediaNS))
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let items = shareItems { ActivityView(items: items) }
        }
        .alert("Delete \(selecting ? "\(selection.count) item\(selection.count == 1 ? "" : "s")" : "item")?",
               isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: { Text("This removes the message from this chat.") }
    }

    // (The old custom header is gone — the native nav bar now carries the title + count.)

    // MARK: - Tab bar (Media / Files / Voice / Links / GIFs)

    // Liquid-glass segmented tab bar (user spec): the 5 tabs live inside one glass capsule and the
    // selected tab rides in its own raised pill — not a flat underline.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { withAnimation(.easeInOut(duration: 0.22)) { tab = t } } label: {
                    Text(t.label)
                        .font(.subheadline.weight(tab == t ? .semibold : .medium))
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            // Selected segment: a raised glass pill inside the bar.
                            if tab == t {
                                // Real glass, not a flat tint. The bar itself is liquidGlass; the selected
                                // segment was a plain 14% primary fill, so it read as a grey blob sitting
                                // on glass instead of a raised glass pill.
                                Capsule(style: .continuous)
                                    .fill(.clear)
                                    .liquidGlass(Capsule(style: .continuous), interactive: true)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .liquidGlass(Capsule(style: .continuous), interactive: true)
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    // Swipe left/right to move between tabs, using the NATIVE paging TabView rather than a hand-rolled
    // drag gesture: it carries the interactive rubber-banding, the velocity handling and the correct
    // relationship with the screen-edge back gesture for free (an edge pan still pops the screen, because
    // the system edge recogniser outranks a scroll view's pan).
    @ViewBuilder private var content: some View {
        TabView(selection: $tab) {
            grid(mediaItems, emptyIcon: "photo.on.rectangle", emptyText: "No media").tag(Tab.media)
            filesList.tag(Tab.files)
            voiceList.tag(Tab.voice)
            linksList.tag(Tab.links)
            grid(gifItems, emptyIcon: "square.stack.3d.up", emptyText: "No GIFs").tag(Tab.gifs)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.22), value: tab)
    }

    // Shown until the first load finishes, so the empty state never flashes while loading.
    @ViewBuilder private var loadingOverlay: some View {
        if !loaded {
            ProgressView().tint(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar (selection only — the tabs live in the header now)

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button { exitSelection() } label: { Image(systemName: "xmark") }.tint(.primary)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
    }

    // "..." menu (user spec): filtering lives here now, plus Select — so the nav bar stays clean
    // and the same control works on every tab, not just Media.
    private var moreMenu: some View {
        Menu {
            if tab == .media {
                Section("Show") {
                    filterButton("All Media", mediaFilter == .all) { mediaFilter = .all }
                    filterButton("Photos", mediaFilter == .photos) { mediaFilter = .photos }
                    filterButton("Videos", mediaFilter == .videos) { mediaFilter = .videos }
                }
            }
            // ALWAYS present, disabled when there is nothing to select. A SwiftUI Menu with no children
            // renders as a button that does nothing at all when tapped - which is exactly what happened on
            // Files, Voice, Links and GIFs, because the "Show" section is Media-only and this Select was
            // conditional on the tab having items. The menu looked broken rather than empty.
            Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                .disabled(currentItems.isEmpty)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
        }
    }

    /// Items on the visible tab (drives whether "Select" is offered).
    private var currentItems: [Message] {
        switch tab {
        case .media: return mediaItems
        case .gifs:  return gifItems
        case .voice: return voiceItems
        case .links: return linkItems
        case .files: return fileItems
        }
    }
    private func filterButton(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { if on { Label(title, systemImage: "checkmark") } else { Text(title) } }
    }

    private var selectionToolbar: some View {
        HStack {
            // Share — 48px real Liquid Glass circle.
            Button { shareSelected() } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20)).foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .liquidGlass(Circle(), interactive: true)
            }
            .disabled(selection.isEmpty)
            Spacer()
            // Count — a glass pill (Apple's floating-toolbar style), not a plain label on a bar.
            Text("\(selection.count) Selected")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .padding(.horizontal, 18).frame(height: 48)
                .liquidGlass(Capsule(), interactive: true)
            Spacer()
            // Delete — 48px real Liquid Glass circle, red glyph.
            Button { confirmDelete = true } label: {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(.red)
                    .frame(width: 48, height: 48)
                    .liquidGlass(Circle(), interactive: true)
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    // MARK: - Media / GIF grid (time-grouped)

    private func grid(_ items: [Message], emptyIcon: String, emptyText: String) -> some View {
        ScrollView {
            if loaded && items.isEmpty { emptyState(emptyIcon, emptyText) }
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(sections(items), id: \.title) { section in
                    Text(section.title)
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 14).padding(.top, 6)
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(section.items) { m in mediaCell(m) }
                    }
                }
            }
            .padding(.top, 4).padding(.bottom, 12)
        }
    }

    // Group items into date sections ("Today", "Yesterday", "This Month", "June", "June 2024"),
    // keeping the existing newest-first order.
    private func sections(_ items: [Message]) -> [(title: String, items: [Message])] {
        let cal = Calendar.current
        var groups: [(title: String, items: [Message])] = []
        let monthFmt = DateFormatter(); monthFmt.dateFormat = "LLLL"
        let monthYearFmt = DateFormatter(); monthYearFmt.dateFormat = "LLLL yyyy"
        let now = Date()
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            let c = cal.dateComponents([.year, .month], from: d)
            let n = cal.dateComponents([.year, .month], from: now)
            if c.year == n.year && c.month == n.month { return "This Month" }
            if c.year == n.year { return monthFmt.string(from: d) }
            return monthYearFmt.string(from: d)
        }
        for m in items {
            let title = bucket(m.createdAt)
            if let last = groups.last, last.title == title {
                groups[groups.count - 1].items.append(m)
            } else {
                groups.append((title, [m]))
            }
        }
        return groups
    }

    private func mediaCell(_ m: Message) -> some View {
        let selected = selection.contains(m.id)
        // A square container (Color.clear) drives the tile size; the thumbnail fills it as an overlay.
        // This makes the size come from the grid column, NOT the content — so images and GIFs (a
        // UIViewRepresentable whose intrinsic size otherwise leaks into the row) are identical squares.
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { thumbnail(m) }
            .clipped()
            .overlay {
                if m.isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.95)).shadow(radius: 3)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if m.isGif {
                    Text("GIF").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
            }
            .overlay {
                if selecting {
                    ZStack {
                        Color.black.opacity(selected ? 0.25 : 0.001)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22)).foregroundStyle(selected ? Color.accentColor : .white)
                            .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            }
            .contentShape(Rectangle())
            .matchedTransitionSource(id: m.id, in: mediaNS)   // hero anchor for the viewer
            .modifier(MediaRectReporter(id: m.id))            // landing target for the drag-down close
            .onTapGesture { tap(m) }
            .contextMenu { if !selecting { itemMenu(m) } }
    }

    @ViewBuilder private func thumbnail(_ m: Message) -> some View {
        if let data = m.localImageData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else if m.isGif, let url = m.imageUrl {
            AnimatedGifView(url: url)
        } else if m.isVideo, let url = m.thumbUrl {
            SecureImageView(imageUrl: url, enc: m.thumbEnc, cid: cid)
        } else if let url = m.imageUrl {
            SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
        } else {
            Rectangle().fill(Color.gray.opacity(0.18))
        }
    }

    // MARK: - Voice list

    private var voiceList: some View {
        ScrollView {
            if loaded && voiceItems.isEmpty { emptyState("mic", "No voice messages") }
            LazyVStack(spacing: 0) {
                ForEach(voiceItems) { m in
                    voiceRow(m)
                    Divider().padding(.leading, 64)
                }
            }
        }
    }

    private func voiceRow(_ m: Message) -> some View {
        let selected = selection.contains(m.id)
        let me = AuthService.shared.uid ?? ""
        return HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected ? Color.accentColor : .secondary)
                // Static row while selecting (no play — the whole row toggles the checkbox).
                Image(systemName: "waveform").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice message").font(.system(size: 16, weight: .medium))
                    Text(durationLabel(m.duration)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                // The REAL playable voice player (same one used in chat) — tap the play button to
                // decrypt + play, scrub the waveform, change speed.
                VoiceMessageView(message: m, cid: cid, isMe: m.authorId == me, dark: dark, plainBackground: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(m.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggle(m) } }
        .contextMenu { if !selecting { itemMenu(m) } }
    }

    // MARK: - Links list

    private var linksList: some View {
        ScrollView {
            if loaded && linkItems.isEmpty { emptyState("link", "No links") }
            LazyVStack(spacing: 0) {
                ForEach(linkItems) { m in
                    linkRow(m)
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    private func linkRow(_ m: Message) -> some View {
        let url = Self.firstURL(in: m.text)
        return Button { goToChat(m) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(url?.host ?? "Link").font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                Text(m.text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if let url { Text(url.absoluteString).font(.caption2).foregroundStyle(Color.accentColor).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { goToChat(m) } label: { Label("Go to Chat", systemImage: "bubble.left") }
            if let url { Button { UIApplication.shared.open(url) } label: { Label("Open Link", systemImage: "safari") } }
        }
    }

    // MARK: - Files list (documents shared in this chat)

    private var filesList: some View {
        ScrollView {
            if loaded && fileItems.isEmpty { emptyState("doc", "No files") }
            LazyVStack(spacing: 0) {
                ForEach(fileItems) { m in
                    fileRow(m)
                    Divider().padding(.leading, 64)
                }
            }
        }
    }

    private func fileRow(_ m: Message) -> some View {
        Button { goToChat(m) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.fileName ?? "Document")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(fileMeta(m)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(m.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { goToChat(m) } label: { Label("Go to Chat", systemImage: "bubble.left") }
        }
    }

    private func fileMeta(_ m: Message) -> String {
        guard let size = m.fileSize, size > 0 else { return "File" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: - Item context menu (media + gifs + voice)

    @ViewBuilder private func itemMenu(_ m: Message) -> some View {
        Button { goToChat(m) } label: { Label("Go to Chat", systemImage: "bubble.left") }
        Button { share(m) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button { selecting = true; selection = [m.id] } label: { Label("Select", systemImage: "checkmark.circle") }
        // Delete-for-everyone is only for MY OWN media — received media can't be deleted from the server.
        if m.authorId == AuthService.shared.uid {
            Button(role: .destructive) { selection = [m.id]; confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: - Actions

    private func tap(_ m: Message) {
        if selecting { toggle(m) }
        else if m.isVideo { viewerVideo = m }
        else if m.isGif { goToChat(m) }
        else if m.isImage { viewerImage = m }
    }
    private func toggle(_ m: Message) {
        if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
    }
    private func exitSelection() { selecting = false; selection = [] }

    // Go to Chat (popToViewController: land directly on the conversation, no profile shown).
    // We do NOT dismiss the gallery ourselves — dismiss() pops us to the PROFILE (a visible flash), and
    // racing it with the profile-pop over-unwound to the chat list. Instead, just tell the open ThreadView
    // to drop its ENTIRE profile→gallery branch at once (showContactInfo = false pops both in one
    // animation), then it scrolls to + briefly flashes the message.
    private func goToChat(_ m: Message) {
        NotificationCenter.default.post(name: .goToMessage, object: GoToMessage(cid: cid, messageId: m.id))
    }

    private func deleteSelected() {
        // Only MY OWN messages — the server rejects deleting others', which made them reappear.
        let me = AuthService.shared.uid
        let ids = Set(all.filter { selection.contains($0.id) && $0.authorId == me }.map(\.id))
        Task {
            for id in ids { await ChatService.deleteMessage(cid: cid, messageId: id) }
            await MainActor.run {
                all.removeAll { ids.contains($0.id) }
                GalleryCache.store[cid] = all   // keep the reopen cache in sync (no deleted-media flash)
                exitSelection()
            }
        }
    }

    private func share(_ m: Message) {
        if let url = Self.firstURL(in: m.text) { shareItems = [url]; return }
        Task {
            if let img = await decryptedImage(m) { await MainActor.run { shareItems = [img] } }
            else if !m.text.isEmpty { await MainActor.run { shareItems = [m.text] } }
        }
    }
    private func shareSelected() {
        // Share the decrypted images among the selection (the shareable representation we can build here).
        let picked = all.filter { selection.contains($0.id) }
        Task {
            var items: [Any] = []
            for m in picked { if let img = await decryptedImage(m) { items.append(img) } }
            if items.isEmpty { for m in picked where !m.text.isEmpty { items.append(m.text) } }
            if !items.isEmpty { await MainActor.run { shareItems = items } }
        }
    }

    // Download + decrypt an image message to a UIImage for sharing (nil for non-images / failures).
    private func decryptedImage(_ m: Message) async -> UIImage? {
        if let data = m.localImageData { return UIImage(data: data) }
        guard m.isImage, let s = m.imageUrl, let url = URL(string: s), let meta = m.enc,
              let (cipher, _) = try? await URLSession.shared.data(from: url),
              let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else { return nil }
        return UIImage(data: dec)
    }

    private func durationLabel(_ d: Double?) -> String {
        let s = Int(d ?? 0); return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func emptyState(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(text).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    // First URL in a string, via the system data detector (handles bare domains + http links).
    static func firstURL(in text: String) -> URL? {
        guard !text.isEmpty,
              let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return det.firstMatch(in: text, range: range)?.url
    }
}

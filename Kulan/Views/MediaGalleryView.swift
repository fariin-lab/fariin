import SwiftUI

// "Go to Chat" event: the open ThreadView for `cid` pops back to itself (out of the profile/gallery
// push) and scrolls to + flashes `messageId`. The standard behavior â€” return to the conversation at
// that message, not open a duplicate chat.
struct GoToMessage { let cid: String; let messageId: String }
extension Notification.Name { static let goToMessage = Notification.Name("goToMessage") }

// Process-lifetime cache of each conversation's gallery content, kept OUTSIDE the view so it survives
// every open/close of "See All Media" â€” a stability trick (the gallery model is retained and only
// loaded once; reopen renders the cached sections synchronously with no spinner). @MainActor so the
// SwiftUI views that read/write it stay data-race free.
@MainActor enum GalleryCache { static var store: [String: [Message]] = [:] }

// Full-screen shared-content gallery, PUSHED (not a sheet). An "All Media" header with a live
// photo/video count and a filter button, then five tabs â€” Media, Files, Voice, Links, GIFs â€” with
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
    // The grid's visible region (global coords) â€” the drag-close lands CLIPPED through it, so a copy
    // flying home to a tile near the top slides behind the All Media header exactly like the chat's
    // close slides behind the chat header (user report: the gallery close felt different).
    @State private var gridFrame: CGRect = .zero
    @State private var shareItems: [Any]?
    @State private var confirmDelete = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    // Same zoom hero as the profile photo / chat bubbles: the viewer grows out of the tapped
    // tile and the drag-down close shrinks back into it.
    private var dark: Bool { scheme == .dark }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    // MARK: - Derived lists (gifs get their own tab, so they're excluded from Media)

    // Albums expanded into their individual photos/videos (user report: a single photo showed in All
    // Media, a multi-photo album never did â€” `isAlbum` messages fell through the image/video filter).
    // The synthetic "<messageId>-<index>" ids match the chat's album tile registry, so the fly-open and
    // the drag-close landing resolve real geometry.
    private var expandedAll: [Message] { all.flatMap { $0.expandedGalleryItems(cid: cid) } }

    private var mediaItems: [Message] {
        expandedAll.filter { ($0.isImage || $0.isVideo) && !$0.isGif }.filter { m in
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

    private var photoCount: Int { expandedAll.filter { $0.isImage && !$0.isGif }.count }
    private var videoCount: Int { expandedAll.filter { $0.isVideo }.count }

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
        content
            .overlay { loadingOverlay }   // spinner until the first load finishes (no empty flash)
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in gridFrame = f }
            })
            // THE TABS FLOAT OVER THE GRID. An OVERLAY, not `safeAreaBar` — that was the previous
            // attempt and the owner checked it on the phone: the photos still stopped at the bar
            // rather than passing under it. safeAreaBar floats over a plain ScrollView, but this
            // content is a paged TabView and the inset reaches the TabView rather than the scroll
            // views inside it, so all it did was reserve a strip, which is what the old VStack did.
            //
            // An overlay cannot reserve anything, so each scroll view carries a matching top content
            // margin instead (`.contentMargins(.top, MediaTabBar.slotHeight, for: .scrollContent)`).
            // Content starts below the bar and scrolls under it — which is exactly what the
            // navigation bar does, and the reason ITS glass has always looked right on this screen.
            .overlay(alignment: .top) { if !selecting { tabBar } }
        // NATIVE nav bar (user spec): centred "All Media" with the live count as the system
        // subtitle, the standard circular back button, and a "..." menu on the right â€” instead of
        // a custom left-aligned header.
        .navigationTitle("All Media")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)   // selection mode â†’ only the X, no back
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if selecting { selectionToolbar } }
        .task {
            // STABLE via a persistent-backed store, so reopen is instant: render the cached list
            // synchronously first â€” no full-screen spinner on reopen â€” then refresh in the background
            // and update the cache. The spinner shows only on the very first load.
            if let cached = GalleryCache.store[cid] { all = cached; loaded = true }
            let fresh = await ChatService.galleryContent(cid)
            all = fresh
            GalleryCache.store[cid] = fresh
            loaded = true
        }
        .fullScreenCover(item: $viewerImage) { msg in
            // No system .zoom any more: SignalMediaOpen flies the tapped tile's media (see flyOpen),
            // the same pipeline as the conversation. Leaving the zoom on ran both animations at once
            // and left the zoom's own dismiss pan fighting SignalDismissHost's.
            ImageViewerView(message: msg, in: mediaItems.filter { $0.isImage && !$0.isGif },
                            cid: cid,
                            clipProvider: { gridFrame == .zero ? nil : gridFrame },
                            rectScope: .gallery)
        }
        .fullScreenCover(item: $viewerVideo) { msg in
            VideoPlayerScreen(message: msg, cid: cid,
                              clipProvider: { gridFrame == .zero ? nil : gridFrame },
                              rectScope: .gallery)
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

    // (The old custom header is gone â€” the native nav bar now carries the title + count.)

    // MARK: - Tab bar (Media / Files / Voice / Links / GIFs)

    // Apple's segmented control, the same one the Calls page uses for All / Missed (owner's order,
    // 2026-08-03). See MediaTabBar for why it cannot be both that and Liquid Glass on a page.
    private var tabBar: some View {
        MediaTabBar(titles: Tab.allCases.map(\.label),
                    selection: Binding(get: { Tab.allCases.firstIndex(of: tab) ?? 0 },
                                       set: { tab = Tab.allCases[$0] }))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)   // together with barHeight this is MediaTabBar.slotHeight
    }

    // (Deleted: ClearSegmentedTrack. It reached into the segmented control and erased its background
    // images so a hand-made glass capsule behind it could show — which is what removed the active-tab
    // indicator, since iOS draws the selected pill as part of that same surface. Nothing replaces it:
    // the stock control already renders in the system material.)

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
        // NO `.animation(value: tab)` HERE, AND THIS IS THE SWIPE LAG HE REPORTED. A paged TabView
        // flips `tab` as your finger crosses the midpoint, WHILE YOU ARE STILL DRAGGING, and an
        // animation attached to the TabView animates the whole five-tab subtree on that same frame.
        // The drag is already the animation; a second one over all of it is what dropped frames
        // under his finger. Same lesson as the photo pager: nothing heavy on the commit frame.
    }

    // Shown until the first load finishes, so the empty state never flashes while loading.
    @ViewBuilder private var loadingOverlay: some View {
        if !loaded {
            ProgressView().tint(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar (selection only â€” the tabs live in the header now)

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button { exitSelection() } label: { Image(systemName: "xmark") }.tint(.primary)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
    }

    // "..." menu (user spec): filtering lives here now, plus Select â€” so the nav bar stays clean
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
            // Share â€” 48px real Liquid Glass circle.
            Button { shareSelected() } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20)).foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .liquidGlass(Circle(), interactive: true)
            }
            .disabled(selection.isEmpty)
            Spacer()
            // Count â€” a glass pill (Apple's floating-toolbar style), not a plain label on a bar.
            Text("\(selection.count) Selected")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .padding(.horizontal, 18).frame(height: 48)
                .liquidGlass(Capsule(), interactive: true)
            Spacer()
            // Delete â€” 48px real Liquid Glass circle, red glyph.
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
        // Clears the floating tab bar at rest and scrolls UNDER it, which is the whole point of the
        // bar being an overlay. A content margin does what padding cannot: it moves where the content
        // STARTS without moving where it is allowed to go.
        .contentMargins(.top, MediaTabBar.slotHeight, for: .scrollContent)
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
        // This makes the size come from the grid column, NOT the content â€” so images and GIFs (a
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
            // fly-open source AND drag-close landing target, in THIS screen's namespace: the chat and
            // the profile strip register the same message ids, and an unscoped registry let whichever
            // laid out last win (the wrong-area open/close).
            // cornerRadius 0 because THESE TILES ARE SQUARE (`.clipped()`, no clip shape). The modifier's
            // default is 14 â€” the profile strip's radius â€” so the drag-close used to shrink the photo
            // into a rounded shape that matched nothing on this screen (user: "the rounded corners are
            // only when i stay profile, not inside All Media").
            .modifier(MediaRectReporter(id: m.id, scope: .gallery, cornerRadius: 0))
            .onTapGesture { tap(m) }
            .contextMenu {
                if !selecting { itemMenu(m) }
            } preview: {
                mediaPreview(m)
            }
    }

    /// The lifted preview behind the long-press menu (owner 2026-08-03: "show real preview, big
    /// preview, apple native, not custom").
    ///
    /// With no `preview:` closure iOS lifts THE VIEW YOU PRESSED, and here that is a grid tile a
    /// third of a screen wide — his screenshot. Handing it the picture at a real size is still the
    /// native preview: same lift, same platter, same menu. Only the content is ours.
    ///
    /// SIZED FROM THE MESSAGE'S OWN PIXEL DIMENSIONS, so a tall photo comes up tall and nothing is
    /// letterboxed inside the platter. A message with no dimensions recorded falls back to a square,
    /// and every number is clamped: UIKit throws an assertion on a preview with a NaN centre, which
    /// is the shape of the crash already on file from build 425.
    @ViewBuilder private func mediaPreview(_ m: Message) -> some View {
        let screen = UIScreen.main.bounds
        let w0 = m.width ?? 0, h0 = m.height ?? 0
        let ratio = (w0 > 0 && h0 > 0) ? CGFloat(h0 / w0) : 1
        let safeRatio = min(max(ratio, 0.3), 2.2)          // extreme panoramas stay a sane shape
        let w = max(80, min(screen.width * 0.86, screen.height * 0.6 / safeRatio))
        thumbnail(m)
            .scaledToFill()
            .frame(width: w, height: w * safeRatio)
            .clipped()
            .overlay {
                if m.isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.95)).shadow(radius: 4)
                }
            }
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
        .contentMargins(.top, MediaTabBar.slotHeight, for: .scrollContent)
    }

    private func voiceRow(_ m: Message) -> some View {
        let selected = selection.contains(m.id)
        let me = AuthService.shared.uid ?? ""
        return HStack(spacing: 12) {
            if selecting { checkbox(selected) }
            // THE SAME PLAYER IN BOTH MODES (user 2026-07-29: "before it is using correct design voice,
            // but when I click select it is using another design"). Selection used to swap in a static
            // "Voice message" row with a waveform glyph - a second design for the same thing, and the
            // only reason for it was that the player owns its own taps. Turning its hit testing off
            // while selecting solves that without changing what you are looking at: the row keeps its
            // waveform, duration and speed, and the whole row toggles.
            VoiceMessageView(message: m, cid: cid, isMe: m.authorId == me, dark: dark, plainBackground: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(!selecting)
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
        .contentMargins(.top, MediaTabBar.slotHeight, for: .scrollContent)
    }

    private func linkRow(_ m: Message) -> some View {
        let url = Self.firstURL(in: m.text)
        let selected = selection.contains(m.id)
        // Links and files had NO selection support at all — no checkbox, and a tap still navigated to
        // the chat. Select mode was reachable from the menu on every tab, so on these two it looked
        // broken: a toolbar saying "0 Selected" over rows that could not be selected.
        return HStack(spacing: 12) {
            if selecting { checkbox(selected) }
            VStack(alignment: .leading, spacing: 3) {
                Text(url?.host ?? "Link").font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                Text(m.text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if let url { Text(url.absoluteString).font(.caption2).foregroundStyle(Color.accentColor).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggle(m) } else { goToChat(m) } }
        .contextMenu {
            if !selecting {
                Button { goToChat(m) } label: { Label("Go to Chat", systemImage: "bubble.left") }
                if let url { Button { UIApplication.shared.open(url) } label: { Label("Open Link", systemImage: "safari") } }
            }
        }
    }

    /// The selection circle, identical on every tab so one row type cannot drift from another.
    private func checkbox(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(selected ? Color.accentColor : .secondary)
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
        .contentMargins(.top, MediaTabBar.slotHeight, for: .scrollContent)
    }

    private func fileRow(_ m: Message) -> some View {
        let selected = selection.contains(m.id)
        return HStack(spacing: 12) {
            if selecting { checkbox(selected) }
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
        .onTapGesture { if selecting { toggle(m) } else { goToChat(m) } }
        .contextMenu {
            if !selecting {
                Button { goToChat(m) } label: { Label("Go to Chat", systemImage: "bubble.left") }
            }
        }
    }

    private func fileMeta(_ m: Message) -> String {
        guard let size = m.fileSize, size > 0 else { return "File" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: - Item context menu (media + gifs + voice)

    // A synthetic album child carries "<messageId>-<index>"; its real message is the ALBUM. Firestore
    // ids never contain "-", so the first segment is always the parent.
    private func parentMessageId(_ id: String) -> String { id.split(separator: "-").first.map(String.init) ?? id }

    @ViewBuilder private func itemMenu(_ m: Message) -> some View {
        Button { goToChat(m) } label: { Label("Go to Chat", systemImage: "bubble.left") }
        Button { share(m) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button { selecting = true; selection = [m.id] } label: { Label("Select", systemImage: "checkmark.circle") }
        // Delete-for-everyone is only for MY OWN media â€” received media can't be deleted from the server.
        // Not offered on album CHILDREN: the server only knows the album message, and a per-item delete
        // by synthetic id would silently do nothing (deleteSelected already filters them out).
        if m.authorId == AuthService.shared.uid, m.id == parentMessageId(m.id) {
            Button(role: .destructive) { selection = [m.id]; confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: - Actions

    private func tap(_ m: Message) {
        if selecting { toggle(m) }
        else if m.isVideo { flyOpen(m, poster: m.thumbUrl) { viewerVideo = m } }
        else if m.isGif { goToChat(m) }
        else if m.isImage { flyOpen(m, poster: m.imageUrl) { viewerImage = m } }
    }

    // OPEN LIKE THE CHAT: fly only the media out of its tile (SignalMediaOpen), then reveal the viewer.
    // This screen used the system .zoom while the conversation flew - the SAME viewer opened with two
    // different animations depending on where you tapped, and the zoom transition's own interactive
    // dismiss pan ran ALONGSIDE SignalDismissHost's, two gestures fighting over one close. The tile's
    // rect is already registered (MediaRectReporter, the drag-close's landing target), so the open now
    // reads the same registry the close lands on - one pipeline, both directions, every entry point.
    private func flyOpen(_ m: Message, poster: String?, present rawPresent: @escaping () -> Void) {
        // Through the gate: a tap arriving while the previous viewer is still dismissing used to be
        // swallowed by SwiftUI (user: "when I close an image and click again fast it doesn't work").
        let present = { MediaPresentGate.present(rawPresent) }
        let key = MediaOpenRects.key(.gallery, m.id)
        // Resolves through BOTH cache tiers â€” memory only was why the first tap after returning from
        // the background slid up from the bottom instead of flying. See SignalMediaOpen.flyOrPresent.
        SignalMediaOpen.flyOrPresent(imageUrl: poster, rectKey: key, present: present)
    }
    private func toggle(_ m: Message) {
        if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
    }
    private func exitSelection() { selecting = false; selection = [] }

    // Go to Chat (popToViewController: land directly on the conversation, no profile shown).
    // We do NOT dismiss the gallery ourselves â€” dismiss() pops us to the PROFILE (a visible flash), and
    // racing it with the profile-pop over-unwound to the chat list. Instead, just tell the open ThreadView
    // to drop its ENTIRE profileâ†’gallery branch at once (showContactInfo = false pops both in one
    // animation), then it scrolls to + briefly flashes the message.
    private func goToChat(_ m: Message) {
        // An album child jumps to its ALBUM message â€” the chat has one row per album, keyed by the
        // parent id; the synthetic per-item id matches no row.
        NotificationCenter.default.post(name: .goToMessage, object: GoToMessage(cid: cid, messageId: parentMessageId(m.id)))
    }

    private func deleteSelected() {
        // Only MY OWN messages â€” the server rejects deleting others', which made them reappear.
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
              let (cipher, _) = try? await MediaSession.shared.data(from: url),
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

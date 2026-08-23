import SwiftUI
import UIKit

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
    /// How far the pager has travelled, in PAGE UNITS — 0 is Media at rest, 1.5 is halfway between
    /// Files and Voice. Written every frame of a drag and read by the tab bar, which is the whole of
    /// "the page and the indicator are one gesture". See `content`.
    @State private var tabProgress: CGFloat = 0
    @State private var mediaFilter: MediaFilter = .all
    @State private var selecting = false
    @State private var preparingShare = false   // Share tapped, items not ready yet (see shareSelected)
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
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue

    /// ⛔ WHAT THE PHONE IS SET TO — asked of the phone, not of the environment.
    ///
    /// `scheme` above cannot answer this. It reports what this view INHERITED, and this view is
    /// pushed from the profile, which pins its whole subtree to dark by the owner's standing rule.
    /// So on a light-mode phone `scheme` says dark here, and everything drawn from it comes out
    /// white on a white page: the title gone entirely, the count a ghost, white glyphs in the bar
    /// (his screenshot).
    ///
    /// The previous attempt at this was `.toolbarColorScheme(nil)`, and nil means "follow the
    /// environment" — it asked the same question of the same liar and got the same answer, which
    /// is why the bar never changed.
    ///
    /// The app's own setting is the authority: Light and Dark answer outright, System defers to the
    /// window's trait, which no SwiftUI subtree override can reach.
    private var pageScheme: ColorScheme {
        if let fixed = AppAppearance(rawValue: appearanceRaw)?.colorScheme { return fixed }
        let style = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
    }
    @Environment(\.dismiss) private var dismiss
    // Same zoom hero as the profile photo / chat bubbles: the viewer grows out of the tapped
    // tile and the drag-down close shrinks back into it.
    private var dark: Bool { pageScheme == .dark }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    // MARK: - Derived lists (gifs get their own tab, so they're excluded from Media)

    // Albums expanded into their individual photos/videos (user report: a single photo showed in All
    // Media, a multi-photo album never did â€” `isAlbum` messages fell through the image/video filter).
    // The synthetic "<messageId>-<index>" ids match the chat's album tile registry, so the fly-open and
    // the drag-close landing resolve real geometry.
    private var expandedAll: [Message] { all.flatMap { $0.expandedGalleryItems(cid: cid) } }

    /// Everything the Media tab holds, BEFORE the Show filter narrows it. Split out because the
    /// "..." menu has to know the difference: a tab with photos in it but the Videos filter on is
    /// empty on screen and still needs its menu, since the way back to All Media is inside it.
    private var allMediaItems: [Message] {
        // ⚠️ `!viewOnce` HERE IS A HOLE CLOSED, not a nicety (found 2026-08-11 while adding the
        // voice exclusion below): a view-once photo was never filtered from this grid, so the
        // person it was burned for could simply reopen it from All Media.
        expandedAll.filter { ($0.isImage || $0.isVideo) && !$0.isGif && !$0.viewOnce }
    }

    private var mediaItems: [Message] {
        allMediaItems.filter { m in
            switch mediaFilter {
            case .all:    return true
            case .photos: return m.isImage
            case .videos: return m.isVideo
            }
        }
    }
    private var gifItems: [Message]  { all.filter { $0.isGif } }
    // One-time notes are excluded the way view-once photos never reach the photo grid: a gallery
    // replay would be a second listen.
    private var voiceItems: [Message] { all.filter { $0.isAudio && !$0.viewOnce } }
    private var fileItems: [Message]  { all.filter { $0.isFile } }
    private var linkItems: [Message] {
        all.filter { !$0.isImage && !$0.isVideo && !$0.isGif && !$0.isAudio && !$0.isFile && Self.firstURL(in: $0.text) != nil }
    }

    // Counted off `mediaItems`, NOT the whole list. The "..." menu can narrow the grid to photos
    // only or videos only, and these two ignored that — so the header went on announcing the full
    // totals over a grid deliberately showing fewer, which reads as tiles missing.
    private var photoCount: Int { mediaItems.filter { $0.isImage && !$0.isGif }.count }
    private var videoCount: Int { mediaItems.filter { $0.isVideo }.count }

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
        .navigationBarBackButtonHidden(selecting)   // selection mode → only the X, no back
        // ⛔ THIS SCREEN'S BAR FOLLOWS THE PHONE, AND IT HAS TO SAY SO OUT LOUD.
        //
        // A pushed screen inherits the navigation bar's appearance from whoever pushed it, and the
        // profile page forces its bar dark — that page is always dark by the owner's rule, photo or
        // not. Pushed from there in light mode, this bar kept the dark scheme and drew WHITE "All
        // Media" and a white count on a white bar: his screenshot, where the title is not faint but
        // simply gone.
        //
        // `nil` was the first attempt and it could not work: nil is "follow the environment", and
        // the environment here is the profile's dark override. It asked the same question of the
        // same liar. `pageScheme` asks the phone instead — see it above.
        //
        // All three, because the leak arrives by three roads. The environment scheme is what the
        // title, the count and every `.primary` in the page read; the toolbar scheme is what the
        // bar's own material and its glass buttons read; and the tint is what the back chevron
        // reads, which the profile pins to white so it survives its own bar's material flip.
        .environment(\.colorScheme, pageScheme)
        .toolbarColorScheme(pageScheme, for: .navigationBar)
        .tint(Color.accentColor)
        .toolbar { toolbar }
        .background { NavBarNoHairline() }   // no hairline under the header (see below)
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
            // No system .zoom any more: MediaOpen flies the tapped tile's media (see flyOpen),
            // the same pipeline as the conversation. Leaving the zoom on ran both animations at once
            // and left the zoom's own dismiss pan fighting MediaDismissHost's.
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

    // ⛔ IT RODE THE NAVIGATION BAR FOR ONE BUILD, AND IT IS BACK HERE FOR GOOD.
    //
    // Moved into the bar's principal slot on 2026-08-20 to match the story picker's
    // Photos/Collections switch, which is one row: close button, control, nothing else. He has seen
    // it on the phone and wants the two rows — Back, "All Media", "…" above; the control on its own
    // strip below — with this control unchanged. "dont chnage bar design … just Plz Chnage position".
    //
    // So the title and the count come back with it, and the four `contentMargins` that reserve the
    // strip come back with them. Do not move it again.
    //
    // Apple's segmented control, the same one the Calls page uses for All / Missed (owner's order,
    // 2026-08-03). See MediaTabBar for why it cannot be both that and Liquid Glass on a page.
    private var tabBar: some View {
        MediaTabBar(titles: Tab.allCases.map(\.label),
                    selection: Binding(get: { Tab.allCases.firstIndex(of: tab) ?? 0 },
                                       set: { tab = Tab.allCases[$0] }),
                    // The pager's own live offset. See `content` for why the bar cannot get this
                    // from `selection`.
                    progress: tabProgress)
        // ⛔ NO HORIZONTAL PADDING HERE — IT WAS BEING APPLIED TWICE AND THAT IS THE WHOLE BUG.
        //
        // `MediaTabBar` already keeps its own 16pt page margin (`pageInset`, on the track itself).
        // This line added a second 16 outside it, so the track actually stood 32pt in while the
        // header's back button sits on the navigation bar's standard 16pt margin. That is his
        // "angel space make it the space back button is using": the two were never going to line up
        // while one of them was paying the margin twice.
        //
        // ⚠️ FIX IT IN ONE PLACE ONLY. If this ever needs changing again, change `pageInset` in
        // `MediaTabBar` — putting a number back here is how it became 32 the first time.
        .padding(.vertical, 8)   // together with barHeight this is MediaTabBar.slotHeight
        // NO BACKDROP ACROSS THE SLOT ANY MORE (his call, 2026-08-14: "can you make the capsule
        // float over the grid, now it looks like it has a background"). The full-width `.bar` band
        // came from the opposite report — the bar floating over nothing, with photos sliding raw
        // through the transparent gap beside it — and the answer to both is the same one the mood
        // bar and the attachment bar landed on: THE CONTROL IS THE SURFACE. Apple's segmented
        // control already carries an opaque track with the selected pill on it, so it is a capsule
        // floating over the photos, and the gap beside it is meant to show them.
        //
        // ⚠️ Do NOT put a glass capsule back around it "to help" — that was the fifth-swing bug, our
        // capsule around Apple's track drawing one pill inside another. It reads differently now
        // that the track is ours: the glass IS the track (see `MediaTabBar`), so there is no second
        // shape. The rule that survives is the one that mattered: never two nested capsules.
        .frame(maxWidth: .infinity)
    }

    // (Deleted: ClearSegmentedTrack. It reached into the segmented control and erased its background
    // images so a hand-made glass capsule behind it could show — which is what removed the active-tab
    // indicator, since iOS draws the selected pill as part of that same surface. Nothing replaces it:
    // the stock control already renders in the system material.)

    // Swipe left/right to move between tabs, using the NATIVE paging TabView rather than a hand-rolled
    // drag gesture: it carries the interactive rubber-banding, the velocity handling and the correct
    // relationship with the screen-edge back gesture for free (an edge pan still pops the screen, because
    // the system edge recogniser outranks a scroll view's pan).
    /// ⛔ A PAGING `ScrollView`, NOT A PAGED `TabView`, AND THE REASON IS THE TAB BAR — owner,
    /// 2026-08-23: "when the Files page is about 10% visible, the active tab indicator is still
    /// completely on Media … the indicator must be driven by the same real-time horizontal scroll
    /// value as the page".
    ///
    /// ⚠️ A PAGED `TabView` HAS NO SUCH VALUE TO GIVE. Its selection is a discrete tag that flips as
    /// the finger crosses the midpoint, and there is no public way to ask it how far the drag has
    /// travelled — so anything hung off it can only ever jump, and jump halfway through. Every
    /// smoothing attempt on the bar itself (a spring on the row, `matchedGeometryEffect`) was
    /// interpolating between two positions AFTER the fact, which is a nicer jump, not a follow.
    ///
    /// `onScrollGeometryChange` reports the offset every frame of the drag, in page units, so the
    /// pill and the page move on one number. Cancelling a swipe carries the pill back with it for
    /// free — it is the same number going the other way.
    ///
    /// ⚠️ THE OLD WARNING ABOUT THE COMMIT FRAME STILL STANDS AND IS STILL OBEYED. Nothing animated
    /// hangs off `tab` here: the bar reads `tabProgress` and draws a pill at a position, which is a
    /// frame's worth of arithmetic and no animation at all. `.scrollPosition` is what a TAP writes,
    /// and that one is allowed to animate because there is no drag under it.
    @ViewBuilder private var content: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { t in
                    page(t)
                        .containerRelativeFrame(.horizontal)
                        .id(t)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: Binding(get: { Optional(tab) },
                                    set: { if let t = $0 { tab = t } }))
        // Page units: 0 is Media sitting still, 1.5 is halfway between Files and Voice. Divided by
        // the CONTAINER's width rather than by a constant, so a rotation or a split view cannot put
        // the pill somewhere the page is not.
        .onScrollGeometryChange(for: CGFloat.self) { g in
            g.containerSize.width > 1 ? g.contentOffset.x / g.containerSize.width : 0
        } action: { _, p in
            tabProgress = p
        }
    }

    @ViewBuilder private func page(_ t: Tab) -> some View {
        switch t {
        case .media: grid(mediaItems, emptyIcon: "photo.on.rectangle", emptyText: "No media")
        case .files: filesList
        case .voice: voiceList
        case .links: linksList
        case .gifs:  grid(gifItems, emptyIcon: "square.stack.3d.up", emptyText: "No GIFs")
        }
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
        } else if showsMoreMenu {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
    }

    /// NO "..." ON AN EMPTY TAB (owner 2026-08-19, on the Files tab with nothing in it). The menu's
    /// only entry on Files, Voice, Links and GIFs is Select, and Select on an empty page is a button
    /// that greys itself out the moment you open it — a control that exists to tell you it cannot be
    /// used. The Media tab keeps its menu as long as the tab holds anything at all, filtered or not,
    /// because the Show section is in there and it is the only way to undo a filter.
    private var showsMoreMenu: Bool {
        tab == .media ? !allMediaItems.isEmpty : !currentItems.isEmpty
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
            // Always present INSIDE the menu, disabled when there is nothing to select. A SwiftUI Menu
            // with no children renders as a button that does nothing at all when tapped, so Select is
            // never made conditional here — the "Show" section above is Media-only, and a tab whose menu
            // held neither looked broken rather than empty. (An empty tab has no "..." at all now; see
            // `showsMoreMenu`. This still matters on Media, where a filter can empty the grid.)
            Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                .disabled(currentItems.isEmpty)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
        }
        // ⛔ IT PRESSES NOW (owner, 2026-08-21: "thers no affect back button has effect couse is
        // native lets add effect like that").
        //
        // The back button beside it is the system's own, so it dims and its glass reacts under a
        // finger for free. A `Menu` does not: it opens on touch-DOWN and, left in its automatic
        // style, never enters a pressed state at all, so the one control on this bar that is ours
        // was the one control that felt dead. `.button` hands it the same button styling the bar
        // gives everything else, which is where that reaction lives — rather than us drawing a
        // second circle behind a circle the toolbar has already drawn.
        .menuStyle(.button)
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
                // A SPINNER WHILE IT PREPARES. Even with the cache below there is a case that has to
                // fetch (a photo evicted from this phone), and a button that stays exactly as it was
                // for a second reads as a button that did not work.
                Group {
                    if preparingShare { ProgressView().tint(.primary) }
                    else { Image(systemName: "square.and.arrow.up").font(.system(size: 20)).foregroundStyle(.primary) }
                }
                .frame(width: 48, height: 48)
                .liquidGlass(Circle(), interactive: true)
            }
            .disabled(selection.isEmpty || preparingShare)
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
                // KEYED BY POSITION, NOT BY TITLE. `id: \.title` assumed two groups can never carry
                // the same name, which only holds while every message is in strict date order. One
                // message with a pending or unreadable `createdAt` puts a second "Today" further
                // down the list, and SwiftUI's answer to a duplicate id is to drop one of them —
                // silently, so it looks like photos are simply missing rather than like a bug.
                ForEach(Array(sections(items).enumerated()), id: \.offset) { _, section in
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
                        // Selected was `Color.accentColor`, which is the app's `.primary` tint and so
                        // WHITE at night — the same white as the unselected ring right beside it. The
                        // only thing carrying the state over a photo was the glyph's shape and a 0.25
                        // dim. Blue makes the colour carry it, which is what a tick is for.
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(selected ? Theme.defaultBubble(dark) : .white)
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
            .foregroundStyle(selected ? Color.primary : .secondary)
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

    // OPEN LIKE THE CHAT: fly only the media out of its tile (MediaOpen), then reveal the viewer.
    // This screen used the system .zoom while the conversation flew - the SAME viewer opened with two
    // different animations depending on where you tapped, and the zoom transition's own interactive
    // dismiss pan ran ALONGSIDE MediaDismissHost's, two gestures fighting over one close. The tile's
    // rect is already registered (MediaRectReporter, the drag-close's landing target), so the open now
    // reads the same registry the close lands on - one pipeline, both directions, every entry point.
    private func flyOpen(_ m: Message, poster: String?, present rawPresent: @escaping () -> Void) {
        // Through the gate: a tap arriving while the previous viewer is still dismissing used to be
        // swallowed by SwiftUI (user: "when I close an image and click again fast it doesn't work").
        let present = { MediaPresentGate.present(rawPresent) }
        let key = MediaOpenRects.key(.gallery, m.id)
        // Resolves through BOTH cache tiers â€” memory only was why the first tap after returning from
        // the background slid up from the bottom instead of flying. See MediaOpen.flyOrPresent.
        MediaOpen.flyOrPresent(imageUrl: poster, rectKey: key, present: present)
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
        let cid = self.cid
        Task {
            if let img = await Self.shareImage(m, cid: cid) { await MainActor.run { shareItems = [img] } }
            else if !m.text.isEmpty { await MainActor.run { shareItems = [m.text] } }
        }
    }
    private func shareSelected() {
        // Share the decrypted images among the selection (the shareable representation we can build here).
        guard !preparingShare else { return }
        let picked = all.filter { selection.contains($0.id) }
        let cid = self.cid
        preparingShare = true
        Task {
            // ALL AT ONCE, not one after another. This was a `for` loop that awaited each photo in
            // turn, so picking four meant four fetches END TO END before the sheet could open, and
            // nothing on screen said anything was happening (owner 2026-08-19: "it opens late").
            // The photos have nothing to do with each other, so they are fetched together and put
            // back in the order they were picked.
            var out: [(Int, UIImage)] = []
            await withTaskGroup(of: (Int, UIImage?).self) { group in
                for (i, m) in picked.enumerated() {
                    group.addTask { (i, await Self.shareImage(m, cid: cid)) }
                }
                for await (i, img) in group { if let img { out.append((i, img)) } }
            }
            var items: [Any] = out.sorted { $0.0 < $1.0 }.map { $0.1 as Any }
            if items.isEmpty { for m in picked where !m.text.isEmpty { items.append(m.text) } }
            await MainActor.run {
                preparingShare = false
                if !items.isEmpty { shareItems = items }
            }
        }
    }

    /// The full-quality image behind a message, for sharing (nil for non-images / failures).
    ///
    /// ⚠️ THE PHONE'S OWN COPY FIRST, and that is the second half of the "it opens late" report.
    /// This went straight to the network and decrypted the photo again every single time, even
    /// though the tile you are looking at was drawn from a picture `DiskImageCache` already holds:
    /// SecureImageView writes the ORIGINAL decrypted bytes to disk the first time a photo is seen.
    /// So Share paid for a download of something the app had in hand.
    ///
    /// The raw file, not `image(for:)`: that one returns the display-bounded bitmap, which would
    /// share a downscaled copy of your own photo. The memory tier is the fallback under it, and the
    /// download stays as the last resort for a photo this phone no longer keeps.
    ///
    /// `static`, so the parallel fetch below hands the task group a message and a cid rather than
    /// the whole view.
    private static func shareImage(_ m: Message, cid: String) async -> UIImage? {
        if let data = m.localImageData { return UIImage(data: data) }
        guard m.isImage, let s = m.imageUrl else { return nil }
        if let raw = await DiskImageCache.shared.rawData(for: s), let ui = UIImage(data: raw) { return ui }
        if let mem = DiskImageCache.shared.memoryImage(s) { return mem }
        guard let url = URL(string: s), let meta = m.enc,
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

/// ⛔ TAKES THE HAIRLINE OFF THIS SCREEN'S NAVIGATION BAR (owner, 2026-08-21: "toheader has broder
/// ios 26 never had top border").
///
/// The line under the header is the bar's SHADOW, which UIKit draws whenever content scrolls beneath
/// it. There is no SwiftUI modifier for it: `.toolbarBackground(.hidden)` takes the material away
/// with it and leaves photographs sliding raw behind the title, which is the opposite of what this
/// screen wants. The one property is `UINavigationBarAppearance.shadowColor`.
///
/// ⚠️ IT IS SET ON THE NAVIGATION ITEM, NOT THE BAR. The bar is shared by every screen in the stack,
/// so clearing it there would silently take the hairline off the pages this one was pushed from and
/// leave it off after popping back. An appearance on `navigationItem` belongs to this screen alone
/// and is put back by the system on the way out.
///
/// ⚠️ AND IT IS A COPY OF WHAT IS ALREADY THERE, not a fresh appearance. A new
/// `UINavigationBarAppearance()` starts transparent and would take this bar's glass with it — the
/// same trade the segmented control lost twice. Only `shadowColor` changes.
private struct NavBarNoHairline: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Next runloop turn: SwiftUI has not attached this view to its hosting controller yet on the
        // pass that builds it, so the responder chain has nowhere to walk.
        DispatchQueue.main.async {
            var responder: UIResponder? = uiView
            while let next = responder?.next {
                if let vc = next as? UIViewController, vc.navigationController != nil {
                    Self.strip(vc); return
                }
                responder = next
            }
        }
    }

    private static func strip(_ vc: UIViewController) {
        guard let bar = vc.navigationController?.navigationBar else { return }
        func cleared(_ source: UINavigationBarAppearance?) -> UINavigationBarAppearance {
            let a = (source?.copy() as? UINavigationBarAppearance) ?? {
                let fresh = UINavigationBarAppearance()
                fresh.configureWithDefaultBackground()
                return fresh
            }()
            a.shadowColor = .clear
            a.shadowImage = UIImage()
            return a
        }
        let item = vc.navigationItem
        item.standardAppearance   = cleared(bar.standardAppearance)
        item.scrollEdgeAppearance = cleared(bar.scrollEdgeAppearance ?? bar.standardAppearance)
        item.compactAppearance    = cleared(bar.compactAppearance ?? bar.standardAppearance)
    }
}

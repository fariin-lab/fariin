import SwiftUI
import Photos
import AVFoundation
import UIKit

// Process-lifetime cache of the Recents first page + album list, so reopening the attach sheet renders
// the grid INSTANTLY (the fetch used to start from zero on every open = an empty sheet for seconds).
@MainActor enum RecentsCache {
    static var assets: [PHAsset] = []
    static var albums: [AttachAlbum] = []
    private static var warming = false

    // Thumbnail pre-cache (the "images coming late" fix): the grid tiles' DECODED images, warmed before
    // the sheet opens. The asset-list prewarm alone still left every tile decoding its thumbnail AFTER
    // it appeared — the grid showed placeholders that filled in a beat later. The caching manager holds
    // the decoded thumbs so tiles render instantly. Request params MUST match precache params for hits.
    static let thumbs = PHCachingImageManager()
    static let thumbSize = CGSize(width: 300, height: 300)
    static let thumbOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic   // fast first, sharp after
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }()
    static func precache(_ list: [PHAsset]) {
        thumbs.startCachingImages(for: list, targetSize: thumbSize, contentMode: .aspectFill, options: thumbOptions)
    }

    // PRE-WARM the recents so the grid is ready BEFORE the sheet ever opens. Called when the chat opens;
    // the fetch runs off-main and the first page + its thumbnails land in the cache, so tapping + shows
    // photos instantly instead of an empty sheet that fills in a beat later.
    /// The warm that is currently running, so the sheet can WAIT for it instead of racing it.
    ///
    /// ⛔ THE SHEET USED TO START A SECOND FETCH OF THE SAME PHOTOS — owner, 2026-08-24, "attach sheet
    /// images coming late", with the grid empty but for the Camera tile. The prewarm below is kicked
    /// off when the chat opens and takes a moment on a real library; tapping + before it lands found
    /// `assets` still empty, skipped the instant path, and went off to fetch the identical first page
    /// itself. Two fetches for one answer, and the sheet showed nothing until the slower one finished.
    private static var warmTask: Task<Void, Never>?

    /// Wait for an in-flight `prewarm`. Returns at once when there isn't one, or when it is done.
    static func awaitWarm() async { await warmTask?.value }

    static func prewarm() {
        guard assets.isEmpty, !warming else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        warming = true
        warmTask = Task.detached(priority: .userInitiated) {
            let f = PHFetchOptions()
            f.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            f.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            let res = PHAsset.fetchAssets(with: f)
            var out: [PHAsset] = []
            let end = min(200, res.count)
            if end > 0 {
                res.enumerateObjects(at: IndexSet(integersIn: 0..<end), options: []) { a, _, _ in out.append(a) }
            }
            await MainActor.run {
                RecentsCache.assets = out
                RecentsCache.precache(Array(out.prefix(60)))   // first ~2 screens of thumbs, decoded + ready
                RecentsCache.warming = false
            }
        }
    }
}

// Standard recents strip for the attach panel: the newest camera-roll
// photos + videos, one tap to send. Asks for read access on first use; with Limited
// access it simply shows whatever the user granted. Photos open the chat editor
// (crop/caption); videos go straight into the send pipeline.
struct AttachRecentsStrip: View {
    /// ⛔ 44, THEIR NUMBER, READ FROM THEIR SOURCE — owner, 2026-08-24: "make it like tg".
    ///
    /// The reference app lays its picker's header controls out inside a 44pt-high container
    /// (`MediaPickerScreen`, `containerSize: CGSize(width: …, height: 44.0)`), inset 16 from the
    /// screen edges (`barButtonSideInset`). Ours were 48 with the same 16 inset, so the inset already
    /// matched and only the button was four points over.
    ///
    /// ⚠️ BOTH BUTTONS, NOT JUST THE ✕. The close and the selected-count sit either side of the
    /// title and read as a pair; changing one would leave the header lopsided. Their glyphs are
    /// unchanged — 44 is the size the reference states for the control, and the marks inside ours
    /// were never what he was comparing.
    ///
    /// ⚠️ ONLY THIS SHEET. `CloseXButton` in the design system is still 48 and is used by the GIF
    /// picker, Edit Profile and the wallpaper sheet; this is the photo sheet's header, which is the
    /// one he measured against theirs.
    private static let headerButtonSize: CGFloat = 44

    var onCamera: () -> Void = {}
    var onClose: () -> Void = {}
    var onPickPhoto: (UIImage) -> Void
    var onPickVideo: (URL) -> Void                              // TAP a video → open the trim editor
    var onSendVideos: ([URL], String) -> Void = { _, _ in }     // SELECT + Send → send videos directly
    var onSendAlbum: ([UIImage], String, Bool) -> Void = { _, _, _ in }   // images, caption, viewOnce
    var onSendMixed: ([ApprovalMedia], String, String?) -> Void = { _, _, _ in }   // items, caption, clientId of the already-posted bubble
    /// Posted the instant Send is tapped, from the grid's already-decoded thumbnails: grid images,
    /// which are videos, caption, clientId. The real send reuses that clientId.
    var onOptimisticGroup: ([UIImage], [Bool], String, String) -> Void = { _, _, _, _ in }
    var onOptimisticFailed: (String) -> Void = { _ in }   // nothing resolved → don't strand the bubble
    var onOpenMedia: ([ApprovalMedia]) -> Void = { _ in }        // tapping media WHILE selecting → the mixed approval pager
    var onCaptionFocused: () -> Void = {}                        // caption field focused → parent grows the sheet to .large
    @Binding var hasSelection: Bool   // ≥1 selected → parent hides the source row (Photos/Files/…)
    /// Ids the approval screen removed while it was open over this sheet. The selection deliberately
    /// SURVIVES opening the editor (X comes back here and re-picking everything was the old
    /// complaint), so the one thing that must travel back is a removal — otherwise a video dropped
    /// in the editor is still ticked here (owner 2026-08-04).
    var removedIds: Set<String> = []
    @FocusState private var captionFocused: Bool

    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var fetchResult: PHFetchResult<PHAsset>?   // the FULL library fetch (lazy) — assets pages out of it
    @State private var loadedCount = 0                        // how many of fetchResult are materialized into `assets`
    private let pageSize = 200                                // batch size per page-in
    @State private var loadingPick = false   // fetching the full-size asset after a tap
    @State private var selectedIds: [String] = []    // chosen asset ids, in tap order (checkbox taps)
    // GLOBAL selection store (native-picker pattern): the selected PHAssets themselves,
    // captured at toggle time — selection survives browsing between albums. Resolving from the visible
    // album's array dropped everything picked in OTHER folders (the cross-album selection bug).
    @State private var selectedAssets: [String: PHAsset] = [:]
    @State private var caption = ""                  // caption for the selected batch
    @State private var viewOnce = false              // "view once" toggle (single photo only)
    @State private var showAlbums = false
    @State private var albumTitle = "Recents"
    @State private var selectedAlbum: PHAssetCollection?   // nil = the newest across the whole library
    @State private var albums: [AttachAlbum] = []

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)   // 3 per row (user request)

    /// The header's own height: the 44pt close button plus 8 above it and 8 below. The grid and the
    /// album list start this far down (see `grid`), so nothing sits UNDER an opaque bar at rest.
    ///
    /// ⚠️ KEEP THIS EQUAL TO WHAT `header` ACTUALLY PADS TO. It is not decoration — `contentMargins`
    /// feeds it to both scroll views as their top margin, so a number smaller than the bar hides the
    /// first row of photos under it and a larger one leaves a strip of empty sheet he has rejected
    /// twice. It was still 56 for a 48pt button after the button became 44 and gained 8 on top.
    private let headerHeight: CGFloat = 60

    var body: some View {
        // THE PHOTOS RUN UNDER THE HEADER (his reference, 2026-08-14: "make the white follow the
        // photo… swipe down and it comes back"). It used to be the first row of a VStack, which is a
        // slot: the grid started below it and the sheet's own white filled the strip, so the header
        // was a lid rather than something the content passes beneath.
        //
        // As a top safe-area inset it reserves exactly its own height, so nothing is hidden at rest —
        // and everything slides under it the moment you scroll, coming back as you scroll down. The
        // header itself paints NOTHING now: the close button carries its own glass circle and the
        // album title floats, which is what theirs does.
        //
        // ⚠️ THAT LAST LINE STOPPED BEING TRUE on 2026-08-17, when the header took a solid background
        // so the title and chevron would stop dissolving into the photos (see `header`). An opaque bar
        // over a grid that starts at the very top edge means the Camera tile and the first row are
        // half covered before you touch anything — owner 2026-08-19, screenshot. The fix is NOT to go
        // back to an inset (that brings back the strip of empty sheet he rejected): the header stays
        // an overlay, and the SCROLL CONTENT gets a top margin of the header's height. At rest the
        // grid begins under a clear edge; scrolled, the photos still run beneath the bar exactly as
        // before, because a content margin moves the content, not the scroll view.
        Group {
            if showAlbums { albumsList } else { grid }
        }
        // ⚠️ AN OVERLAY, NOT AN INSET, and that is his follow-up ("it still has a bit left"). An inset
        // RESERVES its height, so at rest there was still a strip of the sheet's own background above
        // the first photos — the white was gone but the space it held was not. Overlaid, the grid
        // runs to the very top edge and the header floats on it from the first frame, which is what
        // theirs does. Nothing is unreachable: the first row sits under a close button with its own
        // glass circle and a floating title, and one scroll moves it clear.
        .overlay(alignment: .top) { header }
        // ≥1 selected → a caption + Send bar as a native bottom inset bar, so iOS pins it directly above
        // the keyboard (no home-indicator gap between the bar and the keyboard) and above the home
        // indicator when the keyboard is down — exactly like a composer.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selectedIds.isEmpty { captionBar }
        }
        .overlay { if loadingPick { ProgressView().tint(.secondary) } }
        .task {
            guard status == .authorized || status == .limited else { return }
            // STABLE open: render the cached first page + albums instantly (no empty flash), then
            // refresh fresh underneath — the same pattern as the media gallery.
            if assets.isEmpty, selectedAlbum == nil {
                // The chat kicked off a warm when it opened. If it has not landed yet, WAIT for it —
                // it is already fetching exactly this page, and starting our own was what made the
                // grid sit empty. `awaitWarm` returns immediately when nothing is in flight.
                if RecentsCache.assets.isEmpty { await RecentsCache.awaitWarm() }
                if !RecentsCache.assets.isEmpty {
                    assets = RecentsCache.assets
                    albums = RecentsCache.albums
                }
            }
            load(); loadAlbums()
        }
        .onChange(of: selectedIds.isEmpty) { _, empty in hasSelection = !empty }
        .onChange(of: removedIds) { _, gone in
            guard !gone.isEmpty else { return }
            selectedIds.removeAll { gone.contains($0) }
            for id in gone { selectedAssets.removeValue(forKey: id) }
        }
    }

    // X close (48pt glass) + a "Recents ▾" title. (Selection is per-thumbnail via the checkbox — no
    // separate Select button; tapping the photo itself opens it.)
    private var header: some View {
        ZStack {
            Button { withAnimation(.snappy(duration: 0.25)) { showAlbums.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(albumTitle).font(.headline)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                        .rotationEffect(.degrees(showAlbums ? 180 : 0))
                }
                .foregroundStyle(.primary)
            }
            HStack {
                // Inside a specific album (folder) the X becomes a BACK arrow → returns to Recents;
                // at the top it's the close X.
                Button {
                    if selectedAlbum != nil || showAlbums {
                        selectedAlbum = nil
                        albumTitle = "Recents"
                        withAnimation(.snappy(duration: 0.25)) { showAlbums = false }
                        load()
                    } else {
                        onClose()
                    }
                } label: {
                    Image(systemName: (selectedAlbum != nil || showAlbums) ? "chevron.left" : "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        // ⚠️ MERGE 2026-08-24, TWO BRANCHES DISAGREED HERE AND BOTH WERE RIGHT ON
                        // THEIR OWN SIDE. The other branch had this white, correctly, because it
                        // still carries the black header bar. This branch REMOVED that bar on the
                        // owner's word ("back the way it before"), so the header follows the phone's
                        // scheme again and white would be an invisible X in daylight. Colour comes
                        // from the revert, size comes from the other branch's measurement — the two
                        // decisions are independent and neither one cancels the other.
                        .foregroundStyle(.primary)
                        .frame(width: Self.headerButtonSize, height: Self.headerButtonSize)
                        .liquidGlass(Circle(), interactive: true)
                }
                Spacer()
                // Selected count — BLUE Liquid Glass (user spec 2026-07-14 evening: "make blue, don't
                // remove liquid glass"): interactive glass WITH the bubble-blue tint + white number.
                if !selectedIds.isEmpty {
                    Text("\(selectedIds.count)")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: Self.headerButtonSize, height: Self.headerButtonSize)
                        .liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))
                }
            }
        }
        .padding(.horizontal, 16)
        // ⛔ THE ✕ WAS RIDING THE SHEET'S ROUNDED CORNER — owner, 2026-08-24, magnified: his shot shows
        // the glass circle crossing the corner curve and poking outside it. There was no top padding at
        // all, so a 44pt circle began at the sheet's very first pixel, where the corner radius is still
        // cutting the surface away.
        //
        // ⚠️ THIS IS A BAR, SO IT IS SPACED LIKE ONE. His words for what he wants: system chrome
        // attached to the edge, not app content floating in the safe area. A bar item is CENTRED in its
        // bar, and the bar starts below the grabber — it does not start at the sheet's own edge. 8 above
        // and 8 below puts the circle clear of both the grabber and the corner, and centres it.
        .padding(.top, 8)
        .padding(.bottom, 8)
        // ⚠️ A SURFACE UNDER THE HEADER. Owner 2026-08-17, with the sheet open: "Recents ▾" and the
        // X sat directly on the photo grid, so the title and its chevron dissolved into whatever
        // pictures happened to be behind them — and the way into Albums is that chevron, so a
        // control nobody can see is a door nobody can find.
        //
        // The page's own background, not white: this sheet follows the colour scheme, and a
        // hardcoded white bar would be a bright slab across a dark picker. Same reasoning as the
        // rest of the app — see the accent-is-white-at-night note. Extended under the top safe area
        // so it reads as the sheet's own header rather than a stripe floating in it.
        .background(Color(.systemBackground).ignoresSafeArea(edges: .top))
    }

    // Caption + Send bar shown while items are selected (replaces the source row). The selected COUNT is
    // shown at the header top-right (not on the send button); the send button is real Liquid Glass.
    private var captionBar: some View {
        // ⛔ THE COMPOSER'S OWN NUMBERS — owner, 2026-08-25: "make it like what size is using attach
        // bar". This is the same object in a different room: a glass pill with a growing field, a
        // trailing toggle inside it and a tinted send circle beside it. It had drifted on every
        // measurement that shows — 23pt corners against the composer's 20, a 16pt leading inset
        // against 14, 8 and 10 where the composer spaces 3 and 8, and a 17pt arrow against 19 — so
        // the two read as different-sized versions of one control. Numbers below are the composer's,
        // taken from `ThreadView.inputRow` and `ThreadView.rightButton`.
        HStack(alignment: .bottom, spacing: 8) {   // send hugs the bottom as the caption grows
            HStack(alignment: .bottom, spacing: 3) {
                // View-once media can't carry a caption, so the field is disabled + the
                // prompt says why when View Once is on.
                TextField("", text: $caption,
                          prompt: Text(viewOnce ? "No caption for View Once" : "Add a caption…")
                            .foregroundColor(Color(.systemGray)),
                          axis: .vertical)
                    .font(.system(size: 17))   // stated, like the composer's, rather than left to .body
                    .lineLimit(1...7)   // multi-line caption, grows up to ~7 lines then scrolls
                    .foregroundStyle(.primary)
                    .focused($captionFocused)
                    .disabled(viewOnce)
                    .padding(.vertical, 9)   // single-line vertical centering; ① stays bottom-aligned
                // View Once: the "1" toggle inside the caption field, for a single photo.
                // When on, the photo self-destructs after the recipient opens it once — and the caption is
                // cleared + disabled.
                if selectedIds.count == 1 {
                    Button {
                        viewOnce.toggle()
                        if viewOnce { caption = ""; captionFocused = false }
                    } label: {
                        Image(systemName: viewOnce ? "1.circle.fill" : "1.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(viewOnce ? Color(hex: 0x0A84FF) : Color(.systemGray))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 40, height: 40)   // matches the 40px bar; bottom-aligned
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 40)
            .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)   // real native Liquid Glass
            Button { sendSelected() } label: {
                // Match the main composer send: WHITE arrow on a blue-tinted glass circle (was a blue
                // arrow on clear glass, which read as a different, washed-out button). The GLYPH was
                // still 17 against the composer's 19 — the circle matched and the arrow inside it
                // did not, which is the half of "same button" that is easiest to miss.
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)   // 40px send (user spec)
                    .liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
        // Focusing the caption grows the sheet to .large so this bar pins above the keyboard instead of
        // the medium sheet shoving the whole content up (the caption "jumping" to mid-screen).
        .onChange(of: captionFocused) { _, focused in if focused { onCaptionFocused() } }
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // Limited access: a slim banner with a Manage button so the user can add more photos to the
            // shared selection (otherwise the picker silently shows only the old subset forever).
            if status == .limited {
                HStack(spacing: 8) {
                    Text("Only some photos are shared with Fariin.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage") { presentLimitedPicker() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            LazyVGrid(columns: cols, spacing: 6) {
                cameraTile                                   // first cell = Camera
                switch status {
                case .authorized, .limited:
                    ForEach(assets, id: \.localIdentifier) { a in
                        // Tap the PHOTO → single editor when nothing is selected; if a selection is active,
                        // open the multi-image approval (paging) of the selected set instead. Tap the
                        // CHECKBOX → (de)select. Separate, never conflict.
                        RecentThumb(asset: a, selectionNumber: selectionIndex(a),
                                    onOpen: { openTapped(a) },
                                    onToggle: { toggle(a) })
                            .onAppear { loadMoreIfNeeded(a) }   // near the end → page in the next batch
                    }
                case .notDetermined:
                    accessTile("Allow Photos", icon: "photo.on.rectangle.angled") { request() }
                default:
                    accessTile("Settings", icon: "photo.on.rectangle.angled") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
        }
        // Starts the Camera tile and the first row of photos clear of the header bar. See `body`.
        .contentMargins(.top, headerHeight, for: .scrollContent)
    }

    // Native-style album list (Recents, Favorites, Videos, Selfies, Live Photos, Panoramas, user albums).
    private var albumsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    Button { selectAlbum(album) } label: {
                        HStack(spacing: 14) {
                            AlbumThumb(collection: album.collection)
                            Text(album.title).font(.system(size: 17)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        // ⛔ ROOMIER, AND INSET FURTHER FROM THE LEFT — owner, 2026-08-24: the album
                        // list "looks zoomed out" beside his reference, and the rows "tuck" too
                        // close to the edge. The thumbnail carries the row's height, so 52 with 7
                        // above and below is a 66pt row against the reference's ~76; the leading
                        // inset is the other half of it, at 16 against their 20-plus.
                        .padding(.leading, 20).padding(.trailing, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Starts where the TITLE starts, not where the thumbnail does — 20 leading + 60
                    // thumb + 14 gap. Moved with the inset above so the rule still lines up with the
                    // first letter rather than floating in the gap beside it.
                    Divider().padding(.leading, 94)
                }
            }
        }
        // Same as the grid: the first album row is not born under the bar.
        .contentMargins(.top, headerHeight, for: .scrollContent)
    }

    private func selectAlbum(_ album: AttachAlbum) {
        selectedAlbum = album.isAllRecents ? nil : album.collection
        albumTitle = album.title
        withAnimation(.snappy(duration: 0.25)) { showAlbums = false }
        load()
    }

    // The Camera tile is the first cell of the grid; tap to open the camera.
    private var cameraTile: some View {
        Button(action: onCamera) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        // The app's OWN camera icon (ic_camera SVG — same one the composer uses),
                        // not the SF Symbol (user spec 2026-07-14).
                        Image("ic_camera").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 26, height: 26)
                        Text("Camera").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                }
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func accessTile(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 19))
                        Text(text).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary).padding(4)
                }
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func request() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
            DispatchQueue.main.async {
                status = s
                if s == .authorized || s == .limited { load() }
            }
        }
    }

    // Fetch the WHOLE library (no fetchLimit — the old 60 cap was why most of the library never showed),
    // newest first, images+videos only (predicate, so nothing is skipped by manual filtering). The
    // PHFetchResult is lazy, so the fetch itself is cheap; assets are MATERIALIZED in pages of `pageSize`
    // as the grid scrolls (loadMoreIfNeeded), like a windowed gallery.
    private func load() {
        let f = PHFetchOptions()
        f.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        f.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                  PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        // The fetch RESULT is lazy and cheap, so it stays here. Materialising it is not.
        let res = selectedAlbum.map { PHAsset.fetchAssets(in: $0, options: f) } ?? PHAsset.fetchAssets(with: f)
        let end = min(pageSize, res.count)
        let isRecents = selectedAlbum == nil
        // ⛔ THE 200 ASSETS ARE BUILT OFF THE MAIN THREAD NOW — owner, 2026-08-24, "images coming late".
        // `enumerateObjects` over a page is the expensive half and it ran right here, on main, inside
        // `.task` — which SwiftUI runs AFTER the first frame. So the sheet drew its empty grid, then
        // froze while the page was materialised, then the photos appeared. That sequence is exactly
        // what "coming late" looks like from the outside.
        //
        // Same shape as `loadAlbums` directly below, deliberately: detached work, one hop back to the
        // main actor, one assignment.
        Task.detached(priority: .userInitiated) {
            var out: [PHAsset] = []
            if end > 0 {
                out.reserveCapacity(end)
                res.enumerateObjects(at: IndexSet(integersIn: 0..<end), options: []) { a, _, _ in out.append(a) }
            }
            let built = out
            await MainActor.run {
                // ⚠️ ALL FOUR LAND TOGETHER. `fetchResult` and `loadedCount` used to be set here while
                // the page was still being built, which left a window where the paging state described
                // a page that did not exist yet — `loadedCount` at 0 against a grid still showing the
                // cached photos, so a scroll could have paged the first batch in a second time.
                fetchResult = res
                // Swapped in ONE assignment — never blank `assets` to [] first (that wiped the
                // instantly-shown cache and flashed the grid empty on every open).
                assets = built
                loadedCount = end
                if isRecents { RecentsCache.assets = built }
                // Warm the new page's thumbnails (album switches included) so tiles never fill in late.
                RecentsCache.precache(Array(built.prefix(60)))
            }
        }
    }

    // Materialize the next page of the fetch result into the grid's array.
    private func appendNextPage() {
        guard let res = fetchResult, loadedCount < res.count else { return }
        let end = min(loadedCount + pageSize, res.count)
        var out: [PHAsset] = []
        out.reserveCapacity(end - loadedCount)
        res.enumerateObjects(at: IndexSet(integersIn: loadedCount..<end), options: []) { a, _, _ in
            out.append(a)
        }
        assets.append(contentsOf: out)
        loadedCount = end
        // Cache the Recents first page so the NEXT sheet open renders instantly (no empty flash).
        if selectedAlbum == nil, loadedCount <= pageSize { RecentsCache.assets = assets }
        RecentsCache.precache(Array(out.prefix(60)))   // warm the incoming page's thumbs ahead of display
    }

    // Called as thumbnails appear: nearing the end of the loaded window → page in the next batch.
    private func loadMoreIfNeeded(_ a: PHAsset) {
        guard let res = fetchResult, loadedCount < res.count, assets.count >= 30 else { return }
        let tail = assets.suffix(15)
        if tail.contains(where: { $0.localIdentifier == a.localIdentifier }) { appendNextPage() }
    }

    // Limited Photos access: let the user extend the shared selection in place (the manage flow),
    // then reload so the new items appear immediately.
    private func presentLimitedPicker() {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = top?.presentedViewController { top = p }
        guard let top else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in
            DispatchQueue.main.async { load(); loadAlbums() }
        }
    }

    // Build the album list: Recents (whole library) + non-empty smart albums + user albums.
    // OFF the main thread (PhotoKit fetches are thread-safe) and with fetchLimit-1 emptiness checks —
    // the old version full-fetched EVERY album's assets just to count them, ON the main actor, which
    // froze the sheet for seconds on big libraries (the "empty for the first seconds" bug).
    private func loadAlbums() {
        Task.detached(priority: .userInitiated) {
            let one = PHFetchOptions()
            one.fetchLimit = 1   // "is it non-empty?" — never materialize the whole album
            var out: [AttachAlbum] = [AttachAlbum(id: "recents", title: "Recents", collection: nil, isAllRecents: true)]
            let smart: [(PHAssetCollectionSubtype, String)] = [
                (.smartAlbumFavorites, "Favorites"), (.smartAlbumVideos, "Videos"),
                (.smartAlbumSelfPortraits, "Selfies"), (.smartAlbumLivePhotos, "Live Photos"),
                (.smartAlbumPanoramas, "Panoramas"), (.smartAlbumScreenshots, "Screenshots"),
            ]
            for (subtype, name) in smart {
                if let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject,
                   PHAsset.fetchAssets(in: c, options: one).count > 0 {
                    out.append(AttachAlbum(id: c.localIdentifier, title: name, collection: c, isAllRecents: false))
                }
            }
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
                if PHAsset.fetchAssets(in: c, options: one).count > 0 {
                    out.append(AttachAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Album", collection: c, isAllRecents: false))
                }
            }
            let built = out
            await MainActor.run {
                albums = built
                RecentsCache.albums = built
            }
        }
    }

    // Tap routing (the checkbox owns selection, never conflicts):
    //   • Nothing selected → tap opens the SINGLE editor for that item (image editor / video trim editor).
    //   • Selection active → tap opens the MIXED approval pager over the whole selection (images AND
    //     videos together — swipe between all of them, edit each, one caption, one send).
    private func openTapped(_ a: PHAsset) {
        if selectedIds.isEmpty { pick(a) }
        else { openSelected() }
    }

    private func pick(_ a: PHAsset) {
        loadingPick = true
        Task {
            defer { Task { @MainActor in loadingPick = false } }
            if a.mediaType == .video {
                if let url = await Self.videoURL(a) { await MainActor.run { onPickVideo(url) } }
            } else if let ui = await Self.fullImage(a) {
                await MainActor.run { onPickPhoto(ui) }
            }
        }
    }

    // MARK: Multi-select

    // 1-based position of an asset in the current selection (nil = not selected). Photos AND videos.
    private func selectionIndex(_ a: PHAsset) -> Int? {
        guard let i = selectedIds.firstIndex(of: a.localIdentifier) else { return nil }
        return i + 1
    }

    private func toggle(_ a: PHAsset) {
        if let i = selectedIds.firstIndex(of: a.localIdentifier) {
            selectedIds.remove(at: i)
            selectedAssets.removeValue(forKey: a.localIdentifier)
        } else {
            // Cap at Limits.mediaPerMessage (32): warn instead of silently over-selecting.
            guard selectedIds.count < Limits.mediaPerMessage else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            selectedIds.append(a.localIdentifier)
            selectedAssets[a.localIdentifier] = a   // keep the asset itself — survives album switches
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // Tapping media while a selection is active → load EVERY selected item (images AND videos, in tap
    // order) and open the mixed approval pager (swipe all, per-item edit, one caption, one send).
    private func openSelected() {
        let ids = selectedIds
        let byId = resolveSelected(ids)   // global store, NOT the visible album (cross-album selection)
        loadingPick = true
        Task {
            var out: [ApprovalMedia] = []
            for id in ids {
                guard let a = byId[id] else { continue }
                if a.mediaType == .video {
                    if let url = await Self.videoURL(a) {
                        // Duration + a poster thumb for the pager rail.
                        let asset = AVURLAsset(url: url)
                        let dur = (try? await asset.load(.duration).seconds) ?? 0
                        let gen = AVAssetImageGenerator(asset: asset)
                        gen.appliesPreferredTrackTransform = true
                        gen.maximumSize = CGSize(width: 320, height: 320)
                        let thumb = (try? await gen.image(at: .zero).image).map { UIImage(cgImage: $0) }
                        out.append(.video(a.localIdentifier, url, thumb, dur))
                    }
                } else if let ui = await Self.fullImage(a) {
                    out.append(.image(a.localIdentifier, ui))
                }
            }
            await MainActor.run {
                loadingPick = false
                if out.isEmpty { return }
                // KEEP the selection (user spec): the pager/editor opens OVER this sheet, and X returns
                // here — clearing on open forced re-selecting everything after a preview round-trip.
                // A SEND from the pager closes the whole sheet, which resets this state naturally.
                onOpenMedia(out)
            }
        }
    }

    // Load every selected item (in tap order): photos go out as an album (or the editor for one), each
    // selected VIDEO is sent on its own (the album carries images only).
    // Resolve the selection from the GLOBAL store; any id somehow missing (e.g. state restored) is
    // re-fetched from the library by identifier, so no selected item is ever silently dropped.
    private func resolveSelected(_ ids: [String]) -> [String: PHAsset] {
        var byId = selectedAssets
        let missing = ids.filter { byId[$0] == nil }
        if !missing.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
                .enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }
        }
        return byId
    }

    private func sendSelected() {
        let ids = selectedIds
        let onceWanted = viewOnce && ids.count == 1
        let byId = resolveSelected(ids)   // global store, NOT the visible album (cross-album selection)
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)

        // CLOSE FIRST, RESOLVE AFTER — the reference app's model (user: "it must send direct, no loading in the
        // media sheet"). This used to raise a spinner over the sheet and decode EVERY selected asset at
        // full quality first — nine photos, possibly pulled from iCloud — and only THEN hand them over,
        // which is why the sheet sat there loading. Nothing about that work needs the sheet on screen:
        // the send is already optimistic, so the bubbles are the progress indicator. Selection state is
        // cleared and the sheet dismissed on this very tap; the decode continues in a task that is not
        // tied to this view's lifetime, and delivers when it is ready.
        selectedIds = []; selectedAssets = [:]; caption = ""; viewOnce = false; hasSelection = false
        onClose()

        // …but "close first" still left the conversation EMPTY for as long as the resolve took, because
        // the optimistic bubble was only posted once every asset had been pulled from PhotoKit at full
        // resolution, one at a time, and re-encoded. Nine photos, some of them in iCloud, is the ~5s the
        // user timed. The bubble does not need any of that: the grid it was just picked from is holding
        // decoded 300pt thumbnails already, which is exactly what an album bubble renders. So post the
        // bubble NOW from those, and let the real bytes catch up under it.
        //
        // Multi-item only. A single photo already paints immediately through its own send, and posting
        // here too would show it twice.
        let optimisticId: String? = ids.count > 1 ? UUID().uuidString : nil
        if let optimisticId {
            Task {
                var thumbs: [UIImage] = []
                var isVideo: [Bool] = []
                for id in ids {
                    guard let a = byId[id] else { continue }
                    if let t = await Self.gridThumb(a) { thumbs.append(t); isVideo.append(a.mediaType == .video) }
                }
                guard !thumbs.isEmpty else { return }
                onOptimisticGroup(thumbs, isVideo, cap, optimisticId)
            }
        }

        Task {
            // Build the ORDERED mixed list (selection order) so photos + videos ship as ONE group.
            var ordered: [ApprovalMedia] = []
            for id in ids {
                guard let a = byId[id] else { continue }
                if a.mediaType == .video {
                    if let url = await Self.videoURL(a) {
                        let asset = AVURLAsset(url: url)
                        let dur = (try? await asset.load(.duration).seconds) ?? 0
                        let gen = AVAssetImageGenerator(asset: asset)
                        gen.appliesPreferredTrackTransform = true
                        gen.maximumSize = CGSize(width: 640, height: 640)
                        let thumb = (try? await gen.image(at: .zero).image).map { UIImage(cgImage: $0) }
                        ordered.append(.video(a.localIdentifier, url, thumb, dur))
                    }
                } else if let ui = await Self.fullImage(a) {
                    ordered.append(.image(a.localIdentifier, ui))
                }
            }
            await MainActor.run {
                guard !ordered.isEmpty else {
                    if let optimisticId { onOptimisticFailed(optimisticId) }
                    return
                }
                // A single view-once photo keeps its dedicated view-once send (view-once can't be an album).
                if onceWanted, ordered.count == 1, case .image(_, let ui) = ordered[0] {
                    onSendAlbum([ui], cap, true); return
                }
                onSendMixed(ordered, cap, optimisticId)   // ONE group (grouping handled downstream; single item fast-paths)
            }
        }
    }

    // The SAME thumbnail the grid tile is already showing — same manager, same params, so a picked
    // photo is a cache hit and returns in microseconds. This is what the instant album bubble renders.
    private static func gridThumb(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            var resumed = false
            RecentsCache.thumbs.requestImage(for: asset, targetSize: RecentsCache.thumbSize,
                                             contentMode: .aspectFill,
                                             options: RecentsCache.thumbOptions) { img, _ in
                // `.opportunistic` can call back twice (fast then sharp); the continuation takes one.
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
    }

    // Full-quality photo bytes (may pull from iCloud — network allowed).
    private static func fullImage(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat   // single callback
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in
                cont.resume(returning: data.flatMap(UIImage.init(data:)))
            }
        }
    }

    // Copy the picked video to a temp file the transcoder can read after the request ends.
    private static func videoURL(_ asset: PHAsset) async -> URL? {
        await withCheckedContinuation { cont in
            let o = PHVideoRequestOptions()
            o.deliveryMode = .mediumQualityFormat
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, _ in
                guard let urlAsset = av as? AVURLAsset else { cont.resume(returning: nil); return }
                let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: urlAsset.url, to: dest)
                    cont.resume(returning: dest)
                } catch { cont.resume(returning: nil) }
            }
        }
    }
}

// One album row's model. `collection == nil` (isAllRecents) = the whole library ("Recents").
struct AttachAlbum: Identifiable {
    let id: String
    let title: String
    let collection: PHAssetCollection?
    let isAllRecents: Bool
}

// Album cover thumbnail (newest asset in the album / library).
private struct AlbumThumb: View {
    let collection: PHAssetCollection?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(Color.secondary.opacity(0.12)) }
        }
        // 60, up from 52 — see the row's own note. The cover is what sets the row's height, so this
        // is the number that makes the list read at the reference's scale rather than zoomed out.
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task {
            let f = PHFetchOptions()
            f.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            f.fetchLimit = 1
            let asset = collection.map { PHAsset.fetchAssets(in: $0, options: f).firstObject } ?? PHAsset.fetchAssets(with: f).firstObject
            guard let a = asset else { return }
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 150, height: 150),
                                                  contentMode: .aspectFill, options: o) { img, _ in if let img { image = img } }
        }
    }
}

// One thumbnail cell; videos wear a length chip. Flexible size: it fills its grid column as a
// square (Color.clear.aspectRatio keeps it 1:1 whatever the column width).
private struct RecentThumb: View {
    let asset: PHAsset
    var selectionNumber: Int? = nil
    let onOpen: () -> Void      // tap the PHOTO → open it
    let onToggle: () -> Void    // tap the CHECKBOX → (de)select
    @State private var image: UIImage?

    private var durationLabel: String {
        let d = Int(asset.duration.rounded())
        return String(format: "%d:%02d", d / 60, d % 60)
    }
    private var selected: Bool { selectionNumber != nil }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {   // hairline so light thumbs don't dissolve into the sheet
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(selected ? Color(hex: 0x3DA1FD) : Color.primary.opacity(0.06),
                            lineWidth: selected ? 3 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "video.fill").font(.system(size: 9))
                        Text(durationLabel).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            // Tapping the PHOTO opens it (separate from the checkbox below).
            .onTapGesture { onOpen() }
            // Always-visible selection checkbox (top-trailing): tap to (de)select — its own hit area.
            .overlay(alignment: .topTrailing) {
                Button(action: onToggle) {
                    ZStack {
                        Circle().fill(selected ? Color(hex: 0x3DA1FD) : Color.black.opacity(0.35))
                            .frame(width: 26, height: 26)
                        Circle().stroke(.white, lineWidth: 1.5).frame(width: 26, height: 26)
                        if let n = selectionNumber {
                            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    // Big invisible hit area (whole top-trailing corner, ~52pt square incl. corners) —
                    // the visible circle stays 26pt. The 40pt Circle contentShape was too small to grab.
                    .frame(width: 52, height: 52, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .task(id: asset.localIdentifier) {
            // Request through the CACHING manager with the exact precache params: pre-warmed thumbs
            // return instantly (the "images coming late" fix); anything not warmed loads as before.
            RecentsCache.thumbs.requestImage(for: asset,
                                             targetSize: RecentsCache.thumbSize,
                                             contentMode: .aspectFill, options: RecentsCache.thumbOptions) { img, _ in
                if let img { image = img }
            }
        }
    }
}

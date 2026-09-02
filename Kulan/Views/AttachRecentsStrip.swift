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

    /// ⛔ THE LIBRARY TELLS US, WE DO NOT FIND OUT ON OPEN — owner, 2026-09-02: "when I close, take a
    /// new photo, then open, it refreshes AFTER opening; it must be ready when I open".
    ///
    /// ⚠️ THE BUG WAS THE FIRST WORD OF `prewarm`'s GUARD. `assets.isEmpty` made this a once-per-
    /// process warm: the chat opened, the first page landed, and from then on nothing ever asked the
    /// library again. Every later open showed that first page and then let `load()` replace it a
    /// beat later, which is exactly the "refreshing after opening" he is describing — the sheet was
    /// not slow, it was showing a stale answer while it fetched the real one.
    ///
    /// A change observer is the fix rather than a shorter cache life or a fetch on tap. PhotoKit
    /// already knows the moment a screenshot or a camera roll write happens and will say so; asking
    /// on every open would be work done at the one moment there is no time for it, and asking on a
    /// timer would be both later and more often than needed.
    /// ⚠️ `nonisolated` ON THE CALLBACK, and it is not optional. This class is nested inside a
    /// `@MainActor` enum, so it inherits that isolation, while `photoLibraryDidChange` is a
    /// nonisolated protocol requirement — a main-actor method cannot satisfy one, and the compiler
    /// says so. It is also simply true: PhotoKit calls this on its own queue.
    private final class LibraryWatcher: NSObject, PHPhotoLibraryChangeObserver {
        nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
            // Everything this cache holds is main-actor, so the hop is the first thing that happens.
            Task { @MainActor in RecentsCache.refresh() }
        }
    }
    private static let watcher = LibraryWatcher()
    private static var watching = false
    /// A change that arrived while a warm was already running. Without this the newest photo of a
    /// burst can be the one that gets dropped: the change fires, `refresh` sees `warming` and
    /// returns, and nothing asks again.
    private static var refreshPending = false

    /// Start listening. Safe to call repeatedly and before access is granted — it does nothing until
    /// there is a library to watch, and the next call gets it.
    static func startWatching() {
        guard !watching else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        watching = true
        PHPhotoLibrary.shared().register(watcher)
    }

    static func prewarm() {
        guard assets.isEmpty else { return }
        refresh()
    }

    /// Re-read the first page whether or not one is already cached. `prewarm` is this with a
    /// "only if we have nothing" gate in front of it.
    static func refresh() {
        startWatching()
        guard !warming else { refreshPending = true; return }
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
                // A change landed while this was in flight — go again, or the shot that arrived
                // mid-warm is the one the sheet will be missing.
                if RecentsCache.refreshPending {
                    RecentsCache.refreshPending = false
                    RecentsCache.refresh()
                }
            }
        }
    }
}

// Standard recents strip for the attach panel: the newest camera-roll
// photos + videos, one tap to send. Asks for read access on first use; with Limited
// access it simply shows whatever the user granted. Photos open the chat editor
// (crop/caption); videos go straight into the send pipeline.
struct AttachRecentsStrip: View {
    /// Dismiss the sheet. The ✕ that used to call this is gone (owner, 2026-09-02: no header, swipe
    /// down to close) — SEND still calls it, which is the one place the sheet closes itself.
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
    /// ⛔ OWNER, 2026-09-02: THE ALBUM DOOR MOVED OUT OF THIS VIEW. It was the "Recents ▾" title in
    /// a header that no longer exists; it is the round button at the bottom right of the sheet now,
    /// which the PARENT draws beside the attach bar so the two read as one row. The flag has to be a
    /// binding rather than this view's own state, because the button that opens the list and the
    /// list itself are in two different views and must agree.
    ///
    /// ⚠️ DECLARED LAST OF THE EXTERNAL INPUTS ON PURPOSE. Swift matches the memberwise init by
    /// position as well as by name, and the call site already relies on that for `removedIds` — the
    /// note there says so. A new input goes at the end or it silently reorders the existing ones.
    @Binding var showAlbums: Bool
    /// True while a specific album (not Recents) fills the grid — his report off build 725: "when
    /// i click in album like favorite the arrow is going to hide". The parent's round button needs
    /// to keep showing the back arrow INSIDE an album, not only while the list is up, and it
    /// cannot see `selectedAlbum` because that is this view's own state. The strip WRITES this
    /// when an album is chosen; the parent WRITES IT FALSE to mean "take me back to Recents", and
    /// the `.onChange` in `body` is what honours that.
    ///
    /// ⚠️ Declared after `showAlbums`, still last of the external inputs — the memberwise-init
    /// position rule, third time now.
    @Binding var inAlbum: Bool
    @FocusState private var captionFocused: Bool
    /// The KEYBOARD's state, which is not the same thing as `captionFocused`. The composer moved off
    /// its focus flag for exactly this reason — focus flips a beat before the keys move, and on one
    /// of his two phones it flipped without them moving at all.
    @StateObject private var keyboard = KeyboardWatcher()

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
    /// Still local. Nothing outside shows the album's name any more (the header that did is gone),
    /// but the picker still needs to know which album it is in — `load()` reads it and the list
    /// writes it.
    @State private var albumTitle = "Recents"
    @State private var selectedAlbum: PHAssetCollection?   // nil = the newest across the whole library
    @State private var albums: [AttachAlbum] = []

    /// ⛔ **THE GRID IS EDGE TO EDGE — owner, 2026-09-02: "now images Is Runded cornders and Laft and
    /// right has space… make it exactly like image no space".**
    ///
    /// 2pt between tiles, nothing at the sides, and the tiles themselves are square. The 6pt gutters
    /// and 12pt side margins that were here made the grid read as a row of cards laid on a sheet;
    /// he wants one continuous sheet of photographs.
    ///
    /// ⚠️ **THE ROUNDED CORNERS HE STILL WANTS ARE THE SHEET'S, NOT THE TILES'.** In the picture he
    /// matched against, only the top-left and top-right of the whole grid are curved, and that is
    /// the presentation's own corner radius clipping the content — there is no radius on any tile.
    /// So the tiles go to 0 and the curve comes for free, which is also why the grid must reach the
    /// edges: inset by 12 there is nothing for the sheet's corner to cut.
    private static let tileGap: CGFloat = 2
    private let cols = Array(repeating: GridItem(.flexible(), spacing: AttachRecentsStrip.tileGap), count: 3)   // 3 per row (user request)

    var body: some View {
        Group {
            if showAlbums { albumsList } else { grid }
        }
        // ⛔ THE HEADER IS GONE — OWNER, 2026-09-02, with a screenshot: "Photo sheet no header".
        //
        // What went with it: the ✕, the "Recents ▾" title, and the selected-count circle. The way
        // into Albums is the round button at the bottom right now; the way out of the sheet is a
        // swipe down, which the system sheet has always done and which was the second half of his
        // instruction. The count is the only thing with no new home — the numbered ticks on the
        // photos themselves are what is left of it, and he has the screenshot he asked to match.
        //
        // ⚠️ The long comment that used to sit here argued overlay-versus-inset for the header, and
        // both halves of that argument are now moot. What survives it is the conclusion the grid
        // still depends on: this grid runs to the sheet's very top edge and paints nothing above
        // itself. That is why the content margin below went to zero rather than to a smaller number.
        // ≥1 selected → a caption + Send bar as a native bottom inset bar, so iOS pins it directly above
        // the keyboard (no home-indicator gap between the bar and the keyboard) and above the home
        // indicator when the keyboard is down — exactly like a composer.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selectedIds.isEmpty { captionBar }
        }
        .overlay { if loadingPick { ProgressView().tint(.secondary) } }
        .task {
            guard status == .authorized || status == .limited else { return }
            // Access may have been granted since the chat opened, in which case nothing has
            // registered yet. Idempotent — see `RecentsCache.startWatching`.
            RecentsCache.startWatching()
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
        .onChange(of: inAlbum) { _, now in exitAlbumIfNeeded(now) }
        .onChange(of: removedIds) { _, gone in
            guard !gone.isEmpty else { return }
            selectedIds.removeAll { gone.contains($0) }
            for id in gone { selectedAssets.removeValue(forKey: id) }
        }
    }

    // Caption + Send bar shown while items are selected (replaces the source row).
    // ⚠️ The selected COUNT used to be a circle at the header's top right. The header is gone
    // (owner, 2026-09-02) and the count did NOT move onto the send button — the numbered ticks on
    // the photos themselves are the only count now. That is what his screenshot shows.
    private var captionBar: some View {
        HStack(alignment: .bottom, spacing: 10) {   // send hugs the bottom as the caption grows
            HStack(alignment: .bottom, spacing: 8) {
                // View-once media can't carry a caption, so the field is disabled + the
                // prompt says why when View Once is on.
                TextField("", text: $caption,
                          prompt: Text(viewOnce ? "No caption for View Once" : "Add a caption…")
                            .foregroundColor(Color(.systemGray)),
                          axis: .vertical)
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
            .padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 40)
            // ⛔ GLASS ON EVERY OS — owner, 2026-08-25, same call as the attach bar above it. See
            // that one for why the ported blur went, and for the commits it lives in.
            .liquidGlass(RoundedRectangle(cornerRadius: 23, style: .continuous), interactive: true)   // real native Liquid Glass
            Button { sendSelected() } label: {
                // Match the main composer send: WHITE arrow on a blue-tinted glass circle (was a blue
                // arrow on clear glass, which read as a different, washed-out button).
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)   // 40px send (user spec)
                    .liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        // ⛔ THE COMPOSER'S BOTTOM, NOT A FLAT 4 — owner, 2026-08-25. Sides, top, height and corners
        // are untouched: he asked for the bottom padding behaviour and said twice not to change the
        // bar's size. At rest this dips into the indicator band exactly as the composer does; with
        // the keyboard up it keeps the composer's 8pt gap above the keys.
        .padding(.horizontal, 16).padding(.top, 8)
        .systemBarBottomChrome(keyboardUp: keyboard.height > 0)
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
            LazyVGrid(columns: cols, spacing: Self.tileGap) {
                // ⛔ NO CAMERA TILE — owner, 2026-09-02. Camera is a tile INSIDE the attach bar now,
                // beside GIF, Files and Location, and one action does not get two doors on one
                // screen. The grid is photos and nothing else, which is what makes the first row
                // start flush at the top edge.
                switch status {
                case .authorized, .limited:
                    ForEach(assets, id: \.localIdentifier) { a in
                        // Tap the PHOTO → single editor when nothing is selected; if a selection is active,
                        // open the multi-image approval (paging) of the selected set instead. Tap the
                        // CHECKBOX → (de)select. Separate, never conflict.
                        RecentThumb(asset: a, selectionNumber: selectionIndex(a),
                                    // Always — see `RecentThumb.selectionActive`. He could not find
                                    // the checkbox when it only appeared after the first tick.
                                    selectionActive: true,
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
            // ⛔ NO SIDE MARGIN AND NO TOP GAP — see `tileGap`. The photographs reach all four
            // edges of the sheet; the only curve is the one the presentation cuts for itself.
        }
        // ⛔ NO TOP MARGIN — owner, 2026-09-02. It existed to hold the first row clear of an opaque
        // header, and there is no header. The photos begin at the sheet's own top edge, which is the
        // whole of what "no header" looks like; the system drag indicator floats over them, exactly
        // as it does in the screenshot he sent.
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
        // ⛔ 16pt OF TOP MARGIN, AND THE GRID KEEPS NONE — owner, 2026-09-02, build 725 on his
        // phone, corner ringed in red: "sheet angle and album, there's no space".
        //
        // My previous pass took the top space off BOTH doors of this sheet so they would start in
        // the same place, and that was right for one door and wrong for the other. The photo grid
        // is full-bleed pictures: the sheet's corner cuts into an image and it reads as designed.
        // This list is a THUMBNAIL AND A TITLE: the corner cuts into a 60pt rounded rect and the
        // grabber sits on the row's text, and it reads as broken — which is what he ringed.
        //
        // 16 plus the row's own 11 puts the first thumbnail ~27pt down: clear of the grabber,
        // clear of the corner curve, and visibly a list that starts rather than one that leaks
        // out of the top.
        .contentMargins(.top, 16, for: .scrollContent)
    }

    private func selectAlbum(_ album: AttachAlbum) {
        selectedAlbum = album.isAllRecents ? nil : album.collection
        albumTitle = album.title
        // Tells the parent's round button to stay a back arrow while a real album fills the grid.
        inAlbum = selectedAlbum != nil
        withAnimation(.snappy(duration: 0.25)) { showAlbums = false }
        load()
    }

    /// The parent lowering `inAlbum` MEANS "back to Recents" — the round button's arrow tap. The
    /// reset lives here because `selectedAlbum` and `load()` are this view's own; the parent only
    /// speaks through the binding. Guarded so the strip's own write in `selectAlbum` (false, for
    /// Recents, with `selectedAlbum` already nil) does not re-run a load that just ran.
    private func exitAlbumIfNeeded(_ nowInAlbum: Bool) {
        guard !nowInAlbum, selectedAlbum != nil else { return }
        selectedAlbum = nil
        albumTitle = "Recents"
        load()
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
    /// ⛔ THE CIRCLES ARE BACK ON FROM THE FIRST FRAME — owner, 2026-09-02: "please show the select
    /// checkbox, users can't understand this, show it like before". He asked for the opposite
    /// earlier the same day, off build 725, and hiding them did read cleaner — but a control that is
    /// invisible until you have already used it teaches nobody it exists, and picking a SECOND photo
    /// is the thing the grid is for. His first call was about how it looked; this one is about
    /// whether it works, and that wins.
    ///
    /// Kept as a parameter rather than deleted: the hit area, the numbering and the circle were
    /// always three separate things, and this is the one switch between them.
    var selectionActive: Bool = true
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
            // ⛔ SQUARE — owner, 2026-09-02. The 24pt radius is what made these read as cards; the
            // only curve on this screen belongs to the sheet. `clipShape` stays because the picture
            // is `scaledToFill` and still has to be cut to the cell.
            .clipShape(Rectangle())
            // ⛔ NO BLUE BORDER ON A SELECTED TILE — owner, 2026-09-02, off build 725, ringed in
            // red: "when i selected image the blue square remove plz around images". The earlier
            // square-tiles pass kept the stroke on the theory that it was the only thing saying
            // which pictures you are about to send; it is not — the numbered blue badge says it,
            // and on a 2pt-gap grid a 3pt stroke bled into the neighbouring photos. The badge is
            // the whole selected state now. (The unselected hairline went in that same pass.)
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
            // Square, like the tile — the 24pt rounded contentShape was a leftover from the
            // rounded-card era and was quietly clipping the corners out of the tap area.
            .contentShape(Rectangle())
            // Tapping the PHOTO opens it (separate from the checkbox below).
            .onTapGesture { onOpen() }
            // The selection corner: its HIT AREA is always live, its CIRCLE only draws while a
            // selection is active (see `selectionActive`). Hiding the chrome must not hide the
            // door — the first tick is made by tapping the same corner it has always been in, and
            // the moment it lands every tile's circle appears.
            .overlay(alignment: .topTrailing) {
                Button(action: onToggle) {
                    ZStack {
                        if selectionActive || selected {
                            // ⛔ THE EMPTY STATE IS AN EMPTY CIRCLE — owner, 2026-09-02: "the select
                            // checkbox is using grey, remove that grey, make it only a circle, not
                            // grey inside the circle".
                            //
                            // ⚠️ THE GREY WAS DOING A JOB AND THE RING CAN DO IT INSTEAD. A 35%
                            // black disc was there so a white ring stayed visible on a pale
                            // photograph, and it also made every unticked tile carry a smudge. The
                            // ring keeps its own contrast now from a soft shadow — one drawn mark
                            // instead of a filled shape behind it, which is what the story card's
                            // name does over the same problem.
                            //
                            // Ticked still fills, and must: the blue disc IS the "chosen" signal,
                            // and it is the only thing distinguishing a numbered tile from an
                            // empty one at a glance.
                            if selected {
                                Circle().fill(Color(hex: 0x3DA1FD)).frame(width: 26, height: 26)
                            }
                            Circle().stroke(.white, lineWidth: 1.5).frame(width: 26, height: 26)
                                .shadow(color: .black.opacity(selected ? 0 : 0.45), radius: 2, y: 0.5)
                        }
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

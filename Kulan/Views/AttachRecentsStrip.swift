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
    /// ⛔ THE THUMBNAILS THIS SHEET HAS ALREADY DRAWN, kept in memory by asset id — owner, 2026-09-29,
    /// pulling the full sheet down: rows of the grid went blank-white and filled in again. Resizing the
    /// sheet makes SwiftUI rebuild the grid's cells, and a rebuilt `RecentThumb` starts with no image
    /// and waits for the caching manager's callback (asynchronous even on a hit). A tile now draws
    /// from here on its first frame; the callback still refreshes it.
    // `nonisolated(unsafe)`: written from the Photos callback. NSCache is thread-safe on its own.
    nonisolated(unsafe) static let drawn: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.countLimit = 400; return c
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
    /// The photo, and the PHAsset id of the tile it was tapped on: the editor flies out of that tile
    /// and back into it (`MediaOpenRects.Scope.attach`).
    /// TAP a photo: the picture to start the flight on, the asset id, and the loader that hands over
    /// the sharper picture and then the full-resolution photo as they arrive (see `pick`).
    var onPickPhoto: (UIImage, String, AttachPhotoLoad) -> Void
    /// TAP a video: the poster to start the flight on (nil when none could be read), the asset id,
    /// and the loader that hands over the sharper poster, the playable file and our copy (see `pick`).
    var onPickVideo: (UIImage?, String, AttachVideoLoad) -> Void
    var onSendVideos: ([URL], String) -> Void = { _, _ in }     // SELECT + Send → send videos directly
    var onSendAlbum: ([UIImage], String, Bool) -> Void = { _, _, _ in }   // images, caption, viewOnce
    var onSendMixed: ([ApprovalMedia], String, String?) -> Void = { _, _, _ in }   // items, caption, clientId of the already-posted bubble
    /// Posted the instant Send is tapped, from the grid's already-decoded thumbnails: grid images,
    /// which are videos, caption, clientId. The real send reuses that clientId.
    var onOptimisticGroup: ([UIImage], [Bool], String, String) -> Void = { _, _, _, _ in }
    var onOptimisticFailed: (String) -> Void = { _ in }   // nothing resolved → don't strand the bubble
    var onOpenMedia: ([ApprovalMedia], String?) -> Void = { _, _ in }   // tapping media WHILE selecting → the mixed approval pager (+ the tapped asset id)
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
    /// ⛔ The next page swap happens WITHOUT the slide — owner, 2026-09-29, twice: "from Recents,
    /// Album opens with no animation; a folder and Back keep the slide". The parent raises it for
    /// Album-from-Recents; a folder tap (`selectAlbum`) and the parent's Back lower it. A disabling
    /// transaction (build 806) did not reach `.animation(_:value:)`, so the value itself decides.
    /// Last of the external inputs, the memberwise-init position rule.
    @Binding var albumsInstant: Bool
    /// The grid has been scrolled by at least a row (or back above it). Declared last: see the
    /// note on `removedIds` at the call site, the arguments are matched by position too.
    var onScrolledARow: (Bool) -> Void = { _ in }
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
    /// ["folder"] while an album is pushed over the album list, [] otherwise.
    @State private var folderPath: [String] = []
    /// The bottom inset handed to `FolderNavHost`, written only when it changes (see `body`).
    @State private var navBottomInset: CGFloat = 0
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
        // ⛔ A PAGE SLIDE, SCOPED TO THE PAGES — owner, 2026-09-29: "when I tap a folder there is no
        // animation, make it slide in from the right", and in the same message the bar and the
        // Album button vanishing on Album/Back and flickering on an album tap. Both taps flipped
        // these flags inside `withAnimation`, a transaction that reached every view that changed,
        // including the bar's and the round button's glass, which re-materialised late (and the
        // two pages only cross-faded). The animation lives HERE now, on the swap alone: an album
        // comes in from the right over the list, going back returns it to the right. The bar and
        // the button are drawn outside this view (ThreadView's overlay) and see no animation.
        // Each page is opaque so the two never show through each other mid-slide.
        // ⛔ EACH PAGE HAS A FIXED PLACE IN THE STACK — owner, 2026-09-30: "the album list disappears
        // at once, then the album slides in over an empty frame". A ZStack child with no explicit
        // `zIndex` loses its place the moment it is removed, so its removal transition never draws:
        // the leaving page was gone on the first frame and only the arriving one moved. With the
        // order pinned, the list leaves to the left WHILE the album arrives from the right, and
        // Back runs the same pair in reverse.
        // The root page (Recents grid or the album list) in a navigation controller with no visible
        // bar, so a folder can be PUSHED over the list and left with the system's back swipe
        // (owner, 2026-10-04). See `selectAlbum`.
        //
        // ⛔ OUR OWN UIKit NAVIGATION CONTROLLER, NOT A SwiftUI NavigationStack — builds 826 and 827
        // crashed on "+" (owner, 2026-10-06, two crash logs, SIGTRAP in SwiftUI's
        // `NavigationColumnState.boundPathChange`). The sheet sits inside the chat, which is inside
        // the chat list's NavigationStack, and a NavigationStack inside another one is not
        // supported: SwiftUI joined this `[String]` path to the outer stack's `NavigationPath` and
        // trapped when the two types met. `FolderNavHost` is a plain UINavigationController that
        // SwiftUI's navigation never sees, with the same pushed page and the same system back swipe.
        // ⛔ TO THE SHEET'S BOTTOM EDGE — owner, 2026-10-06, two screenshots (Recents and a folder):
        // a black / white band under the bar. A UIKit controller hosted in SwiftUI is sized to the
        // SAFE AREA, so both pages stopped above the home indicator and the sheet's own background
        // showed below. The host now runs to the edge (`ignoresSafeArea(.bottom)`) and is told the
        // bottom inset the SwiftUI side had (bar + caption bar + home indicator) as a safe-area
        // inset, so the grid's scroll view still clears the bar while its pictures scroll under it
        // to the very edge, as they did before the folder page became a UIKit push.
        // ⛔ THE SHEET'S MOVE DOES NOT REBUILD THE GRID — owner 2026-10-17: swiping the sheet from
        // half to full lagged; the reference app's does not. The host sat INSIDE a GeometryReader,
        // and the sheet changes size on every frame of a drag or snap, so every frame re-ran this
        // closure and handed `FolderNavHost` two fresh AnyViews: both hosted pages re-diffed the whole
        // grid (every loaded asset) 60-120 times a second. The reader now sits behind the host and
        // only writes the one number it is for, when that number changes; the host itself no longer
        // depends on the size, so a resize is a plain layout pass.
        FolderNavHost(
            root: AnyView(rootPage),
            folder: AnyView(grid.background(Color(uiColor: .systemBackground))),
            showFolder: !folderPath.isEmpty,
            bottomInset: navBottomInset,
            onPopped: { folderPath = [] }
        )
        .ignoresSafeArea(.container, edges: .bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geo in
                Color.clear.onChange(of: geo.safeAreaInsets.bottom, initial: true) { _, v in
                    if navBottomInset != v { navBottomInset = v }
                }
            }
        }
        // The folder page left by the system swipe: the round button must stop being a Back arrow.
        .onChange(of: folderPath) { _, path in
            if path.isEmpty, inAlbum { inAlbum = false }
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
            // Owner, 2026-10-10: "make it automatic when user clicks +". Never asked yet = ask now,
            // as the sheet opens, instead of waiting for a tap on an "Allow Photos" tile. A refusal
            // cannot be asked again (iOS shows its prompt once); that case keeps the Settings tile.
            if status == .notDetermined { request(); return }
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

    /// The root page under the folder: the Recents grid, or the album list over it (unchanged,
    /// lifted out of the old NavigationStack for `FolderNavHost`).
    private var rootPage: some View {
        ZStack {
            if showAlbums {
                albumsList
                    .background(Color(uiColor: .systemBackground))
                    .transition(.move(edge: .leading))
                    .zIndex(0)
            } else {
                grid
                    .background(Color(uiColor: .systemBackground))
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        // ⚠️ NO `.clipped()` — owner, 2026-09-29, build 803: a white band along the sheet's bottom.
        // A clip cuts at this view's frame, which stops at the safe area, and the grid is meant to
        // scroll on under the bar to the sheet's edge. The sheet's shell already clips the slide.
        .animation(albumsInstant ? nil : .snappy(duration: 0.3), value: showAlbums)
    }

    // Caption + Send bar shown while items are selected (replaces the source row).
    // ⚠️ The selected COUNT used to be a circle at the header's top right. The header is gone
    // (owner, 2026-09-02) and the count did NOT move onto the send button — the numbered ticks on
    // the photos themselves are the only count now. That is what his screenshot shows.
    // ⛔ THE REFERENCE APP'S NUMBERS (owner 2026-10-21: "sides too small, use exactly theirs"):
    // 28pt each side at rest, 16 with the keyboard up; ONE glass capsule, radius 20, min height 40,
    // the send a 40x34 blue pill INSIDE it, 3pt from its right/top/bottom. Same in half and full sheet.
    private var captionBar: some View {
        HStack(alignment: .bottom, spacing: 0) {   // send hugs the bottom as the caption grows
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
            Button { sendSelected() } label: {
                // White arrow on the blue pill, as the main composer send.
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 34)
                    .background(Capsule().fill(Theme.defaultBubble(false)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3).padding(.vertical, 3)
        }
        // ⛔ GLASS ON EVERY OS — owner, 2026-08-25. One capsule round field and send (reference).
        .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        // ⛔ THE COMPOSER'S BOTTOM, NOT A FLAT 4 — owner, 2026-08-25. At rest this dips into the
        // indicator band as the composer does; with the keyboard up it keeps the 8pt gap above the keys.
        .padding(.horizontal, keyboard.height > 0 ? 16 : 28).padding(.top, 8)
        .systemBarBottomChrome(keyboardUp: keyboard.height > 0)
        // Focusing the caption grows the sheet to .large so this bar pins above the keyboard instead of
        // the medium sheet shoving the whole content up (the caption "jumping" to mid-screen).
        .onChange(of: captionFocused) { _, focused in if focused { onCaptionFocused() } }
    }

    private var grid: some View {
        // ⛔ THE LIMITED-ACCESS ROW SITS ABOVE THE GRID, NOT IN IT — owner 2026-10-18, with the
        // reference app beside ours: our line was inside the scroll and the first row of photos was
        // drawn over it. Theirs is a fixed row of its own between the top and the photos: the sentence
        // on the left, a blue MANAGE capsule on the right that offers Select More Photos… and Change
        // Settings. The grid starts under it.
        VStack(spacing: 0) {
            if status == .limited { limitedRow }
            gridScroll
                // Owner 2026-10-14: the attach bar's close button appears once the sheet is full AND the
                // grid has been scrolled by at least a row. One row = a tile's side plus the gap.
                .onScrollGeometryChange(for: Bool.self) { g in
                    let side = (g.containerSize.width - 2 * Self.tileGap) / 3
                    return g.contentOffset.y + g.contentInsets.top >= side + Self.tileGap
                } action: { _, scrolled in onScrolledARow(scrolled) }
        }
    }

    private var limitedRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("You have limited Fariin from accessing your photos.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Menu {
                Button { presentLimitedPicker() } label: {
                    Label("Select More Photos…", systemImage: "photo.badge.plus")
                }
                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                } label: {
                    Label("Change Settings", systemImage: "gearshape")
                }
            } label: {
                Text("MANAGE")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Color(hex: 0x0A84FF), in: Capsule())
            }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .padding(.top, 24).padding(.bottom, 12)
    }

    private var gridScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
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
        // The region a tile may be drawn in while the editor flies out of it or back into it.
        .background { MediaViewAnchor(key: MediaOpenRects.attachGridKey) }
        // Scrolling the photos puts the caption keyboard away (owner 2026-10-21, as the reference
        // app's attach sheet does); the caption keeps its words.
        .scrollDismissesKeyboard(.immediately)
        // ⛔ NO TOP MARGIN — owner, 2026-09-02. It existed to hold the first row clear of an opaque
        // header, and there is no header. The photos begin at the sheet's own top edge, which is the
        // whole of what "no header" looks like; the system drag indicator floats over them, exactly
        // as it does in the screenshot he sent.
    }

    // Native-style album list (Recents, Favorites, Videos, Selfies, Live Photos, Panoramas, user albums).
    private var albumsList: some View {
        albumsScroll
            .scrollDismissesKeyboard(.immediately)
            // Owner 2026-10-14: the close button shows here too once the list has scrolled a row,
            // exactly as on the grid. One row of this list is about 66pt (52 thumbnail + 7 + 7).
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top >= 66
            } action: { _, scrolled in onScrolledARow(scrolled) }
    }

    private var albumsScroll: some View {
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
        albumsInstant = false
        if selectedAlbum != nil {
            // ⛔ A FOLDER IS A PUSHED PAGE — owner, 2026-10-04 on 825: "don't use a custom swipe, use
            // the native Apple swipe". The list stays the root page and the folder is pushed over it,
            // so the system's own back swipe follows the finger, locks the vertical scroll while it
            // runs, and shows the list underneath (the custom offset showed black there).
            load()
            folderPath = ["folder"]
        } else {
            showAlbums = false   // Recents is the root grid itself, not a page
            load()
        }
    }

    /// The parent lowering `inAlbum` MEANS "back to Recents" — the round button's arrow tap. The
    /// reset lives here because `selectedAlbum` and `load()` are this view's own; the parent only
    /// speaks through the binding. Guarded so the strip's own write in `selectAlbum` (false, for
    /// Recents, with `selectedAlbum` already nil) does not re-run a load that just ran.
    private func exitAlbumIfNeeded(_ nowInAlbum: Bool) {
        guard !nowInAlbum, selectedAlbum != nil else { return }
        // The round button's Back while the folder page is up: pop it the system way, and swap the
        // grid's photos back to Recents only once the page has left, so they never change under it.
        let popping = !folderPath.isEmpty
        if popping { folderPath = [] }
        DispatchQueue.main.asyncAfter(deadline: .now() + (popping ? 0.45 : 0)) {
            guard !inAlbum else { return }   // another folder was opened meanwhile
            selectedAlbum = nil
            albumTitle = "Recents"
            load()
        }
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
                if s == .authorized || s == .limited { RecentsCache.startWatching(); load(); loadAlbums() }
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
        let album = selectedAlbum
        let isRecents = album == nil
        let page = pageSize
        Task.detached(priority: .userInitiated) {
            // ⛔ THE QUERY ITSELF OFF THE MAIN THREAD — owner 2026-10-14: "after a relaunch the
            // pictures take seconds to appear". Cold after a launch, Photos' first sorted query of
            // a big library is a good part of a second, and it ran here on main, at the sheet's
            // open, holding the open and every tile behind it. The recents are also warmed before
            // the sheet is ever opened now (`RecentsCache.prewarm`, from the chat list and the chat).
            let res = album.map { PHAsset.fetchAssets(in: $0, options: f) } ?? PHAsset.fetchAssets(with: f)
            let end = min(page, res.count)
            var out: [PHAsset] = []
            if end > 0 {
                out.reserveCapacity(end)
                res.enumerateObjects(at: IndexSet(integersIn: 0..<end), options: []) { a, _, _ in out.append(a) }
            }
            let built = out
            await MainActor.run {
                fetchResult = res
                assets = built
                loadedCount = end
                if isRecents { RecentsCache.assets = built }
                RecentsCache.precache(Array(built.prefix(60)))
            }
        }
    }

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
        // OpenTrace (2026-10-15, measurement only): which tile, where in the grid, what it is.
        let idx = assets.firstIndex { $0.localIdentifier == a.localIdentifier } ?? -1
        OpenTrace.begin("col=\(idx >= 0 ? idx % 3 : -1) row=\(idx >= 0 ? idx / 3 : -1) idx=\(idx) "
                        + "type=\(a.mediaType == .video ? "video" : "photo") px=\(a.pixelWidth)x\(a.pixelHeight) "
                        + "selectedCount=\(selectedIds.count) id=\(a.localIdentifier.prefix(8))")
        // ⛔ A TAP OPENS WHAT WAS TAPPED — owner 2026-10-14: with photos selected, tapping one that
        // is NOT selected opened the selection instead. Only a selected tile opens the selection
        // pager; any other tile opens on its own, as with nothing selected.
        if selectedIds.isEmpty || !selectedIds.contains(a.localIdentifier) { pick(a) }
        else { openSelected(tapped: a.localIdentifier) }
    }

    private func pick(_ a: PHAsset) {
        loadingPick = true
        if a.mediaType == .video {
            // ⛔ SAME AS A PHOTO — owner 2026-10-14: the flight starts at once on the poster, and the
            // file follows. The reference picker's video item flies its poster, waits on nothing,
            // shows the poster in the gallery and builds no player until playback is asked for;
            // it never copies the file first. Ours copied the whole clip to a temp folder before
            // the flight began: seconds on a long one. Now the poster request starts the flight
            // (one sharp screen-size poster, as for photos), the library's own file is handed over the
            // moment it is known so the editor can play it, and our copy, for sending, is made
            // behind that.
            let load = AttachVideoLoad()
            let id = a.localIdentifier
            var started = false
            let start: (UIImage?) -> Void = { img in
                guard !started else { return }
                started = true
                loadingPick = false
                onPickVideo(img, id, load)
            }
            // ⛔ NO BLUR, EVER — owner 2026-10-14: "I don't want to see any blur". One sharp poster at
            // screen size; see `Self.sharpOpenOptions`.
            PHImageManager.default().requestImage(for: a, targetSize: Self.sharpOpenSize,
                                                  contentMode: .aspectFit, options: Self.sharpOpenOptions) { img, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                DispatchQueue.main.async {
                    guard let img else {
                        // No poster at all (an error, nothing cached): open plainly once the file is known.
                        if info?[PHImageErrorKey] != nil, load.playback != nil { start(nil) }
                        return
                    }
                    if !started { OpenTrace.note("start by=poster degraded=\(degraded) img=\(OpenTrace.s(img.size))") }
                    if !started { start(img) } else if !degraded { load.deliverScreen(img) }
                }
            }
            let vo = PHVideoRequestOptions()
            vo.deliveryMode = .mediumQualityFormat
            vo.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: a, options: vo) { av, _, _ in
                guard let urlAsset = av as? AVURLAsset else {
                    DispatchQueue.main.async { if !started { loadingPick = false } }
                    return
                }
                let src = urlAsset.url
                DispatchQueue.main.async { load.deliverPlayback(src) }
                // Our own copy, for the send: made behind the flight, never waited for to open.
                let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
                if (try? FileManager.default.copyItem(at: src, to: dest)) != nil {
                    DispatchQueue.main.async { load.deliverFile(dest) }
                }
            }
            return
        }
        // ⛔ THE FLIGHT STARTS AT ONCE, ON A ROUGH PICTURE — owner 2026-10-14: "the reference is fast,
        // mine is too slow". Six agents read the reference picker: its zoom starts in the tap's own
        // run loop, flying the grid's thumbnail, with a 1280pt aspect-fit picture arriving during
        // the flight (its item view's immediate thumbnail, then its 1280x1280 "screen" request,
        // opportunistic) and the full file later. Ours waited for the full-resolution bytes to
        // decode before the flight began: hundreds of milliseconds of nothing after the tap, and
        // THAT was the slowness, not the spring, whose numbers already match. Same recipe now.
        let load = AttachPhotoLoad()
        load.pixelSize = CGSize(width: a.pixelWidth, height: a.pixelHeight)
        let id = a.localIdentifier
        var started = false
        let start: (UIImage) -> Void = { img in
            guard !started else { return }
            started = true
            loadingPick = false
            onPickPhoto(img, id, load)
        }
        // ⛔ NO BLUR, EVER — owner 2026-10-14, "this is the last time I tell you": the photo opened
        // blurred for a second. The opportunistic request handed over a tiny degraded picture FIRST
        // and the flight started on it, and its "sharp" follow-up was only 1280px, below this
        // phone's 2796px screen. Now one high-quality picture at screen size starts the flight;
        // nothing rough is ever shown. See `Self.sharpOpenOptions`.
        PHImageManager.default().requestImage(for: a, targetSize: Self.sharpOpenSize,
                                              contentMode: .aspectFit, options: Self.sharpOpenOptions) { img, info in
            guard let img else { return }
            let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
            DispatchQueue.main.async {
                if !started { OpenTrace.note("start by=screen degraded=\(degraded) img=\(OpenTrace.s(img.size))") }
                else { OpenTrace.note("later screen degraded=\(degraded) img=\(OpenTrace.s(img.size))") }
                if !started { start(img) } else if !degraded { load.deliverScreen(img) }
            }
        }
        Task {
            let ui = await Self.fullImage(a)
            await MainActor.run {
                if let ui {
                    OpenTrace.note("\(started ? "full arrived" : "start by=full") img=\(OpenTrace.s(ui.size))")
                    start(ui); load.deliverFull(ui)
                }
                else if !started { loadingPick = false }   // nothing of it could be loaded at all
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
    private func openSelected(tapped: String? = nil) {
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
                onOpenMedia(out, tapped)
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

    /// The picture a tapped photo or video OPENS on. `.highQualityFormat` calls back once, with a
    /// sharp picture, never a degraded one first; 3000px on the long side covers every iPhone screen
    /// (the largest is 2868px), so it is never stretched. A photo stored on the phone decodes at this
    /// size in tens of milliseconds; one only in iCloud downloads first, with no rough preview.
    static let sharpOpenSize = CGSize(width: 3000, height: 3000)
    static let sharpOpenOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }()

    // Full-quality photo bytes (may pull from iCloud — network allowed).
    // (The tap no longer waits for this: see `pick`.)
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
                if let shown = image ?? RecentsCache.drawn.object(forKey: asset.localIdentifier as NSString) {
                    Image(uiImage: shown).resizable().scaledToFill()
                } else {
                    // A visible grey, not 12% of the label colour: on the light sheet that read as
                    // empty white (owner, 2026-09-29).
                    Rectangle().fill(Color(.systemGray5))
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
            // Reports the tile's window rect for the editor's fly-out and fly-home, and hides the
            // whole tile (circle too, as the reference app hides the cell) while the copy covers it.
            .modifier(MediaRectReporter(id: asset.localIdentifier, scope: .attach, cornerRadius: 0))
            .task(id: asset.localIdentifier) {
            // Request through the CACHING manager with the exact precache params: pre-warmed thumbs
            // return instantly (the "images coming late" fix); anything not warmed loads as before.
            RecentsCache.thumbs.requestImage(for: asset,
                                             targetSize: RecentsCache.thumbSize,
                                             contentMode: .aspectFill, options: RecentsCache.thumbOptions) { img, _ in
                if let img {
                    image = img
                    RecentsCache.drawn.setObject(img, forKey: asset.localIdentifier as NSString)
                }
            }
        }
    }
}

/// The attach sheet's folder page, pushed on a UIKit navigation controller of its own.
///
/// ⛔ NOT A SwiftUI NavigationStack (owner, 2026-10-06: builds 826 and 827 crashed on "+"). The sheet
/// lives inside the chat, inside the chat list's NavigationStack; a second NavigationStack in there
/// is joined to the outer one by SwiftUI, and its `[String]` path meeting the outer `NavigationPath`
/// trapped in `NavigationColumnState.boundPathChange`. A plain UINavigationController is invisible to
/// SwiftUI's navigation, and keeps what the 2026-10-04 change was for: the folder is a real pushed
/// page, the system back swipe follows the finger and shows the list underneath.
///
/// The old helper also re-pointed the back-swipe delegate of whatever navigation controller it found,
/// which inside the merged stack could be the CHAT's own. This one only ever touches its own.
struct FolderNavHost: UIViewControllerRepresentable {
    let root: AnyView
    let folder: AnyView
    let showFolder: Bool
    /// The bottom inset the SwiftUI side reserves (bar, caption bar, home indicator). The host runs
    /// to the edge and gives its pages this much safe area itself (see the call site).
    var bottomInset: CGFloat = 0
    let onPopped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The navigation controller that keeps its pages' bottom safe area equal to `wantedBottom`,
    /// re-checked on every layout (the home indicator is only known once it is in a window), and
    /// never adding what UIKit already supplies.
    final class EdgeNavigationController: UINavigationController {
        var wantedBottom: CGFloat = 0 { didSet { if wantedBottom != oldValue { view.setNeedsLayout() } } }
        override func viewWillLayoutSubviews() {
            super.viewWillLayoutSubviews()
            let system = max(0, view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom)
            let extra = max(0, wantedBottom - system)
            if abs(additionalSafeAreaInsets.bottom - extra) > 0.5 { additionalSafeAreaInsets.bottom = extra }
        }
    }

    func makeUIViewController(context: Context) -> EdgeNavigationController {
        let c = context.coordinator
        c.rootHost.rootView = root
        let nav = EdgeNavigationController(rootViewController: c.rootHost)
        nav.wantedBottom = bottomInset
        nav.setNavigationBarHidden(true, animated: false)
        nav.view.backgroundColor = .clear
        nav.delegate = c
        nav.interactivePopGestureRecognizer?.delegate = c
        nav.interactivePopGestureRecognizer?.isEnabled = true
        // ⛔ iOS 26's swipe back from ANYWHERE on the page, not only the left edge — owner,
        // 2026-10-06: "swipe sometimes works and sometimes does not". The edge swipe alone loses to
        // the photo grid's scroll when the finger lands a little in from the edge.
        nav.interactiveContentPopGestureRecognizer?.delegate = c
        nav.interactiveContentPopGestureRecognizer?.isEnabled = true
        c.nav = nav
        c.onPopped = onPopped
        if showFolder {
            c.folderHost.rootView = folder
            nav.pushViewController(c.folderHost, animated: false)
        }
        return nav
    }

    func updateUIViewController(_ nav: EdgeNavigationController, context: Context) {
        let c = context.coordinator
        c.onPopped = onPopped
        nav.wantedBottom = bottomInset
        c.rootHost.rootView = root
        c.folderHost.rootView = folder
        let pushed = nav.viewControllers.count > 1
        if showFolder, !pushed {
            nav.pushViewController(c.folderHost, animated: true)
        } else if !showFolder, pushed, nav.transitionCoordinator == nil {
            nav.popToRootViewController(animated: true)
        }
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
        let rootHost = UIHostingController(rootView: AnyView(EmptyView()))
        let folderHost = UIHostingController(rootView: AnyView(EmptyView()))
        weak var nav: UINavigationController?
        var onPopped: () -> Void = {}

        override init() {
            super.init()
            rootHost.view.backgroundColor = .clear
            folderHost.view.backgroundColor = .clear
        }

        /// The swipe begins only when there is a page to go back TO; on the root page it would
        /// freeze the controller.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (nav?.viewControllers.count ?? 0) > 1
        }

        /// The back swipe wins over the grid's scroll: a scroll view's pan waits for it to fail,
        /// which it does at once for a vertical drag, so scrolling is not slowed. Only while there is
        /// a page to go back to; on the root page nothing waits.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard (nav?.viewControllers.count ?? 0) > 1 else { return false }
            return other is UIPanGestureRecognizer && other.view is UIScrollView
        }

        /// Back on the root page by the system swipe (or any pop): tell the strip, which clears its
        /// path and turns the round button back from a Back arrow.
        func navigationController(_ nav: UINavigationController, didShow vc: UIViewController, animated: Bool) {
            if vc === rootHost { onPopped() }
        }
    }
}

/// What a tapped photo hands over while its pictures are still arriving. The flight starts on the
/// rough picture it was given; `onScreen` brings the sharper 1280pt one to the flying copy and the
/// editor; `onFull` brings the full-resolution photo to the editor. Either may already be here
/// when its handler is set, in which case the handler runs at once.
@MainActor final class AttachPhotoLoad {
    /// The photo's exact size from the library, so the flight lands on the rect the editor will lay
    /// the FULL photo out in. The rough preview's size can be a pixel off in aspect, and a landing
    /// sized from it re-fitted by a few points at the hand-over: the "small zoom back at the end"
    /// (owner 2026-10-14, build 918).
    var pixelSize: CGSize = .zero
    private(set) var screen: UIImage?
    private(set) var full: UIImage?
    var onScreen: ((UIImage) -> Void)? { didSet { if full == nil, let screen, let onScreen { onScreen(screen) } } }
    var onFull: ((UIImage) -> Void)? { didSet { if let full, let onFull { onFull(full) } } }
    /// Ignored once the full photo is here: a 1280pt picture arriving after it must not replace it.
    func deliverScreen(_ image: UIImage) {
        guard full == nil else { return }
        screen = image
        onScreen?(image)
    }
    func deliverFull(_ image: UIImage) { full = image; onFull?(image) }
}

/// What a tapped video hands over while its pieces are still arriving (see `pick`). The flight
/// starts on the poster it was given; `onScreen` brings the sharper poster; `onPlayback` brings the
/// library's own file, playable at once, so the editor can build its player; `onFile` brings our
/// copy, which Send prefers. Each may already be here when its handler is set, in which case the
/// handler runs at once.
@MainActor final class AttachVideoLoad {
    private(set) var screen: UIImage?
    private(set) var playback: URL?
    private(set) var file: URL?
    var onScreen: ((UIImage) -> Void)? { didSet { if let screen, let onScreen { onScreen(screen) } } }
    var onPlayback: ((URL) -> Void)? { didSet { if let playback, let onPlayback { onPlayback(playback) } } }
    var onFile: ((URL) -> Void)? { didSet { if let file, let onFile { onFile(file) } } }
    func deliverScreen(_ image: UIImage) { screen = image; onScreen?(image) }
    func deliverPlayback(_ url: URL) { playback = url; onPlayback?(url) }
    func deliverFile(_ url: URL) { file = url; onFile?(url) }
}

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
    static func prewarm() {
        guard assets.isEmpty, !warming else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        warming = true
        Task.detached(priority: .userInitiated) {
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
    var onCamera: () -> Void = {}
    var onClose: () -> Void = {}
    var onPickPhoto: (UIImage) -> Void
    var onPickVideo: (URL) -> Void                              // TAP a video → open the trim editor
    var onSendVideos: ([URL], String) -> Void = { _, _ in }     // SELECT + Send → send videos directly
    var onSendAlbum: ([UIImage], String, Bool) -> Void = { _, _, _ in }   // images, caption, viewOnce
    var onSendMixed: ([ApprovalMedia], String) -> Void = { _, _ in }   // SELECT + Send → ONE mixed group (ordered)
    var onOpenMedia: ([ApprovalMedia]) -> Void = { _ in }        // tapping media WHILE selecting → the mixed approval pager
    var onCaptionFocused: () -> Void = {}                        // caption field focused → parent grows the sheet to .large
    @Binding var hasSelection: Bool   // ≥1 selected → parent hides the source row (Photos/Files/…)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            if showAlbums { albumsList } else { grid }
        }
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
            if assets.isEmpty, selectedAlbum == nil, !RecentsCache.assets.isEmpty {
                assets = RecentsCache.assets
                albums = RecentsCache.albums
            }
            load(); loadAlbums()
        }
        .onChange(of: selectedIds.isEmpty) { _, empty in hasSelection = !empty }
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
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .liquidGlass(Circle(), interactive: true)
                }
                Spacer()
                // Selected count — BLUE Liquid Glass (user spec 2026-07-14 evening: "make blue, don't
                // remove liquid glass"): interactive glass WITH the bubble-blue tint + white number.
                if !selectedIds.isEmpty {
                    Text("\(selectedIds.count)")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // Caption + Send bar shown while items are selected (replaces the source row). The selected COUNT is
    // shown at the header top-right (not on the send button); the send button is real Liquid Glass.
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
                    Text("Only some photos are shared with Kulan.")
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
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 78)
                }
            }
        }
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
        let res = selectedAlbum.map { PHAsset.fetchAssets(in: $0, options: f) } ?? PHAsset.fetchAssets(with: f)
        fetchResult = res
        loadedCount = 0
        // Build the first page and swap it in ONE assignment — never blank `assets` to [] first (that
        // wiped the instantly-shown cache and flashed the grid empty on every open).
        let end = min(pageSize, res.count)
        var out: [PHAsset] = []
        out.reserveCapacity(end)
        if end > 0 {
            res.enumerateObjects(at: IndexSet(integersIn: 0..<end), options: []) { a, _, _ in out.append(a) }
        }
        assets = out
        loadedCount = end
        if selectedAlbum == nil { RecentsCache.assets = out }
        // Warm the new page's thumbnails (album switches included) so tiles never fill in late.
        RecentsCache.precache(Array(out.prefix(60)))
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
                        out.append(.video(UUID(), url, thumb, dur))
                    }
                } else if let ui = await Self.fullImage(a) {
                    out.append(.image(UUID(), ui))
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
        loadingPick = true
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
                        ordered.append(.video(UUID(), url, thumb, dur))
                    }
                } else if let ui = await Self.fullImage(a) {
                    ordered.append(.image(UUID(), ui))
                }
            }
            let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                loadingPick = false
                selectedIds = []; selectedAssets = [:]; caption = ""; viewOnce = false; hasSelection = false
                guard !ordered.isEmpty else { return }
                // A single view-once photo keeps its dedicated view-once send (view-once can't be an album).
                if onceWanted, ordered.count == 1, case .image(_, let ui) = ordered[0] {
                    onSendAlbum([ui], cap, true); return
                }
                onSendMixed(ordered, cap)   // ONE group (grouping handled downstream; single item fast-paths)
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
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

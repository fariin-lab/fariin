import SwiftUI

// ⛔ A CHAT'S STORAGE, ITEM BY ITEM (owner 2026-10-19: "yes please, and don't build a cheap thing").
// The group page's Storage row used to clear the re-downloadable cache in one go and show nothing.
// This page lays out everything of this chat that sits on this phone, biggest first, with its size
// on the tile; sort by Largest / Newest / Oldest; select some or all and delete them from this phone.
//
// ⚠️ DELETING HERE IS DELETE FOR ME, NOT A CACHE TRIM. Under the mailman model a delivered photo,
// video or voice note is ONLY on the phones (DiskImageCache `.own`, VideoCache, AudioCache), so its
// file cannot be dropped while the bubble stays: the bubble would point at nothing. The message is
// hidden on this phone (HiddenMessages, the chat's own Delete for Me) and its files go with it.
// Everyone else in the chat keeps theirs. The confirm says exactly that.
struct ChatStorageView: View {
    let cid: String
    let title: String
    let messages: [Message]
    /// Told when something was deleted, so the page underneath can measure again.
    var onChange: () -> Void = {}

    enum Sort: String, CaseIterable { case largest = "Largest", newest = "Newest", oldest = "Oldest" }

    struct Item: Identifiable {
        enum Kind { case photo, video, album, voice, file, gif }
        let id: String
        let message: Message
        let kind: Kind
        let bytes: Int
        var date: Date { message.createdAt }
    }

    @State private var items: [Item] = []
    @State private var loaded = false
    @State private var sort: Sort = .largest
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var confirmDelete = false
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?

    private var sorted: [Item] {
        switch sort {
        case .largest: return items.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.date > $1.date }
        case .newest:  return items.sorted { $0.date > $1.date }
        case .oldest:  return items.sorted { $0.date < $1.date }
        }
    }
    private var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }
    private var selectedBytes: Int { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    private var allSelected: Bool { !items.isEmpty && selected.count == items.count }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                summary
                if !loaded {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(0..<12, id: \.self) { _ in
                            Rectangle().fill(Color.primary.opacity(0.07)).aspectRatio(1, contentMode: .fit)
                        }
                    }
                } else if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(sorted) { item in tile(item) }
                    }
                }
            }
            .padding(.bottom, selecting ? 110 : 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(selecting ? (selected.isEmpty ? "Select Items" : "\(selected.count) Selected") : "Storage")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button(selecting ? "Done" : "Select") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selecting.toggle()
                            if !selecting { selected.removeAll() }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { if selecting { selectionBar } }
        .task { await measure() }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from This Phone", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're removed from this chat on this phone only and can't be brought back here. Everyone else in the chat keeps theirs.")
        }
        .fullScreenCover(item: $viewerImage) { msg in
            ImageViewerView(message: msg, cid: cid, rectScope: .gallery)
        }
        .fullScreenCover(item: $viewerVideo) { msg in
            VideoPlayerScreen(message: msg, cid: cid, clipProvider: { nil }, rectScope: .gallery)
        }
    }

    private var deleteTitle: String {
        selected.count == 1 ? "Delete 1 item from this phone?" : "Delete \(selected.count) items from this phone?"
    }

    // MARK: - Pieces

    /// The total on this phone, the item count, and the sort, above the grid.
    private var summary: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loaded ? GroupInfoView.bytes(totalBytes) : " ")
                    .font(.title2.weight(.bold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(loaded ? "\(items.count) \(items.count == 1 ? "item" : "items") from \(title) on this phone" : "Measuring…")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Menu {
                Picker("Sort by", selection: $sort.animation(.easeInOut(duration: 0.25))) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down").font(.footnote.weight(.semibold))
                    Text(sort.rawValue).font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
            }
            .disabled(items.isEmpty)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "internaldrive").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text("Nothing from this chat is stored on this phone.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, 32)
    }

    private func tile(_ item: Item) -> some View {
        let isOn = selected.contains(item.id)
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { tileArt(item) }
            .clipped()
            // Size at the top, kind and length at the bottom, both on a soft shade so they read on
            // any picture.
            .overlay(alignment: .top) {
                HStack {
                    Spacer()
                    Text(GroupInfoView.bytes(item.bytes))
                        .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                .padding(5)
            }
            .overlay(alignment: .bottomLeading) { badge(item).padding(6) }
            .overlay { if selecting && isOn { Color.black.opacity(0.25) } }
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    ZStack {
                        Circle().fill(isOn ? Color.accentColor : .black.opacity(0.25))
                        Circle().stroke(.white, lineWidth: 1.5)
                        if isOn {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .padding(6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            // Where the tile is, for the fly out and the fly home (owner 2026-10-21: "open like All
            // Media", not up from the bottom).
            .modifier(MediaRectReporter(id: item.message.id, scope: .gallery, cornerRadius: 0))
            .contentShape(Rectangle())
            .onTapGesture { tap(item) }
            .onLongPressGesture(minimumDuration: 0.35) {
                guard !selecting else { return }
                Haptics.impact(.medium)
                withAnimation(.easeInOut(duration: 0.2)) { selecting = true; selected.insert(item.id) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kindLabel(item.kind)), \(GroupInfoView.bytes(item.bytes))")
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder private func tileArt(_ item: Item) -> some View {
        let m = item.message
        switch item.kind {
        case .photo, .gif, .video:
            if let url = m.imageUrl ?? m.thumbUrl {
                SecureImageView(imageUrl: url, enc: m.imageUrl != nil ? m.enc : m.thumbEnc, cid: cid,
                                placeholderImage: m.previewImage)
            } else { plainArt("photo") }
        case .album:
            if let first = m.album.first {
                SecureImageView(imageUrl: first.imageUrl, enc: first.enc, cid: cid, placeholderImage: m.previewImage)
            } else { plainArt("square.grid.2x2") }
        case .voice:
            plainArt("waveform")
        case .file:
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                VStack(spacing: 6) {
                    Text(fileExt(m.fileName))
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 54)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 1.2))
                    Text(m.fileName ?? "File").font(.caption2).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle).padding(.horizontal, 8)
                }
            }
        }
    }

    private func plainArt(_ symbol: String) -> some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func badge(_ item: Item) -> some View {
        let m = item.message
        switch item.kind {
        case .video:
            label("video.fill", m.duration.map(Self.clock))
        case .album:
            label("square.stack.fill", "\(m.album.count)")
        case .voice:
            label("mic.fill", m.duration.map(Self.clock))
        case .gif:
            label(nil, "GIF")
        case .photo, .file:
            EmptyView()
        }
    }

    private func label(_ symbol: String?, _ text: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            if let text { Text(text).font(.caption2.weight(.semibold)).monospacedDigit() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
    }

    /// Select All / the selected size / Delete, in one floating bar.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "Deselect All" : "Select All") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if allSelected { selected.removeAll() } else { selected = Set(items.map(\.id)) }
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(selected.isEmpty ? "None selected" : GroupInfoView.bytes(selectedBytes))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            Button { confirmDelete = true } label: {
                Image(systemName: "trash").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected.isEmpty ? Color.secondary : Color.red)
                    .frame(width: 40, height: 40)
            }
            .disabled(selected.isEmpty)
            .accessibilityLabel("Delete from This Phone")
        }
        .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 6)
        .liquidGlass(Capsule(), interactive: true)
        .padding(.horizontal, 16).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Work

    private func tap(_ item: Item) {
        if selecting {
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
            return
        }
        switch item.kind {
        // Flies out of its tile and back into it, the All Media page's open (owner 2026-10-21).
        case .photo, .gif: flyOpen(item.message, poster: item.message.imageUrl) { viewerImage = item.message }
        case .video: flyOpen(item.message, poster: item.message.thumbUrl) { viewerVideo = item.message }
        case .album, .voice, .file:
            // Nothing of its own to open here; a tap starts choosing, with this one ticked.
            withAnimation(.easeInOut(duration: 0.2)) { selecting = true; selected.insert(item.id) }
        }
    }

    private func flyOpen(_ m: Message, poster: String?, present rawPresent: @escaping () -> Void) {
        let present = { MediaPresentGate.present(rawPresent) }
        MediaOpen.flyOrPresent(imageUrl: poster, rectKey: MediaOpenRects.key(.gallery, m.id), present: present)
    }

    private func measure() async {
        // The hidden list is read here, on the main thread, where it is written.
        let msgs = messages.filter { !HiddenMessages.isHidden($0.id) }
        let found = await Task.detached(priority: .userInitiated) { Self.items(in: msgs) }.value
        withAnimation(.easeOut(duration: 0.2)) {
            items = found
            loaded = true
        }
    }

    /// Every message of this chat that has something on this phone, with what it takes. Reads file
    /// sizes only, never the bytes.
    nonisolated static func items(in messages: [Message]) -> [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for m in messages where seen.insert(m.id).inserted && !m.deleted {
            let kind: Item.Kind
            if !m.album.isEmpty { kind = .album }
            else if m.isVideo { kind = .video }
            else if m.isGif { kind = .gif }
            else if m.isImage { kind = .photo }
            else if m.isAudio { kind = .voice }
            else if m.isFile { kind = .file }
            else { continue }
            let bytes = Self.bytes(of: m)
            guard bytes > 0 else { continue }
            out.append(Item(id: m.id, message: m, kind: kind, bytes: bytes))
        }
        return out
    }

    nonisolated private static func imageURLs(_ m: Message) -> [String] {
        var out: [String] = []
        if let u = m.imageUrl, !u.isEmpty { out.append(u) }
        if let u = m.thumbUrl, !u.isEmpty { out.append(u) }
        for item in m.album where !item.imageUrl.isEmpty { out.append(item.imageUrl) }
        return out
    }

    nonisolated private static func bytes(of m: Message) -> Int {
        var n = 0
        for u in imageURLs(m) { n += DiskImageCache.shared.diskBytes(for: u).total }
        n += VideoCache.diskBytes(for: m.id)
        for (i, item) in m.album.enumerated() where item.isVideo { n += VideoCache.diskBytes(for: "\(m.id)-\(i)") }
        n += AudioCache.diskBytes(for: m.id)
        if m.isFile, let u = DocumentPrefetch.cached(id: m.id, fileName: m.fileName) {
            n += (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return n
    }

    /// Delete for Me, then the files: the chat's own hide first, so the bubble leaves the chat
    /// before the picture it points at does.
    private func deleteSelected() {
        let gone = items.filter { selected.contains($0.id) }
        for item in gone {
            let m = item.message
            HiddenMessages.hide(m.id)
            AudioCache.remove(m.id)
            VideoCache.remove(m.id)
            for (i, a) in m.album.enumerated() where a.isVideo { VideoCache.remove("\(m.id)-\(i)") }
            // A GIF is a public picture we never sent through our storage; only its cache copy goes.
            for u in Self.imageURLs(m) {
                if m.isGif { DiskImageCache.shared.removeCacheCopy(url: u) } else { DiskImageCache.shared.remove(url: u) }
            }
            if m.isFile, let u = DocumentPrefetch.cached(id: m.id, fileName: m.fileName) {
                try? FileManager.default.removeItem(at: u.deletingLastPathComponent())
            }
        }
        let ids = Set(gone.map(\.id))
        if var g = GalleryCache.store[cid] { g.removeAll { ids.contains($0.id) }; GalleryCache.store[cid] = g }
        MessageSearch.invalidateChat(cid)
        Haptics.notify(.success)
        withAnimation(.easeInOut(duration: 0.25)) {
            items.removeAll { ids.contains($0.id) }
            selected.removeAll()
            selecting = false
        }
        onChange()
    }

    // MARK: - Words

    private func kindLabel(_ k: Item.Kind) -> String {
        switch k {
        case .photo: return "Photo"
        case .video: return "Video"
        case .album: return "Album"
        case .voice: return "Voice message"
        case .file: return "File"
        case .gif: return "GIF"
        }
    }

    private func fileExt(_ name: String?) -> String {
        let ext = ((name ?? "") as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

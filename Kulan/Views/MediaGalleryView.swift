import SwiftUI

// Full-screen shared-content gallery (Telegram-style), PUSHED (not a sheet). Three tabs — Media,
// Audio, Links — with a filter menu on Media/Audio, long-press context menus, and a selection mode
// with a bottom Share / count / Delete toolbar. Links have no filter and no selection.
struct MediaGalleryView: View {
    let cid: String
    let title: String
    let photoUrl: String?

    enum Tab: Hashable { case media, audio, links }
    enum MediaFilter: Hashable { case all, photos, videos, gifs }
    enum AudioFilter: Hashable { case all, voice, files }

    @State private var all: [Message] = []
    @State private var loaded = false
    @State private var tab: Tab = .media
    @State private var mediaFilter: MediaFilter = .all
    @State private var audioFilter: AudioFilter = .all
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?
    @State private var openChat = false
    @State private var shareItems: [Any]?
    @State private var confirmDelete = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    private var dark: Bool { scheme == .dark }
    private let cols = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    // MARK: - Derived lists

    private var mediaItems: [Message] {
        all.filter { $0.isImage || $0.isVideo || $0.isGif }.filter { m in
            switch mediaFilter {
            case .all:    return true
            case .photos: return m.isImage
            case .videos: return m.isVideo
            case .gifs:   return m.isGif
            }
        }
    }
    private var audioItems: [Message] {
        all.filter { $0.isAudio }.filter { _ in
            switch audioFilter { case .all, .voice: return true; case .files: return false }
        }
    }
    private var linkItems: [Message] {
        all.filter { !$0.isImage && !$0.isVideo && !$0.isGif && !$0.isAudio && !$0.isFile && Self.firstURL(in: $0.text) != nil }
    }

    var body: some View {
        content
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(selecting)   // selection mode → only the X, no back
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if selecting { selectionToolbar } }
            .task { if !loaded { all = await ChatService.galleryContent(cid); loaded = true } }
            .fullScreenCover(item: $viewerImage) { ImageViewerView(message: $0, cid: cid) }
            .fullScreenCover(item: $viewerVideo) { VideoPlayerScreen(message: $0, cid: cid) }
            .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
                if let items = shareItems { ActivityView(items: items) }
            }
            .navigationDestination(isPresented: $openChat) {
                ThreadView(cid: cid, title: title, photoUrl: photoUrl)
            }
            .alert("Delete \(selecting ? "\(selection.count) item\(selection.count == 1 ? "" : "s")" : "item")?",
                   isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteSelected() }
            } message: { Text("This removes the message from this chat.") }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .media: mediaGrid
        case .audio: audioList
        case .links: linksList
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button { exitSelection() } label: { Image(systemName: "xmark") }.tint(.primary)
            }
        } else {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    Text("Media").tag(Tab.media)
                    Text("Audio").tag(Tab.audio)
                    Text("Links").tag(Tab.links)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            if tab != .links {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            if tab == .media {
                filterButton("All Media", mediaFilter == .all) { mediaFilter = .all }
                filterButton("Photos", mediaFilter == .photos) { mediaFilter = .photos }
                filterButton("Videos", mediaFilter == .videos) { mediaFilter = .videos }
                filterButton("GIFs", mediaFilter == .gifs) { mediaFilter = .gifs }
            } else {
                filterButton("All Audio", audioFilter == .all) { audioFilter = .all }
                filterButton("Voice Messages", audioFilter == .voice) { audioFilter = .voice }
                filterButton("Audio Files", audioFilter == .files) { audioFilter = .files }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .tint(.primary)
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

    // MARK: - Media grid

    private var mediaGrid: some View {
        ScrollView {
            if mediaItems.isEmpty { emptyState("photo.on.rectangle", "No media") }
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(mediaSections, id: \.title) { section in
                    Text(section.title)
                        .font(.title2.weight(.bold))
                        .padding(.horizontal, 14).padding(.top, 6)
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(section.items) { m in mediaCell(m) }
                    }
                }
            }
            .padding(.top, 4).padding(.bottom, 12)
        }
    }

    // Group media into month sections ("This Month", "June", "June 2024") for date headers, keeping
    // the existing (newest-first) order.
    private var mediaSections: [(title: String, items: [Message])] {
        let cal = Calendar.current
        var groups: [(key: DateComponents, items: [Message])] = []
        for m in mediaItems {
            let comps = cal.dateComponents([.year, .month], from: m.createdAt)
            if let last = groups.last, last.key == comps {
                groups[groups.count - 1].items.append(m)
            } else {
                groups.append((comps, [m]))
            }
        }
        let now = cal.dateComponents([.year, .month], from: Date())
        let monthFmt = DateFormatter(); monthFmt.dateFormat = "LLLL"
        let monthYearFmt = DateFormatter(); monthYearFmt.dateFormat = "LLLL yyyy"
        return groups.map { g in
            let date = cal.date(from: g.key) ?? Date()
            let title: String
            if g.key.year == now.year && g.key.month == now.month {
                title = "This Month"
            } else if g.key.year == now.year {
                title = monthFmt.string(from: date)
            } else {
                title = monthYearFmt.string(from: date)
            }
            return (title, g.items)
        }
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

    // MARK: - Audio list

    private var audioList: some View {
        ScrollView {
            if audioItems.isEmpty { emptyState("mic", "No audio") }
            LazyVStack(spacing: 0) {
                ForEach(audioItems) { m in
                    audioRow(m)
                    Divider().padding(.leading, 64)
                }
            }
        }
    }

    private func audioRow(_ m: Message) -> some View {
        let selected = selection.contains(m.id)
        return HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            Image(systemName: "waveform").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice message").font(.system(size: 16, weight: .medium))
                Text(durationLabel(m.duration)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
            if linkItems.isEmpty { emptyState("link", "No links") }
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
        return Button { openChat = true } label: {
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
            Button { openChat = true } label: { Label("Go to Chat", systemImage: "bubble.left") }
            if let url { Button { UIApplication.shared.open(url) } label: { Label("Open Link", systemImage: "safari") } }
        }
    }

    // MARK: - Item context menu (media + audio)

    @ViewBuilder private func itemMenu(_ m: Message) -> some View {
        Button { openChat = true } label: { Label("Go to Chat", systemImage: "bubble.left") }
        Button { share(m) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button { selecting = true; selection = [m.id] } label: { Label("Select", systemImage: "checkmark.circle") }
        Button(role: .destructive) { selection = [m.id]; confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Actions

    private func tap(_ m: Message) {
        if selecting { toggle(m) }
        else if m.isVideo { viewerVideo = m }
        else if m.isImage { viewerImage = m }
    }
    private func toggle(_ m: Message) {
        if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
    }
    private func exitSelection() { selecting = false; selection = [] }

    private func deleteSelected() {
        let ids = selection
        Task {
            for id in ids { await ChatService.deleteMessage(cid: cid, messageId: id) }
            await MainActor.run {
                all.removeAll { ids.contains($0.id) }
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

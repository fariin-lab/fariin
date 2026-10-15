import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// ⛔ "ADD FILES" INSIDE THE ATTACH SHEET — owner 2026-10-15, with a picture: tapping Files opens this
// page in the sheet (as Location and GIF do): ✕ / "Add files" / •••, an "Upload files" card that opens
// the system file picker, and the files sent recently, each one tap from going again.

/// A file this phone sent recently, kept so it can be sent again in one tap.
struct RecentFile: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let size: Int
    let date: Date
    let chat: String
    let file: String   // the copy's file name inside `FileRecents.dir`
}

/// The "Recent" list of the Add files page. ⚠️ HONEST LIMITS: it knows only files SENT FROM THIS
/// PHONE (from this build on), and only those up to `maxBytes`, because a copy is kept so the row can
/// send it again. Per account (uid in the key and the folder), so another account signed in on this
/// phone never sees these.
enum FileRecents {
    static let maxCount = 20
    static let maxBytes = 25 * 1024 * 1024

    private static var uid: String { AuthService.shared.uid ?? "none" }
    private static var key: String { "files.recent.v1.\(uid)" }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("RecentFiles/\(uid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(_ r: RecentFile) -> URL { dir.appendingPathComponent(r.file) }

    static func all() -> [RecentFile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentFile].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: url($0).path) }
    }

    private static func save(_ list: [RecentFile]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Records a sent file (newest first; the same name and size moves to the top instead of doubling).
    static func note(name: String, data: Data, chat: String) {
        guard data.count <= maxBytes, !name.isEmpty else { return }
        var list = all()
        if let old = list.first(where: { $0.name == name && $0.size == data.count }) {
            list.removeAll { $0.id == old.id }
            try? FileManager.default.removeItem(at: url(old))
        }
        let id = UUID().uuidString
        let file = "\(id)-\(name)"
        guard (try? data.write(to: dir.appendingPathComponent(file), options: .completeFileProtection)) != nil else { return }
        list.insert(RecentFile(id: id, name: name, size: data.count, date: Date(), chat: chat, file: file), at: 0)
        for gone in list.dropFirst(maxCount) { try? FileManager.default.removeItem(at: url(gone)) }
        save(Array(list.prefix(maxCount)))
    }
}

struct AttachFilesPage: View {
    var onBack: () -> Void
    /// A recent file to send again (a local copy).
    var onSendRecent: (URL) -> Void
    /// What the system file picker returned.
    var onImported: (Result<[URL], Error>) -> Void

    @State private var recents: [RecentFile] = FileRecents.all()
    @State private var importing = false
    /// Grid or List for Recent (owner 2026-10-15: the ••• menu chooses it; "Clear Recent" is gone).
    @AppStorage("files.recentLayout") private var layout = "list"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                uploadCard
                    .padding(.top, 8)
                Text("Recent")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                if recents.isEmpty {
                    Text("Files you send will appear here.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else if layout == "grid" {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(recents) { r in
                            Button { onSendRecent(FileRecents.url(r)) } label: { gridCell(r) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(recents) { r in
                            Button { onSendRecent(FileRecents.url(r)) } label: { row(r) }
                                .buttonStyle(.plain)
                            if r.id != recents.last?.id { Divider().padding(.leading, 80) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .contentMargins(.top, 76, for: .scrollContent)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { header }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            onImported(result)
        }
    }

    private var header: some View {
        HStack {
            glassCircle("xmark", label: "Back") { onBack() }
            Spacer()
            Text("Add files").font(.headline)
            Spacer()
            Menu {
                // Grid or List, the chosen one ticked (owner 2026-10-15, with the reference's menu).
                Picker("Layout", selection: $layout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                    Label("List", systemImage: "list.bullet").tag("list")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            // ⛔ PLAIN, LIKE THE X — owner 2026-10-15: "the 3 dots look blurred". The menu's own
            // button style drew its press/fade treatment over the glass; plain draws the glyph as is.
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private var uploadCard: some View {
        Button { importing = true } label: {
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up").font(.system(size: 22, weight: .semibold))
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 24, height: 3)
                }
                .foregroundStyle(.primary)
                .frame(width: 64, height: 64)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upload files").font(.system(size: 20, weight: .semibold)).foregroundStyle(.primary)
                    Text("Choose a new file from your device or iCloud Drive")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func row(_ r: RecentFile) -> some View {
        HStack(spacing: 14) {
            RecentFileIcon(file: r)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle(r)).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func gridCell(_ r: RecentFile) -> some View {
        VStack(spacing: 6) {
            RecentFileIcon(file: r, side: 84)
            Text(r.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                .lineLimit(2).multilineTextAlignment(.center)
            Text(ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }

    /// "74.4 KB • Oct 14 at 9:21 PM › General"
    private func subtitle(_ r: RecentFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file)
        let day = r.date.formatted(.dateTime.month(.abbreviated).day())
        let time = r.date.formatted(date: .omitted, time: .shortened)
        let chat = r.chat.isEmpty ? "" : " \u{203A} \(r.chat)"
        return "\(size) \u{2022} \(day) at \(time)\(chat)"
    }

    private func glassCircle(_ symbol: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A picture's own thumbnail, otherwise a blue document badge with its extension.
private struct RecentFileIcon: View {
    let file: RecentFile
    var side: CGFloat = 54
    @State private var thumb: UIImage?

    private var ext: String { (file.name as NSString).pathExtension.lowercased() }
    private var isImage: Bool { UTType(filenameExtension: ext)?.conforms(to: .image) ?? false }

    var body: some View {
        Group {
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue)
                    Text(ext.isEmpty ? "file" : String(ext.prefix(4)))
                        .font(.system(size: side * 0.28, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        .task(id: file.id) {
            guard isImage else { return }
            let u = FileRecents.url(file)
            thumb = await Task.detached(priority: .utility) { Self.downsample(u, to: 120) }.value
        }
    }

    private static func downsample(_ url: URL, to px: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: px,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Swipe back from the left edge, for the pages that open inside the attach sheet (Location, GIF,
/// Add files). Owner 2026-10-15: "if the user swipes back it must go back to the attach sheet's photos".
/// The page follows the finger from a 22pt strip on its left edge; past 100pt (or a flick) it goes
/// back, otherwise it springs home. The sheet's own pan only begins on vertical drags, so they never
/// compete.
struct EdgeSwipeBack: ViewModifier {
    let onBack: () -> Void
    @State private var dx: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 22)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .onChanged { v in dx = max(0, v.translation.width) }
                            .onEnded { v in
                                if v.translation.width > 100 || v.predictedEndTranslation.width > 260 {
                                    onBack()
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dx = 0 }
                                }
                            }
                    )
            }
    }
}

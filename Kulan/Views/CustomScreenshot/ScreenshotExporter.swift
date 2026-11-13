import SwiftUI
import UIKit
import Photos

// Customize screenshot (owner 2026-11-13): turning the edited chat into pictures, then saving them.
// All of it runs on the phone; the pictures only leave it if the person sends them.
//
// Each picture is a plain UIKit view tree: the wallpaper, the chat's real rows (`ShotRowUIView`) and
// the footer, drawn with `layer.render` at the screen's scale.

/// How the rows split into pictures: indices into the rows, one array per picture.
struct ShotPlan: Equatable {
    var pages: [[Int]] = []
    var pictureCount: Int { max(1, pages.count) }
}

@MainActor enum ScreenshotExporter {
    static let pageTop: CGFloat = 12
    static let footerHeight: CGFloat = 22
    static let footerSpacing: CGFloat = 10
    static let footerBottom: CGFloat = 12
    private static var footerBlock: CGFloat { footerSpacing + footerHeight + footerBottom }

    /// Splits the rows into pictures no taller than the screen, always between two messages.
    static func plan(rows: [ShotMessage], look: ShotLook, cid: String) -> ShotPlan {
        guard !rows.isEmpty else { return ShotPlan() }
        let screen = UIScreen.main.bounds.size
        let budget = screen.height - pageTop - footerBlock
        let places = ShotPlacement.of(rows)
        let probe = ShotRowUIView()
        var pages: [[Int]] = [[]]
        var used: CGFloat = 0
        for i in rows.indices {
            var place = places[i]
            if pages[pages.count - 1].isEmpty { place.showDay = true }
            probe.show(rows[i], place: place, cover: ShotCover(), look: look, width: screen.width, cid: cid)
            let h = probe.rowHeight
            if used + h > budget, !(pages.last?.isEmpty ?? true) {
                pages.append([])
                place.showDay = true
                probe.show(rows[i], place: place, cover: ShotCover(), look: look, width: screen.width, cid: cid)
                used = 0
            }
            pages[pages.count - 1].append(i)
            used += probe.rowHeight
        }
        return ShotPlan(pages: pages)
    }

    /// The edited chat as pictures as wide as the screen. Waits for the sharp photos first, so a
    /// picture never carries the small preview that travels inside a message.
    static func render(rows: [ShotMessage], look: ShotLook, covers: [String: ShotCover],
                       cid: String) async -> [UIImage] {
        guard !rows.isEmpty else { return [] }
        await warmPhotos(rows)
        let width = UIScreen.main.bounds.width
        let places = ShotPlacement.of(rows)
        let pages = plan(rows: rows, look: look, cid: cid).pages.map { page in
            pageView(page.map { rows[$0] }, places: page.map { places[$0] }, look: look,
                     covers: covers, width: width, cid: cid)
        }
        // A sticker's frame and a photo's decode land a moment after the row is configured.
        try? await Task.sleep(for: .milliseconds(450))
        return pages.map(snapshot)
    }

    /// One picture's view tree, laid out and ready to draw.
    private static func pageView(_ rows: [ShotMessage], places: [ShotPlacement], look: ShotLook,
                                 covers: [String: ShotCover], width: CGFloat, cid: String) -> UIView {
        var pagePlaces = places
        if !pagePlaces.isEmpty {
            pagePlaces[0].showDay = true
            pagePlaces[0].joinsPrev = false
            pagePlaces[0].showName = rows[0].senderName != nil
        }
        let views: [ShotRowUIView] = rows.indices.map { i in
            let v = ShotRowUIView()
            v.show(rows[i], place: pagePlaces[i], cover: covers[rows[i].id] ?? ShotCover(),
                   look: look, width: width, cid: cid)
            return v
        }
        let height = pageTop + views.reduce(0) { $0 + $1.rowHeight } + footerBlock
        let page = UIView(frame: CGRect(x: 0, y: 0, width: width, height: ceil(height)))
        page.overrideUserInterfaceStyle = look.dark ? .dark : .light
        let background = UIImageView(image: image(of: ShotBackgroundView(look: look), size: page.bounds.size))
        background.frame = page.bounds
        page.addSubview(background)
        var y = pageTop
        for v in views {
            v.frame = CGRect(x: 0, y: y, width: width, height: v.rowHeight)
            page.addSubview(v)
            y += v.rowHeight
        }
        let footer = UIImageView(image: image(of: ShotFooter(look: look),
                                              size: CGSize(width: width, height: footerHeight)))
        footer.frame = CGRect(x: 0, y: y + footerSpacing, width: width, height: footerHeight)
        page.addSubview(footer)
        page.layoutIfNeeded()
        return page
    }

    private static func snapshot(_ page: UIView) -> UIImage {
        page.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: page.bounds, format: format).image { ctx in
            page.layer.render(in: ctx.cgContext)
        }
    }

    private static func image<V: View>(of view: V, size: CGSize) -> UIImage? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = UIScreen.main.scale
        return r.uiImage
    }

    /// Puts each photo's decrypted copy in memory, where the row reads it without waiting. A photo
    /// not on the phone yet is being fetched by the editor's own row; it gets a few seconds.
    private static func warmPhotos(_ rows: [ShotMessage]) async {
        let urls = rows.flatMap(\.mediaURLs)
        guard !urls.isEmpty else { return }
        for _ in 0..<12 {
            var missing = 0
            for u in urls {
                if await DiskImageCache.shared.image(for: u) == nil { missing += 1 }
            }
            if missing == 0 { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Save

    /// Saves the pictures to Photos with add-only access, the permission the app already asks for
    /// when it saves photos from a chat. Reports the result in the app's own toast.
    static func save(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            ToastNotice.show("Allow Fariin to add photos in Settings to save pictures.")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for img in images { PHAssetChangeRequest.creationRequestForAsset(from: img) }
            }
            ToastNotice.show(images.count == 1 ? "Saved to Photos" : "\(images.count) pictures saved to Photos")
        } catch {
            ToastNotice.show("Couldn't save to Photos. Try again.")
        }
    }
}

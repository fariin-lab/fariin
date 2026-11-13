import SwiftUI
import UIKit
import Photos

// Customize screenshot (owner 2026-11-13): turning the edited chat into pictures, then saving or
// sharing them. All of it runs on the phone; the pictures only leave it if the person sends them.

/// One finished picture: its rows top to bottom, then the footer.
struct ShotPageView: View {
    let rows: [ShotMessage]
    let places: [ShotPlacement]
    let look: ShotLook
    let covers: [String: ShotCover]
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                ShotRowView(message: rows[i], look: look, place: places[i], rowWidth: width,
                            cover: covers[rows[i].id] ?? ShotCover())
            }
            ShotFooter(look: look)
                .padding(.top, ScreenshotExporter.footerSpacing)
                .padding(.bottom, ScreenshotExporter.footerBottom)
        }
        .padding(.top, ScreenshotExporter.pageTop)
        .frame(width: width)
        .background { ShotBackgroundView(look: look) }
        .environment(\.colorScheme, look.dark ? .dark : .light)
    }
}

/// What the editor shows above the button: how many pictures, how many messages.
struct ShotPlan: Equatable {
    var pages: [[Int]] = []
    var pictureCount: Int { max(1, pages.count) }
}

@MainActor enum ScreenshotExporter {
    static let pageTop: CGFloat = 12
    static let footerHeight: CGFloat = 22
    static let footerSpacing: CGFloat = 10
    static let footerBottom: CGFloat = 12

    /// Splits the rows into pictures no taller than the screen, always between two messages.
    /// Each picture starts with its own day pill, as a screenshot of that part of the chat would.
    static func plan(rows: [ShotMessage], look: ShotLook) -> ShotPlan {
        guard !rows.isEmpty else { return ShotPlan() }
        let screen = UIScreen.main.bounds.size
        let budget = screen.height - pageTop - footerHeight - footerSpacing - footerBottom
        let places = ShotPlacement.of(rows)
        var pages: [[Int]] = [[]]
        var used: CGFloat = 0
        for i in rows.indices {
            var place = places[i]
            if pages[pages.count - 1].isEmpty { place.showDay = true }
            let h = height(of: ShotRowView(message: rows[i], look: look, place: place, rowWidth: screen.width),
                           width: screen.width)
            if used + h > budget, !(pages.last?.isEmpty ?? true) {
                pages.append([])
                used = height(of: ShotChip(text: rows[i].day, look: look), width: screen.width) + 14
            }
            pages[pages.count - 1].append(i)
            used += h
        }
        return ShotPlan(pages: pages)
    }

    /// The edited chat as pictures as wide as the screen, at the screen's scale.
    static func render(rows: [ShotMessage], look: ShotLook, covers: [String: ShotCover]) -> [UIImage] {
        let width = UIScreen.main.bounds.width
        let places = ShotPlacement.of(rows)
        return plan(rows: rows, look: look).pages.compactMap { page in
            guard let first = page.first else { return nil }
            var pagePlaces = page.map { places[$0] }
            pagePlaces[0].showDay = true
            pagePlaces[0].joinsPrev = false
            pagePlaces[0].showName = rows[first].senderName != nil
            let renderer = ImageRenderer(content: ShotPageView(rows: page.map { rows[$0] }, places: pagePlaces,
                                                               look: look, covers: covers, width: width))
            renderer.scale = UIScreen.main.scale
            renderer.isOpaque = true
            return renderer.uiImage
        }
    }

    private static func height<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: width))
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
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

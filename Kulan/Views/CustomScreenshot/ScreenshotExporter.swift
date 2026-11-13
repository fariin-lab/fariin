import SwiftUI
import UIKit
import Photos

// Customize screenshot (owner 2026-11-13): turning the edited chat into pictures, then saving or
// sharing them. All of it runs on the phone; the pictures only leave it if the person shares them.

/// One finished page of the picture: the rows it holds, top to bottom.
struct ShotPageView: View {
    let rows: [ShotMessage]
    let places: [ShotPlacement]
    let look: ShotLook
    let hiddenIds: Set<String>
    let showLogo: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                ShotRowView(message: rows[i], look: look, place: places[i],
                            hidden: hiddenIds.contains(rows[i].id))
            }
            if showLogo {
                ShotBranding(look: look).padding(.top, 10)
            }
        }
        .padding(.top, ScreenshotExporter.pageTop)
        .padding(.bottom, ScreenshotExporter.pageBottom)
        .frame(width: width)
        .background { ShotBackgroundView(look: look) }
        .environment(\.colorScheme, look.dark ? .dark : .light)
    }
}

@MainActor enum ScreenshotExporter {
    static let pageTop: CGFloat = 16
    static let pageBottom: CGFloat = 16
    /// Room kept at the bottom of each page for the logo badge.
    static let brandingHeight: CGFloat = 42

    /// The edited chat as pictures as wide as the screen. A chat taller than one screen is split
    /// into several pictures, always between two messages, never through one.
    static func render(rows: [ShotMessage], look: ShotLook,
                       hiddenIds: Set<String>, showLogo: Bool) -> [UIImage] {
        guard !rows.isEmpty else { return [] }
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let width = screen.width
        let budget = screen.height - pageTop - pageBottom - (showLogo ? brandingHeight : 0)
        let places = ShotPlacement.of(rows)

        // Measure every row once at the page width, then fill pages greedily. Pages hold indices
        // into `rows`, so each row keeps the placement it has in the whole picture.
        var pages: [[Int]] = [[]]
        var used: CGFloat = 0
        for i in rows.indices {
            let h = height(of: ShotRowView(message: rows[i], look: look, place: places[i],
                                           hidden: hiddenIds.contains(rows[i].id)),
                           width: width)
            if used + h > budget, !(pages.last?.isEmpty ?? true) {
                pages.append([])
                used = 0
            }
            pages[pages.count - 1].append(i)
            used += h
        }

        return pages.compactMap { page in
            let renderer = ImageRenderer(content: ShotPageView(rows: page.map { rows[$0] },
                                                               places: page.map { places[$0] },
                                                               look: look,
                                                               hiddenIds: hiddenIds, showLogo: showLogo,
                                                               width: width))
            renderer.scale = scale
            renderer.isOpaque = true
            return renderer.uiImage
        }
    }

    private static func height<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: width))
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    // MARK: Save and share

    /// Saves the pictures to Photos with add-only access, the same permission the app already asks
    /// for when it saves photos from a chat. Reports the result in the app's own toast.
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

    /// The system share sheet, over whatever is on top (the editor itself).
    static func share(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = top?.presentedViewController { top = p }
        guard let top else { return }
        let vc = UIActivityViewController(activityItems: images, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX,
                                                             y: top.view.bounds.maxY - 80, width: 1, height: 1)
        top.present(vc, animated: true)
    }
}

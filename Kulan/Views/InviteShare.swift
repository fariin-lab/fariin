import SwiftUI
import UIKit
import LinkPresentation

/// The invite a person shares, and how the share sheet shows it — owner, 2026-09-25, with the sheet's
/// header ringed: it showed a grey "A|" text icon, because what we handed over was bare text and the
/// system draws that icon for text. Now the header carries the Fariin mark and a title, so the sheet
/// says what is being shared before anyone reads the sentence.
///
/// Two doors, one look: `preview` for SwiftUI's `ShareLink`, and `InviteActivityItem` for the pages
/// that present `UIActivityViewController` themselves. Both use the `welcome-mark` asset, the same
/// logo the Fariin channel's avatar draws.
enum InviteShare {
    static var text: String {
        let h = ProfileStore.shared.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }

    static let title = "Invite to Fariin"

    static var preview: SharePreview<Image, Image> {
        SharePreview(title, image: Image("welcome-mark"), icon: Image("welcome-mark"))
    }
}

/// The same invite for `UIActivityViewController`: the text is what is shared, the metadata is only
/// the sheet's header.
final class InviteActivityItem: NSObject, UIActivityItemSource {
    private let text: String
    init(text: String = InviteShare.text) { self.text = text }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { text }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.title = InviteShare.title
        if let logo = UIImage(named: "welcome-mark") {
            meta.iconProvider = NSItemProvider(object: logo)
            meta.imageProvider = NSItemProvider(object: logo)
        }
        return meta
    }
}

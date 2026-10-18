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
    /// ⛔ THE INVITE CARRIES A LINK — owner 2026-10-15: shared into Messages it "shows nothing". It
    /// was a sentence with no link, so the person receiving it had nothing to tap and no card.
    /// Now it ends with my profile page (fariin.com/u/<handle>, which has its own title and
    /// picture for the preview and opens a chat with me in the app), or the home page without a
    /// username.
    static var link: URL {
        let h = ProfileStore.shared.me?.handle ?? ""
        return URL(string: h.isEmpty ? KulanApp.linkHost : KulanApp.userLink(handle: h))
            ?? URL(string: KulanApp.linkHost)!
    }

    /// ⛔ SENTENCE AND LINK ARE TWO ITEMS — owner 2026-10-18: in Messages our invite was bare text
    /// while other messengers showed a big card. Messages only builds the card (the page's
    /// og:title + og:image) for a URL item; a link typed inside a String stays plain words.
    static let sentence = "Let's chat on Fariin. Here's my link"

    static var items: [Any] { [InviteActivityItem(), link] }

    static let title = "Invite to Fariin"

    /// ⛔ THE SYSTEM SHARE SHEET, NOT `ShareLink(item:preview:)` — owner 2026-10-15: from Settings,
    /// Messages showed nothing and another messenger's Next did nothing. Settings and New Chat used
    /// `ShareLink` with a `SharePreview` carrying an image (a300f4c2, 2026-09-25); with a String
    /// item that preview can be what the other app is handed instead of the text. The Fariin
    /// channel's invite has always gone through `InviteActivityItem` (plain text to the app, the
    /// logo only in the sheet's header), so both doors use that now.
    @MainActor static func present() {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = top?.presentedViewController { top = p }
        guard let top else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }
}

/// The invite's sentence for `UIActivityViewController` (the link rides beside it as a URL item);
/// the metadata is only the sheet's header.
final class InviteActivityItem: NSObject, UIActivityItemSource {
    private let text: String
    init(text: String = InviteShare.sentence) { self.text = text }

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

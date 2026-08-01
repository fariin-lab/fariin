import SwiftUI

// The link-preview card inside a text bubble (the Messenger/Signal look the user asked for, reference
// screenshots 2026-07-29): big image on top, then title / description / domain, tappable to open.
// Renders ONLY what travelled inside the message (Message.LinkPreviewData) — the sender fetched and
// sealed it; this view never contacts the site. A pending (just-sent) bubble carries the plaintext
// draft with an UNencrypted local image key, so the card is identical before and after the server echo.
struct LinkPreviewCard: View {
    let preview: Message.LinkPreviewData
    let cid: String
    let isMe: Bool
    let dark: Bool

    private var fg: Color { isMe ? Theme.onAccent(dark) : (dark ? .white : .black) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let img = preview.imageUrl {
                Group {
                    if let enc = preview.imageEnc {
                        SecureImageView(imageUrl: img, enc: enc, cid: cid, smallSync: true)
                    } else if let ui = DiskImageCache.shared.smallImageSync(img) {
                        // The pending bubble's draft image (cached locally under a draft key).
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(fg.opacity(0.10))
                    }
                }
                // Taller hero image — the reference card leads with a big photo, and 140 read as a
                // thin strip next to it (user side-by-side comparison).
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 2) {
                if !preview.title.isEmpty {
                    Text(preview.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(fg)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                if !preview.desc.isEmpty {
                    Text(preview.desc)
                        .font(.system(size: 12))
                        .foregroundStyle(fg.opacity(0.75))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Text(preview.host)
                    .font(.system(size: 11))
                    .foregroundStyle(fg.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fg.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            if let u = URL(string: preview.url) { UIApplication.shared.open(u) }
        }
    }
}

import SwiftUI

// Compact Open-Graph card shown under a message that contains a link. Loads the preview lazily via
// LinkPreviewService (on-device, cached); renders nothing until/unless a usable preview comes back, so
// a plain URL with no OG tags just stays plain text.
struct LinkPreviewCard: View {
    let url: URL
    let isMe: Bool
    let dark: Bool
    @State private var preview: LinkPreview?

    private var fg: Color { isMe ? Theme.onAccent(dark) : (dark ? .white : .black) }

    var body: some View {
        Group {
            if let p = preview {
                HStack(spacing: 10) {
                    if let img = p.imageUrl {
                        AsyncImage(url: img) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { Rectangle().fill(fg.opacity(0.12)) }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(fg).lineLimit(2).multilineTextAlignment(.leading)
                        Text(p.host).font(.system(size: 11))
                            .foregroundStyle(fg.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fg.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
        }
        .task(id: url) {
            let p = await LinkPreviewService.shared.preview(for: url)
            await MainActor.run { withAnimation(.easeIn(duration: 0.2)) { preview = p } }
        }
    }
}

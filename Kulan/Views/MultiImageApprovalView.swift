import SwiftUI

// Multi-image pre-send approval — Signal's AttachmentApproval flow, our own code:
//   • Swipeable, ZOOMABLE pages of the selected photos (order = selection order, like Signal).
//   • A bottom thumbnail RAIL (ApprovalRailCellView equivalent): ordered thumbs, the current one
//     ring-highlighted; tap a thumb to jump to it; the X badge removes it from the batch.
//   • ONE caption for the whole batch (Signal sends a single message body with the album) + a round
//     send button showing the count.
//   • Removing the last photo closes the screen. Glass chrome throughout (native Liquid Glass).
struct MultiImageApprovalView: View {
    @State var images: [UIImage]
    var onSend: (_ images: [UIImage], _ caption: String, _ hd: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var caption = ""
    @State private var hd = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Swipeable zoomable pages (Signal pages its attachments; each zooms independently).
            // Single-tap the photo closes the caption keyboard (native feel).
            TabView(selection: $page) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                    ZoomImageView(image: img, onSingleTap: { captionFocused = false },
                                  onDim: { _ in }, onDismiss: {}, allowsDismissPan: false)
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        // Swipe DOWN on the photo closes the keyboard too (reads the drag without consuming zoom/pan).
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { g in if captionFocused, g.translation.height > 24 { captionFocused = false } }
        )
        // Native placement: the top bar sits just below the status bar, the controls just above the home
        // indicator (and rise above the keyboard) — via safe-area insets, no hard-coded offsets.
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
    }

    // X (close) top-left · HD toggle top-right — Apple's standard corner placement.
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button { hd.toggle() } label: {
                Text("HD").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hd ? Color(hex: 0x3DA1FD) : .white)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // Thumbnail rail (hidden while typing) + caption field + count send button.
    private var bottomControls: some View {
        VStack(spacing: 12) {
            if !captionFocused { rail }
            HStack(spacing: 10) {
                TextField("", text: $caption,
                          prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                    .foregroundStyle(.white).focused($captionFocused)
                    .padding(.horizontal, 16).frame(height: 46)
                    .liquidGlass(Capsule(), interactive: true)
                Button {
                    onSend(images, caption.trimmingCharacters(in: .whitespacesAndNewlines), hd)
                    dismiss()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color(hex: 0x3DA1FD), in: Circle())
                        // Count badge (Signal shows how many are going).
                        Text("\(images.count)").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
                .buttonStyle(StoryPressStyle())
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: captionFocused)
    }

    // Ordered thumbnail rail: current page ring-highlighted, tap to jump, X removes from the batch.
    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if i == page {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color(hex: 0x3DA1FD), lineWidth: 2.5)
                                }
                            }
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { page = i } }
                        if i == page {
                            Button { remove(i) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 6)
        }
        .frame(height: 60)
    }

    private func remove(_ i: Int) {
        guard images.indices.contains(i) else { return }
        images.remove(at: i)
        if images.isEmpty { dismiss(); return }
        if page >= images.count { page = images.count - 1 }
    }
}

import SwiftUI

// Full-screen "Pinned Messages" sheet (reference design): centered title + chat name, glass X, the
// pins rendered as REAL chat bubbles (the same MessageBubble as the conversation, hit-testing off so
// the whole row is a tap target), a jump arrow beside each bubble, day headers, and "Unpin All" at the
// bottom. Tap a bubble or its arrow → close + scroll the chat to that message.
struct PinnedMessagesSheet: View {
    let pinned: [Message]
    let me: String
    let cid: String
    let title: String                       // chat name, shown under the header title
    var nameFor: (String) -> String
    var canUnpin: Bool
    var onUnpin: (String) -> Void
    var onTap: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            Theme.bg(dark).ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || !Calendar.current.isDate(m.createdAt, inSameDayAs: pinned[i - 1].createdAt) {
                            Text(dayLabel(m.createdAt))
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        HStack(spacing: 10) {
                            // The real bubble, exactly as in the chat (interactions off — row taps jump).
                            MessageBubble(message: m, isMe: m.authorId == me, dark: dark, cid: cid,
                                          nameFor: nameFor)
                                .allowsHitTesting(false)
                            // Jump-to-message arrow (reference style).
                            Button { jump(m.id) } label: {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 26, weight: .light))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { jump(m.id) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 90)   // clear the floating Unpin All
            }
            .overlay {
                if pinned.isEmpty {
                    ContentUnavailableView("No pinned messages", systemImage: "pin",
                                           description: Text("Pin a message from its menu."))
                }
            }
        }
        // Header: centered title + chat name, glass X trailing.
        .safeAreaInset(edge: .top) {
            ZStack {
                VStack(spacing: 2) {
                    Text("Pinned Messages").font(.headline)
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .liquidGlass(Circle(), interactive: true)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        // Floating "Unpin All" (reference style), only when allowed.
        .safeAreaInset(edge: .bottom) {
            if canUnpin && !pinned.isEmpty {
                Button {
                    for m in pinned { onUnpin(m.id) }
                    dismiss()
                } label: {
                    Text("Unpin All").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        .padding(.horizontal, 26).frame(height: 48)
                        .liquidGlass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
            }
        }
        .presentationDetents([.large])   // full sheet (reference design)
        .presentationDragIndicator(.visible)
    }

    private func jump(_ id: String) { onTap(id) }

    private func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

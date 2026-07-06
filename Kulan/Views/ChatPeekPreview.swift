import SwiftUI
import UIKit
import FirebaseFirestore

// Rich native context-menu peek for a chat row (Signal-style): a dedicated conversation
// snapshot showing a mini-timeline of the most recent messages — text bubbles, photo
// chips, and voice-note players — inside a smoothly rounded card. Shown above the action
// menu via the .contextMenu(menuItems:preview:) API. Non-interactive (tapping opens chat).
struct ChatPeekPreview: View {
    let conv: Conversation
    let me: String
    let dark: Bool

    @State private var messages: [Message] = []   // last few, loaded on appear

    private var cardBG: Color { dark ? Color(hex: 0x1C1C1E) : Color.white }

    private var dateLabel: String {
        let ms = conv.displayUpdatedAt(me)
        guard ms > 0 else { return "Today" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conv.name(for: me)).font(.headline)
                    Text("end-to-end encrypted").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(dateLabel)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                if messages.isEmpty {
                    HStack { fallbackBubble; Spacer(minLength: 0) }
                } else {
                    ForEach(messages) { m in miniBubble(m) }
                }
            }
        }
        .padding(16)
        .frame(width: UIScreen.main.bounds.width - 28)   // near full-width peek (small side margins)
        .background(cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task { await loadRecent() }
    }

    // One message as a mini bubble: mine = accent on the right, received = gray on the left.
    @ViewBuilder private func miniBubble(_ m: Message) -> some View {
        let mine = m.authorId == me
        HStack {
            if mine { Spacer(minLength: 36) }
            bubbleContent(m, mine: mine)
            if !mine { Spacer(minLength: 36) }
        }
    }

    @ViewBuilder private func bubbleContent(_ m: Message, mine: Bool) -> some View {
        let bg = mine ? Theme.accent(dark) : Theme.received(dark)
        let fg = mine ? Theme.onAccent(dark) : (dark ? Color.white : .black)
        if m.isCall {
            callWidget(m)
        } else if m.isVideo {
            videoBubble(m)
        } else if m.isImage {
            imageBubble(m)
        } else if m.isAudio {
            voiceBubble(fg: fg, bg: bg)
        } else {
            Text(m.text.isEmpty ? " " : m.text)
                .font(.system(size: 15)).foregroundStyle(fg).lineLimit(4)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(bg).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func imageBubble(_ m: Message) -> some View {
        Group {
            if let url = m.imageUrl {
                SecureImageView(imageUrl: url, enc: m.enc, cid: conv.id)
            } else {
                Rectangle().fill(Color.black.opacity(0.85))
            }
        }
        .frame(width: 150, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func videoBubble(_ m: Message) -> some View {
        Group {
            if let url = m.thumbUrl {
                SecureImageView(imageUrl: url, enc: m.thumbEnc, cid: conv.id)
            } else {
                Rectangle().fill(Color.black.opacity(0.85))
            }
        }
        .frame(width: 150, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white)
                .padding(12).background(.black.opacity(0.45), in: Circle())
        }
    }

    private func voiceBubble(fg: Color, bg: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(fg)
            HStack(spacing: 2) {
                ForEach(0..<18, id: \.self) { i in
                    Capsule().fill(fg.opacity(0.5))
                        .frame(width: 2, height: [6, 14, 9, 18, 11, 7].randomElementStable(i))
                }
            }
            Text("Voice").font(.caption).foregroundStyle(fg.opacity(0.85))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(bg).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func callWidget(_ m: Message) -> some View {
        let missed = m.callOutcome == "missed"
        let video = m.callVideo
        return HStack(spacing: 10) {
            Image(systemName: video ? (missed ? "video.slash.fill" : "video.fill")
                                    : (missed ? "phone.arrow.down.left" : "phone.fill"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(missed ? .red : .secondary)
            Text(video ? (missed ? "Missed video call" : "Video call")
                       : (missed ? "Missed call" : "Call")).font(.system(size: 14))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.received(dark))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // Shown until the recent messages load (never empty).
    private var fallbackBubble: some View {
        Text({
            // Group last-message is sealed by its sender → decrypt with the sender's key (cached),
            // not the cid pair (which would show raw ciphertext for groups).
            let d = conv.isGroup
                ? Crypto.shared.decryptGroupCached(conv.lastMessageCipher, cid: conv.id, authorId: conv.lastSender)
                : Crypto.shared.decryptCached(conv.lastMessageCipher, cid: conv.id)
            return d.isEmpty ? "Say hello 👋" : d
        }())
        .font(.system(size: 15)).lineLimit(4)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.received(dark))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // Fetch the last few messages (newest at the bottom) and decrypt for the snapshot.
    private func loadRecent() async {
        guard let snap = try? await Firestore.firestore()
            .collection("conversations").document(conv.id).collection("messages")
            .order(by: "createdAt", descending: true)
            .limit(to: 5)
            .getDocuments() else { return }
        // Warm the right keys before building Messages: each author in a group, else the 1:1 peer.
        if conv.isGroup {
            let authors = Set(snap.documents.compactMap { $0.data()["authorId"] as? String })
            for a in authors where a != me { _ = await Crypto.shared.preloadKey(a) }
        } else {
            _ = await Crypto.shared.preloadKey(conv.otherUid(me))
        }
        let recent = snap.documents
            .map { Message(id: $0.documentID, data: $0.data(), cid: conv.id, crypto: Crypto.shared) }
            .reversed()
        await MainActor.run { messages = Array(recent) }
    }
}

// Deterministic "random-looking" bar heights (no Date/Math.random — stable across renders).
private extension Array where Element == CGFloat {
    func randomElementStable(_ seed: Int) -> CGFloat { self[(seed &* 7 &+ 3) % count] }
}

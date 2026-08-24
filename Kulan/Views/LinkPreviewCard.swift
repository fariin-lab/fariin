import SwiftUI

// The link-preview card inside a text bubble (the the big messengers look the user asked for, reference
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

    /// The handle this card is about, when it is one of our own profile links. Read from the URL
    /// rather than stored, so every message ever sent — including ones from before profile cards
    /// existed — answers the same way with no migration.
    private var profileHandle: String? {
        URL(string: preview.url).flatMap { LinkPreviewService.profileHandle(in: $0) }
    }

    /// The account could not be resolved when this was sent: a deleted account, a released name, or
    /// a typed handle that never existed. The card says so instead of leaving a link that looks live.
    private var profileUnavailable: Bool { preview.desc.isEmpty && preview.title == "Unavailable" }

    @ViewBuilder
    var body: some View {
        if let handle = profileHandle {
            profileCard(handle)
        } else {
            articleCard
        }
    }

    // MARK: - A person

    /// ⛔ A PROFILE IS NOT AN ARTICLE. The article layout leads with a 170pt hero image, which for a
    /// person means their face cropped into a letterbox above a headline. A profile card is the
    /// shape the rest of the app already uses for people: round photo, name, @handle — and, because
    /// the whole point of sending somebody's link is that the person receiving it can reach them, a
    /// button that opens the chat.
    @ViewBuilder private func profileCard(_ handle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if profileUnavailable {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 20))
                            .foregroundStyle(fg.opacity(0.55))
                            .frame(width: 44, height: 44)
                            .background(fg.opacity(0.10), in: Circle())
                    } else if let img = preview.imageUrl, let ui = cardImage(img) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(Circle())
                    } else {
                        // The same letter-on-colour every avatar in the app falls back to.
                        AvatarView(name: preview.title, photoUrl: nil, size: 44)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(profileUnavailable ? "Unavailable" : preview.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(fg).lineLimit(1)
                    Text(profileUnavailable ? "This account is no longer available"
                                            : (preview.desc.isEmpty ? "@\(handle)" : preview.desc))
                        .font(.system(size: 13))
                        .foregroundStyle(fg.opacity(0.75)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, profileUnavailable ? 10 : 8)

            if !profileUnavailable {
                Divider().overlay(fg.opacity(0.12))
                Button { openChat(with: handle) } label: {
                    Text("Send Message")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(fg)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fg.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func cardImage(_ key: String) -> UIImage? {
        DiskImageCache.shared.smallImageSync(key)
    }

    /// The same two steps the deep link takes, so a tap here and a tap on the link itself land in
    /// exactly one place. `AppRouter.pendingChatId` is what the shell watches.
    private func openChat(with handle: String) {
        Task {
            guard let user = await ChatService.findByHandle(handle),
                  let cid = try? await ChatService.openConversation(other: user) else { return }
            await MainActor.run { AppRouter.shared.pendingChatId = cid }
        }
    }

    // MARK: - A page

    private var articleCard: some View {
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
            // In-app Safari sheet, not a trip out to Safari — see WebLink.
            if let u = URL(string: preview.url) { WebLink.open(u) }
        }
    }
}

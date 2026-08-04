import SwiftUI
import Observation
import FirebaseAuth

// Our own in-app message banner, instead of borrowing the iOS one.
//
// A push that lands while the app is OPEN used to be shown by the system: the standard grey
// notification drop-down, which reads as "something outside the app happened" even though you are
// looking at the app. the reference app, the reference app and the reference app all draw their own, styled like the app, and
// that is what this is: avatar, name, the message, tap to open, swipe up to send it away.
//
// The chat you are currently looking at never banners itself — see PushManager.willPresent.

@Observable
final class InAppBannerCenter {
    static let shared = InAppBannerCenter()
    private init() {}

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let cid: String?
        let title: String
        let body: String
        let photoUrl: String?
    }

    private(set) var item: Item?
    private var hideTask: DispatchWorkItem?
    private static let visibleFor: TimeInterval = 4.5

    @MainActor
    func show(cid: String?, title: String, body: String) {
        // A second message replaces the first and restarts the clock, rather than stacking.
        let next = Item(cid: cid, title: title, body: body, photoUrl: cid.flatMap(Self.photo(forCid:)))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { item = next }
        hideTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    @MainActor
    func dismiss() {
        hideTask?.cancel(); hideTask = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { item = nil }
    }

    /// The sender's photo out of the chat list we already hold: the group's photo for a group, the
    /// other person's for a 1:1. Nothing is fetched here — a miss just falls back to the coloured
    /// initial, the same as every other avatar in the app.
    private static func photo(forCid cid: String) -> String? {
        guard let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        else { return nil }
        if conv.convType == "group" { return conv.avatarUrl }
        let me = Auth.auth().currentUser?.uid ?? ""
        guard let other = conv.users.first(where: { $0 != me }) else { return nil }
        return conv.photos[other]
    }
}

struct InAppBannerCard: View {
    let item: InAppBannerCenter.Item
    @State private var dragY: CGFloat = 0

    private var center: InAppBannerCenter { InAppBannerCenter.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AvatarView(name: item.title, photoUrl: item.photoUrl, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(item.body)
                        .font(.system(size: 16))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            // The grabber: the one cue that says this thing can be pushed away.
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 42, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                .overlay(shape.fill(Color.black.opacity(0.28)))
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
        .padding(.horizontal, 10)
        .offset(y: dragY)
        .contentShape(Rectangle())
        .gesture(
            // Upward only: this is a dismiss, not a repositionable window.
            DragGesture(minimumDistance: 5)
                .onChanged { v in dragY = min(0, v.translation.height) }
                .onEnded { v in
                    if v.translation.height < -28 {
                        center.dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragY = 0 }
                    }
                    dragY = 0
                }
        )
        .onTapGesture {
            if let cid = item.cid { AppRouter.shared.pendingChatId = cid }
            center.dismiss()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// Mount once, at the root, above everything the app normally shows.
    func inAppBanner() -> some View {
        overlay(alignment: .top) {
            if let item = InAppBannerCenter.shared.item {
                InAppBannerCard(item: item)
                    .id(item.id)   // a new message re-runs the slide-in instead of swapping text in place
            }
        }
    }
}

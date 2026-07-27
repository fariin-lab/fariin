import SwiftUI
import AVFoundation
import AudioToolbox
import UIKit
import FirebaseAuth

// In-app notification engine — makes the three "In-App Notifications" toggles REAL:
// a message arriving while the app is OPEN shows a top banner (In-App Preview), plays the
// chosen tone (In-App Sounds) and taps the haptic (In-App Vibrate). Fed by MainShell
// observing the conversations repo; the chat currently on screen never notifies
// (AppRouter.activeChatId), muted chats never notify, and the first snapshot after
// launch only seeds the baseline so old unreads can't replay as banners.
@Observable final class InAppNotify {
    static let shared = InAppNotify()
    private init() {}

    struct Banner: Equatable {
        let cid: String
        let title: String
        let hint: String
        let photoUrl: String?
    }
    var banner: Banner?

    @ObservationIgnored private var lastUnread: [String: Int] = [:]
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var lastFire: [String: Date] = [:]
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    func process(_ convs: [Conversation]) {
        let me = Auth.auth().currentUser?.uid ?? ""
        guard !me.isEmpty else { return }
        var fresh: Conversation?
        for c in convs {
            let u = c.unread(me)
            if seeded, u > (lastUnread[c.id] ?? 0), fresh == nil { fresh = c }
            lastUnread[c.id] = u
        }
        seeded = true
        guard let conv = fresh else { return }
        guard conv.id != AppRouter.shared.activeChatId else { return }
        guard !conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000) else { return }
        if let last = lastFire[conv.id], Date().timeIntervalSince(last) < 2 { return }
        lastFire[conv.id] = Date()

        let d = UserDefaults.standard
        if d.object(forKey: "notif.inAppVibrate") as? Bool ?? true {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        if d.object(forKey: "notif.inAppSound") as? Bool ?? true {
            playTone()
        }
        if d.object(forKey: "notif.inAppPreview") as? Bool ?? true {
            let name = conv.name(for: me)
            banner = Banner(cid: conv.id, title: name.isEmpty ? "New message" : name,
                            hint: hint(conv, me: me), photoUrl: conv.photoUrl(for: me))
            hideWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                withAnimation(.spring(duration: 0.35)) { self?.banner = nil }
            }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: w)
        }
    }

    func dismiss() {
        hideWork?.cancel()
        withAnimation(.spring(duration: 0.3)) { banner = nil }
    }

    private func hint(_ c: Conversation, me: String) -> String {
        let cipher = c.lastMessageCipher
        if cipher.hasPrefix("📷") { return "Photo" }
        if cipher.hasPrefix("🎥") || cipher.hasPrefix("🎬") { return "Video" }
        if cipher.hasPrefix("🎤") { return "Voice message" }
        if cipher.hasPrefix("📄") { return "Document" }
        let t = c.isGroup
            ? Crypto.shared.decryptGroupCached(cipher, cid: c.id, authorId: c.lastSender)
            : Crypto.shared.decryptCached(cipher, cid: c.id)
        return t.isEmpty ? "New message" : t
    }

    /// Play the user's chosen notification tone (Settings > Notifications > Sound).
    /// Also used by the sound picker to preview a tone before choosing it.
    func playTone(_ override: String? = nil) {
        var name = override ?? (UserDefaults.standard.string(forKey: "notif.sound") ?? "rebound")
        // A "default" stored before the Apple-tone option was removed. It used to fall through to
        // system sound 1007, which is Note — iMessage's tone coming out of Kulan.
        if name == "default" { name = "rebound" }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            AudioServicesPlaySystemSound(1007)   // last resort: a missing file must still make a noise
            return
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.8
        player?.play()
    }
}

// The floating top banner. Tap opens the chat via the same route a push-notification
// tap uses (AppRouter.pendingChatId — MainShell foregrounds the Chats tab and pushes).
struct InAppBannerView: View {
    let banner: InAppNotify.Banner

    var body: some View {
        Button {
            InAppNotify.shared.dismiss()
            AppRouter.shared.pendingChatName = banner.title
            AppRouter.shared.pendingChatPhoto = banner.photoUrl
            AppRouter.shared.pendingChatId = banner.cid
        } label: {
            HStack(spacing: 10) {
                AvatarView(name: banner.title, photoUrl: banner.photoUrl, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Text(banner.hint).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

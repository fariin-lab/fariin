import FirebaseAuth
import UIKit
import WidgetKit

/// The app's half of the Home Screen widgets (`Shared/WidgetShared.swift`): keeps the snapshot and
/// the faces in the App Group, and asks iOS to redraw when something the widgets show has changed.
/// With App Lock on nothing is written but the lock itself. Unanswered requests stay off the Home
/// Screen, the same as blocked and archived chats.
@MainActor enum WidgetShare {
    private static var pending = false
    private static var last: WidgetShared.Snapshot?
    private static var observer: NSObjectProtocol?

    /// Something changed. At most once every two seconds: both sources fire on every small update.
    static func note() {
        if observer == nil {
            // App Lock turned on or off shows here, as the person leaves the app.
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refresh() }
            }
        }
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                pending = false
                refresh()
            }
        }
    }

    /// Sign-out: nothing of this account stays on the Home Screen.
    static func cleared() {
        last = nil
        WidgetShared.write(.init())
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func refresh() {
        guard let me = Auth.auth().currentUser?.uid else { return }
        var s = WidgetShared.Snapshot(signedIn: true)
        s.locked = UserDefaults.standard.bool(forKey: "appLockEnabled")
        if !s.locked {
            let convs = ConversationsRepository.shared.conversations
            s.chats = convs
                .filter { !$0.isCleared(me) && !$0.isArchived(me) && !$0.isBlockedByMe(me)
                    && !MessageRequests.isUnansweredRequest($0) }
                .sorted { $0.updatedAtMillis > $1.updatedAtMillis }
                .prefix(4)
                .map { .init(id: $0.id, name: $0.displayName(me), photo: $0.displayPhoto(me) ?? $0.avatarUrl,
                             channel: $0.isChannel) }
            let others = StoriesRepository.shared.others
            s.stories = others.filter { $0.hasUnseen }.prefix(3).map { g in
                .init(id: g.authorUid, name: g.name, photo: g.photoUrl, unseen: true,
                      channel: g.groupConvId.map { id in convs.first { $0.id == id }?.isChannel ?? false } ?? false)
            }
            if s.stories.count < 3 {
                s.stories += others.filter { !$0.hasUnseen }.prefix(3 - s.stories.count).map {
                    .init(id: $0.authorUid, name: $0.name, photo: $0.photoUrl)
                }
            }
            if let p = ProfileStore.shared.me {
                s.me = .init(id: me, name: p.name, photo: p.photoUrl)
            }
        }
        guard s != last else { return }
        last = s
        let snap = s
        Task.detached(priority: .utility) {
            await saveFaces(snap)   // first, so the redraw has them
            WidgetShared.write(snap)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    nonisolated private static func saveFaces(_ s: WidgetShared.Snapshot) async {
        for url in ([s.me] + s.chats + s.stories).compactMap({ $0?.photo }) {
            guard let f = NotifShared.avatarFile(url), !FileManager.default.fileExists(atPath: f.path)
            else { continue }
            if url.hasPrefix("fariin-photo://") {
                _ = await ProfilePhotoLoader.shared.avatar(url)   // leaves the copy
            } else if url.hasPrefix("https://"), let u = URL(string: url),
                      let (d, _) = try? await URLSession.shared.data(from: u) {
                NotifShared.saveAvatar(d, for: url)
            }
        }
    }
}

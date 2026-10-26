import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import StoryUI

/// GET NOTIFICATIONS FOR ONE PERSON'S STORIES — owner, 2026-10-16: "by default always need to click
/// Get notifications if you want to get that user every time upload story notification, but never
/// one button to open all users". The reference app's "Notify About Stories", per person.
///
/// Off for everybody until it is turned on for someone, and there is deliberately no switch for
/// everybody at once. Each person turned on is one document `{at, author}` at
/// `users/{me}/storyNotify/{them}`, which only I can read (firestore.rules), so nobody can learn who
/// follows their stories. The push itself is the server's (`onStoryCreated` → `notifyStoryFollowers`):
/// it goes only to people the story was sent to, and never to someone who has blocked the author.
@MainActor @Observable
final class StoryNotifyStore {
    static let shared = StoryNotifyStore()
    private init() {}

    /// The authors whose new stories notify this account.
    private(set) var on: Set<String> = []
    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var loadingFor: String?

    /// Read by the story menu while it draws, so it only ever SCHEDULES the load: writing observed
    /// state in the middle of a view update is not allowed.
    func isOn(_ author: String) -> Bool {
        let me = Auth.auth().currentUser?.uid
        if me != loadedFor, me != loadingFor { Task { await load() } }
        // Not gated on `loadedFor`: a bell turned on before the list arrived must read as on.
        return me != nil && on.contains(author)
    }

    /// Turns it on or off for `author` and answers the new state. The menu changes at once; a write
    /// the server refuses puts it back.
    @discardableResult
    func toggle(_ author: String) -> Bool {
        guard let me = Auth.auth().currentUser?.uid, !author.isEmpty, author != me else { return false }
        let ref = FirestoreHub.db.collection("users").document(me)
            .collection("storyNotify").document(author)
        if on.contains(author) {
            on.remove(author)
            ref.delete { err in
                guard err != nil else { return }
                Task { @MainActor in if Auth.auth().currentUser?.uid == me { StoryNotifyStore.shared.on.insert(author) } }
            }
            return false
        }
        on.insert(author)
        // `author` is how the server finds this follow (stories carry hashed audiences, not uids).
        ref.setData(["at": FieldValue.serverTimestamp(), "author": author]) { err in
            guard err != nil else { return }
            Task { @MainActor in if Auth.auth().currentUser?.uid == me { StoryNotifyStore.shared.on.remove(author) } }
        }
        return true
    }

    private func load() async {
        guard let me = Auth.auth().currentUser?.uid else { on = []; loadedFor = nil; return }
        loadingFor = me
        defer { if loadingFor == me { loadingFor = nil } }
        // Another account's list goes the moment the account changes, not when this one arrives.
        if loadedFor != me { on = []; loadedFor = nil }
        guard let snap = try? await FirestoreHub.db.collection("users").document(me)
            .collection("storyNotify").getDocuments(),
              Auth.auth().currentUser?.uid == me else { return }
        // Union, not replace: one tapped while this was on its way is already in `on` and its write
        // may not be in the snapshot yet.
        on.formUnion(snap.documents.map(\.documentID))
        loadedFor = me
    }

    /// The story menu's question, answered for the viewer package. Nil = not offered: my own story
    /// and the official account.
    static func installSeam() {
        // Asked from the menu's body, which is always the main thread.
        StoryNotifySeam.isOn = { author in
            MainActor.assumeIsolated {
                guard !author.isEmpty, author != Auth.auth().currentUser?.uid,
                      !OfficialChannel.isOfficial(author) else { return nil }
                return StoryNotifyStore.shared.isOn(author)
            }
        }
        StoryGroupStaffSeam.isStaff = { key in
            MainActor.assumeIsolated { GroupStoryStaff.isStaff(ringKey: key) }
        }
    }
}

/// The story viewer's "Get notifications" / "Mute notifications" tap, and the bar that confirms it:
/// the reference's, as on the owner's screenshots (2026-10-16): bell or slashed bell on the left,
/// the name in bold, just above the reply field. A modifier of its own because the viewer's chain
/// is already at the type-checker's limit; its toast state lives here, not on the viewer.
struct StoryNotifyMenuAction: ViewModifier {
    /// The author on screen and their name, or nil when the tap does not apply (my own story).
    let author: () -> (uid: String, name: String)?
    @State private var toast: (on: Bool, name: String)?
    @State private var seq = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .init("storyActionNotify"))) { _ in
                guard let a = author() else { return }
                let on = StoryNotifyStore.shared.toggle(a.uid)
                seq += 1
                let mine = seq
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toast = (on, a.name) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard mine == seq else { return }   // a newer tap keeps its own 3s
                    withAnimation(.easeOut(duration: 0.2)) { toast = nil }
                }
            }
            .overlay(alignment: .bottom) {
                if let t = toast { StoryNotifyBar(on: t.on, name: t.name) }
            }
    }
}

private struct StoryNotifyBar: View {
    let on: Bool
    let name: String

    private var message: Text {
        on ? Text("You will receive a notification whenever ") + Text(name).fontWeight(.semibold) + Text(" posts a story.")
           : Text("You will no longer receive a notification when ") + Text(name).fontWeight(.semibold) + Text(" posts a story.")
    }

    /// ⛔ THE REFERENCE APP'S UNDO TOAST, BY ITS NUMBERS — owner 2026-10-16: "wrong size and wrong
    /// position, make it exactly like theirs". Read from its `UndoOverlayControllerNode`: 12 from
    /// each screen edge (`margin`), at least 50 tall with the text centred (`contentHeight = 20 +
    /// text`, `max(50, …)`), corner 25 continuous, the icon centred in the first 50 (`leftInset`),
    /// text from 50 to 16 short of the right (`rightInset`), 14pt regular white with the name
    /// semibold, on a dark blur. Bottom-anchored `margin` above the bottom inset, which in the story
    /// viewer is the message bar: 12 above it.
    private static var bottomInset: CGFloat {
        let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return max(10, w?.safeAreaInsets.bottom ?? 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: on ? "bell.fill" : "bell.slash.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 50)
            message
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
        }
        .frame(minHeight: 50)
        .background {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(.regularMaterial)
                .environment(\.colorScheme, .dark)
        }
        .padding(.horizontal, 12)
        // The message bar: 44 tall, 16 above the bottom inset (`MessageView`), then 12 more.
        .padding(.bottom, Self.bottomInset + 16 + 44 + 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

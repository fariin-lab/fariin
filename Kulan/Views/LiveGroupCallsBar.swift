import SwiftUI
import FirebaseFirestore

// ⛔ LIVE GROUP CALLS ON THE CALLS TAB (owner 2026-10-20: "a group I'm in has a call going; show it
// on the Calls page with Join, minimal, our own design"). One quiet row per live call: the group's
// photo with a small green live dot, its name, "Live · N joined" with the first faces, and a Join
// capsule. Read from each of my groups' own call document (the rules allow a member to read it;
// there is no cross-group query), for the most recent groups only.

@MainActor @Observable
final class LiveGroupCalls {
    static let shared = LiveGroupCalls()

    struct Live: Identifiable, Equatable {
        let id: String          // the group's cid
        let video: Bool
        let joined: [String]    // uids that came in (the call doc's own list)
    }

    private(set) var calls: [Live] = []
    @ObservationIgnored private var regs: [String: ListenerRegistration] = [:]
    @ObservationIgnored private var byCid: [String: Live] = [:]
    /// Enough to cover the groups anyone is actually in a call with; listeners are cheap but not free.
    private static let cap = 40

    /// Follows the chat list's groups. Called when the Calls tab shows and when the list changes.
    func sync(groups: [Conversation]) {
        let want = Set(groups.filter(\.isGroup).prefix(Self.cap).map(\.id))
        for (cid, r) in regs where !want.contains(cid) {
            r.remove(); regs[cid] = nil; byCid[cid] = nil
        }
        for cid in want where regs[cid] == nil {
            regs[cid] = Firestore.firestore().collection("groupCalls").document(cid)
                .addSnapshotListener { [weak self] snap, _ in
                    Task { @MainActor in self?.apply(cid, snap?.data()) }
                }
        }
        publish()
    }

    private func apply(_ cid: String, _ d: [String: Any]?) {
        var active = (d?["active"] as? Bool) ?? false
        // The chat's zombie guard: a call doc older than 4 hours is not live.
        if active, let ts = d?["startedAt"] as? Timestamp, Date().timeIntervalSince(ts.dateValue()) > 4 * 3600 {
            active = false
        }
        byCid[cid] = active ? Live(id: cid, video: (d?["video"] as? Bool) ?? false,
                                   joined: d?["joined"] as? [String] ?? []) : nil
        publish()
    }

    private func publish() {
        let next = byCid.values.sorted { $0.id < $1.id }
        if next != calls { calls = next }
    }

    /// Sign-out.
    func stopAll() {
        regs.values.forEach { $0.remove() }
        regs = [:]; byCid = [:]; calls = []
    }
}

/// One live call: photo + live dot, name, "Live · N joined" with faces, Join.
struct LiveGroupCallRow: View {
    let live: LiveGroupCalls.Live
    let conv: Conversation?
    let onJoin: () -> Void

    private var title: String { conv?.title ?? "Group" }
    private var me: String { AuthService.shared.uid ?? "" }
    private var faces: [String] { Array(live.joined.filter { $0 != me }.prefix(3)) }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: title, photoUrl: conv?.avatarUrl, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(Color.green).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if !faces.isEmpty {
                        HStack(spacing: -6) {
                            ForEach(faces, id: \.self) { uid in
                                AvatarView(name: conv?.names[uid] ?? "", photoUrl: conv?.photos[uid], size: 18)
                                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                            }
                        }
                    }
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: onJoin) {
                Label("Join", systemImage: live.video ? "video.fill" : "phone.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Capsule().fill(Color.green))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Join call in \(title)")
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let n = live.joined.count
        let kind = live.video ? "Video call" : "Voice call"
        return n > 0 ? "\(kind) · \(n) joined" : kind
    }
}

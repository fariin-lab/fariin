import SwiftUI
import FirebaseFirestore
import FirebaseFunctions

// ⛔ LIVE GROUP CALLS ON THE CALLS TAB (owner 2026-10-20: "a group I'm in has a call going; show it
// on the Calls page with Join, minimal, our own design"). One quiet row per live call: the group's
// photo with a small green live dot, its name, "Voice call · Live", and a Join
// capsule. Read from each of my groups' own call document (the rules allow a member to read it;
// there is no cross-group query), for the most recent groups only.

@MainActor @Observable
final class LiveGroupCalls {
    static let shared = LiveGroupCalls()
    private init() {
        // 2026-10-20 (owner): the Firestore client froze and `FirestoreHub` swapped in a fresh one.
        // Every group's call listener belongs to the stuck client: let them go off the main thread and
        // follow the same groups on the new one. The rows already shown stay until it answers.
        NotificationCenter.default.addObserver(forName: FirestoreHub.swapped, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let live = LiveGroupCalls.shared
                let cids = Array(live.regs.keys)
                FirestoreHub.drop(live.regs.values.map { Optional($0) })
                live.regs = [:]
                cids.forEach { live.attach($0) }
            }
        }
    }

    struct Live: Identifiable, Equatable {
        let id: String          // the group's cid
        let video: Bool
        let joined: [String]    // uids that came in (the call doc's own list)
        var startedAt: Date? = nil
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
        for cid in want where regs[cid] == nil { attach(cid) }
        publish()
    }

    private func attach(_ cid: String) {
        regs[cid] = FirestoreHub.db.collection("groupCalls").document(cid)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in self?.apply(cid, snap?.data()) }
            }
    }

    private func apply(_ cid: String, _ d: [String: Any]?) {
        // A snapshot queued before `sync` dropped this group must not put it back (audit).
        guard regs[cid] != nil else { return }
        // B11 (2026-10-23): no 4-hour guard on the phone's clock (it hid real long calls); the
        // server's sweep closes a doc whose media room is empty, and that write arrives here.
        let active = (d?["active"] as? Bool) ?? false
        byCid[cid] = active ? Live(id: cid, video: (d?["video"] as? Bool) ?? false,
                                   joined: d?["joined"] as? [String] ?? [],
                                   startedAt: (d?["startedAt"] as? Timestamp)?.dateValue()) : nil
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
    /// A4 (2026-10-23): the row of the call I am in says RETURN (the tap brings it back), not JOIN.
    @ObservedObject private var service = GroupCallService.shared
    private var isMine: Bool { service.activeCid == live.id }

    /// Who is in it, from the media server (groupCallPeek), asked while the row is on screen.
    @State private var people: [String] = []
    /// owner 2026-10-23: the faces and the count came in late (the first peek is a network round
    /// trip after the row appears). The row now starts from the last peek of this call, or else the
    /// call document's own `joined` list, and the peek corrects it.
    @MainActor private static var lastPeek: [String: [String]] = [:]
    private var shownPeople: [String] { people.isEmpty ? (Self.lastPeek[live.id] ?? live.joined) : people }

    private var title: String { conv?.title ?? "Group" }

    // ⛔ THE CHAT'S CALL BAR, AS A ROW (owner 2026-10-20: "exactly like this, in the chat and in the
    // call list"): the group, "Video Chat · 4 participants", the faces of who is in it, green JOIN.
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: title, photoUrl: conv?.avatarUrl, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(Color.green).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            faces
            // Owner 2026-10-28: blue liquid glass (was a flat green pill). The glass sits on the pill
            // and the button stays plain: a styled button in a List row turns the WHOLE row into it,
            // so a tap anywhere on the row would join the call.
            Button(action: onJoin) {
                Text(isMine ? "RETURN" : "JOIN")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 32)
                    .glassEffect(.regular.tint(Color.fariinBlue).interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMine ? "Return to the call in \(title)" : "Join the call in \(title)")
        }
        .padding(.vertical, 4)
        .task(id: live.id) { await follow() }
    }

    private var subtitle: String {
        let kind = live.video ? "Video Chat" : "Voice Chat"
        switch shownPeople.count {
        case 0: return kind
        case 1: return "\(kind) · 1 participant"
        default: return "\(kind) · \(shownPeople.count) participants"
        }
    }

    @ViewBuilder private var faces: some View {
        if !shownPeople.isEmpty {
            HStack(spacing: -8) {
                ForEach(Array(shownPeople.prefix(3).enumerated()), id: \.element) { i, uid in
                    AvatarView(name: conv?.names[uid] ?? "", photoUrl: conv?.photos[uid], size: 26)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                        .zIndex(Double(3 - i))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func follow() async {
        let fn = Functions.functions(region: "me-central1").httpsCallable("groupCallPeek")
        while !Task.isCancelled {
            if let r = try? await fn.call(["cid": live.id]), let d = r.data as? [String: Any],
               let list = d["people"] as? [[String: Any]] {
                let uids = list.compactMap { $0["uid"] as? String }
                Self.lastPeek[live.id] = uids
                if uids != people { people = uids }
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }
}


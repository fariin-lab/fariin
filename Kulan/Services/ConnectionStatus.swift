import Foundation
import SwiftUI
import Network
import Observation
import FirebaseAuth
import FirebaseFirestore

// ⛔ THE TITLE SAYS WHETHER WE ARE CONNECTED — owner, 2026-09-16, with the reference app's header
// ringed in pen: a small spinner where the title is, and the word "Connecting".
//
// ── WHY THIS IS NOT A PORT ─────────────────────────────────────────────────────────────────────
//
// The reference app owns its transport, so it can name a connection state exactly: it is dialling,
// it has a socket, it is waiting on a reply. We are on Firestore, which deliberately hides all of
// that — it queues writes, serves from cache and reconnects on its own, and there is no "are you
// connected" to ask it. Copying their state machine would mean inventing states we cannot observe.
//
// So this reports the two facts we CAN observe, and says only what each one honestly supports:
//
//   · `NWPathMonitor`  — is there a route off this device at all. Definitive, and the one case where
//                        "Waiting for network" is a true statement rather than a guess.
//   · Firestore's `metadata.isFromCache`, from ONE listener that asks for metadata changes — see
//                        the correction below. Cache while the path is up is exactly "we are online
//                        and the server has not answered yet", which is what "Connecting" means.
//
// ⛔ THE FIRST VERSION OF THIS SHIPPED IN 747 AND STUCK ON "Connecting" — his screenshot, a fully
// loaded chat list under a spinner that never cleared. The mistake is worth keeping written down.
//
// It fed off `noteSnapshot(fromCache:)` calls from the listeners the app ALREADY runs, on the
// reasoning that a new listener would be a read per reconnect for a label. **But a Firestore
// listener does not deliver metadata-only changes unless it was created with
// `includeMetadataChanges: true`.** Those listeners use the default. So the app heard "from cache"
// during launch and then NEVER heard "from the server", because when the server confirms data that
// has not changed, no callback is delivered at all. On a quiet chat list nothing could ever clear
// the label.
//
// ⚠️ THE SIGNAL HAS TO BE ONE THAT REPORTS THE CONNECTION, not one that reports data. This now
// watches a single document with `includeMetadataChanges: true`, which is the documented way to be
// told when Firestore's view of the server changes. It is one document, it is the user's own, and
// the app is signed in to it anyway — the cost is a listener, not a read per reconnect.
//
// ⚠️ `noteSnapshot(fromCache:)` IS KEPT and the existing callers still feed it. It can only ever
// produce good news now (a server snapshot proves reachability), and good news needs no metadata
// change to be true.
//
// ⚠️ AND IT NEVER SAYS "CONNECTING" ON THE FIRST FRAME. A cold launch legitimately serves from cache
// for a moment, and a header that flashes "Connecting" every time the app opens is noise that
// teaches people to ignore it. `settle` is how long cache-only has to persist before it is worth
// saying out loud; below that the title simply stays the title.
@MainActor
@Observable
final class ConnectionStatus {
    static let shared = ConnectionStatus()

    enum State: Equatable {
        /// The ordinary case: say nothing, the screen shows its own title.
        case online
        /// No route off the device. The phone is in a tunnel, or aeroplane mode is on.
        case waitingForNetwork
        /// There is a route, but what we are being served is still coming off disk.
        case connecting

        /// What the header draws beside its spinner. `nil` means draw the title instead.
        var label: String? {
            switch self {
            case .online: return nil
            case .waitingForNetwork: return "Waiting for network"
            case .connecting: return "Connecting"
            }
        }
    }

    private(set) var state: State = .online

    /// How long the server has to stay silent before the label appears. Long enough that a cold
    /// launch and an ordinary hiccup pass unremarked, short enough to be useful on a bad line.
    private static let settle: TimeInterval = 2.5

    private let monitor = NWPathMonitor()
    private var hasRoute = true          // optimistic until the first path update, as `NetworkState` is
    private var lastServerAnswer = Date()
    private var pending: Task<Void, Never>?
    private var probe: ListenerRegistration?
    private var probeUid: String?
    private var authHandle: AuthStateDidChangeListenerHandle?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.routeChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "ConnectionStatus"))
        // The probe follows the signed-in account, and stops with it: a listener left on the previous
        // user's document is both a leak and a permission error waiting to happen.
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.watch(uid: user?.uid) }
        }
    }

    /// ⛔ THE ONE LISTENER THAT CAN ACTUALLY ANSWER THE QUESTION. `includeMetadataChanges: true` is
    /// the whole point of it: without that flag Firestore stays silent when the only thing that
    /// changed is whether the answer came from the server, which is precisely what this needs to
    /// know. That silence is the 747 bug.
    ///
    /// ⚠️ THE DOCUMENT IS THE USER'S OWN, so it needs no rule of its own and costs one listener on
    /// something the app is already entitled to read.
    private func watch(uid: String?) {
        guard uid != probeUid else { return }
        probe?.remove()
        probe = nil
        probeUid = uid
        guard let uid else { return }
        probe = Firestore.firestore().collection("users").document(uid)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, _ in
                guard let snap else { return }
                Task { @MainActor in self?.noteSnapshot(fromCache: snap.metadata.isFromCache) }
            }
    }

    /// Called by the snapshot listeners the app already runs — one line each, where they already read
    /// `metadata.isFromCache`.
    ///
    /// ⚠️ A SERVER ANSWER IS PROOF AND A CACHED ONE IS NOT. Firestore serves cache for reasons that
    /// have nothing to do with the network (a query it can answer locally, a pending write), so a
    /// cached snapshot only ever starts the clock; it never itself declares us disconnected.
    func noteSnapshot(fromCache: Bool) {
        guard !fromCache else { armSettle(); return }
        lastServerAnswer = Date()
        retryDelay = Self.settle   // 2026-09-24 fix-all #216
        pending?.cancel(); pending = nil
        if hasRoute { state = .online }
    }

    private func routeChanged(_ up: Bool) {
        hasRoute = up
        if !up {
            // No route is knowable immediately and needs no settling period — there is nothing to
            // wait for and saying so at once is the honest thing.
            pending?.cancel(); pending = nil
            state = .waitingForNetwork
            return
        }
        // The route came back. Whether the SERVER is reachable is a separate question, and the next
        // snapshot answers it; until then this is exactly the "connecting" case.
        if state == .waitingForNetwork { state = .connecting }
        armSettle()
    }

    /// Start (or restart) the quiet period after which cache-only becomes something we say out loud.
    private func armSettle() {
        guard hasRoute, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settle))
            guard !Task.isCancelled else { return }
            await self?.settleExpired()
        }
    }

    /// ⛔ SILENCE IS NOT EVIDENCE OF A BROKEN CONNECTION — his report, 2026-09-23: "connection says
    /// connecting sometimes even if i have good internet", on a chat list that had plainly loaded.
    ///
    /// ⚠️ THIS IS THE 747 MISTAKE REACHED FROM THE OTHER END, and it is worth naming because the
    /// fix for 747 is what made it reachable. `routeChanged` calls `armSettle()` on EVERY route-up,
    /// and `NWPathMonitor` reports a path change for things that are not outages at all — an
    /// interface coming or going, a wifi roam, waking from a lock. So a healthy phone arms this
    /// timer, and 2.5 seconds later the old code declared "Connecting" **purely because no snapshot
    /// had arrived in that window**. On an app that synced five minutes ago and is sitting on a
    /// quiet document, no snapshot is ever going to arrive, because there is nothing to send. The
    /// label then stayed up until something unrelated happened to talk to the server.
    ///
    /// The old code did test `lastServerAnswer`, which reads like a guard and is not one: on a quiet
    /// app that value is ALWAYS older than the settle. It only ever caught a snapshot that raced the
    /// timer.
    ///
    /// ⚠️ SO IT ASKS INSTEAD OF ASSUMING. One `source: .server` read of the document the probe is
    /// already watching. It answers the actual question — can we reach the server right now — rather
    /// than inferring it from a quiet listener. Offline, Firestore fails this immediately and
    /// locally without a network attempt, so the cost of being wrong is nothing; online, it costs
    /// one small read on a path blip, which is the honest price of not lying on the header.
    ///
    /// ⚠️ RECOVERY IS STILL THE LISTENER'S JOB, not a poll. The probe carries
    /// `includeMetadataChanges: true`, so when a real connection returns Firestore delivers a
    /// metadata change and `noteSnapshot` puts the state back to `.online`. Nothing here re-arms.
    private func settleExpired() async {
        guard hasRoute else { return }
        pending = nil
        // A server answer may have landed while the timer slept, and `noteSnapshot` would have
        // cancelled us — but a cancellation that loses the race must not leave a stale label.
        guard Date().timeIntervalSince(lastServerAnswer) >= Self.settle else { return }
        // No probe means no account signed in yet, and nothing to ask. Say nothing rather than
        // announcing a connection problem that is really just a launch in progress.
        guard let uid = probeUid else { return }
        do {
            _ = try await Firestore.firestore().collection("users").document(uid)
                .getDocument(source: .server)
            lastServerAnswer = Date()
            retryDelay = Self.settle   // 2026-09-24 fix-all #216
            if hasRoute { state = .online }
        } catch {
            if hasRoute { state = .connecting; scheduleRetry() }
        }
    }

    /// 2026-09-24 fix-all #216: a failed probe used to set "Connecting" and arm nothing, so the
    /// header stayed on it until some other listener happened to hear from the server, which on a
    /// quiet account could be never. It now probes again with a doubling wait (2.5s, 5s, 10s, 20s,
    /// then every 30s) until one answers; any server answer resets the wait.
    private var retryDelay: TimeInterval = ConnectionStatus.settle
    private func scheduleRetry() {
        guard hasRoute, pending == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.settleExpired()
        }
    }
}

// ⛔ THE HEADER'S OWN LABEL — his screenshot: a small spinner, then the word, centred where the
// title sits.
//
// ⚠️ `.headline`, MATCHING `navigationTitle`'s INLINE WEIGHT, because this stands in that title's
// place and a different weight reads as a different screen. The spinner is scaled down rather than
// given a frame: a `ProgressView` at full size is taller than the bar's title row and would grow it.
struct ConnectionTitleLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
            Text(text)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        // Announced as one phrase; the spinner is decoration and has nothing to say on its own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// 2026-09-24 fix-all #173: the connection state on EVERY tab's header, not only Chats. Same rule
/// as the Chats header: a `.principal` item replaces the title, so it is added only while there
/// is something to say, and an ordinary header is untouched. Apply it inside the tab's
/// NavigationStack, on the root screen. Decision: a tab whose principal slot already holds a
/// control (the Calls All/Missed pill) gives it up while the status shows, the way the Chats
/// title does; the filter is back the moment the connection is.
/// `suppressed`: the screen's own title owns the slot right now (Select mode's "N Selected", as on
/// the Chats header, or a full-screen photo).
struct ConnectionTitleToolbar: ViewModifier {
    var suppressed = false
    func body(content: Content) -> some View {
        content.toolbar {
            if !suppressed, let status = ConnectionStatus.shared.state.label {
                ToolbarItem(placement: .principal) { ConnectionTitleLabel(text: status) }
            }
        }
    }
}

extension View {
    /// See `ConnectionTitleToolbar`.
    func connectionTitle(suppressed: Bool = false) -> some View {
        modifier(ConnectionTitleToolbar(suppressed: suppressed))
    }
}

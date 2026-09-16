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
            await MainActor.run {
                guard let self, self.hasRoute else { return }
                self.pending = nil
                // Re-checked rather than assumed: a server answer may have landed while this slept,
                // and `noteSnapshot` would have cancelled us — but a cancellation that loses the race
                // must not be able to leave a stale "Connecting" on screen.
                if Date().timeIntervalSince(self.lastServerAnswer) >= Self.settle {
                    self.state = .connecting
                }
            }
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

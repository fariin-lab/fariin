import Foundation
import SwiftUI
import Network
import Observation

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
//   · Firestore's own `metadata.isFromCache` — the listeners the app ALREADY runs report whether the
//                        answer came from the server or from disk. Cache while the path is up is
//                        exactly "we are online and the server has not answered yet", which is what
//                        "Connecting" means.
//
// ⚠️ NO NEW LISTENER AND NO EXTRA READS. `noteSnapshot(fromCache:)` is called from the listeners
// that already test that flag (stories, conversations). Adding a document to watch purely to ask
// "are we up" would be a read per reconnect, per user, for a label.
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

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.routeChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "ConnectionStatus"))
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

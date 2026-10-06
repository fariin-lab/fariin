import SwiftUI
import LiveKit

/// One quiet capsule that sits under the header (owner spec §14: reconnecting, connection lost, poor
/// network, joining and leaving must each be visible without breaking the layout). It is an overlay:
/// the parent places it with `.overlay(alignment: .top)`, so showing or hiding it never moves a tile.
/// Only the most important message shows at a time: lost > reconnecting > my poor network > a
/// join/leave toast.
struct GroupCallStatusBanner: View {
    @ObservedObject var stage: GroupCallStage

    private struct Item: Equatable {
        let text: String
        let spinner: Bool
    }

    // Join/leave toasts.
    @State private var knownNames: [String: String] = [:]   // tile id -> name, remote people only
    @State private var baselineTaken = false
    @State private var pendingJoined: [String] = []
    @State private var pendingLeft: [String] = []
    @State private var toast: String?
    @State private var toastQueue: [String] = []
    @State private var batchTask: Task<Void, Never>?
    @State private var toastTask: Task<Void, Never>?
    // "Lost" only makes sense after we were connected once.
    @State private var wasConnected = false

    private static let toastSeconds: Double = 2
    private static let batchSeconds: Double = 0.5

    private var localPoor: Bool {
        stage.tiles.first(where: { $0.isLocal })?.networkPoor ?? false
    }

    private var item: Item? {
        switch stage.connectionState {
        case .reconnecting:
            return Item(text: "Reconnecting…", spinner: true)
        case .disconnected:
            return wasConnected ? Item(text: "Connection lost", spinner: false) : nil
        default:
            break
        }
        if localPoor { return Item(text: "Poor connection", spinner: false) }
        if let toast { return Item(text: toast, spinner: false) }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let item {
                HStack(spacing: 6) {
                    if item.spinner {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .controlSize(.mini)
                    }
                    Text(item.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.top, 8)
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(GroupCallMotion.fade, value: item)
        .allowsHitTesting(false)
        .onAppear {
            if case .connected = stage.connectionState { wasConnected = true }
            takeBaseline()
        }
        .onChange(of: stage.connectionState) { _, new in
            if case .connected = new { wasConnected = true }
        }
        .onChange(of: stage.tiles.map(\.id)) { _, _ in diffTiles() }
        .onChange(of: item?.text) { _, new in
            // VoiceOver: say what changed; the capsule itself is not focusable noise.
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
        .onDisappear {
            batchTask?.cancel()
            toastTask?.cancel()
        }
    }

    // MARK: - Join / leave

    private func remoteNames() -> [String: String] {
        var map: [String: String] = [:]
        for t in stage.tiles where !t.isLocal { map[t.id] = t.name }
        return map
    }

    /// The people already here when the banner appears are not "joined".
    private func takeBaseline() {
        guard !baselineTaken else { return }
        baselineTaken = true
        knownNames = remoteNames()
    }

    private func diffTiles() {
        guard baselineTaken else { takeBaseline(); return }
        let now = remoteNames()
        let joined = now.keys.filter { knownNames[$0] == nil }
        let left = knownNames.keys.filter { now[$0] == nil }
        if !joined.isEmpty { pendingJoined.append(contentsOf: joined.compactMap { now[$0] }) }
        if !left.isEmpty { pendingLeft.append(contentsOf: left.compactMap { knownNames[$0] }) }
        knownNames = now
        guard !joined.isEmpty || !left.isEmpty else { return }
        // Wait a beat so a burst ("3 people joined") becomes one message.
        batchTask?.cancel()
        batchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.batchSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            flushPending()
        }
    }

    private func flushPending() {
        if let m = message(pendingJoined, verb: "joined") { toastQueue.append(m) }
        if let m = message(pendingLeft, verb: "left") { toastQueue.append(m) }
        pendingJoined = []
        pendingLeft = []
        showNextToast()
    }

    private func message(_ names: [String], verb: String) -> String? {
        switch names.count {
        case 0: return nil
        case 1:
            let n = names[0].trimmingCharacters(in: .whitespaces)
            return "\(n.isEmpty ? "Someone" : n) \(verb)"
        default: return "\(names.count) people \(verb)"
        }
    }

    private func showNextToast() {
        guard toast == nil, !toastQueue.isEmpty else { return }
        toast = toastQueue.removeFirst()
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.toastSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            toast = nil
            showNextToast()
        }
    }
}

import SwiftUI
import LiveKit

/// The one notice that sits under the header (owner spec §14: connection lost, poor network, joining
/// and leaving must each be visible without breaking the layout). It is an overlay: the parent places
/// it at the top of the stage, so showing or hiding it never moves a tile, and it takes no touches.
/// Only the most important message shows at a time: lost > my poor network > a join/leave notice.
/// Reconnecting is the header subtitle's job (owner's header), so the banner stays out of it.
///
/// owner, 2026-10-06: the join/leave notice is the reference app's now. It names the people ("Alice
/// joined", "Alice and Bob joined", "Alice, Bob and 3 others joined"), shows the photo when it is
/// about one person, and slides down from the top, holds, and slides back up. One at a time, joins
/// before leaves.
struct GroupCallStatusBanner: View {
    @ObservedObject var stage: GroupCallStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One remote person, as a notice needs them.
    private struct Person: Equatable {
        let key: String         // the uid; the tile id when the uid is unknown
        let name: String
        let photoUrl: String?
    }

    private struct Item: Equatable {
        let text: String
        let avatar: Person?     // set when the notice is about exactly one person
        let wide: Bool          // join/leave fills the width; a connection note stays compact
    }

    // Join/leave notices. People are keyed by uid, not by tile id: someone who drops and comes back
    // gets a new tile id, and must still be recognised as the same person.
    @State private var known: [String: Person] = [:]            // remote people only
    @State private var baselineTaken = false
    @State private var pendingJoined: [String: Person] = [:]
    @State private var pendingLeft: [String: Person] = [:]
    @State private var notice: Item? = nil
    // True from the slide in until the slide out has finished: one banner at a time.
    @State private var presenting = false
    @State private var batchTask: Task<Void, Never>? = nil
    @State private var noticeTask: Task<Void, Never>? = nil
    // "Lost" only makes sense after we were connected once.
    @State private var wasConnected = false

    private static let holdSeconds: Double = 2
    private static let batchSeconds: Double = 0.5

    /// Written out so the call site `GroupCallStatusBanner(stage:)` does not depend on what the
    /// synthesized initializer makes of the private state above.
    init(stage: GroupCallStage) {
        _stage = ObservedObject(wrappedValue: stage)
    }

    private static func nanos(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }

    private var localPoor: Bool {
        stage.tiles.first(where: { $0.isLocal })?.networkPoor ?? false
    }

    private var item: Item? {
        switch stage.connectionState {
        case .reconnecting:
            // The header's subtitle already says "Reconnecting…" (owner's header); a second line
            // saying the same, or a poor-network note on top of it, is noise.
            return nil
        case .disconnected:
            // Lost only while the call is still on. My own hang-up, or the screen closing, also
            // ends in .disconnected: the service is then leaving, or already has no call.
            let service = GroupCallService.shared
            guard wasConnected, service.isActive, !service.leaving else { return nil }
            return Item(text: "Connection lost", avatar: nil, wide: false)
        default:
            break
        }
        if localPoor { return Item(text: "Poor connection", avatar: nil, wide: false) }
        return notice
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let item {
                card(item)
                    .padding(.top, 8)
                    .transition(GroupCallNoticeMotion.entry(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(GroupCallNoticeMotion.slide(reduceMotion: reduceMotion), value: item)
        .allowsHitTesting(false)
        .onAppear {
            if case .connected = stage.connectionState { wasConnected = true }
            takeBaseline()
        }
        .onChange(of: stage.connectionState) { old, new in
            // The header subtitle shows "Reconnecting…" but a subtitle change is not spoken; the
            // banner draws nothing for it, so VoiceOver hears it from here (spec §14, §16).
            if new == .reconnecting && old != .reconnecting {
                AccessibilityNotification.Announcement("Reconnecting").post()
            }
            if case .connected = new {
                wasConnected = true
                // The people the room hands me on (re)connect were already there: they are the new
                // baseline, not a "5 people joined" notice on my own join.
                if old != .connected { known = remotePeople() }
            }
        }
        // The whole tile, not only its id: a name or a photo that arrives a moment after the person
        // does must reach `known`, or the notice about them leaving would say "Member left".
        .onChange(of: stage.tiles) { _, _ in diffTiles() }
        .onChange(of: item?.text) { _, new in
            // VoiceOver: say what changed; the banner itself is not focusable noise.
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
        .onDisappear { reset() }
    }

    private func card(_ item: Item) -> GroupCallNoticeCard {
        let avatar = item.avatar.map { GroupCallNoticeCard.Avatar(name: $0.name, photoUrl: $0.photoUrl) }
        return GroupCallNoticeCard(text: item.text, avatar: avatar, wide: item.wide)
    }

    // MARK: - Join / leave

    private func remotePeople() -> [String: Person] {
        var map: [String: Person] = [:]
        for t in stage.tiles where !t.isLocal {
            let key = t.uid.isEmpty ? t.id : t.uid
            map[key] = Person(key: key, name: t.name, photoUrl: t.photoUrl)
        }
        return map
    }

    /// The people already here when the banner appears are not "joined".
    private func takeBaseline() {
        guard !baselineTaken else { return }
        baselineTaken = true
        known = remotePeople()
    }

    private func diffTiles() {
        guard baselineTaken else { takeBaseline(); return }
        let now = remotePeople()
        // Only while connected: before the first connect the room is filling in, and during a
        // reconnect it empties and refills, which is nobody joining or leaving.
        guard wasConnected, stage.connectionState == .connected else { known = now; return }
        var changed = false
        for (key, person) in now where known[key] == nil {
            // Left and came back before the notice went out: the two cancel, nothing is shown.
            if pendingLeft.removeValue(forKey: key) == nil { pendingJoined[key] = person }
            changed = true
        }
        for (key, person) in known where now[key] == nil {
            // Joined and left again before the notice went out: the same, the other way round.
            if pendingJoined.removeValue(forKey: key) == nil { pendingLeft[key] = person }
            changed = true
        }
        known = now
        // Wait a beat so a burst ("Alice, Bob and 3 others joined") becomes one notice. A fixed
        // window from the first change, never restarted: a steady stream of changes cannot hold
        // the notice back for ever.
        guard changed, batchTask == nil else { return }
        batchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.nanos(Self.batchSeconds))
            if Task.isCancelled { return }
            batchTask = nil
            presentNext()
        }
    }

    /// Shows the next notice if nothing is on screen: everyone who joined, else everyone who left.
    /// Whatever arrives while a notice is up stays pending (and can still cancel out) until it has
    /// gone. Both tasks end here, so pending people always have something that will show them.
    private func presentNext() {
        guard !presenting, batchTask == nil else { return }
        let next: Item
        if !pendingJoined.isEmpty {
            // The freshest name and photo: they often arrive a moment after the person does.
            let people = pendingJoined.values.map { known[$0.key] ?? $0 }
            pendingJoined = [:]
            next = Self.makeNotice(people, verb: "joined")
        } else if !pendingLeft.isEmpty {
            let people = Array(pendingLeft.values)
            pendingLeft = [:]
            next = Self.makeNotice(people, verb: "left")
        } else {
            return
        }
        presenting = true
        notice = next
        noticeTask = Task { @MainActor in
            // Slide in, hold, slide out (the reference app's 0.35s / 2s / 0.35s), then the next one.
            try? await Task.sleep(nanoseconds: Self.nanos(GroupCallNoticeMotion.slideSeconds + Self.holdSeconds))
            if Task.isCancelled { return }
            notice = nil
            try? await Task.sleep(nanoseconds: Self.nanos(GroupCallNoticeMotion.slideSeconds))
            if Task.isCancelled { return }
            noticeTask = nil
            presenting = false
            presentNext()
        }
    }

    /// "Alice joined" / "Alice and Bob joined" / "Alice, Bob and 3 others joined", names A to Z.
    private static func makeNotice(_ people: [Person], verb: String) -> Item {
        let sorted = people.sorted { a, b in
            let order = shownName(a.name).localizedCaseInsensitiveCompare(shownName(b.name))
            if order != .orderedSame { return order == .orderedAscending }
            return a.key < b.key
        }
        let names = sorted.map { shownName($0.name) }
        let text: String
        switch names.count {
        case 0:
            text = "Someone \(verb)"    // not reached: the callers pass at least one person
        case 1:
            text = "\(names[0]) \(verb)"
        case 2:
            text = "\(names[0]) and \(names[1]) \(verb)"
        default:
            let others = names.count - 2
            let word = others == 1 ? "other" : "others"
            text = "\(names[0]), \(names[1]) and \(others) \(word) \(verb)"
        }
        return Item(text: text, avatar: sorted.count == 1 ? sorted[0] : nil, wide: true)
    }

    private static func shownName(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Someone" : n
    }

    /// The banner left the screen: its tasks stop with it, so nothing may stay half shown. Without
    /// this a cancelled task would leave `presenting` set and no later notice could ever show. The
    /// next appearance takes a fresh baseline, so whoever came or went meanwhile is not announced late.
    private func reset() {
        batchTask?.cancel()
        batchTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        presenting = false
        notice = nil
        pendingJoined = [:]
        pendingLeft = [:]
        baselineTaken = false
    }
}

// MARK: - The shared look

/// The look every notice at the top of the call shares (the reference app's banner): semibold white
/// text on a dark blur, corner 8, at least 44pt tall, a 40pt photo when it is about one person.
/// `wide` fills the width (up to 512pt) with the text leading, as the reference app's notices do. The
/// two connection notes pass `wide: false` and hug their text: they can sit over the video for a
/// long time. Used by `GroupCallStatusBanner` and by `GroupCallTopToast` (GroupCallSocialViews.swift).
struct GroupCallNoticeCard: View {
    struct Avatar: Equatable {
        let name: String
        let photoUrl: String?
    }

    let text: String
    var avatar: Avatar? = nil
    var wide: Bool = true

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        HStack(spacing: 12) {
            if let avatar {
                AvatarView(name: avatar.name, photoUrl: avatar.photoUrl, size: 40)
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                // Long names, or large Dynamic Type: wrap, shrink a little, rather than cut a name off.
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
            if wide { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .frame(maxWidth: wide ? 512 : nil)
        .background(backdrop)
        .padding(.horizontal, 16)
        // The reference app clamps this text too: a notice must not grow to cover the stage.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// Dark whatever the app's appearance is (the call screen is dark): the blur is forced dark and
    /// a little black sits on it, so white text stays readable over a bright camera picture.
    private var backdrop: some View {
        ZStack {
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            shape.fill(Color.black.opacity(0.4))
        }
    }
}

/// How the top notices come and go: down from the top in 0.35s and back up (the reference app's
/// numbers). With Reduce Motion on nothing slides, the notice fades.
enum GroupCallNoticeMotion {
    static let slideSeconds: Double = 0.35

    static func slide(reduceMotion: Bool) -> Animation {
        reduceMotion ? GroupCallMotion.fade : .easeInOut(duration: slideSeconds)
    }

    /// Fades as it slides: the notice starts its own height higher up, which is over the header.
    static func entry(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : AnyTransition.move(edge: .top).combined(with: .opacity)
    }
}

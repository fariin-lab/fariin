import SwiftUI

// GROUP CALL DEMO STAGE (owner, 2026-10-07). The real stage views (GroupCallGridView, FocusView,
// StripView, StagePager, SelfView) take a `GroupCallStage`, which needs a LiveKit room, so they are
// twinned here. Each twin follows the real one's numbers by calling the same pure pieces:
// `GroupCallPriority.ranked / newestFirst`, `GroupCallLayoutEngine.grid / capacity`,
// `GroupCallMetrics`, `GroupCallMotion`, `GroupCallStripView.height`, `GroupCallSelfView.size`.
//
// The tile itself IS the real `GroupCallTileView` for every state without a picture (camera off,
// connecting spinner, "Can't show video", muted badge, network glyph, raised hand, speaker border).
// A camera that is on has no LiveKit track here, so that one state is drawn by `DemoVideoTile`: a
// moving gradient with the person's avatar, plainly a stand-in, wearing the same badges.

// MARK: - One tile

struct DemoTileView: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    let tile: CallTile
    let style: CallTileStyle
    let isActiveSpeaker: Bool
    let isPinned: Bool
    var onTap: () -> Void

    var body: some View {
        Group {
            if tile.hasVideo && !tile.isConnecting && !tile.videoUnavailable {
                DemoVideoTile(tile: tile, style: style, isActiveSpeaker: isActiveSpeaker,
                              mirrored: tile.isLocal && engine.frontCamera, onTap: onTap)
            } else {
                // The real tile, fed a demo CallTile and no track (= its camera-off look).
                GroupCallTileView(tile: tile, track: nil, style: style,
                                  isActiveSpeaker: isActiveSpeaker, isPinned: isPinned,
                                  onTap: onTap, menu: nil)
            }
        }
        .modifier(DemoTileMenu(tile: tile))
    }
}

/// The long-press menu: Pin / Unpin, and for someone I may act on, Mute, Make admin, Remove…,
/// Remove and Block…. The real menu (`CallTileMenu`) has no block or role items, so this is ours.
private struct DemoTileMenu: ViewModifier {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    let tile: CallTile

    @ViewBuilder
    func body(content: Content) -> some View {
        if tile.isLocal {
            content
        } else {
            content.contextMenu {
                DemoPersonActions(id: tile.id, includePin: true)
                    .environmentObject(engine)
            }
        }
    }
}

/// The actions on one person, shared by the tile's long press and the people list.
struct DemoPersonActions: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    let id: String
    let includePin: Bool

    var body: some View {
        let person = engine.person(id)
        Section(person?.name ?? "") {
            if includePin {
                Button { engine.togglePin(id) } label: {
                    Label(engine.pinnedId == id ? "Unpin" : "Pin",
                          systemImage: engine.pinnedId == id ? "pin.slash" : "pin")
                }
            }
            if engine.canModerate(id) {
                if person?.micOn == true {
                    Button { engine.mute(id) } label: { Label("Mute", systemImage: "mic.slash") }
                }
            }
            if engine.canPromote(id) {
                Button { engine.toggleModerator(id) } label: {
                    Label(person?.role == .moderator ? "Remove as Admin" : "Make Admin",
                          systemImage: "person.badge.shield.checkmark")
                }
            }
            if engine.canModerate(id) {
                Button(role: .destructive) { engine.requestRemove(id, block: false) } label: {
                    Label("Remove…", systemImage: "person.fill.xmark")
                }
                Button(role: .destructive) { engine.requestRemove(id, block: true) } label: {
                    Label("Remove and Block…", systemImage: "hand.raised.slash")
                }
            }
        }
    }
}

/// A camera that is on, without a real track: a slow moving gradient and the person's avatar.
struct DemoVideoTile: View {
    let tile: CallTile
    let style: CallTileStyle
    let isActiveSpeaker: Bool
    let mirrored: Bool
    var onTap: () -> Void

    private var corner: CGFloat { style == .alone ? 0 : GroupCallMetrics.tileCorner }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                DemoFakeCamera(name: tile.name, photoUrl: tile.photoUrl, mirrored: mirrored,
                               avatar: GroupCallTileView.avatarSize(width: geo.size.width, height: geo.size.height))
                badges(width: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.green, lineWidth: GroupCallMetrics.speakingBorder)
                .opacity(isActiveSpeaker ? 1 : 0)
                .animation(GroupCallMotion.fade, value: isActiveSpeaker)
        )
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onTapGesture { onTap() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.name), demo camera\(tile.isMuted ? ", muted" : "")")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func badges(width: CGFloat) -> some View {
        let inset: CGFloat = width >= 170 ? 8 : 4
        let compact = style == .pip && width < 60
        ZStack {
            if tile.isMuted && style != .focus {
                glyph("mic.slash.fill", size: compact ? 16 : 28, font: compact ? 9 : 16)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            HStack(spacing: 4) {
                if tile.isHandRaised && style != .focus && style != .pip {
                    CallRaisedHandChip(name: nil)
                }
                if tile.networkPoor && !compact {
                    glyph("wifi.exclamationmark", size: 22, font: 11)
                }
            }
            .padding(inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: style == .focus ? .topTrailing : .topLeading)
        }
    }

    private func glyph(_ name: String, size: CGFloat, font: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.black.opacity(0.5)))
    }
}

/// The stand-in picture: a gradient whose colours drift, the avatar breathing slightly, and a small
/// "DEMO" mark so nobody mistakes it for a real camera.
struct DemoFakeCamera: View {
    let name: String
    let photoUrl: String?
    let mirrored: Bool
    let avatar: CGFloat

    private var seed: Double {
        Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let drift = sin(t / 3) * 0.06
            let hueA = (seed + drift).truncatingRemainder(dividingBy: 1) + (seed + drift < 0 ? 1 : 0)
            let hueB = (hueA + 0.12).truncatingRemainder(dividingBy: 1)
            ZStack {
                LinearGradient(colors: [Color(hue: hueA, saturation: 0.55, brightness: 0.55),
                                        Color(hue: hueB, saturation: 0.65, brightness: 0.25)],
                               startPoint: UnitPoint(x: 0.2 + sin(t / 4) * 0.2, y: 0),
                               endPoint: UnitPoint(x: 0.8, y: 1))
                AvatarView(name: name, photoUrl: photoUrl, size: avatar)
                    .scaleEffect(1 + sin(t * 1.3) * 0.015)
                    .offset(x: sin(t * 0.7) * 3, y: cos(t * 0.9) * 2)
                Text("DEMO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        }
    }
}

// MARK: - The stage (twin of GroupCallStagePager + the screen's duo / alone choice)

struct DemoStageView: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selfExpanded: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .bottomTrailing) {
                content(size: size)
                selfPip(stageSize: size)
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: engine.mode)
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: engine.remoteCount)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let remotes = engine.tiles.filter { !$0.isLocal }
        if engine.tiles.isEmpty {
            Color.clear
        } else if remotes.isEmpty {
            aloneTile(size: size)
        } else if case .focus(let id) = engine.mode {
            DemoFocusView(tileId: id, label: "Pinned")
        } else if remotes.count == 1, let remote = remotes.first {
            duo(remote, size: size)
        } else {
            // Two pages a vertical swipe apart: the grid, then the speaker page (the real pager).
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    DemoGridView().frame(width: size.width, height: size.height)
                    Group {
                        if let id = engine.speakerPageTileId {
                            DemoFocusView(tileId: id, label: nil)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: size.width, height: size.height)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
        }
    }

    private func aloneTile(size: CGSize) -> some View {
        Group {
            if let local = engine.tiles.first(where: { $0.isLocal }) {
                DemoTileView(tile: local, style: .alone, isActiveSpeaker: false, isPinned: false, onTap: {})
            }
        }
        .frame(width: size.width, height: size.height)
        .transition(.opacity)
    }

    /// Two people: the other person large, the 1:1 screen's 18pt corner (GroupCallDuoView).
    private func duo(_ remote: CallTile, size: CGSize) -> some View {
        DemoTileView(tile: remote, style: .grid,
                     isActiveSpeaker: engine.activeSpeakerId == remote.id,
                     isPinned: false,
                     onTap: { engine.togglePin(remote.id) })
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(GroupCallMetrics.inset)
            .frame(width: size.width, height: size.height)
            .transition(.opacity)
    }

    @ViewBuilder
    private func selfPip(stageSize: CGSize) -> some View {
        let remoteCount = engine.remoteCount
        if remoteCount >= 1, let local = engine.tiles.first(where: { $0.isLocal }) {
            let pip = GroupCallSelfView.size(remoteCount: remoteCount, expanded: selfExpanded, stageSize: stageSize)
            DemoTileView(tile: local, style: .pip, isActiveSpeaker: false, isPinned: false,
                         onTap: { selfExpanded.toggle() })
                .frame(width: pip.width, height: pip.height)
                .clipShape(RoundedRectangle(cornerRadius: GroupCallSelfView.corner, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 4)
                .padding(.trailing, GroupCallSelfView.trailingInset)
                .padding(.bottom, GroupCallMetrics.stripInset)
                .animation(reduceMotion ? nil : GroupCallSelfView.resize, value: selfExpanded)
                .animation(reduceMotion ? nil : GroupCallSelfView.resize, value: remoteCount > 1)
        }
    }
}

// MARK: - Grid (twin of GroupCallGridView, same plan)

struct DemoGridView: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var stripReserve: CGFloat { GroupCallStripView.height - GroupCallMetrics.inset }

    var body: some View {
        GeometryReader { geo in
            grid(size: geo.size)
        }
    }

    @ViewBuilder
    private func grid(size: CGSize) -> some View {
        let remotes = engine.tilesWithLiveSpeech.filter { !$0.isLocal }
        let plan = plan(remotes: remotes, size: size)
        let byId = Dictionary(remotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let layout = plan.layout

        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(plan.placed, id: \.self) { id in
                    if let tile = byId[id], let frame = layout.frames[id] {
                        DemoTileView(tile: tile, style: .grid,
                                     isActiveSpeaker: engine.activeSpeakerId == id,
                                     isPinned: engine.pinnedId == id,
                                     onTap: { engine.togglePin(id) })
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .transition(reduceMotion
                                        ? AnyTransition.opacity
                                        : AnyTransition.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
            .frame(width: plan.gridSize.width, height: plan.gridSize.height, alignment: .topLeading)
            .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: layout.frames)

            if !layout.overflow.isEmpty {
                DemoStripView(ids: layout.overflow)
                    .frame(width: size.width, height: GroupCallStripView.height)
                    .padding(.top, -GroupCallMetrics.inset)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(GroupCallMotion.fade, value: layout.overflow.isEmpty)
    }

    private struct Plan {
        var gridSize: CGSize
        var layout: CallGridLayout
        var placed: [String]
    }

    /// The real grid's plan, step for step: rank (REAL priority), reserve the strip if needed,
    /// sticky cells (the placement twin), then the REAL layout engine.
    private func plan(remotes: [CallTile], size: CGSize) -> Plan {
        let ranked = GroupCallPriority.ranked(remotes, focusedId: engine.pinnedId,
                                              speakerId: engine.activeSpeakerId, now: engine.now)
        let fullCapacity = GroupCallLayoutEngine.capacity(in: size)
        let needsStrip = ranked.count > fullCapacity
        let gridSize = CGSize(width: size.width,
                              height: max(0, size.height - (needsStrip ? Self.stripReserve : 0)))
        let capacity = max(0, GroupCallLayoutEngine.capacity(in: gridSize))
        guard size.width > 0, size.height > 0 else {
            return Plan(gridSize: gridSize, layout: GroupCallLayoutEngine.grid(ids: [], in: gridSize), placed: [])
        }
        let cells = engine.gridPlacement(remotes, capacity: capacity)
        let placedSet = Set(cells)
        let ids = cells + ranked.filter { !placedSet.contains($0.id) }.map(\.id)
        let layout = GroupCallLayoutEngine.grid(ids: ids, in: gridSize)
        return Plan(gridSize: gridSize, layout: layout, placed: ids.filter { layout.frames[$0] != nil })
    }
}

// MARK: - Strip (twin of GroupCallStripView)

struct DemoStripView: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ids: [String]

    var body: some View {
        let byId = Dictionary(engine.tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = GroupCallPriority.newestFirst(ids.compactMap { byId[$0] }).map(\.id)
        let pipWidth = GroupCallSelfView.size(remoteCount: engine.remoteCount, expanded: false, stageSize: .zero).width
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: GroupCallMetrics.stripSpacing) {
                ForEach(ordered, id: \.self) { id in
                    if let tile = byId[id] {
                        DemoTileView(tile: tile, style: .strip,
                                     isActiveSpeaker: engine.activeSpeakerId == id,
                                     isPinned: engine.pinnedId == id,
                                     onTap: { engine.togglePin(id) })
                            .frame(width: GroupCallMetrics.stripTile, height: GroupCallMetrics.stripTile)
                    }
                }
            }
            .padding(.leading, GroupCallMetrics.stripLeading)
            .padding(.trailing, pipWidth + GroupCallSelfView.trailingInset + GroupCallMetrics.spacing)
            .padding(.top, GroupCallMetrics.spacing)
            .padding(.bottom, GroupCallMetrics.stripInset)
        }
        .frame(height: GroupCallStripView.height)
        .animation(GroupCallMotion.stage(reduceMotion: reduceMotion), value: ordered)
    }
}

// MARK: - Focus (twin of GroupCallFocusView: one large tile + the strip of everyone else)

struct DemoFocusView: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    let tileId: String
    /// "Pinned" on a pin, nil on the speaker page.
    let label: String?

    var body: some View {
        let others = engine.tiles.filter { !$0.isLocal && $0.id != tileId }.map(\.id)
        VStack(spacing: 0) {
            if let tile = engine.tiles.first(where: { $0.id == tileId }) {
                DemoTileView(tile: tile, style: .focus,
                             isActiveSpeaker: engine.activeSpeakerId == tileId,
                             isPinned: engine.pinnedId == tileId,
                             onTap: { engine.togglePin(tileId) })
                    .clipShape(RoundedRectangle(cornerRadius: GroupCallMetrics.tileCorner, style: .continuous))
                    .overlay(alignment: .topLeading) { focusLabel(tile) }
                    .padding(.horizontal, GroupCallMetrics.inset)
                    .padding(.top, GroupCallMetrics.inset)
                    .padding(.bottom, others.isEmpty ? GroupCallMetrics.inset : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
            if !others.isEmpty {
                DemoStripView(ids: others)
                    .frame(height: GroupCallStripView.height)
            }
        }
    }

    @ViewBuilder
    private func focusLabel(_ tile: CallTile) -> some View {
        if tile.isHandRaised {
            CallRaisedHandChip(name: tile.name)
                .padding(.top, 10).padding(.leading, 10).padding(.trailing, 44)
        } else if let label {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(.top, 10)
                .padding(.leading, 10)
        }
    }
}

// MARK: - Minimized card (twin of GroupFloatingCallWindow's card)

/// The demo call minimized (owner, 2026-10-07: see how a 2, 3 or 10 person call looks minimized).
/// The real card's size, corner, border, shadow and pick rule, copied rather than shared so the
/// real window stays untouched by the demo: ONE person, the last who spoke, their (fake) camera or
/// their photo on a blurred copy of it. Tap goes back, drag moves it and it snaps to a side.
struct DemoMiniCard: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    let onRestore: () -> Void

    private let w: CGFloat = 112
    private let h: CGFloat = 199
    @State private var shownId: String?
    @State private var base: CGSize = .zero
    @State private var dragLive: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            card
                .offset(dragLive)
                .gesture(drag(in: geo.size))
                .onTapGesture(perform: onRestore)
                .padding(.top, 8 + base.height)
                .padding(.trailing, 12 - base.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .onAppear { shownId = picked?.id }
        .onChange(of: picked?.id) { _, id in if let id { shownId = id } }
        .accessibilityLabel("Back to the call")
    }

    /// `GroupFloatingCallWindow.picked`, on the demo's tiles.
    private var picked: CallTile? {
        let others = engine.tiles.filter { !$0.isLocal }
        guard let first = others.first else {
            if engine.cameraOn, let me = engine.tiles.first(where: { $0.isLocal }) { return me }
            return nil
        }
        let speaking = others.filter { engine.speakingIds.contains($0.id) }
        let shown = shownId.flatMap { id in others.first { $0.id == id } }
        if let shown, engine.speakingIds.contains(shown.id) { return shown }
        if let id = engine.activeSpeakerId, let hit = speaking.first(where: { $0.id == id }) { return hit }
        if let loudest = speaking.first { return loudest }
        if let shown { return shown }
        return others.first { $0.hasVideo } ?? first
    }

    private var card: some View {
        Group {
            if let t = picked {
                ZStack {
                    if t.hasVideo {
                        DemoFakeCamera(name: t.name, photoUrl: t.photoUrl, mirrored: false, avatar: 44)
                    } else {
                        TileBackdrop(photoUrl: t.photoUrl)
                        AvatarView(name: t.name, photoUrl: t.photoUrl, size: w - 36)
                    }
                }
                .id(t.id)
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    let ringing = engine.ringing
                    AvatarView(name: ringing.first?.name ?? "Group Call Demo",
                               photoUrl: ringing.first?.photoUrl, size: 54)
                    Text(GroupCallWords.alone(ringing: ringing.map(\.name)))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2).minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
                .background(Color.black)
            }
        }
        .animation(GroupCallMotion.fade, value: picked?.id)
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let (maxLeft, maxDown) = limits(size)
                let x = min(0, max(maxLeft, base.width + v.translation.width))
                let y = min(maxDown, max(0, base.height + v.translation.height))
                dragLive = CGSize(width: x - base.width, height: y - base.height)
            }
            .onEnded { v in
                let (maxLeft, maxDown) = limits(size)
                let thrownX = base.width + v.predictedEndTranslation.width
                let y = min(maxDown, max(0, base.height + v.predictedEndTranslation.height))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    base = CGSize(width: thrownX < maxLeft / 2 ? maxLeft : 0, height: y)
                    dragLive = .zero
                }
            }
    }

    private func limits(_ size: CGSize) -> (CGFloat, CGFloat) {
        (-(size.width - w - 24), max(0, size.height - h - 8 - 76))
    }
}

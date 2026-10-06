import SwiftUI
import LiveKit

// THE STAGE, AS THE SCREEN PLACES IT (owner, 2026-10-06). The reference app's group call has two
// pages one swipe apart: the grid, and under it the speaker page (whoever is speaking large, the
// others in the strip). This is that pager, and it is the one view GroupCallView puts between the
// header and the controls.
//
// It only differs from the screen before it with 2+ other people on the grid. Fewer than 2, or one
// person focused (a pin, a shared screen): exactly what the screen drew itself, the grid or the
// focus view with the same matched-geometry namespace.
//
// A page is built only while part of it is on screen (contract rule: a video view in the hierarchy
// keeps its stream coming). The speaker page does not exist until the swipe starts, and the grid
// page is dropped once the speaker page fills the stage. Each comes back the moment the finger
// moves toward it.
struct GroupCallStagePager: View {
    @ObservedObject var stage: GroupCallStage
    /// The screen's namespace, for the focus view's large tile (nil under Reduce Motion: it fades).
    var namespace: Namespace.ID?

    private var remoteCount: Int {
        stage.tiles.reduce(0) { $1.isLocal ? $0 : $0 + 1 }
    }

    var body: some View {
        ZStack {
            if case .focus(let id) = stage.mode {
                GroupCallFocusView(stage: stage, focusId: id, namespace: namespace)
                    .transition(.opacity)
            } else if remoteCount >= 2 {
                GroupCallStagePages(stage: stage)
                    .transition(.opacity)
            } else {
                GroupCallGridView(stage: stage)
                    .transition(.opacity)
            }
        }
    }
}

/// Where the vertical scroll is, in the four steps the pager cares about.
private enum CallPagerStep: Int {
    case grid = 0       // at rest on the grid page
    case leavingGrid    // between the pages, the grid still the larger part
    case nearSpeaker    // between the pages, the speaker page the larger part
    case speaker        // at rest on the speaker page

    var gridOnScreen: Bool { self != .speaker }
    var speakerOnScreen: Bool { self != .grid }
    var page: Int { rawValue >= CallPagerStep.nearSpeaker.rawValue ? 1 : 0 }

    /// A point of slack at each end: a resting offset is not always a whole number.
    static func at(offset: CGFloat, pageHeight: CGFloat) -> CallPagerStep {
        guard pageHeight > 0 else { return .grid }
        if offset <= 1 { return .grid }
        if offset >= pageHeight - 1 { return .speaker }
        return offset < pageHeight / 2 ? .leavingGrid : .nearSpeaker
    }
}

/// The two pages. Its own view so its scroll state starts fresh (on the grid) every time the pager
/// comes back from a focus or from a two-person call.
private struct GroupCallStagePages: View {
    @ObservedObject var stage: GroupCallStage
    @State private var step: CallPagerStep = .grid
    /// Shown until the first swipe to the speaker page, then never again on this phone.
    @AppStorage("gc.pagerHintDone") private var hintDone = false

    var body: some View {
        GeometryReader { geo in
            pages(size: geo.size)
        }
    }

    private func pages(size: CGSize) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                gridPage(size: size)
                    .frame(width: size.width, height: size.height)
                speakerPage
                    .frame(width: size.width, height: size.height)
            }
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        // Reports only when the step changes (four times a swipe), not on every scrolled point.
        .onScrollGeometryChange(for: CallPagerStep.self,
                                of: { geometry in
                                    CallPagerStep.at(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                                     pageHeight: geometry.containerSize.height)
                                },
                                action: { _, next in moved(to: next) })
    }

    private func moved(to next: CallPagerStep) {
        let previous = step
        guard next != previous else { return }
        step = next
        guard next.page != previous.page else { return }
        // The reference app's light tap as the page changes.
        Haptics.impact(.light)
        // They found the swipe: the hint has done its job.
        if next.page == 1, !hintDone { hintDone = true }
    }

    // MARK: - Pages

    @ViewBuilder
    private func gridPage(size: CGSize) -> some View {
        if step.gridOnScreen {
            GroupCallGridView(stage: stage)
                .overlay { hintLayer(size: size) }
        } else {
            // The speaker page fills the stage: no grid, so no video view off screen.
            Color.clear
        }
    }

    @ViewBuilder
    private var speakerPage: some View {
        if step.speakerOnScreen, let id = stage.speakerPageTileId {
            // No namespace: nothing flies between the pages, the scroll is the movement.
            GroupCallFocusView(stage: stage, focusId: id, namespace: nil, isSpeakerPage: true)
        } else {
            // Not swiped to yet (or swiped away from): nothing built.
            Color.clear
        }
    }

    // MARK: - The one-time hint

    @ViewBuilder
    private func hintLayer(size: CGSize) -> some View {
        if !hintDone {
            hint
                .padding(.bottom, hintBottom(size: size))
                // A layer the size of the page, so its scroll phase runs from 0 (the grid at rest)
                // to -1 (the grid gone): the hint is gone by half way, as the scroll starts.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .scrollTransition(.interactive, axis: .vertical) { content, phase in
                    content.opacity(1 - min(1, abs(phase.value) * 2))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)   // a VoiceOver user scrolls with three fingers
        }
    }

    /// 22pt above the grid's bottom edge (the reference app's); above the strip when there is one.
    private func hintBottom(size: CGSize) -> CGFloat {
        let hasStrip = remoteCount > GroupCallLayoutEngine.capacity(in: size)
        return 22 + (hasStrip ? GroupCallStripView.height - GroupCallMetrics.inset : 0)
    }

    private var remoteCount: Int {
        stage.tiles.reduce(0) { $1.isLocal ? $0 : $0 + 1 }
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.semibold))
            Text("Swipe up for speaker view")
                .font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

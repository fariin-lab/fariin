import SwiftUI
import LiveKit

// THE STAGE, AS THE SCREEN PLACES IT (owner, 2026-10-06): the grid, or one person large with the
// strip (a pin, a shared screen), with the same matched-geometry namespace.
//
// Owner 2026-10-27: the second page a vertical swipe away (whoever is speaking, large) is gone. A
// small swipe changed the whole screen and kept changing it as people spoke, and he could not tell
// why. Tap a person to make them large, tap again to go back; nothing else moves the stage.
struct GroupCallStagePager: View {
    @ObservedObject var stage: GroupCallStage
    /// The screen's namespace, for the focus view's large tile (nil under Reduce Motion: it fades).
    var namespace: Namespace.ID?
    /// A tap on the person shown large: the screen shows or hides its controls.
    var onFocusTap: () -> Void = {}
    /// I am sharing my screen: my phone shows the sharing card large and everyone else in the strip.
    var iAmSharing = false
    var onStopSharing: () -> Void = {}

    var body: some View {
        ZStack {
            if iAmSharing {
                // ⛔ THE SHARER'S OWN SCREEN — owner 2026-10-28 (the 1:1 call's look): "You're sharing
                // your screen" with Stop Sharing inside, large, and the others small under it. The
                // watchers get my screen large on theirs by itself, as before.
                VStack(spacing: 0) {
                    GroupCallSharingCard(onStop: onStopSharing, onTap: onFocusTap)
                        .padding(.horizontal, GroupCallMetrics.inset)
                        .padding(.top, GroupCallMetrics.inset)
                    let others = stage.tiles.filter { !$0.isLocal }.map(\.id)
                    if !others.isEmpty {
                        GroupCallStripView(stage: stage, ids: others)
                    }
                }
                .transition(.opacity)
            } else if case .focus(let id) = stage.mode {
                GroupCallFocusView(stage: stage, focusId: id, namespace: namespace, onLargeTap: onFocusTap)
                    .transition(.opacity)
            } else {
                GroupCallGridView(stage: stage)
                    .transition(.opacity)
            }
        }
    }
}

/// The sharer's large card, the 1:1 call's (`CallView.shareCard`): the icon, "You're sharing your
/// screen" and Stop Sharing. A tap elsewhere on it shows or hides the controls.
struct GroupCallSharingCard: View {
    let onStop: () -> Void
    let onTap: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GroupCallMetrics.tileCorner, style: .continuous)
                .fill(Color(white: 0.12))
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
            VStack(spacing: 20) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 40, weight: .semibold))
                Text("You're sharing your screen").font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                Button {
                    Haptics.impact(.light)
                    onStop()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        Text("Stop Sharing").font(.system(size: 17, weight: .semibold))
                    }
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop sharing screen")
            }
            .foregroundStyle(.white)
            .padding(20)
        }
    }
}

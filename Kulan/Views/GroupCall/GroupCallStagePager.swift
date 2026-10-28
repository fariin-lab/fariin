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

    var body: some View {
        ZStack {
            if case .focus(let id) = stage.mode {
                GroupCallFocusView(stage: stage, focusId: id, namespace: namespace)
                    .transition(.opacity)
            } else {
                GroupCallGridView(stage: stage)
                    .transition(.opacity)
            }
        }
    }
}

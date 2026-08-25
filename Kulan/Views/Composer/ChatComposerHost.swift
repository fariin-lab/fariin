import SwiftUI
import UIKit

/// Puts `ChatComposerView` in the composer's SwiftUI slot. State goes in whole on every update;
/// the view reports its preferred height back, and a bump of `layoutTick` makes SwiftUI ask
/// `sizeThatFits` again — on the view's own clock when the change was animated, so the frame and
/// the contents move together.
struct ChatComposerHost: UIViewRepresentable {
    var state: ChatComposerState
    var actions: ChatComposerActions
    var recorder: AudioRecorder

    @State private var layoutTick = 0

    func makeUIView(context: Context) -> ChatComposerView {
        let v = ChatComposerView(recorder: recorder)
        let tick = $layoutTick
        v.onHeightChange = { animation in
            // Off the current pass: the report can come from inside a layout or an update.
            DispatchQueue.main.async {
                if let animation {
                    withAnimation(animation) { tick.wrappedValue += 1 }
                } else {
                    tick.wrappedValue += 1
                }
            }
        }
        v.actions = actions
        v.apply(state)
        return v
    }

    func updateUIView(_ v: ChatComposerView, context: Context) {
        v.actions = actions
        v.apply(state)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: ChatComposerView, context: Context) -> CGSize? {
        _ = layoutTick   // read so a bump re-runs this
        var w = proposal.width ?? v.bounds.width
        if !w.isFinite || w <= 0 { w = v.bounds.width }
        return CGSize(width: w, height: v.preferredHeight(forWidth: w))
    }
}

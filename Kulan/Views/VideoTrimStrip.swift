import SwiftUI
import UIKit

// THE video trimmer — the ONE shared implementation used by every editor (single video editor AND the
// multi/mixed media pager). Photos-style: filmstrip with a yellow selection frame + two draggable
// handles, dimmed outside, and a white playhead that tracks playback and can be dragged to scrub.
//
// Behavior contract (user-spec, fixed once HERE and inherited everywhere):
//   • Dragging a handle or the playhead NEVER auto-plays — the video stays paused until Play is tapped.
//   • Handle drags clamp the playhead into the new range (left → trimStart, right → trimEnd).
//   • The playhead is clamped INSIDE the yellow frame against the handles' DRAWN edges (it can never
//     overlap a grip, even at the very start/end where the grips are clamped to the strip bounds).
//   • The playhead's visual is a thin 3pt line; its touch target is a 32pt-wide invisible strip.
struct VideoTrimStrip: View {
    let duration: Double
    let thumbnails: [UIImage]
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var playhead: Double
    @Binding var scrubTime: Double?     // non-nil while dragging → the player previews this frame
    @Binding var playing: Bool
    @Binding var draggingPlayhead: Bool // pass .constant(false) if the host doesn't need it

    var stripHeight: CGFloat = 40
    var handleW: CGFloat = 12
    var minDuration: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let dur = max(0.01, duration)
            let startX = CGFloat(trimStart / dur) * W
            let endX = CGFloat(trimEnd / dur) * W
            ZStack(alignment: .leading) {
                // Thumbnails + the dimmed end sections share ONE rounded clip so the strip's outer
                // corners (including the dimmed parts) are rounded, not square.
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(uiImage: thumbnails[i]).resizable().scaledToFill()
                                .frame(width: W / CGFloat(max(1, thumbnails.count)), height: stripHeight).clipped()
                        }
                    }
                    .frame(width: W, height: stripHeight)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: startX, height: stripHeight)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, W - endX), height: stripHeight).offset(x: endX)
                }
                .frame(width: W, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Yellow selection frame (rounded to match the rounded handle caps).
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: stripHeight).offset(x: startX)
                // PLAYHEAD scrubber, clamped INSIDE the yellow frame against the handles' DRAWN edges.
                let phX = CGFloat((min(max(playhead, trimStart), trimEnd)) / dur) * W
                if trimEnd > trimStart {
                    let leftHandleInner = max(0, startX - handleW / 2) + handleW + 3.5   // right edge of left grip
                    let rightHandleInner = min(W - handleW, endX - handleW / 2) - 3.5    // left edge of right grip
                    Capsule().fill(.white)
                        .frame(width: 3, height: stripHeight + 8)
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .frame(width: 32, height: stripHeight + 16)   // big invisible hit area
                        .contentShape(Rectangle())
                        .offset(x: min(max(leftHandleInner, phX), max(leftHandleInner, rightHandleInner)) - 16)
                        .gesture(playheadDrag(width: W))
                }
                // Rounded trim handles.
                trimHandle.offset(x: max(0, startX - handleW / 2))
                    .gesture(handleDrag(isStart: true, width: W))
                trimHandle.offset(x: min(W - handleW, endX - handleW / 2))
                    .gesture(handleDrag(isStart: false, width: W))
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: stripHeight)
    }

    // Fully-rounded yellow grip (premium/native look) with a darker notch in the middle.
    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: handleW / 2, style: .continuous).fill(Color.yellow)
            .frame(width: handleW, height: stripHeight)
            .overlay(Capsule().fill(.black.opacity(0.55)).frame(width: 2.5, height: 18))
    }

    // Drag the playhead: seek-only; the video stays PAUSED on release.
    private func playheadDrag(width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { g in
                draggingPlayhead = true; playing = false
                let dur = max(0.01, duration)
                let t = Double(min(max(0, g.location.x), W) / W) * dur
                playhead = min(max(t, trimStart), trimEnd)
                scrubTime = playhead
            }
            .onEnded { _ in scrubTime = nil; draggingPlayhead = false }   // stays paused — no auto-play
    }

    // Drag a trim handle: adjusts only the range, previewing the boundary frame; stays paused on release.
    private func handleDrag(isStart: Bool, width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { g in
                playing = false
                let dur = max(0.01, duration)
                let t = Double(min(max(0, g.location.x), W) / W) * dur
                if isStart {
                    trimStart = min(t, trimEnd - minDuration); scrubTime = trimStart
                    if playhead < trimStart { playhead = trimStart }   // playback position can't precede the start
                } else {
                    trimEnd = max(t, trimStart + minDuration); scrubTime = trimEnd
                    if playhead > trimEnd { playhead = trimEnd }       // ...or exceed the end
                }
            }
            .onEnded { _ in scrubTime = nil }   // stays paused — no auto-play
    }
}

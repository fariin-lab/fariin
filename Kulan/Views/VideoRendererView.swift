import SwiftUI
import WebRTC

// Renders a WebRTC video track (local preview or the remote feed) via Metal.
// `mirror` flips horizontally for the local front camera (selfie view).
// `fit` shows the whole frame (letterboxed) instead of filling and cropping: a shared SCREEN must
// never lose its edges. Faces keep the fill.
struct VideoRendererView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirror: Bool = false
    var fit: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        v.clipsToBounds = true
        v.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        // The same mounted view flips between a face and a screen without being rebuilt.
        let mode: UIView.ContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        if uiView.videoContentMode != mode { uiView.videoContentMode = mode }
        // Re-bind only when the track actually changes (attaching twice double-renders).
        if context.coordinator.track !== track {
            let old = context.coordinator.track
            context.coordinator.track = track           // claim synchronously (no double-dispatch)
            // Attach/detach ASYNC (LiveKit pattern): doing it synchronously inside a SwiftUI update
            // can race the WebRTC decode thread delivering frames → garbled/dropped first frames.
            DispatchQueue.main.async {
                old?.remove(uiView)
                track?.add(uiView)
            }
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(uiView)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var track: RTCVideoTrack? }
}

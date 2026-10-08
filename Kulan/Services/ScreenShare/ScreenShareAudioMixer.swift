import Foundation
import WebRTC

/// The shared app's sound in the 1:1 call, while I share my screen.
///
/// ⚠️ NOT AVAILABLE ON THIS WEBRTC (checked 2026-10-08). The plan was a capture post-processing
/// hook on the audio processing module (`RTCAudioCustomProcessingDelegate`, `RTCAudioBuffer`,
/// `RTCDefaultAudioProcessingModule`, and a factory init taking `audioProcessingModule:`). None of
/// those exist in upstream WebRTC M120 (branch-heads/6099, the build stasel/WebRTC 120 ships):
/// `sdk/objc/components/audio/` holds only RTCAudioDevice and RTCAudioSession, and the factory has
/// no audio processing parameter. They exist only in a forked WebRTC build, not in the one 1:1
/// calls run on. So this is the agreed fallback: a plain factory, exactly as before, and `isMixing`
/// does nothing. The extension's audio ring is written but not read on the app side yet.
///
/// The way to add it later on this WebRTC is a custom `RTCAudioDevice` (the factory init
/// `encoderFactory:decoderFactory:audioDevice:` does exist in M120) that mixes the ring into the
/// microphone samples it records, or moving 1:1 calls to a WebRTC build that has the hook.
final class ScreenShareAudioMixer {
    static let shared = ScreenShareAudioMixer()

    /// Whether the shared app's sound should go into my microphone track. CallService sets it while
    /// I share. Kept so the call side is already wired; it has no effect on this WebRTC (see above).
    var isMixing: Bool = false

    /// The call's one peer connection factory. Same construction as before screen share v3, so
    /// codecs and audio behave exactly as they did.
    static func makeFactory() -> RTCPeerConnectionFactory {
        RTCPeerConnectionFactory()
    }

    private init() {}
}

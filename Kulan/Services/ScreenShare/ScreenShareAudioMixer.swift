import Foundation
import WebRTC

/// The shared app's sound in the 1:1 call, while I share my screen.
///
/// ⛔ 2026-10-14 (owner: "I hear their microphone but not the sound playing on their phone"). WebRTC
/// M120 has no hook that adds audio to what it records: the capture post-processing types
/// (`RTCAudioCustomProcessingDelegate`, `RTCAudioBuffer`, `RTCDefaultAudioProcessingModule`) exist
/// only in forked builds, not in the one 1:1 calls run on (checked 2026-10-08). It does accept a whole
/// audio device, so the call's microphone and speaker now run through `CallAudioDevice`, which adds
/// the broadcast extension's app audio to each recorded buffer while `isMixing` is on. The other
/// person hears my voice and my phone's sound in the one audio track, as before plus the sound.
final class ScreenShareAudioMixer {
    static let shared = ScreenShareAudioMixer()

    /// Off = the built-in audio device, exactly as before this change, and no app audio.
    static let useCallAudioDevice = true

    /// Whether the shared app's sound goes into my microphone track. CallService sets it while I
    /// share. The ring is opened here, on the main thread, before the audio thread looks for it.
    var isMixing: Bool = false {
        didSet {
            guard Self.useCallAudioDevice, isMixing, CallAudioDevice.shared.ring == nil else { return }
            CallAudioDevice.shared.ring = ScreenShareIPC.AudioRing()
        }
    }

    /// The call's one peer connection factory. The video codecs are the plain factory's own (H.264
    /// only), so nothing but the audio device changes.
    static func makeFactory() -> RTCPeerConnectionFactory {
        guard useCallAudioDevice else { return RTCPeerConnectionFactory() }
        return RTCPeerConnectionFactory(encoderFactory: RTCVideoEncoderFactoryH264(),
                                        decoderFactory: RTCVideoDecoderFactoryH264(),
                                        audioDevice: CallAudioDevice.shared)
    }

    private init() {}
}

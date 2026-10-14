import Foundation
import AVFoundation
import AudioToolbox
import WebRTC
import os

/// ⛔ THE 1:1 CALL'S MICROPHONE AND SPEAKER, RUN BY US SO THE SHARED SCREEN'S SOUND CAN RIDE IN THE
/// MIC TRACK (owner 2026-10-14: "during screen sharing I hear their microphone but not the sound
/// playing on their phone").
///
/// WebRTC M120 has no hook to add audio to what it records (see `ScreenShareAudioMixer`), but it does
/// accept a whole audio device (`RTCAudioDevice`, the factory's `audioDevice:` init). This is that
/// device, built to behave as the built-in one did:
///  · the same Voice-Processing I/O unit (Apple's echo cancellation), 16-bit mono at the session's
///    own sample rate, both directions on one unit;
///  · the same on/off rule: the built-in device obeys `RTCAudioSession.isAudioEnabled` under manual
///    audio (CallKit owns the session; CallKitManager and CallService switch it), so this one starts
///    and stops on exactly that, via `didChangeCanPlayOrRecord`;
///  · interruptions, a media-services reset and a sample-rate change on a route switch restart it.
/// WebRTC's own processing is unchanged: on iOS it never runs software echo cancellation or gain
/// control whatever the device says (VPIO does both), and noise suppression is the same option.
///
/// While I share my screen (`ScreenShareAudioMixer.isMixing`), the broadcast extension's app audio
/// (48 kHz mono, a ring in the App Group) is added to each recorded buffer, resampled to the unit's
/// rate. It is mixed AFTER the echo canceller, so it is never cancelled as echo.
///
/// Rollback: `ScreenShareAudioMixer.useCallAudioDevice = false` puts the built-in device back.
final class CallAudioDevice: NSObject, RTCAudioDevice, RTCAudioSessionDelegate {
    static let shared = CallAudioDevice()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Kulan", category: "CallAudio")

    /// Every state change runs here, in order. The audio callbacks never touch it.
    private let queue = DispatchQueue(label: "CallAudioDevice")

    private weak var delegate: RTCAudioDeviceDelegate?
    private var deliver: RTCAudioDeviceDeliverRecordedDataBlock?
    private var getPlayout: RTCAudioDeviceGetPlayoutDataBlock?
    /// Made once: handing a block to `deliver` on the audio thread must not allocate.
    private var renderBlock: RTCAudioDeviceRenderRecordedDataBlock!

    private var unit: AudioUnit?
    private var unitRunning = false
    private var rate: Double = 48_000
    private var interrupted = false

    // Read on the audio threads; written on `queue`. Plain Bools: a stale read for one buffer is harmless.
    private var playoutOn = false
    private var recordingOn = false
    private var playoutReady = false
    private var recordingReady = false
    private var ready = false

    // App-audio mixing state, audio input thread only (except `ring`, set before mixing starts).
    var ring: ScreenShareIPC.AudioRing?
    private var readPos: Double = -1
    private let scratchCap = 16_384
    private let scratch: UnsafeMutablePointer<Int16>
    private static let appGain: Double = 0.9

    private override init() {
        scratch = .allocate(capacity: 16_384)
        scratch.initialize(repeating: 0, count: 16_384)
        super.init()
        renderBlock = { [unowned self] flags, timestamp, bus, frames, data, _ in
            guard let unit = self.unit else { return kAudioUnitErr_Uninitialized }
            let status = AudioUnitRender(unit, flags, timestamp, UInt32(bus), frames, data)
            if status == noErr, ScreenShareAudioMixer.shared.isMixing {
                self.mixAppAudio(into: data, frames: Int(frames))
            }
            return status
        }
    }

    // MARK: RTCAudioDevice — what WebRTC reads

    private var session: AVAudioSession { AVAudioSession.sharedInstance() }
    var deviceInputSampleRate: Double { rate }
    var inputIOBufferDuration: TimeInterval { session.ioBufferDuration }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { session.inputLatency }
    var deviceOutputSampleRate: Double { rate }
    var outputIOBufferDuration: TimeInterval { session.ioBufferDuration }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { session.outputLatency }
    var isInitialized: Bool { ready }
    var isPlayoutInitialized: Bool { playoutReady }
    var isPlaying: Bool { playoutOn }
    var isRecordingInitialized: Bool { recordingReady }
    var isRecording: Bool { recordingOn }

    // MARK: RTCAudioDevice — what WebRTC asks

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        queue.sync {
            self.delegate = delegate
            deliver = delegate.deliverRecordedData
            getPlayout = delegate.getPlayoutData
            let r = session.sampleRate
            rate = r > 0 ? r : 48_000
            if !ready { RTCAudioSession.sharedInstance().add(self) }
            ready = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        queue.sync {
            stopUnit(); disposeUnit()
            playoutOn = false; recordingOn = false
            playoutReady = false; recordingReady = false
            if ready { RTCAudioSession.sharedInstance().remove(self) }
            ready = false
            delegate = nil; deliver = nil; getPlayout = nil
        }
        return true
    }

    func initializePlayout() -> Bool { queue.sync { playoutReady = true }; return true }
    func startPlayout() -> Bool { queue.sync { playoutOn = true; update() }; return true }
    func stopPlayout() -> Bool { queue.sync { playoutOn = false; update() }; return true }
    func initializeRecording() -> Bool { queue.sync { recordingReady = true }; return true }
    func startRecording() -> Bool { queue.sync { recordingOn = true; update() }; return true }
    func stopRecording() -> Bool { queue.sync { recordingOn = false; update() }; return true }

    // MARK: RTCAudioSessionDelegate — the same switches the built-in device listens to

    func audioSession(_ session: RTCAudioSession, didChangeCanPlayOrRecord canPlayOrRecord: Bool) {
        queue.async { self.update() }
    }

    func audioSessionDidBeginInterruption(_ session: RTCAudioSession) {
        queue.async { self.interrupted = true; self.update() }
    }

    func audioSessionDidEndInterruption(_ session: RTCAudioSession, shouldResumeSession: Bool) {
        queue.async { self.interrupted = false; self.update() }
    }

    func audioSessionMediaServerReset(_ session: RTCAudioSession) {
        queue.async { self.stopUnit(); self.disposeUnit(); self.update() }
    }

    func audioSessionDidChangeRoute(_ session: RTCAudioSession,
                                    reason: AVAudioSession.RouteChangeReason,
                                    previousRoute: AVAudioSessionRouteDescription) {
        queue.async {
            // A headset that runs at another rate (Bluetooth calls are often 16 or 24 kHz): the unit
            // is rebuilt at the new rate and WebRTC is told, as the built-in device does.
            let r = self.session.sampleRate
            guard r > 0, abs(r - self.rate) > 1 else { return }
            let wasRunning = self.unitRunning
            self.stopUnit(); self.disposeUnit()
            self.rate = r
            self.readPos = -1
            self.delegate?.notifyAudioInputParametersChange()
            self.delegate?.notifyAudioOutputParametersChange()
            if wasRunning { self.update() }
        }
    }

    // MARK: The unit

    /// On `queue`. Runs the unit exactly when WebRTC wants audio and the session allows it.
    private func update() {
        let rtc = RTCAudioSession.sharedInstance()
        let allowed = rtc.useManualAudio ? rtc.isAudioEnabled : true
        let want = ready && (playoutOn || recordingOn) && allowed && !interrupted
        if want && !unitRunning { startUnit() }
        else if !want && unitRunning { stopUnit() }
    }

    private func startUnit() {
        if unit == nil { unit = makeUnit() }
        guard let unit else { return }
        let status = AudioOutputUnitStart(unit)
        if status == noErr {
            unitRunning = true
            readPos = -1
        } else {
            Self.log.error("start failed \(status, privacy: .public)")
            // A unit that will not start is rebuilt next time rather than retried as is.
            disposeUnit()
        }
    }

    private func stopUnit() {
        guard let unit, unitRunning else { return }
        AudioOutputUnitStop(unit)
        unitRunning = false
    }

    private func disposeUnit() {
        guard let u = unit else { return }
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
        unitRunning = false
    }

    private func makeUnit() -> AudioUnit? {
        let r = session.sampleRate
        if r > 0 { rate = r }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { return nil }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(component, &made) == noErr, let u = made else { return nil }

        var on: UInt32 = 1
        let uint32Size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, uint32Size)
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, uint32Size)

        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // What the speaker is fed (bus 0 input) and what the microphone gives (bus 1 output).
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize)
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, formatSize)

        // WebRTC renders the microphone into its own buffer through `renderBlock`.
        var off: UInt32 = 0
        AudioUnitSetProperty(u, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &off, uint32Size)

        let me = Unmanaged.passUnretained(self).toOpaque()
        let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        var playout = AURenderCallbackStruct(inputProc: callAudioPlayoutCallback, inputProcRefCon: me)
        AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &playout, callbackSize)
        var record = AURenderCallbackStruct(inputProc: callAudioRecordCallback, inputProcRefCon: me)
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &record, callbackSize)

        let status = AudioUnitInitialize(u)
        guard status == noErr else {
            Self.log.error("initialize failed \(status, privacy: .public)")
            AudioComponentInstanceDispose(u)
            return nil
        }
        return u
    }

    // MARK: Audio threads

    fileprivate func onRecord(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              _ timestamp: UnsafePointer<AudioTimeStamp>,
                              _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard recordingOn, let deliver else { return noErr }
        return deliver(flags, timestamp, Int(bus), frames, nil, nil, renderBlock)
    }

    fileprivate func onPlayout(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               _ timestamp: UnsafePointer<AudioTimeStamp>,
                               _ bus: UInt32, _ frames: UInt32,
                               _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let data else { return noErr }
        guard playoutOn, let getPlayout else {
            for b in UnsafeMutableAudioBufferListPointer(data) {
                if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
            }
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return noErr
        }
        return getPlayout(flags, timestamp, Int(bus), frames, data)
    }

    /// Adds the shared app's sound to one recorded buffer. Keeps ~80 ms behind the extension's
    /// writes; jumps back to that when it drifts more than 250 ms; skips a buffer it cannot fill
    /// rather than waiting. Nothing is mixed once the extension has been silent for half a second.
    private func mixAppAudio(into list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard let ring, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let raw = first.mData else { return }
        let now = ScreenShareIPC.nowNs()
        let last = ring.lastWriteNs
        guard last > 0, now <= last || now - last < 500_000_000 else { return }

        let srcRate = Double(ScreenShareIPC.Audio.sampleRate)
        let step = srcRate / rate
        let need = Int((Double(frames) * step).rounded(.up)) + 2
        guard need <= scratchCap else { return }
        let written = Double(ring.writeFrames)
        let target = written - srcRate * 0.08
        if readPos < 0 || abs(readPos - target) > srcRate * 0.25 { readPos = target }
        guard readPos >= max(0, written - Double(ring.capacity) + 1),
              readPos + Double(need) <= written else { return }
        ring.read(into: scratch, from: UInt64(readPos), count: need)

        let out = raw.assumingMemoryBound(to: Int16.self)
        let count = min(frames, Int(first.mDataByteSize) / 2)
        var position = 0.0
        for i in 0..<count {
            let j = Int(position)
            let f = position - Double(j)
            let s = Double(scratch[j]) * (1 - f) + Double(scratch[j + 1]) * f
            let mixed = Double(out[i]) + s * Self.appGain
            out[i] = Int16(max(-32768, min(32767, mixed)))
            position += step
        }
        readPos += Double(frames) * step
    }
}

private let callAudioRecordCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    Unmanaged<CallAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
        .onRecord(flags, timestamp, bus, frames)
}

private let callAudioPlayoutCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, data in
    Unmanaged<CallAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
        .onPlayout(flags, timestamp, bus, frames, data)
}

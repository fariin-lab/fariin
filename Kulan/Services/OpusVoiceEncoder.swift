import AVFoundation
import AudioToolbox

/// ⛔ VOICE NOTES ARE OPUS (owner 2026-11-01, "exactly like the reference app"): 48 kHz, mono, about
/// 30 kbit/s, 20 ms packets, which are the reference's numbers. Its files are Ogg, which iOS cannot
/// play; ours are the same codec in a CAF file, which iOS plays with no added library.
///
/// The microphone still records plain audio into stretches (`AudioRecorder`), so pause, the live
/// waveform and drafts are untouched. The stretches become one Opus file here, when a note is
/// reviewed or sent.
///
/// ⚠️ THROUGH `AVAudioConverter`, NOT `AVAudioFile` OR `ExtAudioFile`. Measured on 3 s of audio: both
/// of those accepted the bitrate and wrote 121 to 676 kbit/s. The converter honours it (31 kbit/s).
enum OpusVoiceEncoder {
    static let sampleRate: Double = 48_000
    static let bitRate = 30 * 1024
    private static let framesPerPacket: UInt32 = 960   // 20 ms

    /// One Opus file from these recordings, in order. Nil if a stretch is not 48 kHz mono (a draft
    /// saved by an older build) or anything fails; the caller then falls back to AAC.
    static func encode(_ inputs: [URL], to output: URL) -> Bool {
        guard write(inputs, to: output) else { return false }
        strip(output)
        return true
    }

    /// CAF files come with a 32 KB empty `free` chunk, which is half the size of a 10 s note.
    private static func strip(_ url: URL) {
        guard var d = try? Data(contentsOf: url), d.count > 8, d.prefix(4) == Data("caff".utf8) else { return }
        var p = 8
        while p + 12 <= d.count {
            let size = d[(d.startIndex + p + 4)..<(d.startIndex + p + 12)].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            guard size >= 0, p + 12 + Int(size) <= d.count else { return }
            if d[(d.startIndex + p)..<(d.startIndex + p + 4)] == Data("free".utf8) {
                d.removeSubrange((d.startIndex + p)..<(d.startIndex + p + 12 + Int(size)))
                continue
            }
            p += 12 + Int(size)
        }
        try? d.write(to: url, options: .atomic)
    }

    private static func write(_ inputs: [URL], to output: URL) -> Bool {
        let files = inputs.compactMap { try? AVAudioFile(forReading: $0) }
        guard !files.isEmpty, files.count == inputs.count,
              files.allSatisfy({ $0.processingFormat.sampleRate == sampleRate && $0.processingFormat.channelCount == 1 })
        else { return false }
        let pcmFormat = files[0].processingFormat
        var desc = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opusFormat = AVAudioFormat(streamDescription: &desc),
              let converter = AVAudioConverter(from: pcmFormat, to: opusFormat) else { return false }
        converter.bitRate = bitRate
        converter.bitRateStrategy = "AVAudioBitRateStrategy_Constrained"   // near the target, as a voice note wants

        try? FileManager.default.removeItem(at: output)
        var fileRef: AudioFileID?
        guard AudioFileCreateWithURL(output as CFURL, kAudioFileCAFType, &desc,
                                     .eraseFile, &fileRef) == noErr, let file = fileRef else { return false }
        defer { AudioFileClose(file) }

        var nextFile = 0
        var inputDone = false
        var nextPacket: Int64 = 0
        let chunk: AVAudioFrameCount = 4_800
        guard let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: chunk) else { return false }
        let maxPacket = max(converter.maximumOutputPacketSize, 1_500)
        var cookieWritten = false

        while true {
            let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 50, maximumPacketSize: maxPacket)
            var failure: NSError?
            let status = converter.convert(to: out, error: &failure) { _, state in
                if inputDone { state.pointee = .endOfStream; return nil }
                while nextFile < files.count {
                    input.frameLength = 0
                    if (try? files[nextFile].read(into: input, frameCount: chunk)) != nil, input.frameLength > 0 {
                        state.pointee = .haveData
                        return input
                    }
                    nextFile += 1
                }
                inputDone = true
                state.pointee = .endOfStream
                return nil
            }
            if status == .error || failure != nil { return false }
            if !cookieWritten, let cookie = converter.magicCookie, cookie.count > 0 {
                cookie.withUnsafeBytes { raw in
                    _ = AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, UInt32(raw.count), raw.baseAddress!)
                }
                cookieWritten = true
            }
            var packets = out.packetCount
            if packets > 0, let descriptions = out.packetDescriptions {
                guard AudioFileWritePackets(file, false, out.byteLength, descriptions, nextPacket,
                                            &packets, out.data) == noErr else { return false }
                nextPacket += Int64(packets)
            }
            if status == .endOfStream { break }
        }
        return nextPacket > 0
    }
}

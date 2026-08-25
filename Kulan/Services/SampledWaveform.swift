import Accelerate
import AVFoundation
import Foundation

// ⛔ THE REFERENCE APP'S WAVEFORM, SAMPLED FROM THE FILE THE WAY THEIRS IS — owner, 2026-08-25, on
// the paused review strip: "the waveform looks like dots… use exactly the waveform [the reference]
// is using, that one looks much better."
//
// Theirs is not drawn from microphone metering at all. When a note is to be shown it DECODES the
// audio and walks every PCM sample:
//
//   1. |amplitude| → decibels, with Int16.max as 0 dB              (`vDSP_vdbcon`)
//   2. clip to [−50, 0]: anything quieter than −50 dB is silence   (`vDSP_vclip`)
//   3. mean dB per segment, the file cut into exactly 100 segments (`AudioWaveformSampler`)
//   4. at draw time, per bar: inverseLerp(−50, −20) clamped to 0…1, so −20 dB is full height
//
// Ours metered the recorder's average/peak power on a timer, mapped it through a perceptual curve
// with a −42 dB floor, RMS-bucketed it, stored 0…100, and then re-mapped it at draw time with a
// "quiet knee" that squares anything under 0.30. Every one of those steps is a place for a quiet
// note to lose height, and a quiet four-second test note lost all of it: dots. Theirs has no knee,
// no perceptual curve and no metering timer; it has the file. This is that, in three pieces:
// `SampledWaveform.decibels(of:)` reads the file, `Sampler` is their class, `levels(for:count:)` is
// their `normalizedLevelsToDisplay`. The drawing half lives in `SampledWaveformView`.
enum SampledWaveform {
    /// Their `silenceThreshold` / `clippingThreshold`.
    static let silenceThreshold: Float = -50
    static let clippingThreshold: Float = -20
    /// Their `sampleCount`: "the number of samples to collect for the given audio file."
    static let sampleCount = 100
    /// Their `maximumDuration`: "too intensive to sample a waveform for really long audio files."
    static let maximumDuration: TimeInterval = 15 * 60

    /// Decibel samples for the first audio track of `url`, at most `sampleCount` of them. Empty when
    /// the file cannot be read. Runs off the main thread; a minute of speech decodes in a few tens
    /// of milliseconds, which is why theirs does this on every playback without anyone noticing.
    static func decibels(of url: URL) async -> [Float] {
        await Task.detached(priority: .userInitiated) { () -> [Float] in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.seconds <= maximumDuration,
                  let tracks = try? await asset.loadTracks(withMediaType: .audio),
                  let track = tracks.first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)

            // Their `sampleCount(from:)`: frames from the container metadata × channels, because the
            // channels come interleaved and one waveform is drawn from the average of them.
            let frames = Int(duration.value)
            let channels: Int = {
                guard let descs = (try? await track.load(.formatDescriptions)) ?? nil,
                      let first = descs.first,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) else { return 1 }
                return max(1, Int(asbd.pointee.mChannelsPerFrame))
            }()
            let (inputCount, overflow) = frames.multipliedReportingOverflow(by: channels)
            guard !overflow else { return [] }

            let sampler = Sampler(inputCount: inputCount, outputCount: sampleCount)
            reader.startReading()
            defer { reader.cancelReading() }
            while reader.status == .reading, !sampler.isComplete {
                if Task.isCancelled { return [] }
                guard let buffer = output.copyNextSampleBuffer(),
                      let block = CMSampleBufferGetDataBuffer(buffer) else { break }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                                  totalLengthOut: nil, dataPointerOut: &pointer) == kCMBlockBufferNoErr
                else { return [] }
                UnsafeBufferPointer(start: pointer, count: length)
                    .withMemoryRebound(to: Int16.self) { sampler.update($0) }
                CMSampleBufferInvalidate(buffer)
            }
            return sampler.finalize()
        }.value
    }

    /// Their `normalizedLevelsToDisplay(sampleCount:)`: 0 is silence, 1 is the loudest value drawn.
    static func levels(for decibels: [Float], count: Int) -> [Float] {
        guard count > 0, !decibels.isEmpty else { return [] }
        func normalize(_ db: Float) -> Float {
            let t = (db - silenceThreshold) / (clippingThreshold - silenceThreshold)
            return max(0, min(1, t))
        }
        guard decibels.count > count else { return decibels.map(normalize) }
        return downsample(decibels, to: count).map(normalize)
    }

    /// Their `downsample(samples:toSampleCount:)`: a plain mean over `stride` samples per bar. The
    /// leftover `count % stride` samples at the tail are dropped, as theirs drops them.
    private static func downsample(_ samples: [Float], to count: Int) -> [Float] {
        let stride = samples.count / count
        let filter = [Float](repeating: 1 / Float(stride), count: stride)
        var out = [Float](repeating: 0, count: count)
        vDSP_desamp(samples, vDSP_Stride(stride), filter, &out, vDSP_Length(count), vDSP_Length(stride))
        return out
    }

    /// Their `AudioWaveformSampler`, unchanged in substance: PCM in, one mean-decibel value per
    /// segment out, with the remainder of `inputCount / outputCount` spread across the segments so
    /// the last bar is not a runt.
    final class Sampler {
        private let inputCount: Int
        private let outputCount: Int
        private let segmentLength: Int
        private let segmentRemainder: Int
        private var currentSegmentCount: Int
        private var currentSegmentRemainingCount: Int
        private var currentSegmentAverage: Float
        private var overflowCounter: Int
        private var buffer = [Float]()
        private var output = [Float]()

        init(inputCount: Int, outputCount: Int) {
            self.inputCount = inputCount
            self.outputCount = outputCount
            if inputCount < outputCount {
                // Theirs: "If we don't have enough samples, just use every sample that's provided."
                (segmentLength, segmentRemainder) = (1, 0)
            } else {
                (segmentLength, segmentRemainder) = inputCount.quotientAndRemainder(dividingBy: outputCount)
            }
            currentSegmentAverage = 0
            currentSegmentCount = segmentLength
            currentSegmentRemainingCount = max(1, segmentLength)
            overflowCounter = outputCount - segmentRemainder
        }

        var isComplete: Bool { output.count >= outputCount }

        func update(_ samples: UnsafeBufferPointer<Int16>) {
            let n = samples.count
            guard n > 0, let base = samples.baseAddress else { return }
            if buffer.count < n { buffer.append(contentsOf: [Float](repeating: 0, count: n - buffer.count)) }
            vDSP_vflt16(base, 1, &buffer, 1, vDSP_Length(n))
            vDSP_vabs(buffer, 1, &buffer, 1, vDSP_Length(n))
            // Their comment: "maximum amplitude storable in Int16 = 0 dB (loudest); remember
            // decibels are often negative."
            var zeroDecibel = Float(Int16.max)
            vDSP_vdbcon(buffer, 1, &zeroDecibel, &buffer, 1, vDSP_Length(n), 1)
            var loudest: Float = 0
            var quietest = SampledWaveform.silenceThreshold
            vDSP_vclip(buffer, 1, &quietest, &loudest, &buffer, 1, vDSP_Length(n))
            reduce(sampleCount: n)
        }

        private func reduce(sampleCount: Int) {
            buffer.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                var remaining = sampleCount
                while remaining > 0, !isComplete {
                    let chunk = min(remaining, currentSegmentRemainingCount)
                    guard chunk > 0 else { return }
                    var chunkAverage: Float = 0
                    vDSP_meanv(base.advanced(by: sampleCount - remaining), 1, &chunkAverage, vDSP_Length(chunk))
                    remaining -= chunk
                    currentSegmentRemainingCount -= chunk
                    let total = currentSegmentCount - currentSegmentRemainingCount
                    let newWeight = Float(chunk) / Float(max(1, total))
                    currentSegmentAverage = currentSegmentAverage * (1 - newWeight) + chunkAverage * newWeight
                    if currentSegmentRemainingCount <= 0 {
                        output.append(currentSegmentAverage)
                        currentSegmentAverage = 0
                        currentSegmentCount = segmentLength
                        overflowCounter -= segmentRemainder
                        if overflowCounter <= 0 {
                            currentSegmentCount += 1
                            overflowCounter += segmentLength
                        }
                        currentSegmentRemainingCount = max(1, currentSegmentCount)
                    }
                }
            }
        }

        func finalize() -> [Float] { output }
    }
}

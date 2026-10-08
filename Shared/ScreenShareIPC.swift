import CoreVideo
import Foundation
import Synchronization

/// Screen share v3 (2026-10-08): the shared-memory channel between the BroadcastUpload extension
/// (writer) and the app (reader). Compiled into BOTH targets, so it may only use Foundation,
/// CoreVideo and the standard library. The extension does not link WebRTC.
///
/// Three memory-mapped files in the App Group container (MAP_SHARED, fixed sizes):
/// - `ss_video.bin`: header + two NV12 frame slots (double buffer guarded by a seqlock).
/// - `ss_audio.bin`: header + a 2 s ring of 48 kHz mono Int16 app audio.
/// - `ss_control.bin`: app -> extension liveness and the stop request.
///
/// All numbers are little endian (native on every iPhone) at fixed, naturally aligned offsets.
///
/// One clock for every timestamp in these files: `ScreenShareIPC.nowNs()` (CLOCK_UPTIME_RAW in
/// nanoseconds). It is the same clock as mach_absolute_time, CACurrentMediaTime and the host time
/// ReplayKit stamps its sample buffers with, and it is shared across processes.
enum ScreenShareIPC {
    static let appGroup = "group.com.kulan.messenger.native"

    /// Darwin notification names (CFNotificationCenterGetDarwinNotifyCenter).
    enum Notify {
        /// Extension -> app: the broadcast started and the files are prepared.
        static let started = "com.kulan.ss3.started"
        /// Extension -> app: the broadcast ended (keepalive is also zeroed).
        static let stopped = "com.kulan.ss3.stopped"
        /// App -> extension: please finish (also set `Control.stopRequested`).
        static let stop = "com.kulan.ss3.stop"
    }

    /// Extension liveness rule: finish if the app has not stamped `appAliveNs` for this long.
    static let appAliveTimeoutNs: UInt64 = 4_000_000_000
    /// App rule: the share is dead if the extension's keepalive is older than this.
    static let keepaliveTimeoutNs: UInt64 = 2_000_000_000
    /// Extension stamps its keepalive this often, frames or not.
    static let keepaliveInterval: TimeInterval = 0.5

    static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    // MARK: Barriers

    /// Writer side: everything stored before this is visible before anything stored after it.
    @inline(__always) static func releaseFence() {
        atomicMemoryFence(ordering: .releasing)
    }

    /// Reader side: loads after this cannot be satisfied before loads before it.
    @inline(__always) static func acquireFence() {
        atomicMemoryFence(ordering: .acquiring)
    }

    // MARK: Darwin notifications

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(rawValue: name as CFString),
                                             nil,
                                             nil,
                                             true)
    }

    /// Observes one Darwin notification until deinit. The handler runs on the thread the Darwin
    /// center delivers on (the main thread); hop to your own queue inside it.
    final class DarwinObserver {
        private let name: String
        private let handler: () -> Void

        init(name: String, handler: @escaping () -> Void) {
            self.name = name
            self.handler = handler
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                            DarwinObserver.callback,
                                            name as CFString,
                                            nil,
                                            .deliverImmediately)
        }

        deinit {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                               UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                               CFNotificationName(name as CFString),
                                               nil)
        }

        private static let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue().handler()
        }
    }

    // MARK: Mapped file

    /// A file in the App Group container, created if missing, grown to `size`, mapped read/write
    /// and shared. The descriptor is closed right after mapping; the mapping lives until deinit.
    final class MappedFile {
        let base: UnsafeMutableRawPointer
        let size: Int

        init?(name: String, size: Int) {
            guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ScreenShareIPC.appGroup) else {
                NSLog("[ScreenShare] IPC: no App Group container")
                return nil
            }
            let path = dir.appendingPathComponent(name).path
            let fd = open(path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else {
                NSLog("[ScreenShare] IPC: open %@ failed errno %d", name, errno)
                return nil
            }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            if Int(st.st_size) < size {
                guard ftruncate(fd, off_t(size)) == 0 else {
                    NSLog("[ScreenShare] IPC: ftruncate %@ failed errno %d", name, errno)
                    return nil
                }
            }
            guard let raw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                  raw != UnsafeMutableRawPointer(bitPattern: -1) else {
                NSLog("[ScreenShare] IPC: mmap %@ failed errno %d", name, errno)
                return nil
            }
            base = raw
            self.size = size
        }

        deinit {
            munmap(base, size)
        }

        @inline(__always) func u32(_ offset: Int) -> UInt32 {
            base.load(fromByteOffset: offset, as: UInt32.self)
        }

        @inline(__always) func u64(_ offset: Int) -> UInt64 {
            base.load(fromByteOffset: offset, as: UInt64.self)
        }

        @inline(__always) func set(_ value: UInt32, at offset: Int) {
            base.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
        }

        @inline(__always) func set(_ value: UInt64, at offset: Int) {
            base.storeBytes(of: value, toByteOffset: offset, as: UInt64.self)
        }
    }

    @inline(__always) static func roundUp(_ value: Int, to multiple: Int) -> Int {
        (value + multiple - 1) / multiple * multiple
    }

    // MARK: Video layout

    enum Video {
        static let fileName = "ss_video.bin"
        static let magic: UInt32 = 0x3356_534B   // "KSV3" little endian
        static let version: UInt32 = 1

        static let maxEdge = 1920                       // long and short edge cap
        static let maxFrameBytes = 1920 * 1920 * 3 / 2  // NV12 at 1920x1920

        // File header (offsets in bytes). Fields after `seq` mirror the newest slot (informational;
        // readers use the per-slot header).
        static let oMagic = 0          // UInt32
        static let oVersion = 4        // UInt32
        static let oSeq = 8            // UInt64, bumped AFTER a slot is fully written
        static let oWidth = 16         // UInt32
        static let oHeight = 20        // UInt32
        static let oYStride = 24       // UInt32
        static let oUVStride = 28      // UInt32
        static let oOrientation = 32   // UInt32, CGImagePropertyOrientation raw value
        static let oFullRange = 36     // UInt32, 1 = 420f, 0 = 420v
        static let oTimestampNs = 40   // UInt64, capture host time
        static let oKeepaliveNs = 48   // UInt64, extension stamps every 0.5 s; 0 = stopped
        static let headerSize = 16_384 // one page, so slots start page aligned

        // Per-slot header, at the start of each slot.
        static let sWidth = 0          // UInt32
        static let sHeight = 4         // UInt32
        static let sYStride = 8        // UInt32 (bytes per Y row in the slot; packed = width)
        static let sUVStride = 12      // UInt32 (bytes per CbCr row in the slot; packed = width)
        static let sOrientation = 16   // UInt32
        static let sFullRange = 20     // UInt32
        static let sTimestampNs = 24   // UInt64
        static let sSeq = 32           // UInt64, the seq this slot was published as
        static let slotHeaderSize = 64

        /// Y plane at `slotHeaderSize`, CbCr plane right after it (yStride * height bytes later).
        static let slotStride = ScreenShareIPC.roundUp(slotHeaderSize + maxFrameBytes, to: 16_384)
        static let fileSize = headerSize + 2 * slotStride

        /// Slot that holds the frame published as `seq`.
        @inline(__always) static func slotOffset(forSeq seq: UInt64) -> Int {
            headerSize + Int(seq % 2) * slotStride
        }
    }

    struct FrameInfo {
        var seq: UInt64
        var width: Int
        var height: Int
        var orientation: UInt32
        var fullRange: Bool
        var timestampNs: UInt64
    }

    /// The video file. Writer: the extension. Reader: the app.
    final class VideoChannel {
        let file: MappedFile
        /// Writer-local copy of the last published seq (the writer is the only one bumping it).
        private var writerSeq: UInt64 = 0

        init?() {
            guard let f = MappedFile(name: Video.fileName, size: Video.fileSize) else { return nil }
            file = f
        }

        /// Latest published seq (0 = nothing ever published).
        var seq: UInt64 {
            let s = file.u64(Video.oSeq)
            ScreenShareIPC.acquireFence()
            return s
        }

        var keepaliveNs: UInt64 { file.u64(Video.oKeepaliveNs) }

        // MARK: Writer (extension)

        /// Stamps magic/version and continues from the seq already in the file, so a reader that
        /// stayed mapped across two broadcasts never sees seq go backwards.
        func prepareWriter() {
            file.set(Video.magic, at: Video.oMagic)
            file.set(Video.version, at: Video.oVersion)
            writerSeq = file.u64(Video.oSeq)
            touchKeepalive(ScreenShareIPC.nowNs())
        }

        func touchKeepalive(_ ns: UInt64) {
            file.set(ns, at: Video.oKeepaliveNs)
        }

        /// Copies an NV12 buffer (even width/height, both edges <= 1920) into the free slot and
        /// publishes it. Returns false if the buffer does not fit the contract.
        @discardableResult
        func writeFrame(_ pb: CVPixelBuffer, orientation: UInt32, fullRange: Bool, timestampNs: UInt64) -> Bool {
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            guard w >= 2, h >= 2, w % 2 == 0, h % 2 == 0,
                  w <= Video.maxEdge, h <= Video.maxEdge,
                  CVPixelBufferGetPlaneCount(pb) == 2 else { return false }

            let next = writerSeq &+ 1
            let slot = file.base + Video.slotOffset(forSeq: next)
            guard ScreenShareIPC.packNV12(pb, into: slot + Video.slotHeaderSize, width: w, height: h) else {
                return false
            }
            slot.storeBytes(of: UInt32(w), toByteOffset: Video.sWidth, as: UInt32.self)
            slot.storeBytes(of: UInt32(h), toByteOffset: Video.sHeight, as: UInt32.self)
            slot.storeBytes(of: UInt32(w), toByteOffset: Video.sYStride, as: UInt32.self)
            slot.storeBytes(of: UInt32(w), toByteOffset: Video.sUVStride, as: UInt32.self)
            slot.storeBytes(of: orientation, toByteOffset: Video.sOrientation, as: UInt32.self)
            slot.storeBytes(of: fullRange ? UInt32(1) : 0, toByteOffset: Video.sFullRange, as: UInt32.self)
            slot.storeBytes(of: timestampNs, toByteOffset: Video.sTimestampNs, as: UInt64.self)
            slot.storeBytes(of: next, toByteOffset: Video.sSeq, as: UInt64.self)

            file.set(UInt32(w), at: Video.oWidth)
            file.set(UInt32(h), at: Video.oHeight)
            file.set(UInt32(w), at: Video.oYStride)
            file.set(UInt32(w), at: Video.oUVStride)
            file.set(orientation, at: Video.oOrientation)
            file.set(fullRange ? UInt32(1) : 0, at: Video.oFullRange)
            file.set(timestampNs, at: Video.oTimestampNs)

            ScreenShareIPC.releaseFence()
            file.set(next, at: Video.oSeq)
            writerSeq = next
            return true
        }

        // MARK: Reader (app)

        /// Reads the newest frame if its seq differs from `lastSeq`. `makeBuffer` must return an
        /// NV12 CVPixelBuffer of exactly info.width x info.height (420f if info.fullRange, else
        /// 420v), e.g. from a pool. Returns nil when there is nothing new, the slot looks invalid,
        /// or the writer overtook the copy (seqlock: the frame is dropped, try next tick).
        func readFrame(newerThan lastSeq: UInt64,
                       makeBuffer: (FrameInfo) -> CVPixelBuffer?) -> (FrameInfo, CVPixelBuffer)? {
            guard file.u32(Video.oMagic) == Video.magic else { return nil }
            let s = seq
            guard s != 0, s != lastSeq else { return nil }
            let slot = UnsafeRawPointer(file.base + Video.slotOffset(forSeq: s))
            let w = Int(slot.load(fromByteOffset: Video.sWidth, as: UInt32.self))
            let h = Int(slot.load(fromByteOffset: Video.sHeight, as: UInt32.self))
            let yStride = Int(slot.load(fromByteOffset: Video.sYStride, as: UInt32.self))
            let uvStride = Int(slot.load(fromByteOffset: Video.sUVStride, as: UInt32.self))
            let info = FrameInfo(seq: s,
                                 width: w,
                                 height: h,
                                 orientation: slot.load(fromByteOffset: Video.sOrientation, as: UInt32.self),
                                 fullRange: slot.load(fromByteOffset: Video.sFullRange, as: UInt32.self) != 0,
                                 timestampNs: slot.load(fromByteOffset: Video.sTimestampNs, as: UInt64.self))
            guard slot.load(fromByteOffset: Video.sSeq, as: UInt64.self) == s,
                  w >= 2, h >= 2, w <= Video.maxEdge, h <= Video.maxEdge,
                  yStride >= w, uvStride >= w,
                  yStride * h + uvStride * (h / 2) <= Video.maxFrameBytes else { return nil }
            guard let pb = makeBuffer(info) else { return nil }
            let data = slot + Video.slotHeaderSize
            guard ScreenShareIPC.unpackNV12(y: data, yStride: yStride,
                                            uv: data + yStride * h, uvStride: uvStride,
                                            width: w, height: h, into: pb) else { return nil }
            ScreenShareIPC.acquireFence()
            guard file.u64(Video.oSeq) == s else { return nil }
            return (info, pb)
        }
    }

    // MARK: Audio layout

    enum Audio {
        static let fileName = "ss_audio.bin"
        static let magic: UInt32 = 0x3341_534B   // "KSA3" little endian
        static let version: UInt32 = 1
        static let sampleRate: UInt32 = 48_000
        static let channels: UInt32 = 1
        static let capacityFrames: UInt32 = 96_000 // 2 s

        static let oMagic = 0            // UInt32
        static let oVersion = 4          // UInt32
        static let oSampleRate = 8       // UInt32
        static let oChannels = 12        // UInt32
        static let oCapacityFrames = 16  // UInt32
        // 20..23 padding
        static let oWriteFrames = 24     // UInt64, total frames ever written; stored AFTER samples
        static let oLastWriteNs = 32     // UInt64
        static let headerSize = 64       // Int16 samples start here

        static let fileSize = headerSize + Int(capacityFrames) * 2
    }

    /// The app-audio ring. Writer: the extension. Reader: the app's audio thread (no locks, no
    /// allocation in either path).
    final class AudioRing {
        let file: MappedFile
        let samples: UnsafeMutablePointer<Int16>
        let capacity: Int
        private var writerFrames: UInt64 = 0

        init?() {
            guard let f = MappedFile(name: Audio.fileName, size: Audio.fileSize) else { return nil }
            file = f
            samples = (f.base + Audio.headerSize).bindMemory(to: Int16.self, capacity: Int(Audio.capacityFrames))
            capacity = Int(Audio.capacityFrames)
        }

        /// Total frames ever written (acquire): samples below this index are complete.
        var writeFrames: UInt64 {
            let w = file.u64(Audio.oWriteFrames)
            ScreenShareIPC.acquireFence()
            return w
        }

        var lastWriteNs: UInt64 { file.u64(Audio.oLastWriteNs) }

        // MARK: Writer (extension)

        func prepareWriter() {
            file.set(Audio.magic, at: Audio.oMagic)
            file.set(Audio.version, at: Audio.oVersion)
            file.set(Audio.sampleRate, at: Audio.oSampleRate)
            file.set(Audio.channels, at: Audio.oChannels)
            file.set(Audio.capacityFrames, at: Audio.oCapacityFrames)
            writerFrames = file.u64(Audio.oWriteFrames)
        }

        func write(_ src: UnsafePointer<Int16>, count: Int) {
            guard count > 0 else { return }
            var src = src
            var remaining = count
            if remaining > capacity {           // keep only the newest `capacity` frames
                src += remaining - capacity
                writerFrames &+= UInt64(remaining - capacity)
                remaining = capacity
            }
            var pos = Int(writerFrames % UInt64(capacity))
            var left = remaining
            while left > 0 {
                let n = min(left, capacity - pos)
                (samples + pos).update(from: src, count: n)
                src += n
                left -= n
                pos = 0
            }
            ScreenShareIPC.releaseFence()
            writerFrames &+= UInt64(remaining)
            file.set(writerFrames, at: Audio.oWriteFrames)
            file.set(ScreenShareIPC.nowNs(), at: Audio.oLastWriteNs)
        }

        // MARK: Reader (app)

        /// Copies `count` frames starting at absolute frame index `from` (wrapping). The caller
        /// keeps `writeFrames - capacity < from` and `from + count <= writeFrames`.
        func read(into dst: UnsafeMutablePointer<Int16>, from: UInt64, count: Int) {
            var pos = Int(from % UInt64(capacity))
            var out = dst
            var left = min(count, capacity)
            while left > 0 {
                let n = min(left, capacity - pos)
                out.update(from: samples + pos, count: n)
                out += n
                left -= n
                pos = 0
            }
        }
    }

    // MARK: Control layout

    enum ControlLayout {
        static let fileName = "ss_control.bin"
        static let oAppAliveNs = 0       // UInt64, app stamps every 1 s while a share is wanted
        static let oStopRequested = 8    // UInt32, app sets 1 to ask the extension to finish
        static let fileSize = 64
    }

    final class Control {
        let file: MappedFile

        init?() {
            guard let f = MappedFile(name: ControlLayout.fileName, size: ControlLayout.fileSize) else { return nil }
            file = f
        }

        var appAliveNs: UInt64 {
            get { file.u64(ControlLayout.oAppAliveNs) }
            set { file.set(newValue, at: ControlLayout.oAppAliveNs) }
        }

        var stopRequested: Bool {
            get { file.u32(ControlLayout.oStopRequested) != 0 }
            set { file.set(newValue ? UInt32(1) : 0, at: ControlLayout.oStopRequested) }
        }

        /// App: call before presenting the broadcast picker (clears a stale stop, stamps alive).
        func markShareWanted() {
            stopRequested = false
            appAliveNs = ScreenShareIPC.nowNs()
        }

        /// App: ask the extension to finish (flag + Darwin notification).
        func requestStop() {
            stopRequested = true
            ScreenShareIPC.post(Notify.stop)
        }
    }

    // MARK: NV12 copy helpers

    /// Row-by-row copy, or one copy when both strides equal the row length.
    @inline(__always)
    static func copyPlane(src: UnsafeRawPointer, srcStride: Int,
                          dst: UnsafeMutableRawPointer, dstStride: Int,
                          rowBytes: Int, rows: Int) {
        if srcStride == rowBytes && dstStride == rowBytes {
            dst.copyMemory(from: src, byteCount: rowBytes * rows)
            return
        }
        var s = src
        var d = dst
        for _ in 0..<rows {
            d.copyMemory(from: s, byteCount: rowBytes)
            s += srcStride
            d += dstStride
        }
    }

    /// Packs a bi-planar 4:2:0 buffer (width x height, even) into `dst` as tight rows:
    /// Y at dst (stride = width), CbCr at dst + width * height (stride = width).
    static func packNV12(_ pb: CVPixelBuffer, into dst: UnsafeMutableRawPointer, width: Int, height: Int) -> Bool {
        guard CVPixelBufferGetPlaneCount(pb) == 2 else { return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        guard yStride >= width, uvStride >= width,
              CVPixelBufferGetHeightOfPlane(pb, 0) >= height,
              CVPixelBufferGetHeightOfPlane(pb, 1) >= height / 2 else { return false }
        copyPlane(src: y, srcStride: yStride, dst: dst, dstStride: width, rowBytes: width, rows: height)
        copyPlane(src: uv, srcStride: uvStride, dst: dst + width * height, dstStride: width,
                  rowBytes: width, rows: height / 2)
        return true
    }

    /// Unpacks NV12 planes into a bi-planar CVPixelBuffer, respecting its own strides.
    static func unpackNV12(y: UnsafeRawPointer, yStride: Int,
                           uv: UnsafeRawPointer, uvStride: Int,
                           width: Int, height: Int, into pb: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPlaneCount(pb) == 2,
              CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dy = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let duv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return false }
        let dyStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let duvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        guard dyStride >= width, duvStride >= width else { return false }
        copyPlane(src: y, srcStride: yStride, dst: dy, dstStride: dyStride, rowBytes: width, rows: height)
        copyPlane(src: uv, srcStride: uvStride, dst: duv, dstStride: duvStride, rowBytes: width, rows: height / 2)
        return true
    }
}

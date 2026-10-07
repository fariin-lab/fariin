/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Modified for Kulan: copied from LiveKit 2.17.0 Broadcast/IPC/BroadcastReceiver.swift,
// BroadcastIPCHeader.swift and the decode half of BroadcastImageCodec.swift (all internal there),
// renamed with a KS prefix. Changes: image messages only (no app audio in v1); the header is decoded
// by hand so an audio or unknown message is skipped instead of ending the share; the JPEG is
// decoded straight into a pooled, IOSurface-backed buffer, downscaled to a 1920 long edge with even
// sides, because the extension sends the screen at full resolution.

import CoreImage
import CoreVideo
import Foundation

// MARK: - Header

/// The decode side of LiveKit's `BroadcastIPCHeader`, a Codable enum encoded by
/// PropertyListEncoder. Synthesized enum coding writes `{"image": {"_0": {width, height}, "_1": 90}}`
/// for `case image(Metadata, VideoRotation)`, where VideoRotation is an Int raw value (0/90/180/270).
struct KSBroadcastIPCHeader: Decodable {
    struct ImageMetadata: Decodable {
        let width: Int
        let height: Int
    }

    enum Kind {
        case image(ImageMetadata, rotation: Int)
        case other   // audio, wantsAudio, or anything a later LiveKit adds
    }

    let kind: Kind

    private enum CaseKeys: String, CodingKey { case image }
    private enum ImageKeys: String, CodingKey { case _0, _1 }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKeys.self)
        guard container.contains(.image) else { kind = .other; return }
        let values = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
        let metadata = try values.decode(ImageMetadata.self, forKey: ._0)
        let rotation = (try? values.decode(Int.self, forKey: ._1)) ?? 0
        kind = .image(metadata, rotation: rotation)
    }
}

// MARK: - Receiver

/// Receives broadcast samples from the extension process.
final class KSBroadcastReceiver: @unchecked Sendable {
    /// One encoded screen frame as it came off the socket.
    struct EncodedImage {
        let metadata: KSBroadcastIPCHeader.ImageMetadata
        /// Degrees clockwise (0/90/180/270), from the ReplayKit orientation of the sample.
        let rotation: Int
        let jpeg: Data
    }

    private let channel: KSIPCChannel
    private let headerDecoder = PropertyListDecoder()

    /// Creates a receiver with an open connection to the extension. Suspends until it connects.
    init(socketPath: KSSocketPath) async throws {
        channel = try await KSIPCChannel(acceptingOn: socketPath)
    }

    /// Whether or not the connection to the uploader has been closed.
    var isClosed: Bool { channel.isClosed }

    /// Close the connection to the uploader.
    func close() { channel.close() }

    /// The next image message, still encoded. Non-image messages are skipped. Nil when the
    /// connection closed; throws on a socket error.
    func nextImage() async throws -> EncodedImage? {
        while let message = try await channel.nextMessage() {
            guard let payload = message.payload,
                  let header = try? headerDecoder.decode(KSBroadcastIPCHeader.self, from: message.header),
                  case let .image(metadata, rotation) = header.kind else { continue }
            return EncodedImage(metadata: metadata, rotation: rotation, jpeg: payload)
        }
        return nil
    }
}

// MARK: - Image decode

/// JPEG -> BGRA CVPixelBuffer. Not thread-safe: one instance per receive loop.
final class KSBroadcastImageDecoder {
    enum Error: Swift.Error { case decodingFailed }

    /// Long-edge ceiling for what reaches the encoder. A phone screen is ~2.5k tall; 1920 keeps
    /// text sharp while halving the pixels the encoder has to push at ~2 Mbps.
    static let maxLongEdge: CGFloat = 1920

    // Software rendering: the app is normally in the BACKGROUND while its screen is shared, and GPU
    // work from the background is not allowed. LiveKit's decoder makes the same choice.
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    func decode(_ jpeg: Data) throws -> CVPixelBuffer {
        guard let image = CIImage(data: jpeg) else { throw Error.decodingFailed }
        let srcW = image.extent.width, srcH = image.extent.height
        guard srcW >= 16, srcH >= 16 else { throw Error.decodingFailed }
        let scale = min(1, Self.maxLongEdge / max(srcW, srcH))
        let width = max(16, Int((srcW * scale / 2).rounded()) * 2)
        let height = max(16, Int((srcH * scale / 2).rounded()) * 2)

        guard let buffer = makeBuffer(width: width, height: height) else { throw Error.decodingFailed }
        let target = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / srcW, y: CGFloat(height) / srcH))
        context.render(target, to: buffer)
        return buffer
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || width != poolWidth || height != poolHeight {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}

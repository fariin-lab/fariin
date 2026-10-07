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

// Modified for Kulan: copied from LiveKit 2.17.0 Broadcast/IPC/IPCChannel.swift (internal there),
// renamed with a KS prefix. Only the ACCEPTING (app) side and the receive path are kept: the app
// never sends anything to the extension over the socket (no app audio in v1, so no `wantsAudio`).
// The waiting-state restart delay is computed in floating point (the original truncated 0.1 s to 0).

import Foundation
import Network

/// A communication channel between two processes on the same machine.
final class KSIPCChannel: @unchecked Sendable {
    fileprivate static let restartDelay: TimeInterval = 0.1
    fileprivate static let queue = DispatchQueue(label: "kulan.screenshare.ipc", qos: .userInitiated)

    private static func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let ipcProtocol = NWProtocolFramer.Options(definition: KSIPCProtocol.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(ipcProtocol, at: 0)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private let connection: NWConnection

    enum Error: Swift.Error {
        case cancelled
        case corruptMessage
    }

    /// Creates a channel by accepting a connection from the other process. Suspends until the
    /// extension connects; cancelling the calling Task stops the listener and throws `.cancelled`.
    init(acceptingOn socketPath: KSSocketPath) async throws {
        try? FileManager.default.removeItem(atPath: socketPath.path)

        let parameters = Self.makeParameters()
        parameters.requiredLocalEndpoint = NWEndpoint(ksSocketPath: socketPath)

        let listener = try NWListener(using: parameters)
        guard let connection = try await listener.ksFirstConnection else {
            throw Error.cancelled
        }

        try await connection.ksWaitUntilReady()
        self.connection = connection
    }

    /// Whether or not the connection has been closed.
    var isClosed: Bool {
        connection.state != .ready
    }

    /// Closes the connection associated with this channel. Any pending receive fails, which ends
    /// the message sequence.
    func close() {
        connection.cancel()
    }

    // MARK: - Receiving

    /// One framed message: the plist-encoded header and the raw payload (JPEG bytes for an image).
    /// The header is returned undecoded so the caller can drop a frame BEFORE paying for any decode.
    struct RawMessage {
        let header: Data
        let payload: Data?
    }

    /// Receives the next message. Nil when the connection was closed by either side.
    func nextMessage() async throws -> RawMessage? {
        let raw = try await connection.ksReceiveSingleMessage()
        guard let data = raw.data, raw.isComplete else { return nil }
        guard let payloadSize = raw.context?.ksIPCMessagePayloadSize,
              payloadSize <= data.count else { throw Error.corruptMessage }
        guard payloadSize > 0 else { return RawMessage(header: data, payload: nil) }
        let headerSize = data.count - payloadSize
        return RawMessage(header: data.subdata(in: 0 ..< headerSize),
                          payload: data.subdata(in: headerSize ..< data.count))
    }
}

// MARK: - Extensions

private extension NWListener {
    var ksNewConnections: AsyncThrowingStream<NWConnection, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.cancel()
            }
            newConnectionHandler = { connection in
                continuation.yield(connection)
            }
            stateUpdateHandler = { state in
                switch state {
                case .cancelled: continuation.finish()
                case let .waiting(error): continuation.finish(throwing: error)
                case let .failed(error): continuation.finish(throwing: error)
                default: break
                }
            }
            start(queue: KSIPCChannel.queue)
        }
    }

    var ksFirstConnection: NWConnection? {
        get async throws { try await ksNewConnections.first { _ in true } }
    }
}

private extension NWConnection {
    func ksWaitUntilReady() async throws {
        for await state in ksStateUpdates {
            switch state {
            case .ready: return
            case .setup, .preparing: continue
            case .waiting:
                let restartDelay = UInt64(KSIPCChannel.restartDelay * Double(NSEC_PER_SEC))
                try await Task.sleep(nanoseconds: restartDelay)
                restart()
                continue
            case let .failed(error): throw error
            case .cancelled:
                throw KSIPCChannel.Error.cancelled
            @unknown default: continue
            }
        }
        throw KSIPCChannel.Error.cancelled
    }

    private var ksStateUpdates: AsyncStream<NWConnection.State> {
        AsyncStream { [weak self] continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stateUpdateHandler = nil
            }
            self?.stateUpdateHandler = { state in
                continuation.yield(state)
            }
            self?.start(queue: KSIPCChannel.queue)
        }
    }

    struct KSIncomingMessage {
        let data: Data?
        let context: NWConnection.ContentContext?
        let isComplete: Bool
    }

    func ksReceiveSingleMessage() async throws -> KSIncomingMessage {
        try await withCheckedThrowingContinuation { continuation in
            receiveMessage { data, context, isComplete, error in
                guard let error else {
                    continuation.resume(returning: KSIncomingMessage(data: data, context: context, isComplete: isComplete))
                    return
                }
                continuation.resume(throwing: error)
            }
        }
    }
}

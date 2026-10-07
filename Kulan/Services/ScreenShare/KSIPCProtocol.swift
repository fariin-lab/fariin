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

// Modified for Kulan: copied from LiveKit 2.17.0 Broadcast/IPC/IPCProtocol.swift (internal there),
// renamed with a KS prefix and logging removed. The WIRE FORMAT is unchanged and must stay so: an
// 8-byte header (UInt32 total size, UInt32 payload size, host byte order) before each message, which
// is what the extension's LKSampleHandler writes.

import Foundation
import Network

/// A simple framing protocol suitable for inter-process communication.
final class KSIPCProtocol: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: KSIPCProtocol.self)
    static var label: String { "KSIPCProtocol" }

    fileprivate struct Header {
        /// Total number of bytes in the message.
        let totalSize: UInt32
        /// Number of bytes in the payload section.
        let payloadSize: UInt32
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete _: Bool) {
        let header = Header(
            totalSize: UInt32(messageLength),
            payloadSize: UInt32(message.ksIPCMessagePayloadSize ?? 0)
        )
        framer.writeOutput(data: header.encodedData)
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var tempHeader: Header?
            let parsed = framer.parseInput(
                minimumIncompleteLength: Header.encodedSize,
                maximumLength: Header.encodedSize
            ) { buffer, _ -> Int in
                guard let buffer else { return 0 }
                if buffer.count < Header.encodedSize { return 0 }
                tempHeader = Header(buffer)
                return Header.encodedSize
            }
            guard parsed, let header = tempHeader else {
                return Header.encodedSize
            }
            let message = NWProtocolFramer.Message(ksIPCMessagePayloadSize: Int(header.payloadSize))
            if !framer.deliverInputNoCopy(length: Int(header.totalSize), message: message, isComplete: true) {
                return 0
            }
        }
    }

    required init(framer _: NWProtocolFramer.Instance) {}
    func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer _: NWProtocolFramer.Instance) {}
    func stop(framer _: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer _: NWProtocolFramer.Instance) {}
}

extension NWConnection.ContentContext {
    var ksIPCMessagePayloadSize: Int? {
        guard let metadata = protocolMetadata(definition: KSIPCProtocol.definition) as? NWProtocolFramer.Message else {
            return nil
        }
        return metadata.ksIPCMessagePayloadSize
    }
}

private extension NWProtocolFramer.Message {
    private static let payloadSizeKey = "KSIPCProtocolPayloadSize"

    convenience init(ksIPCMessagePayloadSize: Int) {
        self.init(definition: KSIPCProtocol.definition)
        self[Self.payloadSizeKey] = ksIPCMessagePayloadSize
    }

    var ksIPCMessagePayloadSize: Int? {
        self[Self.payloadSizeKey] as? Int
    }
}

extension KSIPCProtocol.Header {
    init(_ buffer: UnsafeMutableRawBufferPointer) {
        var tempTotalSize: UInt32 = 0
        var tempPayloadSize: UInt32 = 0

        withUnsafeMutableBytes(of: &tempTotalSize) {
            $0.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.baseAddress!.advanced(by: 0),
                    count: MemoryLayout<UInt32>.size
                )
            )
        }
        withUnsafeMutableBytes(of: &tempPayloadSize) {
            $0.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.baseAddress!.advanced(by: MemoryLayout<UInt32>.size),
                    count: MemoryLayout<UInt32>.size
                )
            )
        }
        totalSize = tempTotalSize
        payloadSize = tempPayloadSize
    }

    var encodedData: Data {
        var tempTotalSize = totalSize
        var tempPayloadSize = payloadSize
        var data = Data(bytes: &tempTotalSize, count: MemoryLayout<UInt32>.size)
        data.append(Data(bytes: &tempPayloadSize, count: MemoryLayout<UInt32>.size))
        return data
    }

    static let encodedSize = MemoryLayout<UInt32>.size * 2
}

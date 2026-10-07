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

// Modified for Kulan: copied from LiveKit 2.17.0 Broadcast/IPC/SocketPath.swift (internal there),
// renamed with a KS prefix, logging removed, and the App Group socket lookup from
// BroadcastBundleInfo.swift folded in. The 1:1 call path receives the SAME socket the group (LiveKit)
// path does, so the one broadcast extension serves both.

import Foundation
import Network

/// A UNIX domain path valid on this system.
struct KSSocketPath {
    let path: String

    /// Creates a socket path or returns nil if the given path string is not valid.
    init?(_ path: String) {
        guard Self.isValid(path) else { return nil }
        self.path = path
    }

    /// Proper path validation is essential: the Network framework does not validate it, and
    /// connecting to a socket with an invalid path crashes.
    private static func isValid(_ path: String) -> Bool {
        path.utf8.count <= addressMaxLength
    }

    /// The maximum supported length (in bytes) for socket paths on this system.
    private static let addressMaxLength: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    // MARK: - The broadcast socket (same values LiveKit's BroadcastBundleInfo resolves to)

    /// App Group shared by the app and the broadcast extension.
    static let appGroup = "group.com.kulan.messenger.native"
    /// Bundle id of the broadcast upload extension (the system picker's `preferredExtension`).
    static let broadcastExtension = "com.kulan.messenger.native.broadcast"
    private static let socketFileName = "rtc_SSFD"

    /// `<App Group container>/rtc_SSFD`, or nil when the App Group is not provisioned.
    static var broadcast: KSSocketPath? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return KSSocketPath(container.appendingPathComponent(socketFileName).path)
    }
}

extension NWEndpoint {
    init(ksSocketPath socketPath: KSSocketPath) {
        self = .unix(path: socketPath.path)
    }
}

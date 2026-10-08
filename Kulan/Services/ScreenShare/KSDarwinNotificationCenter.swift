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

// Modified for Kulan: copied from LiveKit 2.17.0 Broadcast/Support/DarwinNotificationCenter.swift
// (internal there), renamed with a KS prefix. Screen share v3 (2026-10-08): the NAMES are now the
// v3 extension's own (Shared/ScreenShareIPC.swift; must stay equal to those constants), so every
// existing caller (CallService's late-start stop, GroupCallService) talks to the new extension.

import Combine
import Foundation

enum KSDarwinNotification: String {
    case broadcastStarted = "com.kulan.ss3.started"
    case broadcastStopped = "com.kulan.ss3.stopped"
    case broadcastRequestStop = "com.kulan.ss3.stop"
}

final class KSDarwinNotificationCenter: @unchecked Sendable {
    static let shared = KSDarwinNotificationCenter()
    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

    func postNotification(_ name: KSDarwinNotification) {
        CFNotificationCenterPostNotification(notificationCenter,
                                             CFNotificationName(rawValue: name.rawValue as CFString),
                                             nil,
                                             nil,
                                             true)
    }
}

extension KSDarwinNotificationCenter {
    /// Returns a publisher that emits events when broadcasting notifications matching the given name.
    func publisher(for name: KSDarwinNotification) -> Publisher {
        Publisher(notificationCenter, name)
    }

    /// A publisher that emits notifications.
    struct Publisher: Combine.Publisher {
        typealias Output = KSDarwinNotification
        typealias Failure = Never

        private let name: KSDarwinNotification
        private let center: CFNotificationCenter?

        fileprivate init(_ center: CFNotificationCenter?, _ name: KSDarwinNotification) {
            self.name = name
            self.center = center
        }

        func receive<S: Subscriber>(subscriber: S) where Never == S.Failure, KSDarwinNotification == S.Input {
            subscriber.receive(subscription: Subscription(subscriber, center, name))
        }
    }

    private class SubscriptionBase {
        let name: KSDarwinNotification
        let center: CFNotificationCenter?

        init(_ center: CFNotificationCenter?, _ name: KSDarwinNotification) {
            self.name = name
            self.center = center
        }

        static let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<SubscriptionBase>
                .fromOpaque(observer)
                .takeUnretainedValue()
                .notifySubscriber()
        }

        func notifySubscriber() {
            // Overridden by the generic subclass, so the C callback above can stay non-generic.
        }
    }

    private class Subscription<S: Subscriber>: SubscriptionBase, Combine.Subscription
        where S.Input == KSDarwinNotification, S.Failure == Never {
        private var subscriber: S?

        init(_ subscriber: S, _ center: CFNotificationCenter?, _ name: KSDarwinNotification) {
            self.subscriber = subscriber
            super.init(center, name)
            addObserver()
        }

        func request(_: Subscribers.Demand) {}

        private var opaqueSelf: UnsafeRawPointer {
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        }

        private func addObserver() {
            CFNotificationCenterAddObserver(center,
                                            opaqueSelf,
                                            Self.callback,
                                            name.rawValue as CFString,
                                            nil,
                                            .deliverImmediately)
        }

        private func removeObserver() {
            guard subscriber != nil else { return }
            CFNotificationCenterRemoveObserver(center,
                                               opaqueSelf,
                                               CFNotificationName(name.rawValue as CFString),
                                               nil)
            subscriber = nil
        }

        override func notifySubscriber() {
            _ = subscriber?.receive(name)
        }

        func cancel() {
            removeObserver()
        }

        deinit {
            removeObserver()
        }
    }
}

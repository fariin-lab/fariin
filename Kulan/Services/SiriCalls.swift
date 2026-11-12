import Foundation
import Intents
import FirebaseAuth

/// "Hey Siri, call Eric on Fariin" (owner 2026-11-12).
///
/// Fariin has no phone numbers, so Siri cannot find people in Contacts. It learns them the system
/// way instead: every call this phone makes is DONATED as an INStartCallIntent naming the person
/// (their uid as the handle), and Siri then offers those names. A spoken name Siri has never seen
/// is matched here against this account's 1:1 chats (`StartCallIntentHandler`). Calls from the
/// Phone app's Recents list arrive the same way.
enum SiriCalls {
    /// The activity types iOS hands the app for a call (Siri, Recents, CarPlay).
    static let activityTypes = [
        NSStringFromClass(INStartCallIntent.self),
        "INStartAudioCallIntent",
        "INStartVideoCallIntent",
    ]

    static func person(uid: String, name: String) -> INPerson {
        let comps = PersonNameComponentsFormatter().personNameComponents(from: name) ?? PersonNameComponents()
        return INPerson(personHandle: INPersonHandle(value: uid, type: .unknown),
                        nameComponents: comps, displayName: name, image: nil,
                        contactIdentifier: nil, customIdentifier: uid)
    }

    /// After a call starts: Siri learns that this name is a Fariin call.
    static func donate(uid: String, name: String, video: Bool) {
        guard !uid.isEmpty, !name.isEmpty else { return }
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil,
                                       audioRoute: .unknown, destinationType: .normal,
                                       contacts: [person(uid: uid, name: name)],
                                       callCapability: video ? .videoCall : .audioCall)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate(completion: nil)
        // No permission popup from the app (owner 2026-11-12: other apps never ask). Siri asks by
        // itself the first time someone uses it with Fariin.
    }

    /// 1:1 chats whose person's name matches what was said, best match first.
    @MainActor static func matches(_ spoken: String) -> [INPerson] {
        guard let me = Auth.auth().currentUser?.uid else { return [] }
        let said = fold(spoken)
        guard !said.isEmpty else { return [] }
        var exact: [INPerson] = [], partial: [INPerson] = []
        for c in ConversationsRepository.shared.conversations where !c.isGroup && !c.isChannel {
            let uid = c.otherUid(me)
            guard !uid.isEmpty else { continue }
            let name = c.name(for: me)
            let n = fold(name)
            if n == said {
                exact.append(person(uid: uid, name: name))
            } else if n.hasPrefix(said + " ") || n.split(separator: " ").contains(Substring(said)) {
                partial.append(person(uid: uid, name: name))
            }
        }
        return exact.isEmpty ? partial : exact
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Siri (or Recents) handed the app a call: start it. Returns whether it was one.
    @MainActor @discardableResult
    static func handle(_ activity: NSUserActivity) -> Bool {
        guard let intent = activity.interaction?.intent else { return false }
        let contact: INPerson?
        var video = false
        if let i = intent as? INStartCallIntent {
            contact = i.contacts?.first
            video = i.callCapability == .videoCall
        } else if let i = intent as? INStartVideoCallIntent {
            contact = i.contacts?.first
            video = true
        } else if let i = intent as? INStartAudioCallIntent {
            contact = i.contacts?.first
        } else {
            return false
        }
        guard let contact else { return false }
        var uid = contact.customIdentifier ?? contact.personHandle?.value ?? ""
        var name = contact.displayName
        if uid.isEmpty, let found = matches(name).first {
            uid = found.customIdentifier ?? ""
            name = found.displayName
        }
        guard !uid.isEmpty else { return false }
        CallService.shared.startCall(to: uid, name: name, video: video)
        return true
    }
}

/// Siri's side of "call Eric on Fariin", answered inside the app (no Intents extension): finds the
/// person among this account's chats, then hands the call to the app.
final class StartCallIntentHandler: NSObject, INStartCallIntentHandling {
    func resolveContacts(for intent: INStartCallIntent,
                         with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let people = intent.contacts, !people.isEmpty else {
            completion([.needsValue()])
            return
        }
        Task { @MainActor in
            let results: [INStartCallContactResolutionResult] = people.map { p in
                if let id = p.customIdentifier, !id.isEmpty { return .success(with: p) }
                let found = SiriCalls.matches(p.displayName)
                switch found.count {
                case 0: return .unsupported()
                case 1: return .success(with: found[0])
                default: return .disambiguation(with: Array(found.prefix(5)))
                }
            }
            completion(results)
        }
    }

    func resolveCallCapability(for intent: INStartCallIntent,
                               with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void) {
        completion(.success(with: intent.callCapability == .videoCall ? .videoCall : .audioCall))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        let activity = NSUserActivity(activityType: NSStringFromClass(INStartCallIntent.self))
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }
}

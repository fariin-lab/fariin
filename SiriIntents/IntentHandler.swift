import Intents

/// Siri's door for "call Eric on Fariin" (owner 2026-11-12). Siri asks this extension first: it
/// accepts the person (a name Siri learned from a donated call carries the Fariin uid; a name it
/// has not seen is matched against the chats by the app itself) and hands the call to the app,
/// which starts it (SiriCalls.handle). No data of its own.
final class IntentHandler: INExtension, INStartCallIntentHandling {
    override func handler(for intent: INIntent) -> Any { self }

    func resolveContacts(for intent: INStartCallIntent,
                         with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let people = intent.contacts, !people.isEmpty else {
            completion([.needsValue()])
            return
        }
        completion(people.map { .success(with: $0) })
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

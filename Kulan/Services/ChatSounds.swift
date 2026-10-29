import Foundation
import AudioToolbox

/// The short sound when a message I sent reaches the server (owner 2026-10-29). Played once the
/// server has it, never at the tap: a message that never goes through never makes the sound, and a
/// photo or video makes it when its upload is done, not when its bubble appears. Whether the other
/// person is online does not matter; that is the ticks' job, not this sound's.
///
/// The file is our own (Resources/Sounds/sent.wav). Played as a system sound, so the ring/silent
/// switch silences it like any other alert. Settings > Notifications > Sound When Sent.
enum ChatSounds {
    static let sentKey = "chat.sentSound"

    static var sentOn: Bool { UserDefaults.standard.object(forKey: sentKey) as? Bool ?? true }

    private static let sentID: SystemSoundID = {
        var id: SystemSoundID = 0
        if let url = Bundle.main.url(forResource: "sent", withExtension: "wav") {
            AudioServicesCreateSystemSoundID(url as CFURL, &id)
        }
        return id
    }()
    private static var lastSent = Date.distantPast

    /// Ten photos landing together make one sound, not ten.
    static func sent() {
        guard sentOn, sentID != 0, Date().timeIntervalSince(lastSent) > 0.3 else { return }
        lastSent = Date()
        AudioServicesPlaySystemSound(sentID)
    }
}

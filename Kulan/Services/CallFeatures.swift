import Foundation

/// Call features that are built but not ready to show — owner, 2026-10-08: "hide and feature-flag
/// the Create Call Link and Group Call features for now. We will complete them in the future."
/// Only person-to-person calls and screen sharing stay visible. Nothing is deleted: flip a switch
/// to `true` and every entry point it guards comes back.
///
/// Receiving stays on where switching it off would break a call another phone already started:
/// a 1:1 moved onto a multi-person call from the other side still shows its call screen.
enum CallFeatures {
    /// Group calls: the call buttons on a group, its "Join call" bar, "Add people" in a call, and
    /// the full-screen invitation when someone adds me.
    static let groupCalls = false
    /// Call links: the "Create a Call Link" row and saved links on the Calls tab, and opening a
    /// link's pre-join screen from a chat, a web link or the list.
    static let callLinks = false
}

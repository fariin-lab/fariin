import SwiftUI

// EXPERIMENTAL "Telegram Conversation" mode — Settings › Privacy & Security.
//
// A comparison switch, not a rewrite. Kulan's conversation code stays exactly as it was; every
// Telegram-derived value is read through this type, so with the toggle OFF the app computes the
// original numbers and behaves byte-for-byte as before. Only with it ON do the Telegram values apply.
//
// Same pattern the earlier "Telegram Media Open" experiment used, which was explicitly built so that
// toggle-OFF was byte-for-byte the existing behaviour.
//
// Values are read from Telegram iOS's own source, cited per property. Nothing is copied from their
// code — these are measurements and rules reproduced in our SwiftUI stack.
enum TGMode {
    static let key = "experimentalTelegramConversation"

    /// Read outside SwiftUI (helper funcs, static geometry). Views should ALSO hold an
    /// `@AppStorage(TGMode.key)` so flipping the switch re-renders them.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    // MARK: - Bubble grouping & merging
    //
    // `ChatMessageItemCommon.swift` → ChatMessageItemLayoutConstants.bubble / .image ("regular" set),
    // and `ChatMessageItemImpl.mergedWithItems`.
    //
    // The structural point their source makes: grouping is carried by CORNER RADIUS, not by gaps.
    // Merged neighbours sit flush (0pt) and differ only in the corners on the joined edge. Kulan's
    // original model used a 14pt gap between clusters, which reads as separate blocks.

    /// `mergedWithItems`: `abs(lhsEffectiveTimestamp - rhsEffectiveTimestamp) < Int32(10 * 60)`.
    /// Kulan's original: 300s.
    static var mergeWindow: TimeInterval { enabled ? 600 : 300 }

    /// `bubble.defaultSpacing` = 2.0 + UIScreenPixel. Kulan's original: 14.
    static var clusterSpacing: CGFloat {
        enabled ? 2.0 + 1.0 / max(1, UIScreen.main.scale) : 14
    }

    /// `bubble.mergedSpacing` = 0.0. Kulan's original: 2.
    static var mergedSpacing: CGFloat { enabled ? 0 : 2 }

    /// `image.defaultCornerRadius` = 16.0 (regular). Kulan's original: 18.
    static var cornerRadius: CGFloat { enabled ? 16 : 18 }

    /// `image.mergedCornerRadius` = 8.0 (regular). Kulan's original: 6.
    static var mergedCornerRadius: CGFloat { enabled ? 8 : 6 }

    /// Telegram returns `.none` from `mergedWithItems` for `TelegramMediaAction` and
    /// `TelegramMediaExpiredContent`, so those rows never merge with a neighbour. Kulan's original
    /// clustering had no such rule (it merged on author + time alone).
    static var excludeServiceFromMerging: Bool { enabled }
}

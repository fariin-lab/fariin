import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13).
//
// When someone screenshots a 1:1 or group chat, we offer to redo the picture: drop messages, hide
// text, change the background, add the Fariin mark. Everything here works on a COPY of what was
// already on screen and already decrypted. Nothing is fetched, nothing is uploaded, and nothing
// reads a message that was not in the list at the moment of the screenshot.

/// One message as the picture draws it. A plain copy, so the editor never holds a live `Message`
/// and later changes to the chat (an edit, a delete) cannot reach into a picture being made.
struct ShotMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case system                       // "X added Y", shown as a centred line
        case media(symbol: String, label: String)
    }

    let id: String
    let kind: Kind
    let text: String
    let isMe: Bool
    let senderUid: String
    /// Someone else's name in a group. Drawn only where a run starts (see `ShotPlacement`).
    let senderName: String?
    let time: Date
    let tick: BubbleTicks.Kind
    /// The day label the chat uses. Drawn only where the day changes (see `ShotPlacement`).
    let day: String
    let replyName: String?
    let replyText: String?
    let edited: Bool
    let forwarded: Bool
    /// A photo or video frame that is already decoded in memory. Never fetched for the picture.
    let image: UIImage?

    static func == (a: ShotMessage, b: ShotMessage) -> Bool { a.id == b.id }
}

/// What the screenshot caught, frozen at that moment.
struct ScreenshotSnapshot: Identifiable {
    let id = UUID()
    let cid: String
    let isGroup: Bool
    let messages: [ShotMessage]
}

extension ScreenshotSnapshot {
    /// Builds the copy from the rows that were on screen. The chat passes its own helpers in, so the
    /// names, day labels and ticks are the ones it already draws.
    @MainActor
    static func make(cid: String, messages: [Message], me: String, isGroup: Bool,
                     readMillis: Double, deliveredMillis: Double, iBlocked: Bool,
                     name: (String) -> String, dayLabel: (Date) -> String) -> ScreenshotSnapshot {
        var out: [ShotMessage] = []
        for m in messages {
            // Content that was never meant to be kept stays out of the picture: view-once media,
            // rows this phone cannot read, and calls (they are not part of the conversation text).
            if m.viewOnce || m.notForMe || m.sealUnreadable == true || m.isCall || m.deleted { continue }
            guard let kind = kind(of: m) else { continue }
            let isMe = m.authorId == me
            out.append(ShotMessage(
                id: m.rowId,
                kind: kind,
                text: m.text,
                isMe: isMe,
                senderUid: m.authorId,
                senderName: isGroup && !isMe && kind != .system ? name(m.authorId) : nil,
                time: min(m.createdAt, Date()),
                tick: tick(m, isMe: isMe, read: readMillis, delivered: deliveredMillis, iBlocked: iBlocked),
                day: dayLabel(m.createdAt),
                replyName: m.replyTo.map { name($0.authorId) },
                replyText: m.replyTo.map { $0.text.isEmpty ? "Message" : $0.text },
                edited: m.edited,
                forwarded: m.forwarded,
                image: image(of: m)))
        }
        return ScreenshotSnapshot(cid: cid, isGroup: isGroup, messages: out)
    }

    private static func kind(of m: Message) -> ShotMessage.Kind? {
        if m.isSystem { return m.text.isEmpty ? nil : .system }
        if m.isSticker { return .media(symbol: "face.smiling", label: m.stickerEmoji ?? "Sticker") }
        if m.isAlbum { return .media(symbol: "photo.on.rectangle", label: "Photos") }
        if m.isImage { return .media(symbol: "photo", label: "Photo") }
        if m.isGif { return .media(symbol: "photo", label: "GIF") }
        if m.isVideo { return .media(symbol: "video", label: "Video") }
        if m.isAudio { return .media(symbol: "waveform", label: "Voice message") }
        if m.isFile { return .media(symbol: "doc", label: m.fileName ?? "File") }
        if let t = m.type, !t.isEmpty, t != "text" {
            // A kind this picture does not draw (poll, location, contact…): a neutral chip, never
            // a guess at its content.
            return m.text.isEmpty ? .media(symbol: "square.text.square", label: "Message") : .text
        }
        return m.text.isEmpty ? nil : .text
    }

    private static func tick(_ m: Message, isMe: Bool, read: Double, delivered: Double,
                             iBlocked: Bool) -> BubbleTicks.Kind {
        guard isMe else { return .none }
        switch m.sendState {
        case .sending: return .sending
        case .failed: return .failed
        case nil:
            if m.held || iBlocked { return .sent }
            let sent = m.createdAt.timeIntervalSince1970 * 1000
            if read >= sent { return .read }
            return delivered >= sent ? .delivered : .sent
        }
    }

    /// Only what is already in memory: the decoded photo, or the small preview that came inside the
    /// message. The picture never starts a download.
    private static func image(of m: Message) -> UIImage? {
        if m.isImage || m.isVideo {
            let url = m.isVideo ? m.thumbUrl : m.imageUrl
            if let url, !url.isEmpty, let hit = DiskImageCache.shared.memoryImage(url) { return hit }
            if let data = m.localImageData, let local = UIImage(data: data) { return local }
            return m.previewImage
        }
        return nil
    }
}

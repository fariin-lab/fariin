import Foundation
import UIKit

// OUR OWN STICKERS, THE ONES THAT SHIP WITH THE APP.
//
// The sticker tray is a search endpoint and nothing in it belongs to us: every picture in there is
// somebody else's, fetched on demand, and a phone with no signal opens a tray with nothing in it.
// This is the first tab that is ours — the owner drew these and asked for a tab of his own for them
// (2026-08-21, seven static stickers).
//
// ⛔ THEY RIDE THE SAME PIPE AS EVERY OTHER STICKER, on purpose. A `GiphyService.Gif` is what the
// tray hands to the editor, what the recents list stores and what the editor turns into a picture —
// four places that would each need a second code path if a local sticker were its own type. So a
// built-in is a `Gif` whose `url` carries our own scheme, and the two places that actually touch
// bytes ask `isOurs` first. Everything between them cannot tell the difference, including recents,
// which means one of these turning up in the clock tab works with no extra code at all.
//
// ⚠️ `sticker://` IS NOT A REAL URL SCHEME AND MUST NEVER REACH THE NETWORK. Both readers below are
// the guard: `StoryStickerSheet.cell` draws it from the bundle instead of asking `AnimatedGifView`,
// and `StoryEditorView.stickerStill` loads it from the bundle instead of `URLSession`. Anything else
// that starts fetching a sticker url has to learn the same thing.
enum BuiltInStickers {
    static let scheme = "sticker://"

    /// The filename in `Kulan/Resources/Stickers`, without the extension. The `id` is what recents
    /// store, so it has to stay stable even if a drawing is replaced.
    struct Item: Identifiable {
        let id: String
        let file: String
    }

    /// ⚠️ THE ORDER IS THE ORDER ON SCREEN. No sorting anywhere — the tray draws this list as it is.
    ///
    /// ⚠️ AND THE NAMES ARE OURS, not the ones the files arrived with. One of them was called after
    /// another company's product; the drawing carries no mark of theirs, but the name would have gone
    /// into the repo, the bundle and every build. It is `new_story_blue` here.
    static let all: [Item] = [
        Item(id: "fariin.new_story_blue", file: "sticker_new_story_blue"),
        Item(id: "fariin.new_story_red",  file: "sticker_new_story_red"),
        Item(id: "fariin.love_burst",     file: "sticker_love_burst"),
        Item(id: "fariin.love_heart",     file: "sticker_love_heart"),
        Item(id: "fariin.heart_walk",     file: "sticker_heart_walk"),
        Item(id: "fariin.yay",            file: "sticker_yay"),
        Item(id: "fariin.coming_soon",    file: "sticker_coming_soon"),
    ]

    /// All of them in the shape the tray already knows how to lay out. 512 square is what they are on
    /// disk, and the grid draws a square cell, so nothing is measured at runtime.
    static let gifs: [GiphyService.Gif] = all.map {
        GiphyService.Gif(id: $0.id, url: scheme + $0.file, width: 512, height: 512)
    }

    static func isOurs(_ url: String) -> Bool { url.hasPrefix(scheme) }

    /// The picture behind one of our urls, or nil if the url is not ours.
    ///
    /// ⚠️ `Bundle.main.url(forResource:)`, NOT `UIImage(named:)`. These are loose files copied into
    /// the bundle rather than entries in the asset catalogue, and the bundle lookup is what the app
    /// already uses for every other loose resource — `wp-pattern`, the ringtones. `UIImage(named:)`
    /// would probably find them too and "probably" is a fifteen-minute round trip to find out.
    ///
    /// Decoded once and kept: the tray draws seven of these in a grid somebody scrolls past twice,
    /// and reading the same file off disk each time is work with nothing to show for it. Seven 512
    /// squares is a couple of megabytes and they are on screen for as long as the tray is open.
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ url: String) -> UIImage? {
        guard isOurs(url) else { return nil }
        let name = String(url.dropFirst(scheme.count))
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let file = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = UIImage(contentsOfFile: file.path) else { return nil }
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

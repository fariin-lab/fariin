//
//  SwiftUIView.swift
//  
//
//  Created by Tolga İskender on 4.06.2023.
//

import SwiftUI

struct EmojiView: View {
    
    var story: Story
    var emojiArray: [[String]]?
    
    @Binding var startAnimating: Bool
    @Binding var selectedEmoji: String
    
    let userClosure: UserCompletionHandler?
    
    // TELEGRAM LOOK (story reply reactions): one compact row of small emojis inside a rounded
    // translucent pill with a "Send reaction as a private message" caption and a trailing chevron
    // — instead of the old big 50pt 2-row grid.
    private var flatEmojis: [String] { emojiArray?.flatMap { $0 } ?? [] }

    var body: some View {
        if !flatEmojis.isEmpty {
            VStack(spacing: 5) {
                Text("Send reaction as a private message")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                HStack(spacing: 0) {
                    ForEach(flatEmojis.indices, id: \.self) { i in
                        Button(flatEmojis[i]) {
                            let emoji = flatEmojis[i]
                            startAnimate()
                            select(emoji: emoji)
                            dismissKeyboard()
                            userClosure?(story, nil, emoji, false)
                        }
                        .font(.system(size: 26))
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            // Compact DARK reaction bar (user: smaller + darker, no chevron): ~62pt tall,
            // 24pt radius, dark-tinted Liquid Glass. WIDTH matches the "Send message" pill below it
            // (user: "make it the size of the pill"): same 16pt left edge, and the right edge stops
            // ~44pt short of the screen — exactly where the pill ends before its heart button — so
            // the bar and the input pill line up as one matched stack instead of the bar overhanging.
            .padding(.horizontal, 14)
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .reactionGlass(24)
            .padding(.leading, 16)
            .padding(.trailing, 44)
        }
    }
    
    private func dismissKeyboard() {
        UIApplication.shared.windows.filter {$0.isKeyWindow}.first?.endEditing(true)
    }
    
    private func select(emoji: String) {
        selectedEmoji = emoji
    }
    
    private func startAnimate() {
       startAnimating = true
    }
}

private extension View {
    // Real Apple Liquid Glass (iOS 26) when available; a translucent dark fill on older iOS
    // (the StoryUI package deploys below iOS 26, so the glass must be availability-guarded).
    @ViewBuilder func reactionGlass(_ radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            // DARK-tinted Liquid Glass (user: make it darker than the default light glass).
            self.glassEffect(.regular.tint(Color.black.opacity(0.45)), in: shape)
        } else {
            self.background(shape.fill(Color.black.opacity(0.6)))
        }
    }
}

struct EmojiView_Previews: PreviewProvider {
    static var previews: some View {
        EmojiView(story: .init(mediaURL: "", date: "", config: StoryConfiguration(mediaType: .image)),
                  emojiArray: [["😂", "😮", "😍"]],
                  startAnimating: .constant(false),
                  selectedEmoji: .constant("🤪"),
                  userClosure: nil)
    }
}

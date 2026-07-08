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
            VStack(spacing: 8) {
                Text("Send reaction as a private message")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.6))
                HStack(spacing: 0) {
                    ForEach(flatEmojis.indices, id: \.self) { i in
                        Button(flatEmojis[i]) {
                            let emoji = flatEmojis[i]
                            startAnimate()
                            select(emoji: emoji)
                            dismissKeyboard()
                            userClosure?(story, nil, emoji, false)
                        }
                        .font(.system(size: 30))
                        .frame(maxWidth: .infinity)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 22)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 14)
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

struct EmojiView_Previews: PreviewProvider {
    static var previews: some View {
        EmojiView(story: .init(mediaURL: "", date: "", config: StoryConfiguration(mediaType: .image)),
                  emojiArray: [["😂", "😮", "😍"]],
                  startAnimating: .constant(false),
                  selectedEmoji: .constant("🤪"),
                  userClosure: nil)
    }
}

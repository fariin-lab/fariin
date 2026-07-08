//
//  SwiftUIView.swift
//
//
//  Created by Tolga İskender on 3.06.2023.
//

import SwiftUI

struct MessageView: View {
    
    // MARK: Public Properties
    var story: Story
    
    @Binding var showEmoji: Bool
    let userClosure: UserCompletionHandler?
    
    // MARK: Private Properties
    @State private var text: String = ""
    @State private var likeButtonTapped: Bool = false
    @State private var clearText: Bool = false
    @FocusState private var replyFocused: Bool   // swipe-up on a friend's story focuses the reply field


    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                switch story.config.storyType {
                case .plain(let config):
                    HStack {
                        Spacer()
                        buttonViewBuilder(config)
                    }
                case .message(let config, _, let placeholder):
                    messageViewBuilder(config, placeholder)
                }
            }
        }
        // Swipe-up on a friend's story opens the keyboard, exactly like tapping the reply pill
        // (the host posts this when it detects an upward swipe on a non-owner story).
        .onReceive(NotificationCenter.default.publisher(for: .init("focusStoryReply"))) { _ in
            replyFocused = true
        }
    }
}

private extension MessageView {
    var onCommitAction: () -> Void {
        return {
            guard !text.isEmpty else {
                return
            }
            clearText.toggle()
            userClosure?(story, text, nil, false)
            // Close the keyboard after sending (WhatsApp: send → keyboard dismisses, story resumes).
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    
    var likeButton: some View  {
        Button {
            likeButtonTapped.toggle()
            userClosure?(story, text, nil, likeButtonTapped)
        } label: {
            Image(systemName: likeButtonTapped ? Constant.MessageView.likeImageTapped : Constant.MessageView.likeImage)
                .font(.title3)                                   // smaller heart
                .foregroundColor(likeButtonTapped ? .red : .white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)   // soft shadow (WhatsApp) so it reads on any photo
                .scaleEffect(likeButtonTapped ? 1.18 : 1.0)      // pop when you give love
                .animation(.spring(response: 0.3, dampingFraction: 0.45), value: likeButtonTapped)
        }
    }
    
    @ViewBuilder
    func buttonViewBuilder(_ config: StoryInteractionConfig?) -> some View {
        if let config {
            HStack(spacing: 16) {
                if config.showLikeButton {
                    likeButton
                }
            }
            .frame(height: Constant.MessageView.height)
        } else {
            EmptyView()
        }
    }
    
    
    func messageViewBuilder(_ config: StoryInteractionConfig?, _ placeholder: String) -> some View {
        HStack(spacing: 8) {   // spec: 8pt between the text pill and the side icon (heart/send)
            replyPill(placeholder)

            // Send button appears once you've typed (heart shows when empty) — was Return-key only.
            if text.isEmpty {
                buttonViewBuilder(config)
            } else {
                Button(action: onCommitAction) {
                    Image(systemName: "paperplane.fill").font(.title2).foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.55), radius: 6, y: 2)   // lifts off bright media (user)
                        .frame(width: 44, height: 44)        // bigger TAP target, same icon size
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Extracted so the type-checker has a bounded expression (adding .focused() to the inline chain
    // pushed it past the "cannot infer contextual base" limit).
    private func replyPill(_ placeholder: String) -> some View {
        // The styling is collapsed into ReplyPillStyle (a ViewModifier, type-checked on its own) so
        // adding .focused() no longer pushes the pill's chain past the type-checker's time limit.
        // .placeholder is defined on TextField specifically, so it must come FIRST (before .focused,
        // which returns some View).
        TextField("", text: $text, onCommit: onCommitAction)
            .placeholder(when: text.isEmpty, view: {
                Text(placeholder).foregroundColor(Color.white)
                    .shadow(color: Color.black.opacity(0.45), radius: 1.5)   // readable on white photos
            })
            .focused($replyFocused)
            .modifier(ReplyPillStyle())
            .onChange(of: text, perform: { newValue in showEmoji = newValue.isEmpty })
            .onChange(of: clearText, perform: { newValue in text = ""; showEmoji = newValue })
            .onChange(of: story, perform: { newValue in likeButtonTapped = newValue.isLiked })
            // onChange only fires on later swipes — seed the FIRST item's heart state too,
            // or a reopened story always shows an empty heart despite being liked.
            .onAppear { likeButtonTapped = story.isLiked }
    }
}

// The reply pill's visual styling, extracted so the type-checker handles it as one bounded unit.
private struct ReplyPillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundColor(Color.white)
            .shadow(color: Color.black.opacity(0.45), radius: 1.5)   // typed text stays readable on white photos
            .padding(.leading, 10)                              // small left space so text isn't flush to the edge
            .frame(height: Constant.MessageView.height)
            .padding(Constant.MessageView.padding)
            .background(Capsule().fill(Color.black.opacity(0.38)))   // filled pill, more native than a bare stroke
            .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
            // Deeper soft shadow (user round 2: still read flat over bright media) — the pill
            // lifts clearly off any photo; effectively invisible on dark ones.
            .shadow(color: Color.black.opacity(0.5), radius: 10, y: 3)
    }
}

struct MessageView_Previews: PreviewProvider {
    static var previews: some View {
        MessageView(story: Story(mediaURL: "", date: "", config: StoryConfiguration(mediaType: .image)), showEmoji: .constant(true), userClosure: nil)
    }
}


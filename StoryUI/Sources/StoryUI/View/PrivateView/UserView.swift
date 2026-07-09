//
//  UserView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 29.04.2022.
//

import SwiftUI

struct UserView: View {

    var image: String
    var name: String
    var date: String
    var onProfile: (() -> Void)?   // tap the avatar+name block → that user's profile
    var showMore: Bool = false     // show the "…" dropdown menu; its buttons post notifications the host runs
    var isMyStory: Bool = false    // my own story → Delete (red) instead of Hide Stories; no Forward

    @Binding var isPresented: Bool

    var body: some View {
        HStack(spacing: Constant.UserView.hStackSpace) {
            // Tappable header block (avatar 38pt + name 14pt + timestamp 12pt) → profile.
            HStack(spacing: Constant.UserView.hStackSpace) {
                CacheAsyncImage(urlString: image)   // 38×38 circle
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(date)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onProfile?() }

            Spacer()

            // "…" sits directly left of the X, same row, so they auto-align (no guessed padding).
            if showMore {
                // Tap "…" → DROPDOWN popover anchored under the button (native iOS Menu).
                Menu {
                    Button { NotificationCenter.default.post(name: .init("storyActionSave"), object: nil) }
                        label: { Label("Save", systemImage: "square.and.arrow.down") }
                    // Forward only makes sense on someone else's story.
                    if !isMyStory {
                        Button { NotificationCenter.default.post(name: .init("storyActionForward"), object: nil) }
                            label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    }
                    Button { NotificationCenter.default.post(name: .init("storyActionShare"), object: nil) }
                        label: { Label("Share", systemImage: "square.and.arrow.up") }
                    // No Delete here on my own story — the owner bar already has a trash button, so
                    // it lived in two places. Others' stories keep Hide Stories.
                    if !isMyStory {
                        Button { NotificationCenter.default.post(name: .init("storyActionHide"), object: nil) }
                            label: { Label("Hide Stories", systemImage: "eye.slash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.black.opacity(0.3)))   // subtle circle → clear on any photo
                        .frame(width: 44, height: 44)                      // keep the 44pt tap target
                        .contentShape(Rectangle())
                }
            }

            // 18pt glyph in a 44×44 touch target, now inside a subtle circle for visibility.
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.black.opacity(0.3)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    NotificationCenter.default.post(name: .replaceCurrentItem, object: nil)
                    isPresented = false
                }
        }
        .padding(.horizontal)
    }
}


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
                    // SAVE, FORWARD AND SHARE ARE MINE-ONLY. All three take somebody else's story
                    // OFF this app permanently, and a story is a promise that it is gone in 24
                    // hours. Save puts it in their camera roll, Forward puts it in another chat,
                    // and Share is the worst of the three because it hands the picture straight to
                    // Instagram or Messages. The author is never told any of it happened.
                    //
                    // Instagram, Snapchat and WhatsApp do not offer any of the three on another
                    // person's story. Telegram does, but only when the author switched it on for
                    // that story. Nobody sells it as a paid feature (owner asked, 2026-08-05).
                    //
                    // Forward used to be `!isMyStory`, which was exactly backwards. Screenshots
                    // still exist, and that is fine: this is about not building the door.
                    if isMyStory {
                        Button { NotificationCenter.default.post(name: .init("storyActionSave"), object: nil) }
                            label: { Label("Save", systemImage: "square.and.arrow.down") }
                        Button { NotificationCenter.default.post(name: .init("storyActionForward"), object: nil) }
                            label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                        Button { NotificationCenter.default.post(name: .init("storyActionShare"), object: nil) }
                            label: { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    // No Delete here on my own story — the owner bar already has a trash button, so
                    // it lived in two places. Others' stories keep Hide Stories.
                    if !isMyStory {
                        Button { NotificationCenter.default.post(name: .init("storyActionHide"), object: nil) }
                            label: { Label("Hide Stories", systemImage: "eye.slash") }
                        // Abuse reporting (App Store 1.2) — the host files the report doc.
                        Button(role: .destructive) { NotificationCenter.default.post(name: .init("storyActionReport"), object: nil) }
                            label: { Label("Report", systemImage: "exclamationmark.bubble") }
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


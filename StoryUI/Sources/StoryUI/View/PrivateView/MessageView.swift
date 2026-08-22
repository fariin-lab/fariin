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
            // Close the keyboard after sending (send → keyboard dismisses, story resumes).
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    
    var likeButton: some View  {
        Button {
            likeButtonTapped.toggle()
            userClosure?(story, text, nil, likeButtonTapped)
        } label: {
            Image(systemName: likeButtonTapped ? Constant.MessageView.likeImageTapped : Constant.MessageView.likeImage)
                // A step up from `.title3` on his 2026-08-12 screenshot: beside a full-width reply
                // pill the heart was reading as an afterthought rather than the other half of the
                // bar. `.title2` is the next size up, which is the same weight the send arrow beside
                // it already uses — so the two swap places without the row changing height.
                .font(.title2)
                .foregroundColor(likeButtonTapped ? .red : .white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)   // soft shadow so it reads on any photo
                .scaleEffect(likeButtonTapped ? 1.18 : 1.0)      // pop when you give love
                .animation(.spring(response: 0.3, dampingFraction: 0.45), value: likeButtonTapped)
                // ROOM TO BREATHE AND TO TAP (owner 2026-08-05: "React give more space plz" — the
                // heart sat squeezed against the screen edge). A 44pt target, Apple's floor.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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
            // ⛔ A MINIMUM HERE TOO, for the same reason: this is the whole reply ROW, and a fixed
            // 44 would clip the pill the moment it grew to a second line. The bar rises with the
            // field and the send circle hangs from the bottom of it (see `sendInset`).
            .frame(minHeight: Constant.MessageView.height)
        } else {
            EmptyView()
        }
    }
    
    
    /// ⚠️ THE SIDE BUTTON HANGS FROM THE BOTTOM, NOT THE MIDDLE (owner 2026-08-22: at five lines
    /// "sand button is canter… dont move real postion"). The pill is a growing field and the button
    /// is a fixed circle, so a centred row slides the circle up the pill's flank as the text grows
    /// and it ends up opposite the middle of the message instead of opposite the line being typed.
    ///
    /// The `sendInset` puts the resting position back exactly where it was: half the difference
    /// between the row's 44pt minimum and the 40pt circle is what centring used to give it at one
    /// line, so at one line nothing moves at all and only the grown states change.
    private var sendInset: CGFloat { (Constant.MessageView.height - Constant.MessageView.sendSize) / 2 }

    func messageViewBuilder(_ config: StoryInteractionConfig?, _ placeholder: String) -> some View {
        HStack(alignment: .bottom, spacing: 12) {   // 12pt between the pill and the side icon — 8 left the heart cramped
            replyPill(placeholder)

            // Send button appears once you've typed (heart shows when empty) — was Return-key only.
            if text.isEmpty {
                buttonViewBuilder(config)
                    .padding(.bottom, sendInset)
            } else {
                Button(action: onCommitAction) {
                    // His 2026-08-18: an arrow, not a paper plane. `arrow.up.circle.fill` is the
                    // send glyph iOS itself uses in a compose field, so it reads as a button rather
                    // than as a loose mark floating beside the pill.
                    // ⚠️ `.resizable()`, NOT a font size, and the 44 is now the CIRCLE rather than an
                    // invisible box around it. It used to be `.font(.title2)` inside a 44pt frame,
                    // so the tap target matched the pill and the thing you could see was half its
                    // height — a 22pt mark floating next to a 44pt field (owner 2026-08-19). Same
                    // number as `Constant.MessageView.height`, so the two cannot drift apart.
                    Image(systemName: "arrow.up.circle.fill")
                        .resizable().scaledToFit()
                        .foregroundColor(.white)
                        .frame(width: Constant.MessageView.sendSize, height: Constant.MessageView.sendSize)
                        .shadow(color: Color.black.opacity(0.55), radius: 6, y: 2)   // lifts off bright media (user)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, sendInset)
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
        //
        // ⛔ IT GROWS TO FIVE LINES NOW, and it used to be one (his 2026-08-21 screenshot: a long
        // reply scrolled sideways inside a 44pt pill, with the beginning of his own sentence gone).
        // `axis: .vertical` plus a lineLimit RANGE is the whole mechanism; the pill's fixed height
        // became a MINIMUM in `ReplyPillStyle` so it has somewhere to grow into.
        //
        // ⛔ AND `onCommit:` IS GONE, WHICH IS THE CRASH. His .ips: EXC_BAD_ACCESS with a pointer
        // authentication failure, and the top of the faulting stack is
        // `PlatformTextFieldCoordinator.triggerPrimaryAction()` → `StateOrBinding.wrappedValue.setter`
        // → `AnyLocation.set`. That is the return key running the send, the send tearing this view
        // down, and SwiftUI then writing back through a binding whose storage has gone. A vertical
        // field has no primary action at all — Return inserts a newline — so the path the crash
        // travelled does not exist any more, and the arrow beside the pill is the one way to send,
        // which is what a multi-line composer does everywhere else.
        // ⚠️ `.placeholder` COMES FIRST AND `.lineLimit` AFTER IT. The note above this line has
        // always said so and I put the lineLimit above it anyway: `.placeholder` is declared on
        // `TextField` itself, not on `View`, so anything that returns `some View` before it takes
        // the member away — "value of type 'some View' has no member 'placeholder'".
        TextField("", text: $text, axis: .vertical)
            .placeholder(when: text.isEmpty, view: {
                Text(placeholder).foregroundColor(Color.white)
                    .shadow(color: Color.black.opacity(0.45), radius: 1.5)   // readable on white photos
            })
            .lineLimit(1...5)
            .focused($replyFocused)
            .modifier(ReplyPillStyle())
            .onChange(of: text, perform: { newValue in showEmoji = newValue.isEmpty })
            // clearText is a TOGGLE (its value flips each send) — assigning it to showEmoji hid
            // the emoji strip after every 2nd reply. After a send the field is empty, so always show.
            .onChange(of: clearText, perform: { _ in text = ""; showEmoji = true })
            .onChange(of: story, perform: { newValue in likeButtonTapped = newValue.isLiked })
            // onChange only fires on later swipes — seed the FIRST item's heart state too,
            // or a reopened story always shows an empty heart despite being liked.
            .onAppear { likeButtonTapped = story.isLiked }
    }
}

// The reply pill's visual styling, extracted so the type-checker handles it as one bounded unit.
private struct ReplyPillStyle: ViewModifier {
    /// Half the resting height, so a one-line pill is identical to the capsule this replaced, and a
    /// grown one keeps the same corner instead of stretching it. The caption bar's own number is 26
    /// for the same reason and against its own taller resting height.
    private static let pill = RoundedRectangle(cornerRadius: Constant.MessageView.height / 2,
                                               style: .continuous)

    func body(content: Content) -> some View {
        content
            .foregroundColor(Color.white)
            .shadow(color: Color.black.opacity(0.45), radius: 1.5)   // typed text stays readable on white photos
            .padding(.leading, 10)                              // small left space so text isn't flush to the edge
            // ⛔ THE PADDING IS INSIDE THE MINIMUM NOW, AND THAT ORDER IS THE WHOLE SIZE FIX.
            //
            // These two lines were the other way round, so the 6pt of breathing room was added
            // OUTSIDE the 44pt floor and a one-line pill stood 56 — his "you changed the size of the
            // bar, make it the size it was before". Padding first, floor second: one line is
            // `max(lineHeight + 12, 44)`, which is 44 exactly as it always was, and a pill that has
            // grown past the floor still keeps its words off the edges.
            .padding(.vertical, 6)
            // A MINIMUM, NOT A HEIGHT. It was `.frame(height:)`, which is what pinned the field to
            // one line and made a long reply scroll sideways inside it. The pill starts at the same
            // 44 and grows with the text, up to the five lines the field allows.
            .frame(minHeight: Constant.MessageView.height)
            .padding(Constant.MessageView.padding)
            // ⛔ NOT A CAPSULE, FOR THE REASON THE CAPTION BAR IS NOT ONE EITHER.
            //
            // His report: at three lines the bar still wears full round ends, and it should behave
            // like the caption bar. It should, and the caption bar already wrote down why — a
            // capsule's radius is half its height, so a field that GROWS turns its ends into huge
            // lozenges as it goes. That bar settled on a fixed continuous radius for exactly this.
            //
            // 22 is not a new look at rest: the pill's resting height is 44, so a capsule was
            // already drawing a 22pt radius there. One line is unchanged and only the tall states
            // differ, which is the half he asked about.
            .background(Self.pill.fill(Color.black.opacity(0.38)))   // filled pill, more native than a bare stroke
            .overlay(Self.pill.stroke(Color.white.opacity(0.5), lineWidth: 1))
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


import SwiftUI

// ⛔ SUBSCRIPTIONS, A PREVIEW — owner 2026-10-27: "build the Subscriptions page UI now, I will build
// the features later". Shown only to @v (SettingsView). NOTHING HERE IS REAL YET: no purchase, no
// StoreKit, no feature switched on. The button says "Coming Soon" and does nothing, and the line
// under it says these are previews, so the page never claims to sell or unlock anything.
// TODO: StoreKit 2 products, a server check of the entitlement, and each feature built for real.
//
// owner 2026-10-27 (second look): the star alone on top (no disc), the rows' icons drawn like the
// Settings rows (`SettingsRowLabel`: a 20pt outline glyph, no coloured tile), the button pinned at
// the foot so it never needs a scroll, and a tap on a feature opens a sheet that explains it.

struct SubscriptionsView: View {
    fileprivate struct Feature: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let more: String
    }

    private let features: [Feature] = [
        .init(id: "files", icon: "arrow.up.doc", title: "Bigger Files",
              detail: "Send files and videos up to 4 GB each.",
              more: "Share long videos, big documents and whole folders in one go, in any chat. Everyone can still open what you send, whether they have Plus or not."),
        .init(id: "speed", icon: "bolt", title: "Faster Downloads",
              detail: "Photos, videos and files arrive at full speed.",
              more: "Media you open downloads at the full speed of your connection, so long videos and large files are ready sooner."),
        .init(id: "voice", icon: "waveform", title: "Voice to Text",
              detail: "Read a voice message when you can't listen.",
              more: "Tap a voice message to see what was said as text. Useful in a meeting, on the bus, or anywhere you can't play sound."),
        .init(id: "translate", icon: "character.bubble", title: "Translate Chats",
              detail: "Read any message in your own language.",
              more: "Messages in another language show a Translate button. Your own messages are sent as you wrote them."),
        .init(id: "folders", icon: "folder", title: "More Folders and Pins",
              detail: "Up to 20 chat folders and 10 pinned chats.",
              more: "Sort your chats into more folders and keep more of them pinned at the top of your list."),
        .init(id: "stickers", icon: "face.smiling", title: "Extra Stickers and Reactions",
              detail: "Packs and reactions only members get.",
              more: "New sticker packs and reactions that only Plus members can send. Everyone in the chat still sees them."),
        .init(id: "video", icon: "person.crop.circle", title: "Video Profile Photo",
              detail: "A short moving clip on your profile.",
              more: "Set a few seconds of video as your profile picture. It plays when someone opens your profile."),
        .init(id: "icons", icon: "app.badge", title: "App Icons",
              detail: "Pick an icon for Fariin on your Home Screen.",
              more: "Choose from a set of extra app icons for your Home Screen."),
        .init(id: "quiet", icon: "eye.slash", title: "Quiet Story Viewing",
              detail: "Watch stories without showing up in the views.",
              more: "Watch stories without appearing in the list of who has seen them, for as long as you leave it on."),
        .init(id: "badge", icon: "star", title: "Member Badge",
              detail: "A star beside your name in chats and lists.",
              more: "A small star next to your name shows that you support Fariin."),
    ]

    @State private var opened: Feature?

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(features) { f in
                    Button { opened = f } label: { row(f) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("What's included").textCase(nil)
            }
        }
        .listSectionSpacing(20)
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        // Always on screen, at the foot (owner 2026-10-27: "no need to scroll for it").
        .safeAreaInset(edge: .bottom) { subscribeBar }
        .sheet(item: $opened) { f in FeatureSheet(feature: f) }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "star.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x7B61FF), Color(hex: 0x0A84FF), Color(hex: 0x2BD2C9)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(.top, 12)
            Text("Fariin Plus")
                .font(.system(size: 28, weight: .bold))
            Text("More of Fariin, and it helps keep the app free for everyone.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    /// The Settings row's look: a 20pt outline glyph in a 24pt slot, 16pt to the text.
    private func row(_ f: Feature) -> some View {
        HStack(spacing: 16) {
            Image(systemName: f.icon)
                .font(.system(size: 20))
                .frame(width: 24)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.body)
                Text(f.detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subscribeBar: some View {
        VStack(spacing: 8) {
            Button {} label: {
                Text("Coming Soon")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.onFariinAction)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Capsule().fill(Color.fariinAction.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(true)
            Text("A preview. These features aren't available yet and nothing can be bought here.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
        .background(.bar)
    }
}

/// One feature, explained: its icon, its name and a few lines on what it does.
private struct FeatureSheet: View {
    let feature: SubscriptionsView.Feature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CloseXButton(diameter: 44) { dismiss() }
            }
            .padding(.horizontal, 16).padding(.top, 14)
            Image(systemName: feature.icon)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.primary)
                .padding(.top, 4)
            Text(feature.title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Text(feature.more)
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28).padding(.top, 10)
            Spacer(minLength: 16)
            Text("Coming with Fariin Plus")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.hidden)
    }
}

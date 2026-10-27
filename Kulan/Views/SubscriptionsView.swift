import SwiftUI

// ⛔ SUBSCRIPTIONS, A PREVIEW — owner 2026-10-27: "build the Subscriptions page UI now, I will build
// the features later". Shown only to @v (SettingsView). NOTHING HERE IS REAL YET: no purchase, no
// StoreKit, no feature switched on. The button says "Coming Soon" and does nothing, and the footer
// says these are previews, so the page never claims to sell or unlock anything.
// TODO: StoreKit 2 products, a server check of the entitlement, and each feature built for real.

struct SubscriptionsView: View {
    @Environment(\.colorScheme) private var scheme

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    private let features: [Feature] = [
        .init(icon: "arrow.up.doc", tint: .blue, title: "Bigger Files",
              detail: "Send files and videos up to 4 GB each."),
        .init(icon: "bolt.fill", tint: .orange, title: "Faster Downloads",
              detail: "Photos, videos and files arrive at full speed."),
        .init(icon: "waveform", tint: .purple, title: "Voice to Text",
              detail: "Read a voice message when you can't listen."),
        .init(icon: "character.bubble", tint: .teal, title: "Translate Chats",
              detail: "Read any message in your own language."),
        .init(icon: "folder.fill", tint: .indigo, title: "More Folders and Pins",
              detail: "Up to 20 chat folders and 10 pinned chats."),
        .init(icon: "face.smiling", tint: .yellow, title: "Extra Stickers and Reactions",
              detail: "Packs and reactions only members get."),
        .init(icon: "person.crop.circle.badge.plus", tint: .pink, title: "Video Profile Photo",
              detail: "A short moving clip on your profile."),
        .init(icon: "app.badge", tint: .green, title: "App Icons",
              detail: "Pick an icon for Fariin on your Home Screen."),
        .init(icon: "eye.slash", tint: .gray, title: "Quiet Story Viewing",
              detail: "Watch stories without showing up in the views."),
        .init(icon: "star.fill", tint: Color(hex: 0xF5B400), title: "Member Badge",
              detail: "A star beside your name in chats and lists."),
    ]

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(features) { f in row(f) }
            } header: {
                Text("What's included").textCase(nil)
            }
            Section {
                VStack(spacing: 10) {
                    Button {} label: {
                        Text("Coming Soon")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(Capsule().fill(Color.fariinBlue.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    Text("A preview. These features aren't available yet and nothing can be bought here.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
            }
        }
        .listSectionSpacing(20)
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: 0x7B61FF), Color(hex: 0x0A84FF), Color(hex: 0x2BD2C9)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 92, height: 92)
                Image(systemName: "star.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color(hex: 0x0A84FF).opacity(0.35), radius: 18, y: 8)
            .padding(.top, 8)
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

    private func row(_ f: Feature) -> some View {
        HStack(spacing: 14) {
            Image(systemName: f.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(f.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.body.weight(.medium))
                Text(f.detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

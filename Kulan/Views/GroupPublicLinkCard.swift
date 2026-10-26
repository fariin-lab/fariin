import SwiftUI
import UIKit

/// ⛔ A PUBLIC GROUP'S LINK ON ITS INFO PAGE — 2026-10-19 groups v2. One card, one row: "Link" and
/// fariin.com/<name>. A tap offers Copy, Share and the QR code (the invite link's QR sheet,
/// `GroupLinkQRSheet`). Every member sees it: a public link is open to all by definition.
struct GroupPublicLinkCard: View {
    let name: String
    let title: String
    let cardColor: Color
    var photo: String? = nil        // for the QR card (owner 2026-10-20: it showed no photo)
    var memberCount: Int? = nil
    /// Inside another card (the About card on the group page): no surface of its own.
    var embedded = false

    @State private var showQR = false
    @State private var showShare = false
    @State private var copied = false

    private var link: String { GroupDirectory.link(name) }
    private var shownLink: String { "fariin.com/\(name)" }

    var body: some View {
        // A tap opens the share sheet straight away, the one Share Group uses (owner 2026-10-20);
        // the QR glyph opens the code; press and hold to copy.
        Button { showShare = true } label: { row }
            .buttonStyle(.plain)
            .contextMenu {
                Button { copy() } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            }
            .modifier(LinkCardSurface(on: !embedded, color: cardColor))
            .sheet(isPresented: $showQR) { GroupLinkQRSheet(title: title, link: link, photo: photo, memberCount: memberCount) }
            .sheet(isPresented: $showShare) { SendContactSheet(contactText: link) }
    }

    private var row: some View {
        HStack(spacing: 14) {
            Image(systemName: "link").font(.system(size: 17))
                .frame(width: 26)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                // Fariin blue, the one action colour (owner 2026-10-26: "make it blue link").
                Text(shownLink).foregroundStyle(Color.fariinBlue).lineLimit(1)
                Text(copied ? "Copied" : "Link").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { showQR = true } label: {
                Image(systemName: "qrcode").font(.system(size: 17)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("QR Code")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var shareItems: [Any] {
        if let url = URL(string: link) { return [url] }
        return [link]
    }

    private func copy() {
        UIPasteboard.general.string = link
        Haptics.notify(.success)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private struct LinkCardSurface: ViewModifier {
    let on: Bool
    let color: Color
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.profileSurface(plain: color) } else { content }
    }
}

/// ⛔ ONE CARD FOR ABOUT AND THE LINK (owner's mockup 2026-10-26): an "About" title with its icon,
/// the description left-aligned with every line shown, a thin line, then the public link row.
/// Either half alone when the group has only one of them. The member's group page and a visitor's
/// both draw this one.
struct GroupAboutCard: View {
    let desc: String
    let linkName: String
    let title: String
    let cardColor: Color
    var photo: String? = nil
    var memberCount: Int? = nil
    var openURL: OpenURLAction? = nil

    var body: some View {
        if !desc.isEmpty || !linkName.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "text.alignleft").font(.system(size: 17))
                            Text("Description").font(.body)
                        }
                        .foregroundStyle(.primary)
                        descText
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, linkName.isEmpty ? 14 : 16)
                }
                if !linkName.isEmpty {
                    // The line starts under the link text, as between the settings rows.
                    if !desc.isEmpty { Divider().padding(.leading, 56) }
                    GroupPublicLinkCard(name: linkName, title: title, cardColor: cardColor,
                                        photo: photo, memberCount: memberCount, embedded: true)
                }
            }
            .profileSurface(plain: cardColor)
        }
    }

    @ViewBuilder private var descText: some View {
        let t = Text(GroupInfoView.blueLinks(desc)).font(.body).foregroundStyle(.primary)
            .tint(Color(hex: 0x0A84FF))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        if let openURL { t.environment(\.openURL, openURL) } else { t }
    }
}

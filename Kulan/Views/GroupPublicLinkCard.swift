import SwiftUI
import UIKit

/// ⛔ A PUBLIC GROUP'S LINK ON ITS INFO PAGE — 2026-10-19 groups v2. One card, one row: "Link" and
/// fariin.com/<name>. A tap offers Copy, Share and the QR code (the invite link's QR sheet,
/// `GroupLinkQRSheet`). Every member sees it: a public link is open to all by definition.
struct GroupPublicLinkCard: View {
    let name: String
    let title: String
    let cardColor: Color

    @State private var showQR = false
    @State private var showShare = false
    @State private var copied = false

    private var link: String { GroupDirectory.link(name) }
    private var shownLink: String { "fariin.com/\(name)" }

    var body: some View {
        Menu {
            Button { copy() } label: { Label("Copy Link", systemImage: "doc.on.doc") }
            Button { showShare = true } label: { Label("Share Link", systemImage: "square.and.arrow.up") }
            Button { showQR = true } label: { Label("QR Code", systemImage: "qrcode") }
        } label: {
            row
        }
        .profileSurface(plain: cardColor)
        .sheet(isPresented: $showQR) { GroupLinkQRSheet(title: title, link: link) }
        .sheet(isPresented: $showShare) { ActivityView(items: shareItems) }
    }

    private var row: some View {
        HStack(spacing: 14) {
            Image(systemName: "link").font(.system(size: 17))
                .frame(width: 26)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(shownLink).foregroundStyle(Color.accentColor).lineLimit(1)
                Text(copied ? "Copied" : "Link").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "qrcode").font(.system(size: 17)).foregroundStyle(.secondary)
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

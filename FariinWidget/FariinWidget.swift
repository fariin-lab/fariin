import ImageIO
import SwiftUI
import UIKit
import WidgetKit

/// The Home Screen widgets: Recent (chats) and Stories, small and wide (owner 2026-11-02). The app
/// asks for a reload when its data changes (`WidgetShare`), so the timeline is one entry that never
/// expires on its own.
struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetShared.Snapshot
    let faces: [String: UIImage]
}

struct Provider: TimelineProvider {
    private func entry() -> Entry {
        let s = WidgetShared.read()
        var faces: [String: UIImage] = [:]
        for url in ([s.me] + s.chats + s.stories).compactMap({ $0?.photo }) where faces[url] == nil {
            if let i = Self.face(url) { faces[url] = i }
        }
        return Entry(date: Date(), snap: s, faces: faces)
    }

    /// Small on purpose: a widget has little memory, and a saved photo can be 2 MB.
    private static func face(_ url: String) -> UIImage? {
        guard let f = NotifShared.avatarFile(url),
              let src = CGImageSourceCreateWithURL(f as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 180,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .init(), faces: [:]) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }
}

private let ringBlue = Color(red: 0x3D / 255, green: 0xA1 / 255, blue: 0xFD / 255)

private struct Face: View {
    let person: WidgetShared.Person?
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let n = person?.name.first {
                ZStack {
                    Color(uiColor: .systemGray3)
                    Text(String(n).uppercased()).font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    Color(uiColor: .systemGray3)
                    Image(systemName: "person.fill").font(.system(size: size * 0.46)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: person?.channel == true ? size * 0.3 : size / 2,
                                    style: .continuous))
    }
}

private struct Cell: View {
    let name: String
    let person: WidgetShared.Person?
    let image: UIImage?
    var ring = false
    var plus = false
    let size: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if ring { Circle().stroke(ringBlue, lineWidth: 2.5).frame(width: size, height: size) }
                Face(person: person, image: image, size: ring ? size - 9 : size)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if plus {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 22, height: 22)
                        .background(Color.primary, in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                .multilineTextAlignment(.center).foregroundStyle(.primary)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct Card<Row: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let row: () -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                Spacer()
                Image("Logo").resizable().scaledToFit().frame(width: 18, height: 18)
            }
            if let note {
                Spacer()
                Text(note).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
                Spacer()
            } else {
                row()
                Spacer(minLength: 0)
            }
        }
        .containerBackground(Color(uiColor: .secondarySystemBackground), for: .widget)
    }
}

private func note(_ s: WidgetShared.Snapshot) -> String? {
    if !s.signedIn { return "Sign in to Fariin" }
    if s.locked { return "Open Fariin to see this" }
    return nil
}

struct ChatsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let s = entry.snap
        let count = family == .systemSmall ? 2 : 4
        let shown = Array(s.chats.prefix(count))
        Card(title: "Recent", note: note(s) ?? (shown.isEmpty ? "Your chats show here" : nil)) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(shown) { p in
                    Link(destination: WidgetShared.chatLink(p.id)) {
                        Cell(name: p.name, person: p, image: p.photo.flatMap { entry.faces[$0] }, size: 56)
                    }
                }
                ForEach(shown.count..<max(shown.count, count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
        .widgetURL(shown.first.map { WidgetShared.chatLink($0.id) })
    }
}

struct StoriesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let s = entry.snap
        let count = family == .systemSmall ? 1 : 3
        let shown = Array(s.stories.prefix(count))
        Card(title: "Stories", note: note(s)) {
            HStack(alignment: .top, spacing: 6) {
                Link(destination: WidgetShared.addStoryLink) {
                    Cell(name: "Add story", person: s.me, image: s.me?.photo.flatMap { entry.faces[$0] },
                         plus: true, size: 56)
                }
                ForEach(shown) { p in
                    Link(destination: WidgetShared.storyLink(p.id)) {
                        Cell(name: p.name, person: p, image: p.photo.flatMap { entry.faces[$0] },
                             ring: p.unseen, size: 56)
                    }
                }
                ForEach(shown.count..<max(shown.count, count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
        .widgetURL(WidgetShared.addStoryLink)
    }
}

struct ChatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.chatsKind, provider: Provider()) { ChatsView(entry: $0) }
            .configurationDisplayName("Recent")
            .description("Your latest chats, one tap away.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StoriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.storiesKind, provider: Provider()) { StoriesView(entry: $0) }
            .configurationDisplayName("Stories")
            .description("New stories on your Home Screen.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct FariinWidgets: WidgetBundle {
    var body: some Widget {
        ChatsWidget()
        StoriesWidget()
    }
}

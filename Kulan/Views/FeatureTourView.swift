import SwiftUI

/// ⛔ THE INTRO AFTER SIGN-UP — owner, 2026-09-25, with a reference app's five-page tour: a line
/// illustration, a bold title, two lines of text, page dots, one big button, and Skip under it.
/// He chose the four features (private chats, stories and Glow, calls, username not phone) and asked
/// me to draw the pictures. They are drawn here from SF Symbols at their thinnest weight, layered the
/// way the reference layers its sketches, so they follow Dynamic Type, both themes and every screen
/// size with no image files to keep in step.
///
/// Shown once, right after a new account's profile is saved (RootView `.tour`). Every sentence is
/// true of the app as built: the chats claim is the E2EE the app implements, calls make no
/// encryption claim, and "no address book" is literal (the app never asks for Contacts).
struct FeatureTourView: View {
    var onDone: () -> Void

    @State private var page = 0

    private struct Page {
        let title: String
        let text: String
        let art: AnyView
    }

    private let pages: [Page] = [
        Page(title: "Welcome to Fariin",
             text: "Private chats, calls and stories.",
             art: AnyView(TourArt.welcome)),
        Page(title: "Private chats",
             text: "Messages are end-to-end encrypted. Only you and the people you talk to can read them.",
             art: AnyView(TourArt.privateChats)),
        Page(title: "Stories and Glow",
             text: "Share moments that disappear after a day. Glow someone to follow their stories.",
             art: AnyView(TourArt.stories)),
        Page(title: "Calls",
             text: "Voice and video calls with the people in your chats.",
             art: AnyView(TourArt.calls)),
        Page(title: "Your username, not your number",
             text: "People find you by @username. No phone number, and Fariin never reads your address book.",
             art: AnyView(TourArt.username)),
    ]

    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 0) {
                            Spacer()
                            pages[i].art
                                .frame(width: 240, height: 220)
                                .foregroundStyle(.primary)
                                .accessibilityHidden(true)
                            Spacer().frame(height: 56)
                            Text(pages[i].title)
                                .font(.system(size: 30, weight: .bold))
                                .multilineTextAlignment(.center)
                            Text(pages[i].text)
                                .font(.body).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 12)
                            Spacer()
                            Spacer()
                        }
                        .padding(.horizontal, 32)
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                dots.padding(.bottom, 28)

                Button {
                    if isLast { onDone() } else { withAnimation(.easeInOut(duration: 0.3)) { page += 1 } }
                } label: {
                    Text(page == 0 ? "Take a quick tour" : (isLast ? "Get started" : "Next"))
                        .authPrimaryPill()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                // Skip keeps its place on the last page (hidden, not removed) so the big button does
                // not jump up as you arrive there.
                Button("Skip") { onDone() }
                    .font(.body).foregroundStyle(.secondary)
                    .frame(height: 44)
                    .padding(.top, 10)
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
                    .padding(.bottom, 8)
            }
        }
    }

    /// The reference's dots: the current page is a short capsule, the rest are small circles.
    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(i == page ? 1 : 0.25))
                    .frame(width: i == page ? 22 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: page)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
    }
}

/// The five drawings. Thin-weight symbols, layered and offset like a sketch, with the reference's
/// small four-point sparkles.
private enum TourArt {
    static func symbol(_ name: String, _ size: CGFloat, _ weight: Font.Weight = .ultraLight) -> some View {
        Image(systemName: name).font(.system(size: size, weight: weight))
    }

    static func sparkle(_ size: CGFloat) -> some View {
        Image(systemName: "sparkle").font(.system(size: size, weight: .regular))
    }

    static var welcome: some View {
        ZStack {
            symbol("bubble.left", 96).offset(x: -44, y: -40)
            symbol("bubble.right", 132).offset(x: 20, y: 6)
            symbol("bubble.left", 64).offset(x: -52, y: 70)
            sparkle(26).offset(x: 98, y: -36)
        }
    }

    static var privateChats: some View {
        ZStack {
            symbol("bubble.left", 150)
            symbol("lock.fill", 44, .regular).offset(y: -8)
            symbol("bubble.right", 62).offset(x: 86, y: 70)
            sparkle(24).offset(x: 88, y: -74)
            sparkle(16).offset(x: -94, y: 58)
        }
    }

    static var stories: some View {
        ZStack {
            Circle().strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [16, 9]))
                .frame(width: 150, height: 150)
            symbol("person.fill", 64, .regular)
            symbol("sparkles", 40).offset(x: 86, y: -70)
            symbol("rectangle.portrait", 52).offset(x: -96, y: 52).rotationEffect(.degrees(-8))
        }
    }

    static var calls: some View {
        ZStack {
            symbol("bubble.left", 150)
            symbol("phone.fill", 46, .regular).offset(y: -8)
            symbol("video", 52).offset(x: 88, y: 66)
            sparkle(24).offset(x: -90, y: -70)
        }
    }

    static var username: some View {
        ZStack {
            Circle().stroke(lineWidth: 2.5).frame(width: 110, height: 110).offset(x: -40, y: -18)
            Circle().stroke(lineWidth: 2.5).frame(width: 150, height: 150).offset(x: 12, y: 8)
            symbol("at", 72, .light).offset(x: 12, y: 8)
            symbol("plus.circle", 44).offset(x: 78, y: 70)
            sparkle(22).offset(x: -92, y: -78)
        }
    }
}

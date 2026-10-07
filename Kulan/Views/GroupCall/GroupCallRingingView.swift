import SwiftUI

// THE RINGING SCREEN (owner, 2026-10-07, plan #4: "feeling like flat design"). While I am alone in
// a call I started and the people I rang have not answered, the middle of the screen shows WHO is
// being rung: their photo large with a slow pulse around it, their names under it, and "Ringing…".
// It used to show my own photo, with the names squeezed onto two lines of the header.
//
// A pure view: the real call (GroupCallView, over GroupCallDuoView) and the demo both draw it from
// plain values, so the demo shows exactly the real screen. It takes no touches; taps fall through
// to the screen under it (show / hide the controls).

struct GroupCallRingingView: View {
    struct Person: Equatable {
        let name: String
        let photoUrl: String?
    }

    /// The people being rung, in the call's order. The first one is the big photo.
    let people: [Person]
    /// My camera is on and fills the screen behind: no colour of our own, a smaller photo, and a
    /// shadow so the white words stay readable over the picture.
    let overVideo: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var size: CGFloat { overVideo ? 120 : 160 }

    var body: some View {
        ZStack {
            if !overVideo {
                Self.ground(people.first?.photoUrl).ignoresSafeArea()
            }
            VStack(spacing: 22) {
                photo
                VStack(spacing: 6) {
                    Text(Self.names(people.map(\.name)))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("Ringing…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 32)
                .shadow(color: .black.opacity(overVideo ? 0.5 : 0), radius: 8)
            }
            // A little above the middle, clear of the controls under it.
            .padding(.bottom, 60)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .onAppear { pulsing = true }
    }

    private var photo: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 1.5)
                        .frame(width: size, height: size)
                        .scaleEffect(pulsing ? 1.5 : 1)
                        .opacity(pulsing ? 0 : 0.9)
                        .animation(.easeOut(duration: 2.4)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(i) * 1.2),
                                   value: pulsing)
                }
            }
            AvatarView(name: people.first?.name ?? "", photoUrl: people.first?.photoUrl, size: size)
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 26, y: 10)
            if people.count > 1 {
                Text("+\(people.count - 1)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(white: 0.2)))
                    .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 3))
                    .offset(x: size * 0.36, y: size * 0.36)
            }
        }
        .frame(width: size * 1.5, height: size * 1.5)
    }

    /// "Ana", "Ana and Bilan", "Ana, Bilan and 3 others".
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            let rest = names.count - 2
            return "\(names[0]), \(names[1]) and \(rest) \(rest == 1 ? "other" : "others")"
        }
    }

    /// The colour a voice call takes from the person's photo (GroupCallDuoView's `ground`), from the
    /// caches already filled by their avatar; black when there is no photo.
    static func ground(_ url: String?) -> Color {
        guard let url, !url.isEmpty else { return .black }
        if let p = ProfilePalette.warm(url: url) { return Color(p.page) }
        if let shown = ProfilePhotoLoader.shared.cachedAvatar(url),
           let p = ProfilePalette.now(shown, url: url) { return Color(p.page) }
        return .black
    }
}

import SwiftUI

// App-wide "alive" empty state: ContentUnavailableView with the icon doing a quiet
// periodic bounce (native symbol effect, no Lottie dependency). Same call shape as
// the system convenience init, so swapping a static empty state in is one line.
// Rule of use (the big messengers): animate waiting/empty moments only, never busy screens.
struct EmptyStateView: View {
    let title: String
    let icon: String
    var text: String? = nil
    // One greeting bounce as the screen appears, then rest — an endlessly repeating
    // bounce read as fidgety (user verdict on build 352), and it started 3s late.
    @State private var greet = 0

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .symbolEffect(.bounce, value: greet)
            }
        } description: {
            if let text { Text(text) }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { greet += 1 }   // after the push settles
        }
    }
}

import SwiftUI

// App-wide "alive" empty state: ContentUnavailableView with the icon doing a quiet
// periodic bounce (native symbol effect, no Lottie dependency). Same call shape as
// the system convenience init, so swapping a static empty state in is one line.
// Rule of use (TG/WA/Signal): animate waiting/empty moments only, never busy screens.
struct EmptyStateView: View {
    let title: String
    let icon: String
    var text: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .symbolEffect(.bounce, options: .repeat(.periodic(delay: 3.0)))
            }
        } description: {
            if let text { Text(text) }
        }
    }
}

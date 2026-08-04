import SwiftUI

// Placeholder shell for Phase 0/1. Real UI starts in Phase 4 (TabView + chat list).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Fariin")
                .font(.largeTitle.weight(.bold))
            Text("Native build — Phase 1")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}

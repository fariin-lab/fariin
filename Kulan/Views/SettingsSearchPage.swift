import SwiftUI

/// ⛔ SETTINGS SEARCH, FROM THE SETTINGS PAGE'S OWN SEARCH BUTTON — owner 2026-10-13, with the
/// reference's screen: the search field at the top with a round X beside it, the keyboard up, and
/// every settings page listed underneath, the pages that live inside another page carrying that
/// page's name under their own ("Two-step verification / Account"). Typing searches every setting,
/// rows and toggles inside the pages included (`SettingsIndex`, the same list the app-wide search
/// reads), and a tap opens the page that holds it.
struct SettingsSearchPage: View {
    var onSignOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [SettingsIndex.Entry] { SettingsIndex.matching(query, onSignOut: onSignOut) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                List(results) { e in
                    SettingsIndexResultRow(entry: e)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
                .overlay {
                    if results.isEmpty {
                        NoSearchResults(query: query.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            // Up with the page, as the reference's is: a search page opened to be typed into.
            try? await Task.sleep(nanoseconds: 150_000_000)
            focused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                // owner 2026-11-05: the typed words and the placeholder were hard to read on the glass,
                // in dark mode and in light. The system label colours, set outright, so nothing
                // inherited from the page can wash them out.
                Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: .secondaryLabel))
                TextField("Search", text: $query,
                          prompt: Text("Search").foregroundStyle(Color(uiColor: .secondaryLabel)))
                    .foregroundStyle(Color(uiColor: .label))
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .liquidGlass(Capsule())

            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlass(Circle(), interactive: true)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

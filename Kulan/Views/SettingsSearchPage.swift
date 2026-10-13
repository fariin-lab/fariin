import SwiftUI

/// ⛔ SETTINGS SEARCH, FROM THE SETTINGS PAGE'S OWN SEARCH BUTTON — owner 2026-10-13, with the
/// reference's screen: the search field at the top with a round X beside it, the keyboard up, and
/// every settings page listed underneath, the pages that live inside another page carrying that
/// page's name under their own ("Two-step verification / Account"). Typing narrows the list by title
/// or by the words people type for it (`SettingsIndex`, the same list the app-wide search reads).
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
                    NavigationLink { e.dest } label: { row(e) }
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
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
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

    /// A top-level page wears its icon; a page inside another page is indented under the same column,
    /// with no icon and its parent's name beneath, as the reference draws it.
    @ViewBuilder private func row(_ e: SettingsIndex.Entry) -> some View {
        if let parent = e.parent {
            HStack(spacing: 16) {
                Color.clear.frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.body)
                    Text(parent).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } else if e.system {
            SettingsRowLabel(e.title, system: e.icon)
        } else {
            SettingsRowLabel(e.title, e.icon)
        }
    }
}

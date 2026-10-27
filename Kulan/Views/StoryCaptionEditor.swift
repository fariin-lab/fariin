import SwiftUI
import FirebaseFirestore

// ⛔ EDIT A POSTED STORY'S CAPTION — owner 2026-10-27 ("I wrote the caption wrong"): the author, on
// their own story or a group story they posted. Only the caption changes; the picture, the audience
// and the views stay. The rules let the author change `caption` and nothing else of the content.
// The story listeners carry the new caption to everyone who has the story.

struct StoryCaptionEditor: View {
    let story: Story
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    init(story: Story, onSaved: @escaping () -> Void = {}) {
        self.story = story
        self.onSaved = onSaved
        _text = State(initialValue: story.caption)
    }

    private var limit: Int { Limits.storyCaptionChars }
    private var changed: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != story.caption }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Caption", text: Binding(get: { text },
                                                       set: { text = String($0.prefix(limit)) }),
                              axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                } footer: {
                    HStack {
                        Text("Everyone who can see this story sees the new caption.")
                        Spacer()
                        Text("\(text.count)/\(limit)").monospacedDigit()
                    }
                }
            }
            .navigationTitle("Edit Caption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!changed || saving)
                }
            }
            .alert("Could not save the caption", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: { Text("Check your connection and try again.") }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }

    private func save() {
        saving = true
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                try await FirestoreHub.db.collection("stories").document(story.id)
                    .updateData(["caption": clean])
                saving = false
                onSaved()
                dismiss()
            } catch {
                saving = false
                failed = true
            }
        }
    }
}

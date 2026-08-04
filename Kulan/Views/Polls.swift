import SwiftUI
import FirebaseFirestore

// Polls. The poll content (question + options) travels E2EE inside the message text as a "fariin-poll:"
// marker (see Message.poll). Votes are stored per-voter under messages/{mid}/votes/{uid} as option
// indices only — the server can't read what the options mean, and each voter owns their own vote doc.

enum PollService {
    private static var db: Firestore { Firestore.firestore() }
    private static var me: String { AuthService.shared.uid ?? "" }

    private static func votesRef(_ cid: String, _ messageId: String) -> CollectionReference {
        db.collection("conversations").document(cid)
            .collection("messages").document(messageId).collection("votes")
    }

    static func setVote(cid: String, messageId: String, options: [Int]) {
        let ref = votesRef(cid, messageId).document(me)
        Task {
            if options.isEmpty { try? await ref.delete() }
            else { try? await ref.setData(["options": options, "at": FieldValue.serverTimestamp()]) }
        }
    }

    /// Live map of uid → chosen option indices.
    static func listen(cid: String, messageId: String, _ cb: @escaping ([String: [Int]]) -> Void) -> ListenerRegistration {
        votesRef(cid, messageId).addSnapshotListener { snap, _ in
            var out: [String: [Int]] = [:]
            for d in snap?.documents ?? [] {
                if let opts = d.data()["options"] as? [Int], !opts.isEmpty { out[d.documentID] = opts }
                else if let opts = d.data()["options"] as? [NSNumber], !opts.isEmpty { out[d.documentID] = opts.map { $0.intValue } }
            }
            cb(out)
        }
    }
}

// The poll body rendered inside a message bubble (background/meta come from the parent MessageBubble).
struct PollBubbleContent: View {
    let poll: PollCard
    let cid: String
    let messageId: String
    let isMe: Bool
    let dark: Bool

    @State private var votes: [String: [Int]] = [:]
    @State private var listener: ListenerRegistration?
    private var me: String { AuthService.shared.uid ?? "" }

    private var myVotes: Set<Int> { Set(votes[me] ?? []) }
    private var totalVoters: Int { votes.count }
    private func count(_ i: Int) -> Int { votes.values.reduce(0) { $0 + ($1.contains(i) ? 1 : 0) } }
    private func fraction(_ i: Int) -> Double { totalVoters == 0 ? 0 : Double(count(i)) / Double(totalVoters) }

    private var track: Color { isMe ? Color.white.opacity(0.25) : Color.primary.opacity(0.12) }
    private var fill: Color { isMe ? Color.white.opacity(0.9) : Color.primary.opacity(0.85) }
    private var accent: Color { isMe ? Color.white : Color.primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(poll.question).font(.system(size: 16, weight: .semibold))
                Text(poll.multiple ? "Select one or more" : "Select one")
                    .font(.caption2).opacity(0.7)
            }
            ForEach(Array(poll.options.enumerated()), id: \.offset) { i, opt in
                Button { toggle(i) } label: { optionRow(i, opt) }.buttonStyle(.plain)
            }
            Text("\(totalVoters) vote\(totalVoters == 1 ? "" : "s")").font(.caption2).opacity(0.7)
        }
        .onAppear {
            guard listener == nil else { return }
            listener = PollService.listen(cid: cid, messageId: messageId) { votes = $0 }
        }
        .onDisappear { listener?.remove(); listener = nil }
    }

    private func optionRow(_ i: Int, _ opt: String) -> some View {
        let chosen = myVotes.contains(i)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: chosen ? (poll.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                         : (poll.multiple ? "square" : "circle"))
                    .foregroundStyle(accent).font(.system(size: 16))
                Text(opt).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                // Fixed size (not .caption) so it can't grow at large Dynamic Type and crush the narrow
                // fixed-width poll bubble's option label.
                Text("\(Int((fraction(i) * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold)).opacity(0.85).layoutPriority(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(track).frame(height: 6)
                    Capsule().fill(fill).frame(width: max(6, geo.size.width * fraction(i)), height: 6)
                        .animation(.easeInOut(duration: 0.25), value: fraction(i))
                }
            }.frame(height: 6)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func toggle(_ i: Int) {
        var next: [Int]
        if poll.multiple {
            var s = myVotes
            if s.contains(i) { s.remove(i) } else { s.insert(i) }
            next = Array(s).sorted()
        } else {
            next = myVotes.contains(i) ? [] : [i]   // tapping the chosen one again clears it
        }
        PollService.setVote(cid: cid, messageId: messageId, options: next)
    }
}

// Compose a new poll (question + 2–10 options + optional multiple-answers).
struct PollComposerSheet: View {
    let onSend: (_ marker: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var multiple = false

    private var trimmedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimmedOptions.count >= 2
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Question") {
                    TextField("Ask a question", text: $question, axis: .vertical).lineLimit(1...3)
                }
                Section("Options") {
                    ForEach(options.indices, id: \.self) { i in
                        HStack {
                            TextField("Option \(i + 1)", text: $options[i])
                            if options.count > 2 {
                                Button { options.remove(at: i) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if options.count < 10 {
                        Button { options.append("") } label: { Label("Add option", systemImage: "plus.circle") }
                    }
                }
                Section {
                    Toggle("Multiple answers", isOn: $multiple)
                }
            }
            .navigationTitle("New Poll").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") {
                        let id = UUID().uuidString.prefix(12).lowercased()
                        let marker = Message.pollMarkerText(id: String(id),
                                                            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                                                            options: trimmedOptions, multiple: multiple)
                        onSend(marker)
                        dismiss()
                    }.disabled(!canSend)
                }
            }
        }
    }
}

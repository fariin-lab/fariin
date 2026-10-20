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
        // `document("")` is a Firestore crash, and `me` is empty once signed out.
        guard !me.isEmpty, !messageId.isEmpty else { return }
        let ref = votesRef(cid, messageId).document(me)
        Task {
            if options.isEmpty { try? await ref.delete() }
            else { try? await ref.setData(["options": options, "at": FieldValue.serverTimestamp()]) }
        }
    }

    /// Stop Poll (2026-10-19): the creator closes it for good. The rules refuse new votes after.
    static func stop(cid: String, messageId: String) async throws {
        try await db.collection("conversations").document(cid)
            .collection("messages").document(messageId).updateData(["pollClosed": true])
    }

    /// Live map of uid → chosen option indices. Shared per poll (PollVotesHub); call on the main thread.
    static func listen(cid: String, messageId: String, _ cb: @escaping ([String: [Int]]) -> Void) -> ListenerRegistration {
        PollVotesHub.shared.subscribe(key: "\(cid)|\(messageId)", cb) {
            votesRef(cid, messageId).addSnapshotListener { snap, _ in
                var out: [String: [Int]] = [:]
                for d in snap?.documents ?? [] {
                    if let opts = d.data()["options"] as? [Int], !opts.isEmpty { out[d.documentID] = opts }
                    else if let opts = d.data()["options"] as? [NSNumber], !opts.isEmpty { out[d.documentID] = opts.map { $0.intValue } }
                }
                PollVotesHub.shared.deliver(key: "\(cid)|\(messageId)", out)
            }
        }
    }
}

/// One votes listener per poll, shared by every view showing it, and kept for a minute after the
/// last one goes (audit 2026-10-20: a poll scrolled out and back in started a new listener each
/// time, and a big poll was read again from the server). Main thread only.
private final class PollVotesHub {
    static let shared = PollVotesHub()
    private struct Entry {
        var reg: ListenerRegistration?
        var votes: [String: [Int]]?
        var subs: [UUID: ([String: [Int]]) -> Void] = [:]
        var idleSince = 0   // bumped on each release, so an older teardown timer does nothing
    }
    private var entries: [String: Entry] = [:]

    func subscribe(key: String, _ cb: @escaping ([String: [Int]]) -> Void,
                   start: () -> ListenerRegistration) -> ListenerRegistration {
        let id = UUID()
        var e = entries[key] ?? Entry()
        e.subs[id] = cb
        e.idleSince += 1
        if e.reg == nil { e.reg = start() }
        entries[key] = e
        if let v = e.votes { cb(v) }   // the last answer at once, no wait for the server
        return PollVotesHandle { [weak self] in self?.release(key: key, id: id) }
    }

    func deliver(key: String, _ votes: [String: [Int]]) {
        guard var e = entries[key] else { return }
        e.votes = votes
        entries[key] = e
        for cb in e.subs.values { cb(votes) }
    }

    private func release(key: String, id: UUID) {
        guard var e = entries[key] else { return }
        e.subs[id] = nil
        guard e.subs.isEmpty else { entries[key] = e; return }
        e.idleSince += 1
        let mark = e.idleSince
        entries[key] = e
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let e = self.entries[key], e.subs.isEmpty, e.idleSince == mark else { return }
            e.reg?.remove()
            self.entries[key] = nil
        }
    }
}

private final class PollVotesHandle: NSObject, ListenerRegistration {
    private var onRemove: (() -> Void)?
    init(_ onRemove: @escaping () -> Void) { self.onRemove = onRemove }
    func remove() { onRemove?(); onRemove = nil }
}

// The poll body rendered inside a message bubble (background/meta come from the parent MessageBubble).
struct PollBubbleContent: View {
    let poll: PollCard
    let cid: String
    let messageId: String
    let isMe: Bool
    let dark: Bool
    /// 2026-09-24 decision D-composer-1: a poll now shows as a pending bubble before the server has
    /// it, under its clientId. A vote there would land on a message that never exists, so the
    /// options wait until the real message is in.
    var canVote: Bool = true

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
        guard canVote else { return }   // 2026-09-24 decision D-composer-1: not while pending
        var next: [Int]
        if poll.multiple {
            var s = myVotes
            if s.contains(i) { s.remove(i) } else { s.insert(i) }
            next = Array(s).sorted()
        } else {
            next = myVotes.contains(i) ? [] : [i]   // tapping the chosen one again clears it
        }
        // Two quick taps on a multiple-answer poll kept only the second choice (audit, 2026-09-24):
        // `myVotes` is read from the listener, which had not yet delivered the first tap, so the
        // second tap built its list from nothing and overwrote the first. Record the choice locally
        // straight away; the listener replaces it with the same thing a moment later.
        if next.isEmpty { votes[me] = nil } else { votes[me] = next }
        PollService.setVote(cid: cid, messageId: messageId, options: next)
    }
}

// Compose a new poll (owner 2026-10-19, our own layout): question, 2–10 options, then Multiple
// answers, Hide who voted, Quiz (tap an option's circle to mark it right) and an end time.
struct PollComposerSheet: View {
    let onSend: (_ marker: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    /// Each option keeps its own id (audit 2026-10-20: removing one by index crashed the field
    /// binding) and its own right-answer mark.
    struct Opt: Identifiable { let id = UUID(); var text = ""; var right = false }
    @State private var options: [Opt] = [Opt(), Opt()]
    @State private var multiple = false
    @State private var hideVoters = false
    @State private var quiz = false
    @State private var ends: EndChoice = .never
    @State private var sent = false

    enum EndChoice: Hashable, CaseIterable {
        case never, hour, day, week
        var label: String {
            switch self { case .never: "Never"; case .hour: "In 1 hour"; case .day: "In 1 day"; case .week: "In 1 week" }
        }
        var seconds: Double? {
            switch self { case .never: nil; case .hour: 3600; case .day: 86_400; case .week: 604_800 }
        }
    }

    /// The options kept (non-empty), each with whether it was marked right.
    private var kept: [(text: String, right: Bool)] {
        options.compactMap { o in
            let t = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : (t, o.right)
        }
    }
    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && kept.count >= 2
            && (!quiz || kept.contains { $0.right })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Question") {
                    TextField("Ask a question", text: $question, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    ForEach(Array(options.enumerated()), id: \.element.id) { i, o in optionRow(i, o.id) }
                    if options.count < 10 {
                        Button { options.append(Opt()) } label: { Label("Add option", systemImage: "plus") }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    if quiz { Text("Tap the circle next to the right answer.") }
                }
                Section {
                    // A quiz takes one answer (audit 2026-10-20: quiz + multiple locked voters after
                    // their first pick).
                    setting("checklist", "Multiple answers", $multiple).disabled(quiz)
                    setting("eye.slash", "Hide who voted", $hideVoters)
                    setting("graduationcap", "Quiz", $quiz)
                    Picker(selection: $ends) {
                        ForEach(EndChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        row("timer", "Ends")
                    }
                } footer: {
                    Text(footer)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New Poll").navigationBarTitleDisplayMode(.inline)
            .onChange(of: quiz) { _, on in if on { multiple = false } }
            .onChange(of: multiple) { _, many in if !many { keepOneRight() } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { send() }.fontWeight(.semibold).disabled(!canSend)
                }
            }
        }
    }

    private var footer: String {
        var parts: [String] = []
        if hideVoters { parts.append("Results show only the numbers, not names.") }
        if quiz { parts.append("Voters see if they were right after they answer, and cannot change it.") }
        if ends != .never { parts.append("Voting stops automatically.") }
        return parts.isEmpty ? "Anyone in the chat can vote and see who voted." : parts.joined(separator: " ")
    }

    private func setting(_ icon: String, _ title: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) { row(icon, title) }
    }

    /// A small glyph (owner 2026-10-20: the icons read too big) in a fixed slot, then the title.
    private func row(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
            Text(title)
        }
    }

    private func optionRow(_ i: Int, _ id: UUID) -> some View {
        let right = options.first { $0.id == id }?.right ?? false
        return HStack(spacing: 10) {
            if quiz {
                Button { mark(id) } label: {
                    Image(systemName: right ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(right ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(right ? "Right answer" : "Mark as right answer")
            }
            TextField("Option \(i + 1)", text: Binding(
                get: { options.first { $0.id == id }?.text ?? "" },
                set: { v in if let k = options.firstIndex(where: { $0.id == id }) { options[k].text = v } }))
            if options.count > 2 {
                Button { options.removeAll { $0.id == id } } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }.buttonStyle(.plain)
            }
        }
    }

    /// A quiz has one right answer (multiple is off while Quiz is on).
    private func mark(_ id: UUID) {
        for k in options.indices { options[k].right = options[k].id == id ? !options[k].right : false }
    }

    private func keepOneRight() {
        var seen = false
        for k in options.indices where options[k].right {
            if seen { options[k].right = false } else { seen = true }
        }
    }

    private func send() {
        // A second tap during the dismiss animation sent the poll twice (audit, 2026-09-24).
        guard !sent, canSend else { return }
        sent = true
        let id = UUID().uuidString.prefix(12).lowercased()
        let list = kept
        let marker = Message.pollMarkerText(
            id: String(id), question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            options: list.map(\.text), multiple: multiple, hideVoters: hideVoters,
            correct: quiz ? list.indices.filter { list[$0].right } : [],
            endsAt: ends.seconds.map { (Date().timeIntervalSince1970 + $0) * 1000 })
        onSend(marker)
        dismiss()
    }
}

// The results page (owner 2026-10-19): each option with its count and, unless the poll hides
// them, who chose it; the end time or "Poll ended"; Stop Poll for its creator.
struct PollResultsSheet: View {
    let poll: PollCard
    let cid: String
    let messageId: String
    let closed: Bool
    let isCreator: Bool
    let names: [String: String]
    let meName: String

    @Environment(\.dismiss) private var dismiss
    @State private var votes: [String: [Int]] = [:]
    @State private var listener: ListenerRegistration?
    @State private var confirmStop = false
    @State private var stopped = false
    @State private var stopError: String?
    private var me: String { AuthService.shared.uid ?? "" }

    private var isOpen: Bool {
        if closed || stopped { return false }
        if let e = poll.endsAt { return Date().timeIntervalSince1970 * 1000 < e }
        return true
    }
    private func voters(_ i: Int) -> [String] {
        votes.filter { $0.value.contains(i) }.map(\.key)
            .sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }
    private func name(_ uid: String) -> String { uid == me ? meName : (names[uid] ?? "Member") }

    private var status: String {
        let n = votes.count
        let count = "\(n) vote\(n == 1 ? "" : "s")"
        if !isOpen { return "Poll ended · \(count)" }
        if let e = poll.endsAt {
            let left = Date(timeIntervalSince1970: e / 1000)
            return "\(count) · ends \(left.formatted(.relative(presentation: .named)))"
        }
        return count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if poll.isQuiz {
                            Label("Quiz", systemImage: "graduationcap").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(poll.question).font(.title3.weight(.semibold))
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(poll.options.indices, id: \.self) { i in
                    let who = voters(i)
                    Section {
                        if poll.hideVoters {
                            Text(who.isEmpty ? "No votes" : "\(who.count) vote\(who.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        } else if who.isEmpty {
                            Text("No votes").foregroundStyle(.secondary)
                        } else {
                            ForEach(who, id: \.self) { uid in
                                HStack(spacing: 12) {
                                    AvatarView(name: name(uid), photoUrl: nil, size: 30)
                                    Text(name(uid)).lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            if poll.correct.contains(i), votes[me] != nil || !isOpen {   // only after I voted or it ended (audit)
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            Text(poll.options[i]).textCase(nil)
                            Spacer()
                            Text(percent(who.count)).textCase(nil)
                        }
                    }
                }
                if poll.hideVoters {
                    Section { } footer: { Text("Names are hidden for this poll.") }
                }
                if isCreator && isOpen {
                    Section {
                        Button(role: .destructive) { confirmStop = true } label: {
                            Label("Stop Poll", systemImage: "stop.circle")
                        }
                    } footer: {
                        Text("No one can vote after this. The results stay.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Poll Results").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear {
                guard listener == nil else { return }
                listener = PollService.listen(cid: cid, messageId: messageId) { votes = $0 }
            }
            .onDisappear { listener?.remove(); listener = nil }
            .alert("Stop this poll?", isPresented: $confirmStop) {
                Button("Cancel", role: .cancel) {}
                Button("Stop Poll", role: .destructive) { stop() }
            } message: { Text("No one will be able to vote anymore.") }
            .alert("Could not stop the poll", isPresented: Binding(get: { stopError != nil },
                                                                 set: { if !$0 { stopError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(stopError ?? "") }
        }
    }

    private func percent(_ n: Int) -> String {
        votes.isEmpty ? "0%" : "\(Int((Double(n) / Double(votes.count) * 100).rounded()))%"
    }

    private func stop() {
        stopped = true
        Task {
            do { try await PollService.stop(cid: cid, messageId: messageId) } catch {
                let msg = error.localizedDescription
                await MainActor.run { stopped = false; stopError = msg }
            }
        }
    }
}

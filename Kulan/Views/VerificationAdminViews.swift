import SwiftUI

// THE VERIFICATION CONSOLE.
//
// Hidden unless the account holds the `verify` capability, and that is not the security — the
// Firestore rules refuse every write behind these screens independently, so somebody who reached
// them anyway could still change nothing. It is hidden so a normal user never sees a door they
// cannot open.
//
// The shape follows the work rather than the data: an admin arrives either knowing who they came
// for (search) or wanting to see what the team has been doing (recent activity), so those are the
// two halves of the front page.

struct VerificationAdminView: View {
    @State private var query = ""
    @State private var results: [VerificationAdmin.FoundPeer] = []
    @State private var recent: [VerificationAdmin.AuditEntry] = []
    @State private var searching = false
    @State private var loadFailed: String?
    /// Rises on every keystroke; a search result that is not from the newest one is dropped. Typing
    /// "malia" fires five queries and they can land in any order, and without this the screen can
    /// settle on the results for "mal".
    @State private var searchGeneration = 0

    var body: some View {
        List {
            if let loadFailed {
                Section {
                    Label(loadFailed, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if !query.isEmpty {
                Section("Results") {
                    if searching && results.isEmpty {
                        HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                    } else if results.isEmpty {
                        Text("Nobody found.").foregroundStyle(.secondary)
                    } else {
                        ForEach(results) { found in
                            NavigationLink { VerificationDetailView(found: found) } label: {
                                VerificationResultRow(found: found)
                            }
                        }
                    }
                }
            } else {
                Section {
                    ForEach(recent) { entry in
                        VerificationAuditRow(entry: entry, showsPeer: true)
                    }
                    if recent.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recent activity")
                } footer: {
                    Text("Every grant, change, suspension and removal is recorded permanently, with who did it and why. Entries can never be edited or deleted, including by the owner.")
                }
            }
        }
        .navigationTitle("Verification")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Username or user ID")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task { await loadRecent() }
        .onChange(of: query) { _, new in
            searchGeneration += 1
            let generation = searchGeneration
            Task { await runSearch(new, generation: generation) }
        }
    }

    private func loadRecent() async {
        do { recent = try await VerificationAdmin.recentActivity() }
        catch { loadFailed = error.localizedDescription }
    }

    private func runSearch(_ text: String, generation: Int) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if generation == searchGeneration { results = []; searching = false }
            return
        }
        searching = true
        // A short wait so a five-letter name is one query rather than five.
        try? await Task.sleep(for: .milliseconds(250))
        guard generation == searchGeneration else { return }
        do {
            let found = try await VerificationAdmin.search(trimmed)
            guard generation == searchGeneration else { return }
            results = found
            searching = false
        } catch {
            guard generation == searchGeneration else { return }
            loadFailed = error.localizedDescription
            searching = false
        }
    }
}

private struct VerificationResultRow: View {
    let found: VerificationAdmin.FoundPeer

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(found.name.isEmpty ? "Unnamed" : found.name)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    // The same view the rest of the app draws. A console with its own drawing of the
                    // badge is a console that can disagree with the app about who is verified.
                    VerifiedMark(peer: found.peer, size: 13)
                }
                Text(found.handle.isEmpty ? found.peer.id : "@\(found.handle)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // The one thing worth shouting about in a list: verified, and not the same peer we
            // reviewed. Everything else can wait for the detail screen.
            if found.hasDriftedSinceVerification {
                Label("Renamed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
            } else if let status = found.verification?.status, status != .active {
                Text(status.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - One peer

struct VerificationDetailView: View {
    let found: VerificationAdmin.FoundPeer

    @State private var kind: Verification.Kind = .business
    @State private var reason = ""
    @State private var notes = ""
    @State private var caseFile = VerificationAdmin.CaseFile()
    @State private var history: [VerificationAdmin.AuditEntry] = []
    @State private var working = false
    @State private var failure: String?
    @State private var confirmingWithdraw = false
    @State private var current: Verification?
    @Environment(\.dismiss) private var dismiss

    private var isVerified: Bool { current?.showsBadge == true }
    private var hasRecord: Bool { current != nil }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(found.name.isEmpty ? "Unnamed" : found.name)
                        .font(.system(size: 20, weight: .semibold))
                    Text(found.handle.isEmpty ? "no username" : "@\(found.handle)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(found.peer.key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)

                if let current {
                    LabeledContent("Status", value: current.status.label)
                    if let k = current.kind { LabeledContent("Type", value: k.label) }
                    if let at = current.verifiedAt {
                        LabeledContent("Verified", value: at.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }

            // THE DRIFT WARNING. Loud, and above the controls, because it changes what the admin
            // should do — this is the case where the right action is usually to look again rather
            // than to leave a working badge alone.
            if found.hasDriftedSinceVerification, let v = current {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Renamed since verification").font(.system(size: 15, weight: .semibold))
                            Text("Approved as \(v.verifiedName.isEmpty ? "—" : v.verifiedName) (@\(v.verifiedHandle)). The badge is vouching for a name nobody reviewed.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Picker("Type", selection: $kind) {
                    ForEach(Verification.Kind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                TextField("Why (internal, never shown to them)", text: $reason, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text(isVerified ? "Change" : "Verify")
            } footer: {
                Text("The reason is stored with the decision and is the answer to \u{201C}why does this account have a badge\u{201D} for whoever asks next. It is never shown to the verified person.")
            }

            Section {
                if !isVerified {
                    Button {
                        act(hasRecord ? .restored : .granted, status: .active)
                    } label: {
                        Label(hasRecord ? "Restore verification" : "Verify this account",
                              systemImage: "checkmark.seal.fill")
                    }
                    .disabled(!canSubmit)
                } else {
                    Button {
                        act(.typeChanged, status: .active)
                    } label: {
                        Label("Update type", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!canSubmit || current?.kind == kind)

                    Button {
                        act(.suspended, status: .suspended)
                    } label: {
                        Label("Suspend while reviewing", systemImage: "pause.circle")
                    }
                    .disabled(!canSubmit)

                    Button(role: .destructive) {
                        confirmingWithdraw = true
                    } label: {
                        Label("Remove verification", systemImage: "xmark.seal")
                    }
                    .disabled(!canSubmit)
                }
            } footer: {
                if isVerified {
                    Text("Suspending hides the badge and keeps the record and its history. Removing does the same and marks it withdrawn — neither ever deletes anything.")
                }
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red).font(.system(size: 13)) }
            }

            if !caseFile.notes.isEmpty {
                Section("Notes") {
                    Text(caseFile.notes).font(.system(size: 14))
                }
            }

            Section("History") {
                if history.isEmpty {
                    Text("Nothing recorded.").foregroundStyle(.secondary)
                } else {
                    ForEach(history) { entry in
                        VerificationAuditRow(entry: entry, showsPeer: false)
                    }
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .overlay { if working { ProgressView().controlSize(.large) } }
        // ALERT, same reason as the rest of the app's destructive confirms: on iOS 26 a
        // confirmationDialog attached to a plain view renders as an anchored popover and drops its
        // cancel button. Taking a badge off somebody is not a thing to leave in a bubble whose only
        // visible button does it.
        .alert("Remove this account's verification?", isPresented: $confirmingWithdraw) {
            Button("Remove verification", role: .destructive) { act(.withdrawn, status: .revoked) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The badge disappears everywhere. The record and its history are kept.")
        }
        .task { await load() }
    }

    private var canSubmit: Bool {
        !working && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() async {
        current = found.verification
        if let k = current?.kind { kind = k }
        do {
            caseFile = try await VerificationAdmin.caseFile(for: found.peer)
            history = try await VerificationAdmin.history(for: found.peer)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func act(_ action: VerificationAdmin.Action, status: Verification.Status) {
        working = true
        failure = nil
        Task {
            do {
                try await VerificationAdmin.apply(
                    action, to: found.peer, status: status,
                    kind: status == .revoked ? current?.kind : kind,
                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    peerName: found.name, peerHandle: found.handle
                )
                reason = ""
                current = VerificationIndex.of(found.peer)
                history = (try? await VerificationAdmin.history(for: found.peer)) ?? history
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - One line of the trail

private struct VerificationAuditRow: View {
    let entry: VerificationAdmin.AuditEntry
    let showsPeer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
                Text(entry.action?.label ?? "Changed")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if let at = entry.at {
                    Text(at.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            // The name AS IT WAS when the decision was taken, not as it is now. An entry that only
            // carried a uid would be unreadable a year later, which is exactly when it gets read.
            if showsPeer {
                Text(entry.peerHandle.isEmpty ? entry.peerKey : "@\(entry.peerHandle)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if !entry.reason.isEmpty {
                Text(entry.reason).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if !entry.adminHandle.isEmpty {
                Text("by @\(entry.adminHandle)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.action {
        case .granted, .restored: return "checkmark.seal.fill"
        case .suspended:          return "pause.circle.fill"
        case .withdrawn:          return "xmark.seal.fill"
        case .typeChanged:        return "arrow.triangle.2.circlepath"
        case .noteAdded, .none:   return "note.text"
        }
    }

    private var tint: Color {
        switch entry.action {
        case .granted, .restored: return Color(hex: 0x3DA1FD)
        case .suspended:          return .orange
        case .withdrawn:          return .red
        default:                  return .secondary
        }
    }
}

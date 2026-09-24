import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// ⛔ SECURITY NOTIFICATIONS — the third row of his Security card, 2026-09-16.
//
// ⚠️ THE SWITCH IS REAL, AND THAT IS THE ONLY REASON THIS SCREEN EXISTS. `notifyNewLogin` in
// `functions-loginalert` reads `users/{uid}.securityAlerts` before it sends, so turning this off
// genuinely stops the mail. A settings toggle the sender ignores is a control that pretends to work,
// which is the one thing this project's own rules forbid outright — if the server could not be made
// to honour it, the row should not have been added.
//
// ⚠️ ABSENT MEANS ON, on both sides. Every account that predates the switch has no such field, and
// the safe reading of a missing preference about a security warning is that they want it. Only an
// explicit false turns it off.
struct SecurityNotificationsView: View {
    @State private var alerts = true
    @State private var loading = true
    @State private var error: String?

    private var uid: String? { Auth.auth().currentUser?.uid }

    var body: some View {
        List {
            Section {
                // Audit 2026-09-24: this was `onChange(of: alerts)`, which also fired for the two
                // writes that are NOT the person — the value arriving from `load`, and the put-back
                // in `save`'s catch. The put-back then saved the old value, and if that failed too it
                // put back again: a failing write flipped the switch back and forth for ever. Only a
                // tap saves now.
                Toggle("Sign-in alerts", isOn: Binding(get: { alerts },
                                                       set: { on in alerts = on; Task { await save(on) } }))
                    .disabled(loading)
            } footer: {
                Text("Email me when my account is signed in to on a device it has not been used on before. These emails are how you would find out about a sign-in that was not you.")
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Security notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let uid else { return }
        do {
            let snap = try await Firestore.firestore().collection("users").document(uid).getDocument()
            // ⚠️ The nil-coalesce is the "absent means on" rule, and it must stay on both sides of
            // the wire — see the file note.
            alerts = (snap.data()?["securityAlerts"] as? Bool) ?? true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ on: Bool) async {
        guard !loading, let uid else { return }
        // Offline, `setData` does not fail, it waits for the server — so the switch sat on a value
        // nothing had accepted, with no word said. Refuse up front, the way the sign-in doors do.
        guard NetworkState.shared.isOnline else {
            alerts = !on
            error = "No internet connection. Check your connection and try again."
            return
        }
        do {
            try await Firestore.firestore().collection("users").document(uid)
                .setData(["securityAlerts": on], merge: true)
            error = nil
        } catch {
            // Put the switch back rather than leaving it showing a state the server never accepted.
            alerts = !on
            self.error = error.localizedDescription
        }
    }
}

import SwiftUI
import FirebaseFunctions

/// Channel API key (owner 2026-11-10). A secret key that lets a program (the owner's own AI script)
/// read, post, edit, delete and pin in THIS channel, any time, with nobody signed in.
///
/// Only the accounts on `ChannelApiKey.makers` see the row, and only in a channel they own. The
/// server checks the same thing (functions-groups `channelApiKey`, lib/channelapi.js), so the list
/// here only hides the row; it grants nothing. The key is shown ONCE when made: the server keeps
/// only its hash and the last 4 characters.
enum ChannelApiKey {
    static let makers: Set<String> = [
        "SVf0zxDVZzO8oLbGvM150QWgIWd2",   // @v
        "a74hUgOoNYOmxMDoNCWI4nO81xH3",   // @kream
    ]
    static let endpoint = "https://me-central1-kulan-2ef85.cloudfunctions.net/channelApi"

    static func shows(_ conv: Conversation?, me: String) -> Bool {
        guard let conv, conv.isChannel, conv.isOwner(me) else { return false }
        return makers.contains(me) && !conv.fariinLocked
    }

    static func call(_ cid: String, _ action: String) async throws -> [String: Any] {
        let r = try await Functions.functions(region: "me-central1").httpsCallable("channelApiKey")
            .call(["cid": cid, "action": action] as [String: Any])
        return (r.data as? [String: Any]) ?? [:]
    }
}

struct ChannelApiKeyView: View {
    let cid: String

    @State private var loading = true
    @State private var hasKey = false
    @State private var hint: String?
    @State private var createdAt: Date?
    /// The full key, only right after Create / New Key, until the page closes.
    @State private var freshKey: String?
    @State private var copied = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmNew = false
    @State private var confirmRevoke = false

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let freshKey {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(freshKey)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            UIPasteboard.general.string = freshKey
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy Key", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    .padding(.vertical, 4)
                } else if hasKey {
                    HStack {
                        Text("Active key")
                        Spacer()
                        Text("••••\(hint ?? "")").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if let createdAt {
                        HStack {
                            Text("Created")
                            Spacer()
                            Text(createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No key").foregroundStyle(.secondary)
                }
            } footer: {
                if freshKey != nil {
                    Text("Copy it now. Fariin keeps only the last 4 characters, so it can't be shown again.")
                } else {
                    Text("A program with this key can read, post, edit, delete and pin posts in this channel. It can't change the channel's settings, admins or owner.")
                }
            }

            if !loading {
                Section {
                    Button(hasKey ? "New Key" : "Create Key") {
                        if hasKey { confirmNew = true } else { run("create") }
                    }
                    .disabled(busy)
                    if hasKey {
                        Button("Revoke Key", role: .destructive) { confirmRevoke = true }
                            .disabled(busy)
                    }
                } footer: {
                    Text("New Key stops the old key at once. Revoke stops it with no new one.")
                }

                Section {
                    Text(ChannelApiKey.endpoint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Address")
                } footer: {
                    Text("Send the key as \"Authorization: Bearer <key>\" with a JSON body, for example {\"action\":\"post\",\"text\":\"Hello\"}. Actions: read, post, edit, delete, pin, unpin.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Make a new key?", isPresented: $confirmNew) {
            Button("New Key", role: .destructive) { run("create") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old key stops working right away. Any program using it must get the new one.")
        }
        .alert("Revoke this key?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) { run("revoke") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Programs using it can no longer read or post in this channel.")
        }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func load() async {
        do {
            let d = try await ChannelApiKey.call(cid, "status")
            hasKey = d["hasKey"] as? Bool ?? false
            hint = d["hint"] as? String
            createdAt = (d["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func run(_ action: String) {
        busy = true
        Task {
            do {
                let d = try await ChannelApiKey.call(cid, action)
                await MainActor.run {
                    if action == "create", let k = d["key"] as? String {
                        freshKey = k
                        copied = false
                        hasKey = true
                        hint = d["hint"] as? String
                        createdAt = Date()
                    } else {
                        freshKey = nil
                        hasKey = false
                        hint = nil
                        createdAt = nil
                    }
                    busy = false
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; busy = false }
            }
        }
    }
}

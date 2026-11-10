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
    @State private var running: String?
    @State private var done = 0

    private var example: String {
        "POST \(ChannelApiKey.endpoint)\nX-Api-Key: <your key>\nContent-Type: application/json\n\n{\"action\":\"post\",\"text\":\"Hello\"}"
    }
    @State private var addressCopied = false
    @State private var exampleCopied = false

    var body: some View {
        List {
            // 1. What this is (same layout as Android ChannelApiKeyPage).
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Channel API").font(.title2.bold()).padding(.top, 6)
                    Text("Let your own program read and post in this channel, any time.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            // 2. The key.
            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let freshKey {
                    Text(freshKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        UIPasteboard.general.string = freshKey
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy Key", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                } else if hasKey {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active")
                                if let createdAt {
                                    Text("Created \(createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } icon: { Image(systemName: "key") }
                        Spacer()
                        Text("••••\(hint ?? "")").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                            .transition(.scale.combined(with: .opacity))
                    }
                } else {
                    Label("No key yet", systemImage: "key").foregroundStyle(.secondary)
                }
                if !loading {
                    Button {
                        if hasKey { confirmNew = true } else { run("create") }
                    } label: {
                        HStack {
                            Label(hasKey ? "New Key" : "Create Key", systemImage: hasKey ? "arrow.clockwise" : "plus")
                                .contentTransition(.symbolEffect(.replace))
                            Spacer()
                            if running == "create" { ProgressView().transition(.opacity) }
                        }
                    }
                    .disabled(busy)
                    if hasKey {
                        Button(role: .destructive) { confirmRevoke = true } label: {
                            HStack {
                                Label("Revoke Key", systemImage: "trash")
                                Spacer()
                                if running == "revoke" { ProgressView().transition(.opacity) }
                            }
                        }
                        .disabled(busy)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            } header: {
                Text("Key")
            } footer: {
                if freshKey != nil {
                    Text("Copy it now. Fariin keeps only the last 4 characters, so it can't be shown again.")
                } else if hasKey {
                    Text("New Key stops the old key at once. Revoke stops it with no new one.")
                } else {
                    Text("Only you can see this page. The key works for this channel only.")
                }
            }

            if !loading {
                // 3. How to connect.
                Section("Connect") {
                    Button {
                        UIPasteboard.general.string = ChannelApiKey.endpoint
                        withAnimation(.snappy) { addressCopied = true }
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Address").foregroundStyle(.primary)
                                    Text(ChannelApiKey.endpoint).font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "link") }
                            Spacer()
                            Image(systemName: addressCopied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    HStack {
                        Label("Key goes in header", systemImage: "lock")
                        Spacer()
                        Text("X-Api-Key").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                // 4. What the key can do: the plain words, and the action as the program sends it.
                Section {
                    apiAction("doc.text", "Read posts", "read")
                    apiAction("textformat", "Post text", "post + text")
                    apiAction("photo", "Post a photo", "post + image or imageUrl")
                    apiAction("pencil", "Edit a post", "edit + id + text")
                    apiAction("trash", "Delete a post", "delete + id")
                    apiAction("pin", "Pin or unpin", "pin / unpin + id")
                } header: {
                    Text("What it can do")
                } footer: {
                    Text("It can't change the channel's settings, admins or owner.")
                }

                // 5. One example to copy.
                Section {
                    Text(example)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        UIPasteboard.general.string = example
                        withAnimation(.snappy) { exampleCopied = true }
                    } label: {
                        Label(exampleCopied ? "Copied" : "Copy Example", systemImage: exampleCopied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                } header: {
                    Text("Example")
                } footer: {
                    Text("Up to 20 changes a minute and 500 a day. Photos: JPEG or PNG, up to 10 MB.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.snappy(duration: 0.35), value: hasKey)
        .animation(.snappy(duration: 0.35), value: freshKey)
        .animation(.snappy(duration: 0.25), value: running)
        .animation(.snappy(duration: 0.35), value: loading)
        .sensoryFeedback(.success, trigger: done)
        .sensoryFeedback(.selection, trigger: copied)
        .sensoryFeedback(.selection, trigger: exampleCopied)
        .sensoryFeedback(.selection, trigger: addressCopied)
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

    private func apiAction(_ icon: String, _ title: String, _ action: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(action).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: icon) }
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
        running = action
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
                    running = nil
                    done += 1
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; busy = false; running = nil }
            }
        }
    }
}

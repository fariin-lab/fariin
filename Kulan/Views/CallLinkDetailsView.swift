import SwiftUI

// CALL LINK DETAILS — a saved link's page, pushed from its row in the Calls list. The same card
// as the create sheet; the name and approval rows and Delete only for the link's creator (its
// admin), the share rows for everyone who has it.
struct CallLinkDetailsView: View {
    let link: SavedCallLink

    @Environment(\.dismiss) private var dismiss
    @State private var service = CallLinkService.shared
    /// nil until the link's own doc has answered; the switch stays disabled until then rather
    /// than showing a guess.
    @State private var approval: Bool?
    @State private var approvalFailed = false
    @State private var isVideo: Bool?   // Call Type (owner, 2026-10-06); nil until read
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteFailed = false
    // "Make a New Link" was removed on the owner's word (2026-10-06, screenshot: "remove this
    // feature"). The server's regenerateCallLink stays deployed, unused by the app.
    @State private var editingName = false   // Call Name comes up as a sheet

    /// The live copy from the service, so a rename shows here at once.
    private var current: SavedCallLink {
        service.links.first { $0.roomId == link.roomId } ?? link
    }

    var body: some View {
        ScrollView {
            // ⛔ THE SAME MINIMALIST LAYOUT AS THE CREATE SHEET — owner, 2026-10-04: what the call is
            // and Join, the three ways to pass it on as tiles, the two settings plain, Delete last.
            VStack(spacing: 22) {
                CallLinkHero(key: current.key, title: current.title) {
                    GroupCallService.shared.openLobby(key: current.key)   // pre-join screen (2026-10-06)
                }
                CallLinkShareRows(saved: current, compact: true)
                if current.admin {
                    CallLinkGroup {
                        Button { editingName = true } label: {
                            HStack {
                                Text("Call Name")
                                Spacer(minLength: 8)
                                Text(current.name.isEmpty ? "None" : current.name)
                                    .foregroundStyle(.secondary).lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                        Toggle("Admin Approval", isOn: Binding(get: { approval ?? true },
                                                               set: { setApproval($0) }))
                            .disabled(approval == nil)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                        Divider().padding(.leading, 16)
                        CallTypeRow(isVideo: isVideo) { setVideo($0) }
                    }
                }
                if current.admin {
                    CallLinkGroup {
                        Button { confirmDelete = true } label: {
                            HStack {
                                Spacer()
                                if deleting {
                                    ProgressView()
                                } else {
                                    Text("Delete Call Link").foregroundStyle(.red)
                                }
                                Spacer()
                            }
                            .frame(minHeight: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(deleting)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Call Link")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard current.admin, approval == nil else { return }
            approval = await CallLinkService.shared.approval(for: link)
            isVideo = await CallLinkService.shared.isVideo(link)
        }
        .alert("Delete this call link?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("People who have it will no longer be able to join.")
        }
        .alert("Couldn't change setting", isPresented: $approvalFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
        .sheet(isPresented: $editingName) {
            CallLinkNameSheet(initial: current.name) { name in
                try await CallLinkService.shared.rename(link, to: name)
            }
        }
        .alert("Couldn't delete call link", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    private func setVideo(_ on: Bool) {
        let before = isVideo
        isVideo = on
        Task { @MainActor in
            do { try await CallLinkService.shared.setVideo(link, on: on) }
            catch {
                isVideo = before
                approvalFailed = true
            }
        }
    }

    /// Saved to the server at once. The switch moves first; a refusal puts it back and says so.
    private func setApproval(_ on: Bool) {
        let before = approval
        approval = on
        Task { @MainActor in
            do { try await CallLinkService.shared.setApproval(link, on: on) }
            catch {
                approval = before
                approvalFailed = true
            }
        }
    }

    private func delete() {
        guard !deleting else { return }
        deleting = true
        let target = current
        Task { @MainActor in
            do {
                try await CallLinkService.shared.delete(target)
                deleting = false
                dismiss()
            } catch {
                deleting = false
                deleteFailed = true
            }
        }
    }
}

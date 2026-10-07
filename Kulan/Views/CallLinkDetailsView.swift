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
    /// Audit M-095, 2026-10-07: per switch, what the server last confirmed and whether a save runs.
    @State private var approvalSaved: Bool?
    @State private var approvalSaving = false
    @State private var videoSaved: Bool?
    @State private var videoSaving = false
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
                CallLinkHero(key: current.key, title: current.title, video: isVideo ?? true) {
                    GroupCallService.shared.openLobby(key: current.key)   // pre-join screen (2026-10-06)
                }
                // The address says /video/ or /voice/; until the doc has been read it is shown as
                // video, which is what every link made before the setting is.
                CallLinkShareRows(saved: current, video: isVideo ?? true, compact: true)
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
                            .tint(.green)   // green always (owner, 2026-10-06: white-on-white in dark mode)
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
            approvalSaved = approval
            isVideo = await CallLinkService.shared.isVideo(link)
            videoSaved = isVideo
        }
        .alert("Delete this call link?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
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

    /// Audit M-023, 2026-10-07: deleting the link of the call I am in also closes that call on
    /// the server, so the question says so.
    private var deleteMessage: String {
        let group = GroupCallService.shared
        if group.isActive, group.currentLink?.roomId == current.roomId {
            return "People who have it will no longer be able to join, and the call on it ends for everyone in it."
        }
        return "People who have it will no longer be able to join."
    }

    /// Audit M-095, 2026-10-07 (both switches): one save at a time, the newest value sent when
    /// it ends, a refusal back to what the server last confirmed. Two quick flips used to race as
    /// two unordered calls and could leave the server opposite to the switch.
    private func setVideo(_ on: Bool) {
        isVideo = on
        guard !videoSaving else { return }
        videoSaving = true
        Task { @MainActor in
            while let want = isVideo, want != videoSaved {
                do {
                    try await CallLinkService.shared.setVideo(link, on: want)
                    videoSaved = want
                } catch {
                    isVideo = videoSaved
                    approvalFailed = true
                    break
                }
            }
            videoSaving = false
        }
    }

    /// Saved to the server at once. The switch moves first; a refusal puts it back and says so.
    private func setApproval(_ on: Bool) {
        approval = on
        guard !approvalSaving else { return }
        approvalSaving = true
        Task { @MainActor in
            while let want = approval, want != approvalSaved {
                do {
                    try await CallLinkService.shared.setApproval(link, on: want)
                    approvalSaved = want
                } catch {
                    approval = approvalSaved
                    approvalFailed = true
                    break
                }
            }
            approvalSaving = false
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

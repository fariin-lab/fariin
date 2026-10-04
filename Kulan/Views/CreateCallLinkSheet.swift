import SwiftUI
import UIKit

// CREATE CALL LINK — product item 5, the reference app's sheet.
//
// Tap "Create a Call Link" → a spinner over the Calls tab while the server makes the link → this
// sheet. The link already exists on the server when the sheet opens, but it is only put into my
// Calls list on Done, Join, Copy or Share (`CallLinkService.persist`). Swiping the sheet away
// leaves nothing behind in the list, the way the reference app forgets a link you never used.
//
// Present it with `.createCallLinkFlow(isPresented:)` on the Calls list; the flow owns the spinner,
// the failure alert and the sheet.

// MARK: - Flow

extension View {
    /// Flip `isPresented` to true to create a link and open the sheet. It goes back to false on its
    /// own once the create has finished, whichever way it went.
    func createCallLinkFlow(isPresented: Binding<Bool>) -> some View {
        modifier(CreateCallLinkFlow(isPresented: isPresented))
    }
}

struct CreateCallLinkFlow: ViewModifier {
    @Binding var isPresented: Bool
    @State private var creating = false
    @State private var draft: CallLinkDraft?
    @State private var failed = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if creating {
                    ZStack {
                        // Swallows taps while the server works, so a second tap cannot start a
                        // second link.
                        Color.black.opacity(0.001).ignoresSafeArea()
                        ProgressView()
                            .controlSize(.large)
                            .frame(width: 80, height: 80)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: isPresented) { _, now in
                if now { start() }
            }
            .sheet(item: $draft) { d in
                CreateCallLinkSheet(draft: d)
            }
            .alert("Couldn't create call link", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
    }

    private func start() {
        guard !creating else { return }
        withAnimation(.easeOut(duration: 0.15)) { creating = true }
        Task { @MainActor in
            do {
                let d = try await CallLinkService.shared.create()
                withAnimation(.easeOut(duration: 0.15)) { creating = false }
                draft = d
            } catch {
                withAnimation(.easeOut(duration: 0.15)) { creating = false }
                failed = true
            }
            isPresented = false
        }
    }
}

// MARK: - Sheet

struct CreateCallLinkSheet: View {
    @State private var draft: CallLinkDraft
    init(draft: CallLinkDraft) { _draft = State(initialValue: draft) }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var approvalFailed = false
    /// Measured from the content; the first value is a close estimate so the sheet does not open
    /// at one height and move to another.
    @State private var contentHeight: CGFloat = 470

    var body: some View {
        NavigationStack {
            ScrollView {
                // ⛔ MINIMALIST — owner, 2026-10-04: "redesign this sheet, minimalist and clear".
                // One thing per line, in the order a person uses them: what the call is, Join, the
                // three ways to hand the link on as round buttons, then the two settings, plain.
                VStack(spacing: 22) {
                    header
                    VStack(spacing: 8) {
                        CallLinkAvatar(key: draft.key, size: 64)
                        Text(draft.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(shortLink)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button { join() } label: {
                        Text("Join Call")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.defaultBubble(scheme == .dark), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    CallLinkShareRows(draft: draft, compact: true) {
                        await CallLinkService.shared.persist(draft)
                    }
                    CallLinkGroup {
                        NavigationLink {
                            CallLinkNameEditor(initial: draft.name) { name in
                                try await CallLinkService.shared.rename(draft, to: name)
                                draft.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .prefix(CallLinkDefaults.maxNameLength))
                            }
                        } label: {
                            HStack {
                                Text("Call Name")
                                Spacer(minLength: 8)
                                Text(draft.name.isEmpty ? "None" : draft.name)
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
                        Toggle("Admin Approval", isOn: Binding(get: { draft.approval }, set: { setApproval($0) }))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.height(contentHeight + 12)])
        .presentationDragIndicator(.visible)
        .alert("Couldn't change setting", isPresented: $approvalFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    /// Title in the middle, the blue check (Done) on the right. A plain header rather than a
    /// navigation bar so the sheet can be exactly as tall as what it holds.
    private var header: some View {
        ZStack {
            Text("Call Link")
                .font(.headline)
            HStack {
                Spacer()
                Button("Done") { done() }
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.top, 6)
    }

    /// The link without its scheme: "fariin.com/call/#key=…", cut in the middle when long.
    private var shortLink: String {
        let full = CallLinkKey(text: draft.key)?.url.absoluteString ?? ""
        return full.replacingOccurrences(of: "https://", with: "")
    }

    private func done() {
        let d = draft
        Task { await CallLinkService.shared.persist(d) }
        dismiss()
    }

    private func join() {
        let d = draft
        dismiss()
        Task { @MainActor in
            await CallLinkService.shared.persist(d)
            // Let the sheet finish leaving before the call screen comes up over it.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await GroupCallService.shared.joinLink(key: d.key, video: true)
        }
    }

    /// Saved to the server at once. The switch moves first; a refusal puts it back and says so.
    private func setApproval(_ on: Bool) {
        let before = draft.approval
        draft.approval = on
        let d = draft
        Task { @MainActor in
            do { try await CallLinkService.shared.setApproval(d, on: on) }
            catch {
                draft.approval = before
                approvalFailed = true
            }
        }
    }
}

// MARK: - Shared pieces (the details page uses these too)

/// The round video tile of a call link. Its colour comes from the link's room id, so the same link
/// is the same colour on every phone and in every list.
struct CallLinkAvatar: View {
    let key: String     // the formatted root key
    let size: CGFloat

    /// Eight calm colours, mid-tone so white reads on all of them in light and dark.
    private static let palette: [Color] = [
        Color(hex: 0x4F7DF3), Color(hex: 0x2FA37C), Color(hex: 0xE0794F), Color(hex: 0x8C6BDB),
        Color(hex: 0xD3577A), Color(hex: 0x2C9BB8), Color(hex: 0xC69A2E), Color(hex: 0x5E8C4A),
    ]

    static func color(for key: String) -> Color {
        let room = CallLinkKey(text: key)?.roomId ?? ""
        let first = UInt8(room.prefix(2), radix: 16) ?? 0
        return palette[Int(first) % palette.count]
    }

    var body: some View {
        Circle()
            .fill(Self.color(for: key))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "video.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Avatar, name, the link itself and Join.
struct CallLinkCard: View {
    let key: String
    let title: String
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CallLinkAvatar(key: key, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(CallLinkKey(text: key)?.url.absoluteString ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onJoin) {
                Text("Join")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.green, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A rounded group of rows, the inset-grouped look without a List (a List cannot be measured
/// for a fitted sheet).
struct CallLinkGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CallLinkDivider: View {
    var body: some View { Divider().padding(.leading, 52) }
}

struct CallLinkRow: View {
    let icon: String
    let title: String
    var tint: Color = .primary
    var chevron = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

struct CallLinkApprovalRow: View {
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 17))
                .frame(width: 24)
            Toggle("Require Admin Approval", isOn: $isOn)
                .disabled(!enabled)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }
}

/// "Share Link via Kulan", "Copy Link", "Share Link". `beforeShare` runs first on each (the
/// create sheet saves the link into the list there; the details page has nothing to do).
struct CallLinkShareRows: View {
    let link: any CallLinkRef
    let beforeShare: () async -> Void

    /// Three round buttons in a row instead of three rows (the create sheet, owner 2026-10-04).
    var compact = false

    init(draft: CallLinkDraft, compact: Bool = false, beforeShare: @escaping () async -> Void) {
        self.link = draft; self.beforeShare = beforeShare; self.compact = compact
    }
    init(saved: SavedCallLink) {
        self.link = saved; self.beforeShare = {}
    }

    @State private var sendInApp = false
    @State private var systemShare = false
    @State private var toast = ""
    @State private var toastShown = false

    private var urlText: String { link.url?.absoluteString ?? "" }

    private func sendInKulan() { Task { @MainActor in await beforeShare(); sendInApp = true } }
    private func copyLink() {
        UIPasteboard.general.string = urlText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        flash("Link copied")
        Task { await beforeShare() }
    }
    private func shareLink() { Task { @MainActor in await beforeShare(); systemShare = true } }

    @ViewBuilder private var actions: some View {
        if compact {
            HStack(spacing: 10) {
                roundAction("paperplane", "Send", sendInKulan)
                roundAction("doc.on.doc", "Copy", copyLink)
                roundAction("square.and.arrow.up", "Share", shareLink)
            }
        } else {
            CallLinkGroup {
                Button(action: sendInKulan) {
                    CallLinkRow(icon: "arrowshape.turn.up.right", title: "Share Link via Kulan")
                }
                .buttonStyle(.plain)
                CallLinkDivider()
                Button(action: copyLink) {
                    CallLinkRow(icon: "doc.on.doc", title: "Copy Link")
                }
                .buttonStyle(.plain)
                CallLinkDivider()
                Button(action: shareLink) {
                    CallLinkRow(icon: "square.and.arrow.up", title: "Share Link")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One equal-width tile: the glyph over its word, on the grouped surface.
    private func roundAction(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Send" ? "Send in a chat" : title)
    }

    var body: some View {
        actions
        // The chat picker every other "share into a chat" in the app uses; it sends the link as a
        // text message into whichever chats are picked.
        .sheet(isPresented: $sendInApp) {
            SendContactSheet(contactText: urlText, onSent: { flash($0) })
        }
        .sheet(isPresented: $systemShare) {
            SystemShareSheet(items: link.url.map { [$0 as Any] } ?? [])
                .presentationDetents([.medium, .large])
        }
        // Over the rows themselves: anything hung below them is clipped by the sheet's scroll view.
        .overlay {
            if toastShown {
                Text(toast)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .fixedSize()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func flash(_ text: String) {
        toast = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toastShown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.25)) { toastShown = false }
        }
    }
}

/// "Add Call Name": one field, 32 characters, Save.
struct CallLinkNameEditor: View {
    let initial: String
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    init(initial: String, onSave: @escaping (String) async throws -> Void) {
        self.initial = initial; self.onSave = onSave
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                TextField(CallLinkDefaults.name, text: $text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .onChange(of: text) { _, v in
                        if v.count > CallLinkDefaults.maxNameLength {
                            text = String(v.prefix(CallLinkDefaults.maxNameLength))
                        }
                    }
            } footer: {
                Text("\(text.count)/\(CallLinkDefaults.maxNameLength)")
            }
        }
        .navigationTitle("Call Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { save() }
                        .disabled(trimmed == initial)
                }
            }
        }
        .onAppear { focused = true }
        .alert("Couldn't save name", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    private func save() {
        guard !saving, trimmed != initial else { return }
        saving = true
        let name = trimmed
        Task { @MainActor in
            do {
                try await onSave(name)
                saving = false
                dismiss()
            } catch {
                saving = false
                failed = true
            }
        }
    }
}

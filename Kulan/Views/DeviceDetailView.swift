import SwiftUI

/// One signed-in device, opened from Settings › Devices — owner, 2026-09-25: "this page looks too
/// basic". Everything shown is what the device itself reported; nothing is estimated. Another
/// device can be signed out from here; this one cannot (that is Sign Out in Account).
struct DeviceDetailView: View {
    let session: DeviceSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var working = false
    @State private var error: String?

    private let fullDate = Date.FormatStyle(date: .abbreviated, time: .shortened)

    private var isActive: Bool {
        session.isThisDevice || session.lastSeenAt > Date().addingTimeInterval(-360)
    }

    /// ⛔ A SHEET NOW, NOT A PAGE — owner, 2026-09-29, with the reference's device sheet: "when I tap a
    /// device it opens a full page; open a sheet about 60%". ✕ at the top left, the tile, name and
    /// status, the facts in one card, and the sign-out as a wide red button at the bottom.
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    DeviceTile(session: session, size: 64)
                    Text(session.displayName).font(.title2.weight(.bold))
                    // ⛔ "Online", GREY, NO DOT — owner, 2026-10-14: "remove This device and Active
                    // now, only make it Online", in the grey of the line under the name.
                    if isActive {
                        Text("Online").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Last active \(session.lastSeenAt.formatted(.relative(presentation: .named)))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Model", value: session.displayName)
                if !session.os.isEmpty { LabeledContent("System", value: session.os) }
                if !session.appVersion.isEmpty { LabeledContent("Fariin", value: session.appVersion) }
                if !session.location.isEmpty { LabeledContent("Location", value: session.location) }
                if let created = session.createdAt {
                    LabeledContent("Signed in", value: created.formatted(fullDate))
                }
                LabeledContent("Last active", value: isActive ? "Now" : session.lastSeenAt.formatted(fullDate))
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !session.isThisDevice {
                Button { confirm = true } label: {
                    ZStack {
                        Text("Sign Out This Device").opacity(working ? 0 : 1)
                        if working { ProgressView().tint(.white) }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.red, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(working)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(16)
        }
        .presentationDetents([.fraction(0.6)])
        // SOLID, NOT GLASS — owner, 2026-09-29: "this sheet looks like glass; a light sheet in light
        // mode, a dark one in dark mode". iOS 26 draws a partial sheet as glass by default; the
        // grouped background is the page colour the facts card is designed to sit on.
        .scrollContentBackground(.hidden)
        .presentationBackground(Color(.systemGroupedBackground))
        .alert("Sign out \(session.displayName)?", isPresented: $confirm) {
            Button("Sign Out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will stop receiving messages and calls.")
        }
    }

    private func signOut() {
        working = true
        error = nil
        Task {
            do {
                try await DeviceRegistry.shared.signOut(deviceId: session.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// The device's picture: blue for the phone in your hand, the system's neutral grey for the rest,
/// so "which one am I" is answered by colour before any text is read.
struct DeviceTile: View {
    let session: DeviceSession
    let size: CGFloat

    var body: some View {
        let glyph = Image(systemName: session.isPad ? "ipad" : "iphone")
            .font(.system(size: size * 0.5, weight: .medium))
            .frame(width: size, height: size)
        if session.isThisDevice {
            glyph
                .foregroundStyle(.white)
                .background(
                    LinearGradient(colors: [Color.blue.opacity(0.95), Color.blue.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom),
                    // ⛔ ROUND AND BLUE — owner, 2026-09-29: "green is not my app's colour, use blue;
                    // make the icons circles". This device is the app's blue.
                    in: Circle())
        } else {
            // ⛔ THE REFERENCE MESSENGER'S GREY — owner, 2026-10-14: "the grey is too dark, use their
            // grey". Their linked-device row draws its icon on `Color(.systemFill)` with the glyph in
            // the primary colour; a white glyph would vanish on that light grey, so it comes too.
            glyph
                .foregroundStyle(.primary)
                .background(Color(.systemFill), in: Circle())
        }
    }
}

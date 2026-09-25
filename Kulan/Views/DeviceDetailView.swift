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

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    DeviceTile(session: session, size: 72)
                    Text(session.displayName).font(.title2.weight(.bold))
                    if isActive {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(session.isThisDevice ? "This device · Active now" : "Active now")
                                .font(.subheadline.weight(.medium)).foregroundStyle(.green)
                        }
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
                if let created = session.createdAt {
                    LabeledContent("Signed in", value: created.formatted(fullDate))
                }
                LabeledContent("Last active", value: isActive ? "Now" : session.lastSeenAt.formatted(fullDate))
            }

            if !session.isThisDevice {
                Section {
                    Button(role: .destructive) { confirm = true } label: {
                        HStack {
                            Text("Sign Out This Device")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .tint(.red)
                    .disabled(working)
                } footer: {
                    Text("It stops receiving messages and calls straight away, and is signed out the next time it is opened.")
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
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

/// The device's picture: green for the phone in your hand, the system's neutral grey for the rest,
/// so "which one am I" is answered by colour before any text is read.
struct DeviceTile: View {
    let session: DeviceSession
    let size: CGFloat

    var body: some View {
        let colour: Color = session.isThisDevice ? .green : Color(.systemGray)
        Image(systemName: session.isPad ? "ipad" : "iphone")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [colour.opacity(0.95), colour.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

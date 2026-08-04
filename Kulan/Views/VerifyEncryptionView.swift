import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

// Fariin's own "verify encryption" screen (our look, not a copy of other messengers).
// Shows the chat's safety number + a QR of it. Two people confirm their end-to-end
// encryption is genuine either by comparing the number or by scanning each other's code;
// a match marks the chat Verified. If a key ever changes (new device / re-install), the
// number changes and the chat quietly drops back to unverified — the standard behavior.
struct VerifyEncryptionView: View {
    let cid: String
    let peerName: String
    let peerUid: String
    let peerPhotoUrl: String?

    @Environment(\.colorScheme) private var scheme
    @State private var number: String = ""          // the 60-digit safety number
    @State private var loadError = false            // peer hasn't published a key yet
    @State private var verified = false
    @State private var showScanner = false
    @State private var scanOutcome: ScanOutcome?

    private var dark: Bool { scheme == .dark }
    private var cardColor: Color { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF2F2F7) }
    private var myName: String { ProfileStore.shared.me?.name ?? "You" }
    private var myPhoto: String? { ProfileStore.shared.me?.photoUrl }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if loadError {
                    unavailable
                } else if number.isEmpty {
                    ProgressView().padding(.top, 60)
                } else {
                    qrCard
                    numberCard
                    scanButton
                    note
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .task { await compute() }
        .sheet(isPresented: $showScanner) {
            VerifyScanSheet { code in handleScanned(code) }
        }
        .alert(item: $scanOutcome) { outcome in
            switch outcome {
            case .match:
                return Alert(title: Text("Verified"),
                             message: Text("Your safety number with \(peerName) matches. This chat is end-to-end encrypted and confirmed."),
                             dismissButton: .default(Text("Done")))
            case .mismatch:
                return Alert(title: Text("Numbers don't match"),
                             message: Text("The scanned code doesn't match your safety number. Your messages are still encrypted, but you couldn't confirm \(peerName)'s device. Try scanning again, or compare the numbers by hand."),
                             dismissButton: .default(Text("OK")))
            case .invalid:
                return Alert(title: Text("Not a Fariin code"),
                             message: Text("That QR code isn't a Fariin verification code. Ask \(peerName) to open Encryption on their side."),
                             dismissButton: .default(Text("OK")))
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                avatarLabel(myName, myPhoto, "You")
                Image(systemName: verified ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(verified ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
                    .background(cardColor, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                avatarLabel(peerName, peerPhotoUrl, peerName)
            }
            .padding(.top, 8)
            Text(verified ? "This chat is verified" : "This chat is end-to-end encrypted")
                .font(.headline)
            Text("Messages and calls with \(peerName) are secured with end-to-end encryption. No one outside this chat, not even Fariin, can read them.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func avatarLabel(_ name: String, _ photo: String?, _ caption: String) -> some View {
        VStack(spacing: 6) {
            AvatarView(name: name, photoUrl: photo, size: 60)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: 120)
    }

    private var qrCard: some View {
        VStack(spacing: 0) {
            if let img = qrImage(SafetyNumber.qrPayload(number)) {
                Image(uiImage: img)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(18)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .padding(6)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var numberCard: some View {
        VStack(spacing: 10) {
            Text("Safety number")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(Array(SafetyNumber.grouped(number).enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var scanButton: some View {
        Button { showScanner = true } label: {
            Label(verified ? "Scan again" : "Scan their code", systemImage: "qrcode.viewfinder")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private var note: some View {
        Text("To verify, ask \(peerName) to open Encryption on their device, then scan their code, or read the numbers aloud to check they match.")
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.slash").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Can't show the safety number yet")
                .font(.headline)
            Text("\(peerName) hasn't finished setting up encryption on their device. Try again once they've opened the chat.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 50).padding(.horizontal, 20)
    }

    // MARK: - Logic

    private func compute() async {
        try? await Crypto.shared.ensureReady()
        guard let me = AuthService.shared.uid,
              let myPub = Crypto.shared.myPublicKeyData,
              let theirPub = await Crypto.shared.publicKeyData(for: peerUid) else {
            await MainActor.run { loadError = true }
            return
        }
        // The 5200-round hash is cheap but off the main actor keeps the push animation smooth.
        let n = await Task.detached(priority: .userInitiated) {
            SafetyNumber.compute(myUid: me, myPub: myPub, theirUid: peerUid, theirPub: theirPub)
        }.value
        await MainActor.run {
            number = n
            verified = UserDefaults.standard.bool(forKey: verifyKey(n))
        }
    }

    private func handleScanned(_ code: String) {
        showScanner = false
        guard let scanned = SafetyNumber.numberFromQR(code) else { scanOutcome = .invalid; return }
        if scanned == number {
            verified = true
            UserDefaults.standard.set(true, forKey: verifyKey(number))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            scanOutcome = .match
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            scanOutcome = .mismatch
        }
    }

    // Verified flag is keyed by the NUMBER, so if either key ever changes the number
    // changes and the chat is automatically no longer "verified" (re-verify required).
    private func verifyKey(_ n: String) -> String { "fariin_verified_\(cid)_\(n)" }

    private func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private enum ScanOutcome: Identifiable {
        case match, mismatch, invalid
        var id: Int { hashValue }
    }
}

// Scanner sheet for reading the other person's verification QR. Wraps the shared QRScanner
// with a dismiss chrome + a hint, so the verify flow doesn't route through the "find a user"
// resolver in ScanQRView.
private struct VerifyScanSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            QRScanner { code in onCode(code) }.ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            .padding(12).liquidGlass(Circle(), interactive: true)
                    }
                    Spacer()
                }
                Spacer()
                Text("Point at their Fariin verification code")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .liquidGlass(Capsule())
                    .padding(.bottom, 40)
            }
            .padding()
        }
    }
}

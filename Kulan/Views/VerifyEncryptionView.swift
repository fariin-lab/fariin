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
        // ⛔ REDESIGNED 2026-08-23 ON HIS ORDER: "make it clear and minimalist … dont rmeove any
        // feature just redesign smooth and clean".
        //
        // Nothing was taken out. Every element on this page is still here — the two faces, the lock
        // that becomes a seal, the key-changed record, the code, the twelve groups, Scan, both
        // paragraphs, the unavailable state. What changed is how much FURNITURE they sit in.
        //
        // The page had three filled grey cards stacked down it, one of which was a card wrapped
        // around another card (a white QR panel inside a grey one), and a block of monospaced digits
        // in a third. On a screen whose whole job is to let two people read twelve numbers to each
        // other, the boxes were the loudest thing on it. They are gone; the code keeps one white
        // panel because a QR has to be read off white, and the digits sit on the page.
        //
        // ⚠️ THE SPACING IS THE STRUCTURE NOW. With the cards gone, the only thing separating one
        // section from the next is air, so these numbers are doing work the fills used to do — 32
        // between sections, 16 inside one. Tightening them is what would make this read as a list.
        ScrollView {
            VStack(spacing: 32) {
                header
                if loadError {
                    unavailable
                } else if number.isEmpty {
                    ProgressView().padding(.top, 60)
                } else {
                    qrCard
                    numberCard
                    VStack(spacing: 14) {
                        scanButton
                        note
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
        // Follows the phone. A pushed screen inherits the bar's appearance from whoever pushed it,
        // and the profile page forces its bar dark — see the note in `MediaGalleryView`.
        .toolbarColorScheme(nil, for: .navigationBar)
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
        VStack(spacing: 16) {
            // ⚠️ THE FACES ARE SMALLER AND CLOSER, and the lock between them is a mark rather than a
            // third circle. It used to be a 22pt glyph on a 44pt filled disc, which made a row of
            // three round objects out of two people and a status — the eye counted three faces. At
            // 26pt with no disc it reads as what it is: the state of the line BETWEEN them.
            HStack(spacing: 16) {
                avatarLabel(myName, myPhoto, "You")
                Image(systemName: verified ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(verified ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    // Lifted onto the avatars' own centre line rather than the column's: the labels
                    // under the faces are part of those columns and would otherwise drag the lock
                    // down below the pictures it sits between.
                    .offset(y: -11)
                avatarLabel(peerName, peerPhotoUrl, peerName)
            }
            VStack(spacing: 8) {
                Text(verified ? "This chat is verified" : "This chat is end-to-end encrypted")
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Messages and calls with \(peerName) are secured with end-to-end encryption. No one outside this chat, not even Fariin, can read them.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // Narrower than the page. A centred paragraph running the full width reads as a
                    // block of text; broken nearer its natural measure it reads as a caption, which
                    // is what it is.
                    .frame(maxWidth: 320)
            }
            // THE RECORD, and it does not go away. The chat's bar can be tapped once and is then
            // gone for good, so before this there was no answer anywhere to "has this person's
            // number ever changed?" — the only trace was the Verified badge quietly not being
            // there, which reads identically to never having verified in the first place.
            // ⚠️ Stated as a fact with a date and nothing more. A new phone or a reinstall does
            // this too, and is much the likelier reason.
            if let changed = SafetyKeyLog.lastChangedAt(peerUid) {
                Label {
                    Text("Safety number last changed \(changed.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: "lock.rotation")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
        }
    }

    private func avatarLabel(_ name: String, _ photo: String?, _ caption: String) -> some View {
        VStack(spacing: 8) {
            AvatarView(name: name, photoUrl: photo, size: 56)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: 110)
    }

    /// ⛔ ONE PANEL, NOT TWO. The QR was a white card inside a grey card — a frame around a frame,
    /// and the outer one carried no information at all. The white stays because a QR has to be read
    /// off white in both appearances; what holds it to the page in light mode is a hairline of the
    /// same grey the outer card used to be filled with, which separates it without boxing it.
    private var qrCard: some View {
        Group {
            if let img = qrImage(SafetyNumber.qrPayload(number)) {
                Image(uiImage: img)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 208, height: 208)
                    .padding(20)
                    .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(cardColor, lineWidth: dark ? 0 : 1)
                    }
            }
        }
    }

    /// ⛔ THE DIGITS SIT ON THE PAGE. They were in a filled card, and this is the one thing on the
    /// screen somebody actually reads out loud to another person — a grey block around it is a
    /// second thing for the eye to resolve before it can start reading.
    ///
    /// ⚠️ THE LABEL IS CENTRED NOW, over centred numbers. Left-aligned above a centred grid it was
    /// the only thing on the page hanging off the left margin.
    private var numberCard: some View {
        VStack(spacing: 16) {
            Text("SAFETY NUMBER")
                .font(.system(size: 11, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.secondary)
            // 14 rather than 10 between rows: three rows of monospaced figures at the old spacing
            // read as one field of digits, and the whole point is that they are twelve separate
            // groups you check one at a time.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                ForEach(Array(SafetyNumber.grouped(number).enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(.system(size: 17, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var scanButton: some View {
        Button { showScanner = true } label: {
            Label(verified ? "Scan again" : "Scan their code", systemImage: "qrcode.viewfinder")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Color.accentColor, in: Capsule())
                // Accent IS `.primary` app-wide, so this capsule is white at night and a hardcoded
                // white label vanished into it. `onAccent` is that colour's declared inverse.
                .foregroundStyle(Theme.onAccent(dark))
        }
    }

    private var note: some View {
        Text("To verify, ask \(peerName) to open Encryption on their device, then scan their code, or read the numbers aloud to check they match.")
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320)
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.slash").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Can't show the safety number yet")
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("\(peerName) hasn't finished setting up encryption on their device. Try again once they've opened the chat.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .padding(.top, 40)
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

import SwiftUI
import UIKit
import AVFoundation
import Observation
import CoreImage.CIFilterBuiltins
import FirebaseAuth

// ⛔ PHONE-TO-PHONE CHAT TRANSFER SCREENS (device-storage plan phase 4, 2026-11-12, both apps alike).
//   1. Settings > Chats > Transfer Chats (old phone): Show QR, then "Done on your new phone".
//      The same page has Receive Chats, for a phone that is already set up.
//   2. Sign-in (new phone, no history yet): "Moving from another phone?" Scan QR / Not Now, asked
//      BEFORE the iCloud restore check; Not Now goes on to that check.
//   3. Errors in plain words (ChatTransfer.Failure).
// Everything here stays hidden while `ChatTransfer.enabled` is false.

// MARK: - The QR picture

enum TransferQR {
    /// Plain square modules, black on white, correction level M: the transfer code is long (about 90
    /// characters) and is read once from a screen at arm's length, so it is drawn for the scanner,
    /// not dressed up like the profile code.
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Sign-in: "Moving from another phone?"

/// The receive screen at sign-in. RootView shows it while `asking` is true.
@MainActor @Observable
final class ChatTransferOffer {
    static let shared = ChatTransferOffer()
    private init() {}

    var asking = false
}

@MainActor enum ChatTransferFlow {
    /// The FIRST step of the sign-in restore check (ChatBackupFlow.atSignIn): only when this phone
    /// holds no history for the account. Returns once the person scanned, chose Not Now, or nothing
    /// was asked.
    static func atSignIn() async {
        guard ChatTransfer.enabled, let uid = Auth.auth().currentUser?.uid else { return }
        // Asked before anything else is filed: messages arriving after sign-in would count as history.
        let hasHistory = await Task.detached(priority: .userInitiated) { LocalMessageDB.shared.hasHistory(uid: uid) }.value
        // Once per account on this phone: after Not Now, Settings > Chats > Transfer Chats still has it.
        let askedKey = "chatTransfer.asked.\(uid)"
        guard !hasHistory, !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        let offer = ChatTransferOffer.shared
        offer.asking = true
        while offer.asking {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
        }
    }
}

// MARK: - Settings > Chats > Transfer Chats (old phone)

struct ChatTransferPage: View {
    enum Stage: Equatable {
        case idle
        case preparing
        case uploading(Int, Int)
        case showing(ChatTransfer.Code, Date)
        case done
        case expired
    }

    @State private var stage = Stage.idle
    @State private var problem: String?
    @State private var work: Task<Void, Never>?
    @State private var watch: Task<Void, Never>?
    @State private var receiving = false

    private var uid: String { Auth.auth().currentUser?.uid ?? "" }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                content
                if let problem {
                    Text(problem).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Divider().padding(.vertical, 8)
                receiveRow
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Transfer Chats")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stopAll() }
        .fullScreenCover(isPresented: $receiving) {
            ChatReceiveView(startScanning: true) { receiving = false }
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: stage == .done ? "checkmark" : "iphone.and.arrow.forward")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.fariinAction)
                .frame(width: 84, height: 84)
                .liquidGlass(Circle())
            Text(stage == .done ? "Done on your new phone" : "Move your chats to a new phone")
                .font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text(stage == .done
                 ? "Your chats are on your new phone now."
                 : "Open Fariin on your new phone, sign in, and scan this code. Your chats move directly; the code works for one hour.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .idle, .expired:
            if stage == .expired {
                Text(ChatTransfer.Failure.expired.errorDescription ?? "")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            pill(stage == .expired ? "Show New QR" : "Show QR") { showQR() }
        case .preparing:
            busyRow("Getting your chats ready...")
        case .uploading(let n, let total):
            busyRow("Preparing \(n) of \(total)")
        case .showing(let code, let made):
            qrCard(code)
            HStack(spacing: 10) {
                ProgressView()
                Text("Waiting for your new phone...").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Works until \(made.addingTimeInterval(ChatTransfer.lifetime).formatted(date: .omitted, time: .shortened))")
                .font(.footnote).foregroundStyle(.secondary)
        case .done:
            EmptyView()
        }
    }

    private func qrCard(_ code: ChatTransfer.Code) -> some View {
        Group {
            if let img = TransferQR.image(code.text) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Transfer QR code")
            } else {
                Color.white
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white))
        .frame(maxWidth: 340)
        .aspectRatio(1, contentMode: .fit)
        .environment(\.colorScheme, .light)
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(height: 50)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold)).foregroundStyle(Color.onFariinAction)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Capsule().fill(Color.fariinAction))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var receiveRow: some View {
        VStack(spacing: 8) {
            Button { receiving = true } label: {
                Label("Receive Chats", systemImage: "qrcode.viewfinder")
                    .font(.body.weight(.semibold)).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .liquidGlass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            Text("On this phone, scan the code shown on your other phone.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    // MARK: Work

    private func showQR() {
        problem = nil
        stopAll()
        stage = .preparing
        let me = uid
        work = Task {
            do {
                let code = try await ChatTransfer.send(uid: me) { n, total in
                    if n > 0 { stage = .uploading(n, total) }
                }
                let made = Date()
                stage = .showing(code, made)
                UIApplication.shared.isIdleTimerDisabled = true   // the screen stays on while the code waits
                startWatching(code, made: made, uid: me)
            } catch is CancellationError {
                stage = .idle
            } catch {
                problem = ChatTransfer.plain(error).errorDescription
                Haptics.notify(.error)
                stage = .idle
            }
        }
    }

    /// Every 5 s: has the new phone emptied the folder? The code stops at one hour.
    private func startWatching(_ code: ChatTransfer.Code, made: Date, uid: String) {
        watch?.cancel()
        watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                if Date().timeIntervalSince(made) >= ChatTransfer.lifetime {
                    UIApplication.shared.isIdleTimerDisabled = false
                    stage = .expired
                    return
                }
                if await ChatTransfer.pickedUp(uid: uid, tid: code.tid) == true {
                    UIApplication.shared.isIdleTimerDisabled = false
                    Haptics.notify(.success)
                    stage = .done
                    return
                }
            }
        }
    }

    private func stopAll() {
        work?.cancel(); work = nil
        watch?.cancel(); watch = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

// MARK: - Receiving (new phone)

/// "Moving from another phone?" at sign-in (`startScanning` false), or straight to the camera from
/// Receive Chats (`startScanning` true). Scan, "Receiving 3 of 7", then "Your chats are here".
struct ChatReceiveView: View {
    var startScanning = false
    var onDone: () -> Void

    enum Stage: Equatable {
        case ask
        case working(Int, Int)
        case done(Int)
        case failed(String)
    }
    @State private var stage = Stage.ask
    @State private var scanning = false
    @State private var started = false
    @State private var work: Task<Void, Never>?

    private var uid: String { Auth.auth().currentUser?.uid ?? "" }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: icon)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.fariinAction)
                .frame(width: 96, height: 96)
                .liquidGlass(Circle())
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if case .failed(let words) = stage {
                Text(words).font(.subheadline.weight(.semibold)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            buttons
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).ignoresSafeArea())
        .interactiveDismissDisabled()
        .fullScreenCover(isPresented: $scanning) {
            TransferScanView(onCode: { code in
                scanning = false
                receive(code)
            }, onCancel: {
                scanning = false
            })
        }
        .onAppear {
            guard !started else { return }
            started = true
            if startScanning { scanning = true }
        }
        .onDisappear { work?.cancel() }
    }

    private var icon: String {
        switch stage {
        case .done: return "checkmark"
        case .working: return "arrow.down"
        default: return "qrcode.viewfinder"
        }
    }

    private var title: String {
        switch stage {
        case .done: return "Your chats are here"
        case .working: return "Moving your chats"
        default: return startScanning ? "Receive your chats" : "Moving from another phone?"
        }
    }

    private var subtitle: String {
        switch stage {
        case .done(let n): return n == 1 ? "1 message moved." : "\(n.formatted()) messages moved."
        case .working(let n, let total): return "Receiving \(n) of \(total)"
        default:
            return "On your old phone, open Fariin, go to Settings > Chats > Transfer Chats and tap Show QR. Then scan the code here."
        }
    }

    @ViewBuilder private var buttons: some View {
        switch stage {
        case .working:
            ProgressView().frame(height: 52)
        case .done:
            primary("Continue") { onDone() }
        case .ask, .failed:
            primary(stage == .ask ? "Scan QR" : "Scan Again") { scanning = true }
            Button(startScanning ? "Close" : "Not Now") { onDone() }
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold)).foregroundStyle(Color.onFariinAction)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Capsule().fill(Color.fariinAction))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func receive(_ code: ChatTransfer.Code) {
        let me = uid
        stage = .working(0, code.files)
        work?.cancel()
        work = Task {
            do {
                let n = try await ChatTransfer.receive(code, uid: me) { done, total in
                    stage = .working(done, total)
                }
                Haptics.notify(.success)
                stage = .done(n)
            } catch is CancellationError {
                stage = .ask
            } catch {
                Haptics.notify(.error)
                stage = .failed(ChatTransfer.plain(error).errorDescription ?? "")
            }
        }
    }
}

// MARK: - The camera

/// Full-screen camera for the transfer code: a clear square in a dimmed screen, Cancel, and one line
/// of help. Only a transfer code is taken; anything else says so and the camera keeps looking.
struct TransferScanView: View {
    var onCode: (ChatTransfer.Code) -> Void
    var onCancel: () -> Void

    @State private var resetToken = 0
    @State private var wrongCode = false
    @State private var cameraDenied = false
    @State private var taken = false

    var body: some View {
        ZStack {
            QRScanner(onCode: { text in read(text) }, resetToken: resetToken).ignoresSafeArea()
            cutout.ignoresSafeArea()
            if cameraDenied { cameraOff }
            VStack {
                HStack {
                    Button("Cancel") { onCancel() }
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .liquidGlass(Capsule(), interactive: true)
                    Spacer()
                }
                Spacer()
                Text(wrongCode ? (ChatTransfer.Failure.notACode.errorDescription ?? "") : "Point at the code on your old phone")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .liquidGlass(Capsule())
                    .padding(.bottom, 40)
            }
            .padding()
        }
        .onAppear { checkCamera() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            checkCamera()
        }
    }

    private var cutout: some View {
        GeometryReader { geo in
            let side = min(geo.size.width * 0.78, geo.size.height * 0.45)
            ZStack {
                Color.black.opacity(0.5)
                    .mask {
                        Rectangle()
                            .overlay(alignment: .center) {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .frame(width: side, height: side)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(taken ? Color.green : Color.white, lineWidth: 3)
                    .frame(width: side, height: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    private var cameraOff: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
            Text("Camera access is off").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("Fariin needs the camera to scan the code. Turn it on in Settings.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            Button {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            } label: {
                Text("Open Settings").font(.body.weight(.semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 28).frame(height: 48)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private func checkCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: cameraDenied = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { cameraDenied = !ok; if ok { resetToken += 1 } }
            }
        default:
            if cameraDenied { resetToken += 1 }
            cameraDenied = false
        }
    }

    private func read(_ text: String) {
        guard !taken else { return }
        guard let code = ChatTransfer.Code.parse(text) else {
            wrongCode = true
            Haptics.notify(.error)
            // Again in a second, so a wrong code still in view is not read on every frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { resetToken += 1 }
            return
        }
        taken = true
        Haptics.notify(.success)
        onCode(code)
    }
}

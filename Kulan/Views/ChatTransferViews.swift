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

    /// Which phone the chats go to: only the instructions differ (the code works for both).
    enum Target: String { case android, iphone }
    @State private var target = Target.iphone
    @State private var begun = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if begun { steps } else { start }
                if let problem {
                    Text(problem).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Transfer Chats")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stopAll() }
        .fullScreenCover(isPresented: $receiving) {
            ChatReceiveView(startScanning: true) { receiving = false }
        }
    }

    // MARK: Start (owner 2026-11-12: a guided start, not a bare QR button)

    private var start: some View {
        VStack(spacing: 22) {
            phonesDrawing
            VStack(spacing: 8) {
                Text("Move chats to a new phone").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text("Which phone are you moving to?").font(.body).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                choice(.android, title: "Android", detail: "Samsung, Pixel and others", icon: "smartphone")
                choice(.iphone, title: "iPhone", detail: "Any iPhone", icon: "iphone")
            }
        }
    }

    private var phonesDrawing: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone").font(.system(size: 54, weight: .light))
            Image(systemName: "arrow.right").font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.fariinAction)
            Image(systemName: "iphone").font(.system(size: 54, weight: .light))
        }
        .foregroundStyle(.secondary)
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func choice(_ t: Target, title: String, detail: String, icon: String) -> some View {
        Button { target = t } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: target == t ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(target == t ? Color.fariinAction : Color.secondary)
            }
            .foregroundStyle(.primary)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(target == t ? Color.fariinAction : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: The three steps (old phone)

    private enum Mark { case waiting, working, done }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, "Getting your chats ready", mark: readyMark, detail: readyDetail)
            step(2, "Connect your new phone", mark: connectMark, detail: connectDetail)
            if case .showing(let code, let made) = stage {
                VStack(spacing: 10) {
                    qrCard(code)
                    Text("Works until \(made.addingTimeInterval(ChatTransfer.lifetime).formatted(date: .omitted, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.leading, 44).padding(.bottom, 16)
            }
            step(3, "Moving chats", mark: movingMark,
                 detail: stage == .done ? "Your chats are on your new phone." : nil)
            if stage == .expired {
                Text(ChatTransfer.Failure.expired.errorDescription ?? "")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private var readyMark: Mark {
        switch stage {
        case .preparing, .uploading: return .working
        case .idle: return .waiting
        default: return .done
        }
    }

    private var readyDetail: String? {
        if case .uploading(let n, let total) = stage, total > 0 {
            return "\(Int((Double(n) / Double(total) * 100).rounded()))%"
        }
        return nil
    }

    private var connectMark: Mark {
        switch stage {
        case .showing: return .working
        case .done: return .done
        default: return .waiting
        }
    }

    private var connectDetail: String? {
        guard case .showing = stage else { return nil }
        return target == .android
            ? "On your Android phone, install Fariin from Google Play and sign in. Then open Settings > Chats > Transfer Chats, tap This is my new phone and scan this code."
            : "On your new iPhone, install Fariin and sign in. Then open Settings > Chats > Transfer Chats, tap This is my new phone and scan this code."
    }

    private var movingMark: Mark {
        switch stage {
        case .done: return .done
        case .showing: return .working
        default: return .waiting
        }
    }

    private func step(_ n: Int, _ title: String, mark: Mark, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(mark == .done ? Color.fariinAction : Color(.tertiarySystemFill))
                switch mark {
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.onFariinAction)
                case .working:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Text("\(n)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                    .foregroundStyle(mark == .waiting ? Color.secondary : Color.primary)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 10) {
            if !begun {
                pill("Continue") { begun = true; showQR() }
                Button("This is my new phone") { receiving = true }
                    .font(.body.weight(.semibold)).foregroundStyle(Color.fariinAction)
                    .padding(.vertical, 6)
            } else if stage == .done {
                pill("Done") { begun = false; stage = .idle }
            } else if stage == .expired {
                pill("Show New Code") { showQR() }
                outlined("Cancel") { stopAll(); begun = false; stage = .idle }
            } else {
                outlined("Cancel") { stopAll(); begun = false; stage = .idle }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(Color(.systemBackground).opacity(0.001))
    }

    private func outlined(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity).frame(height: 50)
                .overlay(Capsule().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white))
        .frame(maxWidth: 260)
        .aspectRatio(1, contentMode: .fit)
        .environment(\.colorScheme, .light)
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

    // MARK: Work

    private func showQR() {
        problem = nil
        stopAll()
        stage = .preparing
        UIApplication.shared.isIdleTimerDisabled = true   // awake from the first step, not only the QR
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
                UIApplication.shared.isIdleTimerDisabled = false
                stage = .idle
            } catch {
                UIApplication.shared.isIdleTimerDisabled = false
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
        .onDisappear { work?.cancel(); UIApplication.shared.isIdleTimerDisabled = false }
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
        case .working(let n, let total):
            if n == 0 { return "Connected to your old phone" }
            return n >= total ? "Opening chats on this phone" : "Receiving chats"
        default: return startScanning ? "Receive your chats" : "Moving from another phone?"
        }
    }

    private var subtitle: String {
        switch stage {
        case .done(let n): return n == 1 ? "1 message moved." : "\(n.formatted()) messages moved."
        case .working(let n, let total):
            if n == 0 { return "Getting ready to receive your chats." }
            return n >= total ? "Almost done." : "\(n) of \(total) parts"
        default:
            return "On your old phone, open Fariin, go to Settings > Chats > Transfer Chats, choose this phone and tap Continue. Then scan the code here."
        }
    }

    @ViewBuilder private var buttons: some View {
        switch stage {
        case .working:
            ProgressView().frame(height: 52)
        case .done:
            primary("Done") { onDone() }
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
        UIApplication.shared.isIdleTimerDisabled = true   // a sleeping phone would pause the move
        work?.cancel()
        work = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
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

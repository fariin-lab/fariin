import SwiftUI
import UIKit
import AVFoundation
import CoreImage.CIFilterBuiltins

// Share-my-handle QR + a scanner — the main way two anonymous users connect in person.

// An https link, so a phone WITHOUT Fariin that scans this code still lands somewhere real
// instead of showing "Safari cannot open the page because the address is invalid". Camera.app
// reads it as a normal web link, and on a phone that does have the app, the Universal Link
// hands it straight over.
private func fariinLink(_ handle: String) -> String { KulanApp.userLink(handle: handle) }

private func qrImage(from string: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
}

// My QR code — others scan it to start a chat with me.
struct MyQRView: View {
    @Environment(\.dismiss) private var dismiss
    private var handle: String { ProfileStore.shared.me?.handle ?? "" }
    private var name: String { ProfileStore.shared.me?.name ?? "" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                if let img = qrImage(from: fariinLink(handle)) {
                    Image(uiImage: img)
                        .interpolation(.none).resizable().scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(20)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary))
                }
                VStack(spacing: 4) {
                    Text(name).font(.title3.weight(.semibold))
                    Text("@\(handle)").foregroundStyle(.secondary)
                }
                Text("Scan this code in Fariin to start a chat.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                ShareLink(item: fariinLink(handle)) {
                    Label("Share my link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 24)
            }
            .padding()
            .navigationTitle("My QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// Camera QR scanner → resolves a Fariin link to a user.
struct ScanQRView: View {
    var onUser: (UserProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var handling = false
    @State private var notFound = false
    @State private var scanReset = 0   // bump to re-arm the scanner after a failed resolve

    var body: some View {
        ZStack {
            QRScanner(onCode: { code in resolve(code) }, resetToken: scanReset).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            .padding(12).liquidGlass(Circle(), interactive: true)
                    }
                    Spacer()
                }
                Spacer()
                Text(notFound ? "No Fariin user found" : "Point at a Fariin QR code")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .liquidGlass(Capsule())
                    .padding(.bottom, 40)
            }
            .padding()
        }
    }

    private func resolve(_ code: String) {
        guard !handling else { return }
        // THE SAME PARSER THE APP OPENS LINKS WITH, deliberately. This used to test for
        // `scheme == "kulan"` by hand, and the moment the printed code above became an https
        // link that hand-written test would have rejected our own QR — the scanner refusing the
        // exact code it had just drawn. Sharing one parser makes that class of mismatch
        // impossible rather than merely unlikely. It also means codes printed or screenshotted
        // back when they were kulan:// still scan, because the parser still reads both.
        guard let url = URL(string: code),
              case .user(let handle)? = KulanApp.route(from: url) else {
            // Not a Fariin code: show feedback + re-arm — the scanner used to stay dead here.
            notFound = true
            rearmScanner()
            return
        }
        handling = true
        Task {
            if let user = await ChatService.findByHandle(handle) {
                await MainActor.run { onUser(user); dismiss() }
            } else {
                await MainActor.run { notFound = true; handling = false; rearmScanner() }
            }
        }
    }

    // Re-arm after a beat, so a bad code still in frame retries ~1/s instead of every camera frame.
    private func rearmScanner() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { scanReset += 1 }
    }
}

// AVFoundation QR camera (UIKit-backed).
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var resetToken: Int = 0   // caller bumps this to re-arm scanning after a failed resolve
    func makeUIViewController(context: Context) -> ScannerVC { let vc = ScannerVC(); vc.onCode = onCode; return vc }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {
        if vc.lastResetToken != resetToken { vc.lastResetToken = resetToken; vc.reset() }
    }

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var lastResetToken = 0
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resizeAspectFill
            p.frame = view.bounds
            view.layer.addSublayer(p)
            preview = p
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); session.stopRunning() }

        private var didFind = false   // fire once — not on every camera frame (was spamming findByHandle ~30fps)
        func reset() { didFind = false }   // re-arm after a failed resolve, or one bad scan kills the scanner
        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objs: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !didFind,
                  let obj = objs.first as? AVMetadataMachineReadableCodeObject, let s = obj.stringValue else { return }
            didFind = true
            onCode?(s)
        }
    }
}

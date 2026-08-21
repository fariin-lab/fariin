import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import CoreImage.CIFilterBuiltins

// Share-my-handle QR + a scanner — the main way two anonymous users connect in person.

// An https link, so a phone WITHOUT Fariin that scans this code still lands somewhere real
// instead of showing "Safari cannot open the page because the address is invalid". Camera.app
// reads it as a normal web link, and on a phone that does have the app, the Universal Link
// hands it straight over.
private func fariinLink(_ handle: String) -> String { KulanApp.userLink(handle: handle) }

/// CORRECTION LEVEL H, and it is not decoration.
///
/// The generator defaults to "M", which can lose about 15% of the code and still be read. The mark
/// sitting in the middle of the finished code covers roughly a fifth of it, so at M the code would
/// scan on a good day and fail on a bad one — the worst kind of broken, because it works while you
/// are testing it. H tolerates 30%, which is the room the mark actually takes.
private func qrImage(from string: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "H"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
}

/// Read a QR code out of a still image, for the "scan a picture" path.
///
/// A code that arrives as a screenshot is the common case, not the exotic one: somebody sends their
/// code in a chat, or on paper somebody photographs it, and there is no second phone to point a
/// camera at. `CIDetector` is the same machinery the camera path uses, pointed at one frame.
func qrString(in image: UIImage) -> String? {
    guard let cg = image.cgImage else { return nil }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                              context: CIContext(),
                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: CIImage(cgImage: cg)) as? [CIQRCodeFeature]
    // FIRST NON-EMPTY, not simply first. A photograph of a poster can hold several codes, and one of
    // them decoding to nothing must not be taken as "no code in this picture".
    return features?.compactMap({ $0.messageString }).first(where: { !$0.isEmpty })
}

// My QR code — others scan it to start a chat with me.
//
// ONE CARD, WITH A FACE ON IT. The code used to be a bare black square in a bordered white box with
// the name printed underneath, which is a correct QR code and nothing else: held up across a table
// it says nothing about whose it is until the other phone has already read it. The card now carries
// the photo, the name and the handle together, so the person scanning can see they are pointing at
// the right person before they point.
//
// AND IT CAN FLIP TO THE SCANNER. The two halves of the same job lived in different corners of the
// app — this screen in Settings, the camera inside New Chat — so meeting somebody meant one of you
// digging through a different menu. Either side can now become the other in one tap, which is what
// makes the whole thing work standing in a room with somebody.
struct MyQRView: View {
    /// Handed in when this screen was itself opened FROM the scanner. Then "Scan a code" just goes
    /// back rather than stacking a second camera on top of the first one.
    var onScan: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showScanner = false
    private var dark: Bool { scheme == .dark }
    private var me: UserProfile? { ProfileStore.shared.me }
    private var handle: String { me?.handle ?? "" }
    private var name: String { me?.name ?? "" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                card
                Text("Scan this code in Fariin to start a chat.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                ShareLink(item: fariinLink(handle)) {
                    // The app tints itself `.primary` (KulanApp), so `Color.accentColor` here is
                    // WHITE in dark mode and black in light. A hardcoded white label was therefore
                    // invisible on its own capsule every night, and correct every day, which is why
                    // it survived so long. `Theme.onAccent` is the inverse of that same colour.
                    Label("Share my link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(Theme.onAccent(dark))
                }
                .padding(.horizontal, 24)
                Button {
                    if let onScan { onScan() } else { showScanner = true }
                } label: {
                    Label("Scan a code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .padding(.horizontal, 24)
            }
            .padding()
            .navigationTitle("My QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $showScanner) {
                // `onMyCode: dismiss` on the scanner we open ourselves: its "My code" button comes
                // back HERE instead of presenting a second copy of this screen on top of this one.
                ScanQRView(onMyCode: { showScanner = false }) { user in
                    // ⚠️ ROUTE FIRST, THEN ONE DISMISS, and do NOT close the cover by hand on the
                    // way. `showScanner = false` followed by `dismiss()` is the trap
                    // BottomActionSheet.swift already carries a note about: acting on a presenter
                    // while the thing it presented is still animating away is how a dismiss gets
                    // swallowed, and here that would leave this screen sitting over the chat it
                    // just routed to. Dismissing this view takes its cover with it, so one call
                    // does both.
                    //
                    // The route is set before the dismiss because the shell consumes
                    // `pendingChatId` once the list is up; setting it after would race the
                    // teardown of the view still holding the closure.
                    //
                    // The same two steps New Chat takes: route to the conversation id, and create
                    // the conversation behind it in case these two have never spoken. Routing alone
                    // would open a chat whose document does not exist yet.
                    AppRouter.shared.pendingChatId = ChatService.convId(AuthService.shared.uid ?? "", user.id)
                    AppRouter.shared.pendingChatName = user.name.isEmpty ? user.handle : user.name
                    AppRouter.shared.pendingChatPhoto = user.photoUrl
                    Task { try? await ChatService.openConversation(other: user) }
                    dismiss()
                }
            }
        }
    }

    /// The photo sits ON the card's edge rather than inside it, which is what stops the card reading
    /// as a plain white box with a face pasted in the corner.
    private var card: some View {
        VStack(spacing: 0) {
            AvatarView(name: name, photoUrl: me?.photoUrl, size: 76)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 5))
                .zIndex(1)
                .offset(y: 38)
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(name).font(.title3.weight(.bold))
                    Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 46)
                qrBlock
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .padding(.horizontal, 8)
    }

    /// ALWAYS ON WHITE, in both themes. A QR code is read as dark-on-light and inverting it for dark
    /// mode is the classic way to make one that half the scanners in the world refuse.
    @ViewBuilder private var qrBlock: some View {
        if let img = qrImage(from: fariinLink(handle)) {
            Image(uiImage: img)
                .interpolation(.none).resizable().scaledToFit()
                .frame(width: 220, height: 220)
                .overlay {
                    // The mark, in the middle, on its own white disc so it never sits half on a
                    // black module. Sized against the 30% the H correction level buys us.
                    OfficialAvatar(size: 44)
                        .padding(5)
                        .background(.white, in: Circle())
                }
                .padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            // A handle that has not loaded yet. Reserve the space rather than let the card jump.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 256, height: 256)
                .overlay { ProgressView() }
        }
    }
}

// Camera QR scanner → resolves a Fariin link to a user.
//
// TWO THINGS BESIDES THE CAMERA, and both are about the times there is no code in front of the lens.
//
// A PICTURE. Codes arrive as screenshots at least as often as they arrive on tables: somebody sends
// theirs in a chat, or it is on a poster you photographed. With only a camera the answer was to find
// a second phone, put the code on that, and point this one at it.
//
// MY CODE. Meeting somebody in person needs both halves, and they lived in different corners of the
// app — the camera inside New Chat, the code in Settings — so one of you had to go hunting through a
// menu you were not already in. Either side turns into the other in one tap now.
struct ScanQRView: View {
    /// Provided when this scanner was opened FROM the code screen, so "My code" goes back instead of
    /// presenting a second copy of that screen over the top of the first.
    var onMyCode: (() -> Void)?
    var onUser: (UserProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var handling = false
    @State private var notFound = false
    @State private var scanReset = 0   // bump to re-arm the scanner after a failed resolve
    @State private var photoItem: PhotosPickerItem?
    @State private var showMyCode = false
    /// A picked photograph with no code in it. Separate from `notFound`, which means "a code, but
    /// nobody behind it" — telling somebody there is no Fariin user in a picture of their lunch
    /// answers a question they did not ask.
    @State private var noCodeInPhoto = false

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
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle").font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(12).liquidGlass(Circle(), interactive: true)
                    }
                }
                Spacer()
                Text(hint)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .liquidGlass(Capsule())
                Button {
                    if let onMyCode { onMyCode() } else { showMyCode = true }
                } label: {
                    Label("My code", systemImage: "qrcode")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .liquidGlass(Capsule(), interactive: true)
                }
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
            .padding()
        }
        .onChange(of: photoItem) { _, item in readPickedPhoto(item) }
        .sheet(isPresented: $showMyCode) {
            // `onScan: dismiss` for the same reason the code screen passes one to us: its "Scan a
            // code" button comes back to this camera rather than opening another one.
            MyQRView(onScan: { showMyCode = false })
        }
    }

    private var hint: String {
        if noCodeInPhoto { return "No QR code in that picture" }
        if notFound { return "No Fariin user found" }
        return "Point at a Fariin QR code"
    }

    /// The picked image goes through `resolve` — the same path a camera frame takes — so a photo and
    /// a live code cannot start behaving differently from each other.
    private func readPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        notFound = false
        noCodeInPhoto = false
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            guard let code = qrString(in: image) else {
                await MainActor.run { noCodeInPhoto = true; photoItem = nil }
                return
            }
            await MainActor.run {
                photoItem = nil
                // `handling` is the camera's one-at-a-time latch and a stale one would silently
                // swallow this. Clearing it is safe: a picked photo is a deliberate act, not a
                // frame arriving on its own.
                handling = false
                resolve(code)
            }
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
        noCodeInPhoto = false   // a code is in hand now, whatever it turns out to be
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

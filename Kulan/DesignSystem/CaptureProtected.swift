import SwiftUI
import UIKit

/// Keeps its content out of screenshots and screen recordings, as far as iOS allows.
///
/// ⛔ OWNER, 2026-09-30, about a one-time photo and a one-time voice note: "user can't download,
/// can't take screenshot, can't record". A message that may be seen once and can be photographed
/// off the screen has not been seen once.
///
/// TWO MECHANISMS, and only one of them is a promise:
///
///   1. SCREEN RECORDING AND MIRRORING: GUARANTEED. `UIScreen.isCaptured` is documented and it
///      changes before a recording carries frames. The content is hidden for as long as it is on.
///   2. A STILL SCREENSHOT: NOT GUARANTEED BY ANY PUBLIC API. There is no call that refuses one.
///      What exists is the system's own secure text field, whose canvas is left out of screenshots
///      and recordings, and a view placed inside that canvas inherits it. This is the same
///      mechanism the story viewer's `CaptureShield` uses (the reference app's, read from its
///      source), here with the canvas as a real view so buttons inside keep working.
///
/// ⚠️ WHEN UIKIT DOES NOT HAND OVER THE CANVAS, THE CONTENT IS SHOWN UNSHIELDED. The canvas is an
/// undocumented subview. Failing closed would mean a one-time photo that can never be seen at all
/// after a system update; failing open leaves the recording half, which is the documented one.
struct CaptureProtected<Content: View>: UIViewControllerRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> CaptureProtectedController<Content> {
        CaptureProtectedController(content: content)
    }

    func updateUIViewController(_ controller: CaptureProtectedController<Content>, context: Context) {
        controller.update(content)
    }
}

final class CaptureProtectedController<Content: View>: UIViewController {
    private let host: UIHostingController<Content>
    /// Kept alive for as long as the content is: the canvas is only secure while its field exists.
    private let field = UITextField()
    private var captureObserver: NSObjectProtocol?

    init(content: Content) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
    }

    func update(_ content: Content) {
        host.rootView = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        host.view.backgroundColor = .clear
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false

        addChild(host)
        if let canvas = SecureCanvas.of(field) {
            canvas.subviews.forEach { $0.removeFromSuperview() }
            canvas.isUserInteractionEnabled = true
            Self.pin(canvas, in: view)
            Self.pin(host.view, in: canvas)
        } else {
            Self.pin(host.view, in: view)
        }
        host.didMove(toParent: self)

        applyCapture()
        captureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyCapture()
        }
    }

    /// The guaranteed half: nothing is drawn while the screen is being recorded or mirrored.
    private func applyCapture() {
        host.view.isHidden = UIScreen.main.isCaptured
    }

    static func pin(_ child: UIView, in parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }
}

/// The secure text field's canvas, shared by `CaptureProtected` and the chat's message list
/// (Disable Sharing › No Screenshots). By its class name where that is recognisable, otherwise the
/// view behind the field's first layer, which is where `CaptureShield` finds the same canvas. The
/// field must be kept alive for as long as the canvas is in use.
enum SecureCanvas {
    static func of(_ field: UITextField) -> UIView? {
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        field.layoutIfNeeded()
        if let named = field.subviews.first(where: {
            String(describing: type(of: $0)).contains("CanvasView")
        }) {
            return named
        }
        return field.layer.sublayers?.first?.delegate as? UIView
    }
}

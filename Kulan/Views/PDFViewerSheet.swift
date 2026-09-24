import SwiftUI
import PDFKit

// Full PDF reader (PDFKit) with Liquid Glass chrome — opened when a received .pdf is tapped. Scrolls +
// pinch-zooms continuously; top bar = close · filename · share; a page indicator floats at the bottom.
struct PDFViewerSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var page = 1
    @State private var pageCount = 0
    @State private var showShare = false
    @State private var failed = false
    // 2026-09-24 fix-all #213: a password-protected PDF opened as a blank reader. PDFKit hands back a
    // LOCKED document whose pages draw nothing until it is unlocked, so the reader now asks.
    @State private var locked = false          // reported by PDFKitView while the file is still shut
    @State private var showUnlock = false
    @State private var passwordField = ""
    @State private var submittedPassword = ""  // what PDFKitView tries; cleared after a wrong one
    @State private var wrongPassword = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            PDFKitView(url: url, currentPage: $page, pageCount: $pageCount, failed: $failed,
                       locked: $locked, password: submittedPassword, wrongPassword: $wrongPassword)
                .ignoresSafeArea()
            if failed {
                Text("Couldn't open the file.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { if pageCount > 1 { pageBar } }
        .sheet(isPresented: $showShare) { ActivityView(items: [url]) }
        // 2026-09-24 fix-all #213: the unlock prompt, again after a wrong password.
        .onChange(of: locked) { _, isLocked in if isLocked { showUnlock = true } }
        .onChange(of: wrongPassword) { _, wrong in
            guard wrong else { return }
            submittedPassword = ""; passwordField = ""
            showUnlock = true
        }
        .alert("Password protected", isPresented: $showUnlock) {
            SecureField("Password", text: $passwordField)
            Button("Open") { wrongPassword = false; submittedPassword = passwordField }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text(wrongPassword ? "That password is not right." : "Enter the password to open this file.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(title)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                .padding(.horizontal, 16).frame(height: 40)
                .liquidGlass(Capsule(), interactive: false)
            Spacer(minLength: 8)
            Button { showShare = true } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var pageBar: some View {
        Text("\(page) of \(pageCount)")
            .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
            .padding(.horizontal, 16).frame(height: 34)
            .liquidGlass(Capsule(), interactive: false)
            .padding(.bottom, 10)
    }
}

// PDFKit PDFView wrapper: continuous vertical scroll, auto-scale, reports the current page.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var currentPage: Int
    @Binding var pageCount: Int
    @Binding var failed: Bool
    // 2026-09-24 fix-all #213: the locked-file handshake with PDFViewerSheet.
    @Binding var locked: Bool
    var password: String
    @Binding var wrongPassword: Bool

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        v.pageShadowsEnabled = false
        // A file named .pdf that PDFKit cannot read (damaged, cut short, not really a PDF) used to
        // leave a blank white reader with nothing to say why. Report it so the sheet can say so.
        let parsed = PDFDocument(url: url)
        if let doc = parsed, doc.isLocked {
            // 2026-09-24 fix-all #213: held back until `updateUIView` unlocks it with a password.
            context.coordinator.pending = doc
            DispatchQueue.main.async { locked = true }
        } else if let doc = parsed, doc.pageCount > 0 {
            v.document = doc
            DispatchQueue.main.async { pageCount = doc.pageCount }
        } else {
            DispatchQueue.main.async { failed = true }
        }
        context.coordinator.view = v
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: v)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        // 2026-09-24 fix-all #213: try each submitted password once. An empty one resets the
        // memory, so retyping the same password after a wrong answer is tried again.
        let c = context.coordinator
        guard let doc = c.pending else { return }
        if password.isEmpty { c.tried = ""; return }
        guard password != c.tried else { return }
        c.tried = password
        if doc.unlock(withPassword: password) {
            c.pending = nil
            v.document = doc
            DispatchQueue.main.async {
                locked = false
                if doc.pageCount > 0 { pageCount = doc.pageCount } else { failed = true }
            }
        } else {
            DispatchQueue.main.async { wrongPassword = true }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleUIView(_ v: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        let parent: PDFKitView
        weak var view: PDFView?
        var pending: PDFDocument?   // 2026-09-24 fix-all #213: a locked file waiting for its password
        var tried = ""              // 2026-09-24 fix-all #213: the password last tried on it
        init(_ p: PDFKitView) { parent = p }
        @objc func pageChanged() {
            guard let v = view, let cur = v.currentPage, let doc = v.document else { return }
            let idx = doc.index(for: cur) + 1
            if parent.currentPage != idx { parent.currentPage = idx }
        }
    }
}

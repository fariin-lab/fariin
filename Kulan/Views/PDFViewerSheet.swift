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

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            PDFKitView(url: url, currentPage: $page, pageCount: $pageCount)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { if pageCount > 1 { pageBar } }
        .sheet(isPresented: $showShare) { ActivityView(items: [url]) }
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

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        v.pageShadowsEnabled = false
        if let doc = PDFDocument(url: url) {
            v.document = doc
            DispatchQueue.main.async { pageCount = doc.pageCount }
        }
        context.coordinator.view = v
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: v)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleUIView(_ v: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        let parent: PDFKitView
        weak var view: PDFView?
        init(_ p: PDFKitView) { parent = p }
        @objc func pageChanged() {
            guard let v = view, let cur = v.currentPage, let doc = v.document else { return }
            let idx = doc.index(for: cur) + 1
            if parent.currentPage != idx { parent.currentPage = idx }
        }
    }
}

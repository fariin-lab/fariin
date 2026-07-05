import SwiftUI
import UIKit

// Telegram-style sheet engine (behaviour studied from Telegram-iOS's story viewers component and
// REIMPLEMENTED — never copied; Telegram's code is GPL). The core idea: the sheet is NOT driven by a
// custom drag gesture. ONE native UIScrollView owns both the sheet's position and the list's
// scrolling, so every drag inherits iOS's real scroll physics (momentum, deceleration, rubber-band)
// and there is exactly ONE input — gesture fights are structurally impossible.
//
// Layout: the scroll content is a column [transparent spacer, one screen tall][sheet card + rows].
//   contentOffset.y == 0          → sheet fully hidden below the screen (closed)
//   contentOffset.y == expansion  → sheet fully open (its top parked at screenH - expansion)
//   contentOffset.y  > expansion  → the surface keeps scrolling = the list scrolls (long lists)
// Touches over the spacer fall through to whatever is behind (story, carousel, backdrop drag).
//
// Snap rule on release (Telegram's half-point rule): iOS first projects the natural deceleration
// target; if that target lands short of half the expansion the sheet closes, past half it opens.
// Because the projection is UIKit's own, velocity handling is exactly native.
final class SheetSurfaceScrollView: UIScrollView {
    var passThroughHeight: CGFloat = 0   // content-space height of the transparent spacer
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Points inside the spacer belong to the layers behind the sheet (story / carousel).
        if point.y < passThroughHeight { return nil }
        return super.hitTest(point, with: event)
    }
}

struct TelegramSheetSurface<Content: View>: UIViewRepresentable {
    let expansion: CGFloat                 // E: how tall the open sheet is
    @Binding var progress: CGFloat         // 0 closed … 1 open; readable/writable by the host
    let onClosed: () -> Void               // surface settled at closed → unmount the sheet
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> SheetSurfaceScrollView {
        let scroll = SheetSurfaceScrollView()
        // Telegram's exact scroll configuration (studied from their component):
        scroll.canCancelContentTouches = true
        scroll.delaysContentTouches = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator

        let host = UIHostingController(rootView: AnyView(column()))
        host.view.backgroundColor = .clear
        scroll.addSubview(host.view)
        context.coordinator.host = host
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateUIView(_ scroll: SheetSurfaceScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.host?.rootView = AnyView(column())
        coordinator.layoutIfNeeded()

        // Push EXTERNAL progress writes (swipe-up open tracking, backdrop collapse drag, the
        // openViewers/closeViewers springs) into the offset — but never while the user's finger
        // owns the surface: the scroll view is the single source of truth during its own drags.
        if !scroll.isTracking && !scroll.isDecelerating {
            let desired = progress * expansion
            if abs(scroll.contentOffset.y - desired) > 0.5, scroll.contentOffset.y <= expansion + 0.5 {
                coordinator.isSyncing = true
                scroll.setContentOffset(CGPoint(x: 0, y: desired), animated: false)
                coordinator.isSyncing = false
            }
        }
    }

    private func column() -> some View {
        let screenH = UIScreen.main.bounds.height
        return VStack(spacing: 0) {
            Color.clear.frame(width: UIScreen.main.bounds.width, height: screenH)
                .allowsHitTesting(false)
            content()
                .frame(width: UIScreen.main.bounds.width, alignment: .top)
                .frame(minHeight: expansion, alignment: .top)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: TelegramSheetSurface
        var host: UIHostingController<AnyView>?
        weak var scroll: SheetSurfaceScrollView?
        var isSyncing = false

        init(_ parent: TelegramSheetSurface) { self.parent = parent }

        // Size the hosted column and the scroll metrics. Called from updateUIView (row count /
        // search filtering changes the content height).
        func layoutIfNeeded() {
            guard let scroll, let host else { return }
            let screen = UIScreen.main.bounds
            let target = CGSize(width: screen.width, height: .greatestFiniteMagnitude)
            var size = host.sizeThatFits(in: target)
            size.width = screen.width
            // The column = spacer(screenH) + sheet(≥ expansion).
            size.height = max(size.height, screen.height + parent.expansion)
            if host.view.frame.size != size {
                host.view.frame = CGRect(origin: .zero, size: size)
            }
            if scroll.contentSize != size { scroll.contentSize = size }
            if scroll.frame.size != screen.size { scroll.frame = CGRect(origin: .zero, size: screen.size) }
            scroll.passThroughHeight = screen.height
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isSyncing else { return }
            let p = max(0, min(1, scrollView.contentOffset.y / max(1, parent.expansion)))
            if abs(parent.progress - p) > 0.001 { parent.progress = p }
        }

        // Telegram's half-point snap: let UIKit project the deceleration target, then round it to
        // closed (0) or open (E) when it lands inside the expansion region. Past E the list scrolls
        // free with native deceleration.
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            let e = parent.expansion
            let t = targetContentOffset.pointee.y
            if t < e {
                targetContentOffset.pointee.y = t < e * 0.5 ? 0 : e
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // Telegram dismisses the keyboard the moment the surface starts moving.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { closeIfSettledClosed(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { closeIfSettledClosed(scrollView) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { closeIfSettledClosed(scrollView) }
        }

        private func closeIfSettledClosed(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.y <= 0.5 {
                parent.progress = 0
                parent.onClosed()
            }
        }
    }
}

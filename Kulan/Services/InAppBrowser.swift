import UIKit
import WebKit
import SafariServices

/// KULAN'S OWN BROWSER — owner, 2026-10-13: "whenever a user taps any link … open it inside Kulan's
/// own browser sheet", with the reference app's browsing behaviour.
///
/// What is the reference app's, verified in its source (BrowserUI, read 2026-10-13), not guessed:
/// - the page stays invisible until loading passes 10%, then fades in, so a sheet never opens onto
///   a white flash of half-drawn layout;
/// - edge swipes go back and forward through the page history;
/// - the controls FOLLOW THE FINGER: every point scrolled moves a 0-1 collapse fraction by that many
///   points over the top bar's height; near either end of the page the fraction is capped so the
///   controls come back before you reach it; when the finger lets go they snap to whichever side is
///   nearer the middle (0.25s ease), and a tap on the collapsed top opens them again (0.4s spring);
/// - only web addresses load in place; tel:, mailto:, maps and the like go to the system, FaceTime
///   is ignored outright (a page must not be able to start a call), and a page that asks for a new
///   window gets it in this one;
/// - alerts and confirms a page raises are shown natively, titled with the site.
///
/// ⛔ THE LOOK IS iOS 26 LIQUID GLASS WITH NO BARS AND NO LINES — owner 2026-10-13 (build 908, with
/// the reference's screen beside ours: "top header and bottom are using borders, make it exactly
/// like image 2"). The page fills the whole sheet. Floating over it: a glass circle (close), a glass
/// capsule with the address and the loading fill, a glass circle (menu); at the bottom one floating
/// glass capsule with back, forward, share, bookmark and open-in-Safari. The page is inset so its
/// top starts below the controls; scrolled, it runs under the glass.
///
/// ⚠️ PRIVACY. WebKit runs the page in its own process, so the page cannot read Kulan's memory. What
/// would open a door is a script bridge (`WKScriptMessageHandler`) or an injected user script: this
/// browser has NEITHER, and must keep it that way. The page has no way to call into the app.
final class InAppBrowserViewController: UIViewController {

    private let initialURL: URL
    private let webView: WKWebView

    // Top: close circle, address capsule, menu circle.
    private let closeGlass = InAppBrowserViewController.glass()
    private let addressGlass = InAppBrowserViewController.glass()
    private let menuGlass = InAppBrowserViewController.glass()
    private let closeButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let addressButton = UIButton(type: .system)
    private let hostLabel = UILabel()
    private let lockView = UIImageView()
    private let progressFill = UIView()

    // Bottom: one floating capsule.
    private let bottomGlass = InAppBrowserViewController.glass()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let bookmarkButton = UIButton(type: .system)
    private let safariButton = UIButton(type: .system)

    private let errorView = UIStackView()
    private let errorMessage = UILabel()

    private var observations: [NSKeyValueObservation] = []

    // Sizes. `expandedTop` is the distance that collapses the controls fully (the reference's top
    // bar height); `toolbarHeight` is the bottom capsule's.
    private let expandedTop: CGFloat = 58
    private let toolbarHeight: CGFloat = 50
    private let control: CGFloat = 44

    /// 0 = controls fully out, 1 = top shrunk to the address alone and the bottom capsule gone.
    private var collapse: CGFloat = 0
    private var lastOffsetToTop: CGFloat?
    private var ignoreScrollUntilStopped = false
    /// Whether the glass is currently drawn; it dematerialises past the middle of a collapse.
    private var glassShown = true

    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0]

    /// The app's interactive glass, as the composer's pill and lock use it.
    private static func glass() -> UIVisualEffectView {
        let g = UIGlassEffect(style: .regular)
        g.isInteractive = true
        let v = UIVisualEffectView(effect: g)
        v.cornerConfiguration = .capsule()
        return v
    }

    init(url: URL) {
        initialURL = url
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Sites decide what to serve by the user agent; this makes them treat us as mobile Safari.
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        sheetPresentationController?.detents = [.large()]

        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        webView.alpha = 0
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)

        buildTop()
        buildBottom()
        buildErrorView()

        // WebKit posts these on the main thread; `assumeIsolated` says so to the compiler.
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressChanged() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshButtons() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshButtons() } },
            // Stop mid-load leaves `estimatedProgress` where it was; this is what clears the fill then.
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshButtons(); self?.progressChanged() } },
        ]

        refreshTitle()
        refreshButtons()
        webView.load(URLRequest(url: initialURL))
    }

    private func symbol(_ name: String, _ size: CGFloat, _ weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    private func fill(_ glass: UIVisualEffectView, with button: UIButton) {
        button.frame = glass.contentView.bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(button)
    }

    private func buildTop() {
        closeButton.setImage(symbol("xmark", 17), for: .normal)
        closeButton.tintColor = .label
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        fill(closeGlass, with: closeButton)
        view.addSubview(closeGlass)

        menuButton.setImage(symbol("ellipsis", 17), for: .normal)
        menuButton.tintColor = .label
        menuButton.accessibilityLabel = "More"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menuItems() ?? [])
        }])
        fill(menuGlass, with: menuButton)
        view.addSubview(menuGlass)

        // The loading fill sweeps across the capsule behind the address, as the reference shows it.
        progressFill.backgroundColor = UIColor.label.withAlphaComponent(0.10)
        progressFill.alpha = 0
        addressGlass.contentView.addSubview(progressFill)
        hostLabel.font = .systemFont(ofSize: 17, weight: .regular)
        hostLabel.textColor = .label
        hostLabel.textAlignment = .center
        hostLabel.lineBreakMode = .byTruncatingMiddle
        lockView.contentMode = .scaleAspectFit
        lockView.tintColor = .secondaryLabel
        lockView.image = symbol("lock.fill", 11)
        // The capsule is a button so a tap on it always brings the controls back.
        addressButton.addAction(UIAction { [weak self] _ in self?.expandBars() }, for: .touchUpInside)
        addressButton.accessibilityLabel = "Address"
        fill(addressGlass, with: addressButton)
        addressGlass.contentView.addSubview(lockView)
        addressGlass.contentView.addSubview(hostLabel)
        view.addSubview(addressGlass)
    }

    private func buildBottom() {
        func setUp(_ b: UIButton, _ name: String, _ label: String, _ action: @escaping () -> Void) {
            b.setImage(symbol(name, 19, .regular), for: .normal)
            b.tintColor = .label
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            bottomGlass.contentView.addSubview(b)
        }
        setUp(backButton, "chevron.backward", "Back") { [weak self] in self?.webView.goBack() }
        setUp(forwardButton, "chevron.forward", "Forward") { [weak self] in self?.webView.goForward() }
        setUp(shareButton, "square.and.arrow.up", "Share") { [weak self] in self?.share() }
        setUp(bookmarkButton, "bookmark", "Add to Reading List") { [weak self] in self?.addToReadingList() }
        setUp(safariButton, "safari", "Open in Safari") { [weak self] in
            guard let self else { return }
            // Leaving is allowed, but only when asked for by name.
            UIApplication.shared.open(self.webView.url ?? self.initialURL)
        }
        view.addSubview(bottomGlass)

        // Holding Back or Forward lists the pages in that direction, as the reference does.
        backButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.historyItems(back: true) ?? [])
        }])
        forwardButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.historyItems(back: false) ?? [])
        }])
    }

    private func buildErrorView() {
        errorView.axis = .vertical
        errorView.alignment = .center
        errorView.spacing = 10
        errorView.isHidden = true

        let icon = UIImageView(image: symbol("wifi.exclamationmark", 38, .regular))
        icon.tintColor = .tertiaryLabel
        let title = UILabel()
        title.text = "Can't open this page"
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        errorMessage.font = .systemFont(ofSize: 15)
        errorMessage.textColor = .secondaryLabel
        errorMessage.numberOfLines = 0
        errorMessage.textAlignment = .center
        var retry = UIButton.Configuration.glass()
        retry.title = "Try Again"
        let retryButton = UIButton(configuration: retry)
        retryButton.addAction(UIAction { [weak self] _ in self?.reload() }, for: .touchUpInside)

        [icon, title, errorMessage, retryButton].forEach(errorView.addArrangedSubview)
        errorView.setCustomSpacing(18, after: errorMessage)
        view.insertSubview(errorView, aboveSubview: webView)
    }

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutBars()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    private var topPad: CGFloat { view.safeAreaInsets.top + 10 }
    private var bottomPad: CGFloat { max(view.safeAreaInsets.bottom, 12) + 4 }

    /// Every frame here is a straight blend of the expanded and collapsed layouts by `collapse`, so
    /// the controls track the finger point for point and any animation of `collapse` animates them all.
    private func layoutBars() {
        let w = view.bounds.width, h = view.bounds.height
        let safe = view.safeAreaInsets
        let f = collapse

        // The page fills the sheet and is inset so its top and bottom clear the floating glass.
        webView.frame = view.bounds
        let inset = UIEdgeInsets(top: topPad + control + 8, left: 0, bottom: bottomPad + toolbarHeight + 8, right: 0)
        let sv = webView.scrollView
        if sv.contentInset != inset {
            let atTop = sv.contentOffset.y <= -sv.contentInset.top + 1
            sv.contentInset = inset
            sv.verticalScrollIndicatorInsets = inset
            if atTop { sv.contentOffset.y = -inset.top }
        }

        // TOP. Collapsing lifts the row a little; the two circles shrink and fade, the capsule
        // shrinks less and keeps its address, which is all a collapsed top shows.
        let side: CGFloat = 16
        let centerY = topPad + control / 2 - 10 * f
        let circleScale = 1 - 0.35 * f
        closeGlass.bounds = CGRect(x: 0, y: 0, width: control, height: control)
        closeGlass.center = CGPoint(x: side + safe.left + control / 2, y: centerY)
        menuGlass.bounds = closeGlass.bounds
        menuGlass.center = CGPoint(x: w - side - safe.right - control / 2, y: centerY)
        for (g, b) in [(closeGlass, closeButton), (menuGlass, menuButton)] {
            g.transform = CGAffineTransform(scaleX: circleScale, y: circleScale)
            b.alpha = 1 - f
            g.isUserInteractionEnabled = f < 0.5
        }

        let addressX = closeGlass.center.x + control / 2 + 14
        let addressW = max(0, menuGlass.center.x - control / 2 - 14 - addressX)
        addressGlass.bounds = CGRect(x: 0, y: 0, width: addressW, height: control)
        addressGlass.center = CGPoint(x: addressX + addressW / 2, y: centerY)
        let pillScale = 1 - 0.25 * f
        addressGlass.transform = CGAffineTransform(scaleX: pillScale, y: pillScale)

        let lockW: CGFloat = lockView.isHidden ? 0 : 11, gap: CGFloat = lockView.isHidden ? 0 : 5
        let textMax = max(0, addressW - 32 - lockW - gap)
        let textW = min(hostLabel.sizeThatFits(CGSize(width: textMax, height: control)).width, textMax)
        let rowX = (addressW - (lockW + gap + textW)) / 2
        lockView.frame = CGRect(x: rowX, y: (control - lockW) / 2, width: lockW, height: lockW)
        hostLabel.frame = CGRect(x: rowX + lockW + gap, y: 0, width: textW, height: control)
        progressFill.frame = CGRect(x: 0, y: 0, width: addressW * CGFloat(webView.estimatedProgress), height: control)

        // BOTTOM. One capsule, slid off the bottom edge as the fraction grows.
        let bottomW = min(w - 96, 360)
        let travel = toolbarHeight + bottomPad + 20
        bottomGlass.frame = CGRect(x: (w - bottomW) / 2, y: h - bottomPad - toolbarHeight + travel * f,
                                   width: bottomW, height: toolbarHeight)
        let buttons = [backButton, forwardButton, shareButton, bookmarkButton, safariButton]
        let slot = (bottomW - 16) / CGFloat(buttons.count)
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: 8 + slot * CGFloat(i), y: 0, width: slot, height: toolbarHeight)
        }

        // Past the middle the glass itself dematerialises (iOS 26 animates an effect change), so a
        // collapsed top is the address alone over the page.
        let wantGlass = f < 0.5
        if wantGlass != glassShown {
            glassShown = wantGlass
            UIView.animate(withDuration: 0.25) {
                for g in [self.closeGlass, self.menuGlass, self.addressGlass] {
                    g.effect = wantGlass ? Self.glassEffect() : nil
                }
            }
        }

        let errorWidth = min(w - 64, 340)
        errorMessage.preferredMaxLayoutWidth = errorWidth   // or a long message stays one clipped line
        let errorSize = errorView.systemLayoutSizeFitting(CGSize(width: errorWidth, height: .greatestFiniteMagnitude),
                                                          withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        errorView.frame = CGRect(x: (w - errorWidth) / 2, y: h / 2 - errorSize.height / 2 - 20, width: errorWidth, height: errorSize.height)
    }

    private static func glassEffect() -> UIGlassEffect {
        let g = UIGlassEffect(style: .regular)
        g.isInteractive = true
        return g
    }

    private func setCollapse(_ value: CGFloat, animation: BarAnimation) {
        guard value != collapse else { return }
        collapse = value
        switch animation {
        case .none:
            layoutBars()
        case .snap:
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) { self.layoutBars() }
        case .spring:
            UIView.animate(springDuration: 0.4, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.layoutBars() }
        }
    }

    private enum BarAnimation { case none, snap, spring }

    private func expandBars() {
        guard collapse > 0 else { return }
        if webView.scrollView.isDecelerating { ignoreScrollUntilStopped = true }
        lastOffsetToTop = nil
        setCollapse(0, animation: .spring)
    }

    // MARK: - State

    private func progressChanged() {
        let p = webView.estimatedProgress
        // Hidden until the page has something to show, then faded in.
        if p >= 0.1, webView.alpha == 0, errorView.isHidden {
            UIView.animate(withDuration: 0.2) { self.webView.alpha = 1 }
        }
        if webView.isLoading && p < 1 {
            progressFill.alpha = 1
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.layoutBars() }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.layoutBars() }
            UIView.animate(withDuration: 0.25, delay: 0.2, options: [.beginFromCurrentState]) { self.progressFill.alpha = 0 }
        }
    }

    private func refreshTitle() {
        let url = webView.url ?? initialURL
        let host = Self.displayHost(url)
        let secure = url.scheme?.lowercased() == "https" && webView.hasOnlySecureContent
        hostLabel.text = url.scheme?.lowercased() == "http" ? "Not Secure · " + host : host
        lockView.isHidden = !secure
        addressButton.accessibilityValue = webView.title
        view.setNeedsLayout()
    }

    private func refreshButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        shareButton.isEnabled = webView.url != nil
        bookmarkButton.isEnabled = webView.url != nil
    }

    private static func displayHost(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func reload() {
        hideError()
        if webView.url != nil { webView.reload() } else { webView.load(URLRequest(url: initialURL)) }
    }

    private func showError(_ error: Error) {
        errorMessage.text = error.localizedDescription
        errorView.isHidden = false
        webView.alpha = 0
        view.setNeedsLayout()
    }

    private func hideError() {
        errorView.isHidden = true
    }

    // MARK: - Menus and actions

    private func menuItems() -> [UIMenuElement] {
        let url = webView.url ?? initialURL
        let loading = webView.isLoading
        let reload = UIAction(title: loading ? "Stop Loading" : "Reload", image: UIImage(systemName: loading ? "xmark" : "arrow.clockwise")) { [weak self] _ in
            guard let self else { return }
            if self.webView.isLoading { self.webView.stopLoading() } else { self.reload() }
        }
        let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
            UIPasteboard.general.url = url
        }
        let find = UIAction(title: "Find on Page", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
            self?.webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }

        let zoom = webView.pageZoom
        let steps = Self.zoomSteps
        let smaller = UIAction(title: "Smaller", image: UIImage(systemName: "textformat.size.smaller"),
                               attributes: zoom <= steps.first! ? .disabled : []) { [weak self] _ in self?.stepZoom(-1) }
        let larger = UIAction(title: "Larger", image: UIImage(systemName: "textformat.size.larger"),
                              attributes: zoom >= steps.last! ? .disabled : []) { [weak self] _ in self?.stepZoom(1) }
        let reset = UIAction(title: "Actual Size (\(Int((zoom * 100).rounded()))%)", image: UIImage(systemName: "textformat.size"),
                             attributes: zoom == 1 ? .disabled : []) { [weak self] _ in self?.webView.pageZoom = 1 }
        let textSize = UIMenu(title: "Text Size", image: UIImage(systemName: "textformat.size"), children: [smaller, larger, reset])

        return [
            UIMenu(options: .displayInline, children: [reload, copy]),
            UIMenu(options: .displayInline, children: [find, textSize]),
        ]
    }

    private func stepZoom(_ direction: Int) {
        let steps = Self.zoomSteps
        let current = webView.pageZoom
        let next = direction > 0 ? steps.first(where: { $0 > current + 0.001 }) : steps.last(where: { $0 < current - 0.001 })
        if let next { webView.pageZoom = next }
    }

    private func historyItems(back: Bool) -> [UIMenuElement] {
        let list: [WKBackForwardListItem] = back ? Array(webView.backForwardList.backList.reversed()) : webView.backForwardList.forwardList
        return list.prefix(15).map { item in
            let title = item.title?.isEmpty == false ? item.title! : Self.displayHost(item.url)
            return UIAction(title: title, subtitle: Self.displayHost(item.url)) { [weak self] _ in self?.webView.go(to: item) }
        }
    }

    private func share() {
        guard let url = webView.url else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        present(sheet, animated: true)
    }

    /// The bookmark button: the page goes into the system Reading List (Safari's), which needs no
    /// list of our own. The icon fills to say it worked.
    private func addToReadingList() {
        guard let url = webView.url, SSReadingList.supportsURL(url) else { return }
        do {
            try SSReadingList.default()?.addItem(with: url, title: webView.title, previewText: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            bookmarkButton.setImage(symbol("bookmark.fill", 19, .regular), for: .normal)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.bookmarkButton.setImage(self.symbol("bookmark", 19, .regular), for: .normal)
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: - Leaving the browser for another app

    /// Hands a non-web address to the system: a phone number to the dialer, mail to Mail, our own
    /// `kulan://` back to the app (after closing the sheet, so the destination is not hidden under it).
    private func openOutside(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "kulan" {
            dismiss(animated: true) { UIApplication.shared.open(url) }
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// Same exclusions as `WebLink.useSheet`: App Store and Apple Maps pages belong to their apps.
    private static func belongsToAnApp(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "apps.apple.com" || host == "itunes.apple.com" || host == "maps.apple.com"
    }
}

// MARK: - Scrolling: the bars follow the finger

extension InAppBrowserViewController: UIScrollViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCollapse(scrollView, settling: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            ignoreScrollUntilStopped = false
            updateCollapse(scrollView, settling: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        ignoreScrollUntilStopped = false
        updateCollapse(scrollView, settling: true)
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        expandBars()
        return true
    }

    /// The reference app's rule, in our terms: the fraction moves by the scrolled distance over the
    /// top bar's height; within one bar-height of either end of the page it is capped so the bars
    /// are back by the time you arrive; off the finger it settles at 0 or 1.
    /// `settling` comes from the end-of-drag callbacks, where the scroll view may still report itself
    /// dragging or decelerating; the snap must happen there regardless.
    private func updateCollapse(_ scrollView: UIScrollView, settling: Bool) {
        guard !ignoreScrollUntilStopped else { return }
        let toTop = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        let toBottom = max(0, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.maxY)
        // Recorded BEFORE the bars move: resizing the page can scroll it again from inside
        // `setCollapse`, and that nested call must not count this same distance a second time.
        guard let last = lastOffsetToTop else { lastOffsetToTop = toTop; return }
        lastOffsetToTop = toTop

        var f = max(0, min(1, collapse + (toTop - last) / expandedTop))
        if toBottom < toolbarHeight {
            f = min(f, toBottom / toolbarHeight)
        } else if toTop < expandedTop {
            f = min(f, toTop / expandedTop)
        }
        let interacting = !settling && (scrollView.isDragging || scrollView.isDecelerating)
        if !interacting { f = f < 0.5 ? 0 : 1 }
        setCollapse(f, animation: interacting ? .none : .snap)
    }
}

// MARK: - Navigation

extension InAppBrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if mainFrame && Self.belongsToAnApp(url) && navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        // A page must not be able to start a call on its own.
        if scheme == "facetime" || scheme == "facetime-audio" { return }
        openOutside(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType || !navigationResponse.isForMainFrame {
            return decisionHandler(.allow)
        }
        // A file the page cannot show (a zip, an installer). Say so, and offer Safari, which can save it.
        decisionHandler(.cancel)
        let url = navigationResponse.response.url
        let name = navigationResponse.response.suggestedFilename ?? "This file"
        let alert = UIAlertController(title: "Can't Show This File", message: "\(name) can't be opened here.", preferredStyle: .alert)
        if let url {
            alert.addAction(UIAlertAction(title: "Open in Safari", style: .default) { _ in UIApplication.shared.open(url) })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        hideError()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideError()
        // A new page starts with the bars out, as the reference does.
        lastOffsetToTop = nil
        setCollapse(0, animation: .spring)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    private func handleFailure(_ error: Error) {
        let ns = error as NSError
        // Cancelled: a newer navigation replaced this one, or one we cancelled ourselves above.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        // WebKit's "frame load interrupted" is the same thing for a policy cancel.
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        guard ns.domain == NSURLErrorDomain else { return }
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process was killed (memory); reload rather than leave a blank sheet.
        webView.reload()
    }
}

// MARK: - Windows and dialogs the page asks for

extension InAppBrowserViewController: WKUIDelegate {

    /// `target="_blank"` and `window.open`: the reference opens these in the browser too, never
    /// outside. We load them in this same view, so Back returns to the page that opened it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                webView.load(navigationAction.request)
            } else if scheme != "facetime" && scheme != "facetime-audio" {
                openOutside(url)
            }
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        dismiss(animated: true)
    }

    private func siteTitle(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page" : host
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return completionHandler() }
        let alert = UIAlertController(title: siteTitle(frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return completionHandler(false) }
        let alert = UIAlertController(title: siteTitle(frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return completionHandler(nil) }
        let alert = UIAlertController(title: siteTitle(frame), message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        present(alert, animated: true)
    }
}

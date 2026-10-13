import UIKit
import WebKit

/// KULAN'S OWN BROWSER — owner, 2026-10-13: "whenever a user taps any link … open it inside Kulan's
/// own browser sheet", with the reference app's browsing behaviour and a simpler look of our own.
///
/// What is the reference app's, verified in its source (BrowserUI, read 2026-10-13), not guessed:
/// - the page stays invisible until loading passes 10%, then fades in, so a sheet never opens onto
///   a white flash of half-drawn layout;
/// - edge swipes go back and forward through the page history;
/// - the bars FOLLOW THE FINGER: every point scrolled moves a 0-1 collapse fraction by that many
///   points over the top bar's height; near either end of the page the fraction is capped so the bars
///   come back before you reach it; when the finger lets go they snap to whichever side is nearer
///   the middle (0.25s ease), and a tap on the collapsed bar opens them again (0.4s spring);
/// - only web addresses load in place; tel:, mailto:, maps and the like go to the system, FaceTime
///   is ignored outright (a page must not be able to start a call), and a page that asks for a new
///   window gets it in this one;
/// - alerts and confirms a page raises are shown natively, titled with the site.
///
/// What is ours: the layout. Title and address sit left-aligned in a plain bar with the two
/// controls at the right, and back / forward / reload / share live in a full-width bottom bar, not
/// a floating pill.
///
/// ⚠️ PRIVACY. WebKit runs the page in its own process, so the page cannot read Kulan's memory. What
/// would open a door is a script bridge (`WKScriptMessageHandler`) or an injected user script: this
/// browser has NEITHER, and must keep it that way. The page has no way to call into the app.
final class InAppBrowserViewController: UIViewController {

    private let initialURL: URL
    private let webView: WKWebView

    private let topBar = UIView()
    private let topSeparator = UIView()
    private let titleLabel = UILabel()
    private let hostLabel = UILabel()
    private let lockView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let progressView = UIView()

    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let bottomSeparator = UIView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    private let errorView = UIStackView()
    private let errorMessage = UILabel()

    private var observations: [NSKeyValueObservation] = []

    // Bar sizes. The reference collapses its top bar to a slim strip and slides the toolbar away.
    private let expandedTop: CGFloat = 58
    private let collapsedTop: CGFloat = 26
    private let toolbarHeight: CGFloat = 49

    /// 0 = bars fully out, 1 = top bar slim and toolbar gone.
    private var collapse: CGFloat = 0
    private var lastOffsetToTop: CGFloat?
    private var ignoreScrollUntilStopped = false

    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0]

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

        buildTopBar()
        buildBottomBar()
        buildErrorView()

        // WebKit posts these on the main thread; `assumeIsolated` says so to the compiler.
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.progressChanged() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshTitle() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshButtons() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshButtons() } },
            // Stop mid-load leaves `estimatedProgress` where it was; this is what clears the line then.
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshButtons(); self?.progressChanged() } },
        ]

        refreshTitle()
        refreshButtons()
        webView.load(URLRequest(url: initialURL))
    }

    private func buildTopBar() {
        topBar.backgroundColor = .systemBackground
        view.addSubview(topBar)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        topBar.addSubview(titleLabel)

        hostLabel.font = .systemFont(ofSize: 13)
        hostLabel.textColor = .secondaryLabel
        hostLabel.lineBreakMode = .byTruncatingMiddle
        topBar.addSubview(hostLabel)

        lockView.contentMode = .scaleAspectFit
        lockView.tintColor = .secondaryLabel
        topBar.addSubview(lockView)

        var close = UIButton.Configuration.glass()
        close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        close.baseForegroundColor = .label
        closeButton.configuration = close
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        topBar.addSubview(closeButton)

        var more = UIButton.Configuration.glass()
        more.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        more.baseForegroundColor = .label
        menuButton.configuration = more
        menuButton.accessibilityLabel = "More"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menuItems() ?? [])
        }])
        topBar.addSubview(menuButton)

        progressView.backgroundColor = view.tintColor
        progressView.alpha = 0
        topBar.addSubview(progressView)

        topSeparator.backgroundColor = .separator
        topBar.addSubview(topSeparator)

        // The collapsed bar is the way back to the full one.
        topBar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(topBarTapped)))
    }

    private func buildBottomBar() {
        view.addSubview(bottomBar)
        bottomSeparator.backgroundColor = .separator
        bottomBar.contentView.addSubview(bottomSeparator)

        func setUp(_ b: UIButton, _ symbol: String, _ label: String, _ action: @escaping () -> Void) {
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
            c.baseForegroundColor = .label
            b.configuration = c
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            bottomBar.contentView.addSubview(b)
        }
        setUp(backButton, "chevron.backward", "Back") { [weak self] in self?.webView.goBack() }
        setUp(forwardButton, "chevron.forward", "Forward") { [weak self] in self?.webView.goForward() }
        setUp(reloadButton, "arrow.clockwise", "Reload") { [weak self] in
            guard let self else { return }
            if self.webView.isLoading { self.webView.stopLoading() } else { self.reload() }
        }
        setUp(shareButton, "square.and.arrow.up", "Share") { [weak self] in self?.share() }

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

        let icon = UIImageView(image: UIImage(systemName: "wifi.exclamationmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 38, weight: .regular)))
        icon.tintColor = .tertiaryLabel
        let title = UILabel()
        title.text = "Can't open this page"
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        errorMessage.font = .systemFont(ofSize: 15)
        errorMessage.textColor = .secondaryLabel
        errorMessage.numberOfLines = 0
        errorMessage.textAlignment = .center
        var retry = UIButton.Configuration.filled()
        retry.title = "Try Again"
        retry.cornerStyle = .capsule
        let retryButton = UIButton(configuration: retry)
        retryButton.addAction(UIAction { [weak self] _ in self?.reload() }, for: .touchUpInside)

        [icon, title, errorMessage, retryButton].forEach(errorView.addArrangedSubview)
        errorView.setCustomSpacing(18, after: errorMessage)
        view.addSubview(errorView)
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

    /// Every frame here is a straight blend of the expanded and collapsed layouts by `collapse`, so
    /// the bars track the finger point for point and any animation of `collapse` animates them all.
    private func layoutBars() {
        let w = view.bounds.width, h = view.bounds.height
        let safe = view.safeAreaInsets
        let f = collapse
        let side: CGFloat = 16 + safe.left

        let barHeight = expandedTop * (1 - f) + collapsedTop * f
        topBar.frame = CGRect(x: 0, y: 0, width: w, height: safe.top + barHeight)
        topSeparator.frame = CGRect(x: 0, y: topBar.bounds.height - 1 / traitCollection.displayScale, width: w, height: 1 / traitCollection.displayScale)
        topSeparator.alpha = 1 - f

        // The two controls shrink and fade as the bar slims; they are gone at 1.
        let button: CGFloat = 38
        let midY = safe.top + barHeight / 2
        closeButton.bounds = CGRect(x: 0, y: 0, width: button, height: button)
        closeButton.center = CGPoint(x: w - 16 - safe.right - button / 2, y: midY)
        menuButton.bounds = closeButton.bounds
        menuButton.center = CGPoint(x: closeButton.center.x - button - 8, y: midY)
        for b in [closeButton, menuButton] {
            let s = 1 - 0.35 * f
            b.transform = CGAffineTransform(scaleX: s, y: s)
            b.alpha = 1 - f
            b.isUserInteractionEnabled = f < 0.5
        }

        // Expanded: title over a lock + address line, left-aligned. Collapsed: the address alone,
        // small and centred, which is all a slim bar has room for.
        let textRight = menuButton.center.x - button / 2 - 12
        let textWidth = max(0, textRight - side)
        let titleH = titleLabel.font.lineHeight
        titleLabel.frame = CGRect(x: side, y: safe.top + expandedTop / 2 - titleH - 1 - f * expandedTop / 2, width: textWidth, height: titleH)
        titleLabel.alpha = max(0, 1 - f * 2)

        let lockSize: CGFloat = lockView.isHidden ? 0 : 11
        let lockGap: CGFloat = lockView.isHidden ? 0 : 4
        let hostFit = hostLabel.sizeThatFits(CGSize(width: textWidth, height: 20))
        let hostW = max(0, min(hostFit.width, textWidth - lockSize - lockGap))
        let hostH = hostLabel.font.lineHeight
        let expandedRow = CGRect(x: side, y: safe.top + expandedTop / 2 + 2, width: lockSize + lockGap + hostW, height: hostH)
        let collapsedRow = CGRect(x: (w - (lockSize + lockGap + hostW)) / 2, y: safe.top + (collapsedTop - hostH) / 2, width: expandedRow.width, height: hostH)
        let row = CGRect(x: expandedRow.minX + (collapsedRow.minX - expandedRow.minX) * f,
                         y: expandedRow.minY + (collapsedRow.minY - expandedRow.minY) * f,
                         width: expandedRow.width, height: hostH)
        lockView.frame = CGRect(x: row.minX, y: row.midY - lockSize / 2, width: lockSize, height: lockSize)
        hostLabel.frame = CGRect(x: row.minX + lockSize + lockGap, y: row.minY, width: hostW, height: hostH)

        // Loading line along the bottom edge of the top bar.
        let progress = CGFloat(webView.estimatedProgress)
        progressView.frame = CGRect(x: 0, y: topBar.bounds.height - 2.5, width: w * progress, height: 2.5)

        // The toolbar slides down by its own height times the fraction.
        let bottomFull = toolbarHeight + safe.bottom
        bottomBar.frame = CGRect(x: 0, y: h - bottomFull + bottomFull * f, width: w, height: bottomFull)
        bottomSeparator.frame = CGRect(x: 0, y: 0, width: w, height: 1 / traitCollection.displayScale)
        let buttons = [backButton, forwardButton, reloadButton, shareButton]
        let slot = (w - safe.left - safe.right - 24) / CGFloat(buttons.count)
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: safe.left + 12 + slot * CGFloat(i), y: 0, width: slot, height: toolbarHeight)
        }

        // The page fills what the bars leave.
        let webTop = topBar.frame.maxY
        let webBottom = h - bottomFull * (1 - f)
        webView.frame = CGRect(x: 0, y: webTop, width: w, height: max(0, webBottom - webTop))

        let errorWidth = min(w - 64, 340)
        errorMessage.preferredMaxLayoutWidth = errorWidth   // or a long message stays one clipped line
        let errorSize = errorView.systemLayoutSizeFitting(CGSize(width: errorWidth, height: .greatestFiniteMagnitude),
                                                          withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        errorView.frame = CGRect(x: (w - errorWidth) / 2, y: webView.frame.midY - errorSize.height / 2 - 20, width: errorWidth, height: errorSize.height)
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

    @objc private func topBarTapped() {
        guard collapse > 0 else { return }
        expandBars()
    }

    private func expandBars() {
        if webView.scrollView.isDecelerating { ignoreScrollUntilStopped = true }
        lastOffsetToTop = nil
        setCollapse(0, animation: .spring)
    }

    // MARK: - State

    private func progressChanged() {
        let p = webView.estimatedProgress
        // Hidden until the page has something to show, then faded in.
        if p >= 0.1, webView.alpha == 0 {
            UIView.animate(withDuration: 0.2) { self.webView.alpha = 1 }
        }
        if webView.isLoading && p < 1 {
            progressView.alpha = 1
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.layoutBars() }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.layoutBars() }
            UIView.animate(withDuration: 0.25, delay: 0.2, options: [.beginFromCurrentState]) { self.progressView.alpha = 0 }
        }
    }

    private func refreshTitle() {
        let url = webView.url ?? initialURL
        let host = Self.displayHost(url)
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titleLabel.text = title.isEmpty ? host : title
        let secure = url.scheme?.lowercased() == "https" && webView.hasOnlySecureContent
        if url.scheme?.lowercased() == "http" {
            hostLabel.text = "Not Secure · " + host
            lockView.isHidden = true
        } else {
            hostLabel.text = host
            lockView.isHidden = !secure
            lockView.image = UIImage(systemName: "lock.fill")
        }
        view.setNeedsLayout()
    }

    private func refreshButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        reloadButton.configuration?.image = UIImage(systemName: webView.isLoading ? "xmark" : "arrow.clockwise",
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        reloadButton.accessibilityLabel = webView.isLoading ? "Stop" : "Reload"
        shareButton.isEnabled = webView.url != nil
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
        let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() }
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

        // Leaving is allowed, but only when asked for by name.
        let safari = UIAction(title: "Open in Safari", image: UIImage(systemName: "safari")) { _ in
            UIApplication.shared.open(url)
        }
        return [
            UIMenu(options: .displayInline, children: [reload, copy, share]),
            UIMenu(options: .displayInline, children: [find, textSize]),
            UIMenu(options: .displayInline, children: [safari]),
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

import SwiftUI
import FirebaseFunctions

// ⛔ THE REPORT SHEET (owner 2026-11-08): every "Report" in the app opens this one sheet. A reason
// from a fixed list, its sub-reason, a confirm page, then a thanks page with the follow-up actions.
// The contract (shared with Android) is Documents/fariin-plans/report-contract.md; the server side
// is the `reportContent` callable (functions-groups). Our own words, never the reference app's.

/// What is being reported. The raw value is the contract's `kind`.
enum ReportKind: String {
    case user, message, story, channel, group, post, reply

    /// The word in "Why are you reporting this …?".
    var noun: String { self == .user ? "account" : rawValue }
    /// A person stands behind it, so Block is offered.
    var hasPerson: Bool { [.user, .story, .message, .reply].contains(self) }
}

struct ReportSub: Identifiable, Hashable {
    let id: String
    let title: String
    /// Sent instead of the parent's category (nudity › "under 18" goes in as child_safety).
    var category: String? = nil
}

struct ReportReason: Identifiable, Hashable {
    let id: String          // the contract's `category`
    let title: String
    var subTitle: String = ""
    var subs: [ReportSub] = []

    static let all: [ReportReason] = [
        ReportReason(id: "nudity", title: "Nudity or sexual content", subTitle: "What kind of sexual content?", subs: [
            .init(id: "nudity", title: "Nudity or sexual activity"),
            .init(id: "sexual_messages", title: "Sexual messages or requests"),
            .init(id: "intimate_images", title: "Sharing private images of someone"),
            .init(id: "involves_minor", title: "It involves someone under 18", category: "child_safety"),
        ]),
        ReportReason(id: "child_safety", title: "Child safety", subTitle: "What's happening?", subs: [
            .init(id: "abuse_material", title: "Sexual images or video of a child"),
            .init(id: "grooming", title: "An adult contacting a child in a sexual way"),
            .init(id: "child_harm", title: "A child being hurt or in danger"),
            .init(id: "child_bullying", title: "A child being bullied"),
        ]),
        ReportReason(id: "hate", title: "Hate speech or symbols", subTitle: "Who is being attacked?", subs: [
            .init(id: "race", title: "Race or ethnicity"),
            .init(id: "religion", title: "Religion"),
            .init(id: "gender_orientation", title: "Gender or sexual orientation"),
            .init(id: "disability", title: "Disability"),
            .init(id: "symbols", title: "Hateful symbols"),
        ]),
        ReportReason(id: "scam", title: "Scam or fraud", subTitle: "What kind of scam?", subs: [
            .init(id: "money_offer", title: "Fake investment or money offer"),
            .init(id: "asking_money", title: "Asking for money or gift cards"),
            .init(id: "phishing", title: "Trying to steal accounts or passwords"),
            .init(id: "fake_seller", title: "Fake shop or seller"),
        ]),
        ReportReason(id: "violence", title: "Violence or dangerous groups", subTitle: "What's the problem?", subs: [
            .init(id: "threat", title: "A threat to hurt someone"),
            .init(id: "extremism", title: "Terrorism or extremist group"),
            .init(id: "graphic", title: "Graphic violence"),
            .init(id: "incitement", title: "Calling for violence"),
        ]),
        ReportReason(id: "illegal_goods", title: "Selling illegal or restricted items", subTitle: "What is being sold?", subs: [
            .init(id: "drugs", title: "Drugs"),
            .init(id: "weapons", title: "Weapons"),
            .init(id: "animals", title: "Animals"),
            .init(id: "other_goods", title: "Something else"),
        ]),
        ReportReason(id: "bullying", title: "Bullying or harassment", subTitle: "Who is being bullied?", subs: [
            .init(id: "me", title: "Me"),
            .init(id: "someone_i_know", title: "Someone I know"),
            .init(id: "someone_else", title: "Someone else"),
            .init(id: "private_info", title: "Sharing someone's private information"),
        ]),
        ReportReason(id: "impersonation", title: "Pretending to be someone else", subTitle: "Who are they pretending to be?", subs: [
            .init(id: "me", title: "Me"),
            .init(id: "someone_i_know", title: "Someone I know"),
            .init(id: "public_figure", title: "A celebrity or public figure"),
            .init(id: "business", title: "A business or organization"),
        ]),
        ReportReason(id: "ip", title: "Copyright or trademark", subTitle: "What is being copied?", subs: [
            .init(id: "copyright", title: "My photos, music or other work"),
            .init(id: "trademark", title: "My brand name or logo"),
        ]),
        ReportReason(id: "self_harm", title: "Suicide or self-harm", subTitle: "What are you seeing?", subs: [
            .init(id: "suicide", title: "Suicide or self-injury"),
            .init(id: "eating_disorder", title: "Eating disorder"),
        ]),
        ReportReason(id: "spam", title: "Spam"),
        ReportReason(id: "other", title: "Something else"),
    ]

    static func find(_ id: String) -> ReportReason? { all.first { $0.id == id } }

    /// "Reason › Sub-reason" for a stored category/sub pair ("My reports"). involves_minor is filed
    /// under child_safety but was picked under nudity, and reads the same either way.
    static func label(category: String, sub: String) -> String {
        guard let r = find(category) else { return "Reported" }
        if sub == "involves_minor" { return "Child safety › It involves someone under 18" }
        guard !sub.isEmpty, let s = r.subs.first(where: { $0.id == sub }) else { return r.title }
        return "\(r.title) › \(s.title)"
    }
}

/// Everything one Report button knows about what it reports, plus the follow-up actions its screen
/// can offer. The actions use the screen's own existing helpers (block, leave, mute).
struct ReportTarget: Identifiable {
    let id = UUID()
    var kind: ReportKind
    /// The contract's `id`: a uid (user), story id (story), reply id (reply). Chats use `cid`/`mid`.
    var targetId: String = ""
    var cid: String = ""
    var mid: String = ""
    var aid: String = ""
    /// Who Block would block (empty: no Block offered).
    var personUid: String = ""
    /// The name in "… won't know it was you" and in "Block <name>". Empty reads "They".
    var name: String = ""
    /// Kind `message` only (a group message): the words the reporter may choose to share.
    var messageText: String? = nil
    /// The chat Mute would mute (1:1 or group). nil: no Mute offered.
    var muteCid: String? = nil
    /// "Leave <name>" on the thanks page, for a channel/group I am in. The caller's own leave.
    var leaveTitle: String? = nil
    var onLeave: (() -> Void)? = nil
    /// After a successful Block (the sheet blocks through BlockList), so the screen can update.
    var onBlocked: (() -> Void)? = nil
    /// Opened from a Block dialog's "Block and Report": the person is already blocked, so the
    /// Block toggle is ON and hidden, and the report records `block: true`.
    var preBlocked: Bool = false
    /// After the report has been filed.
    var onReported: (() -> Void)? = nil
}

enum ReportService {
    private static var fn: Functions { Functions.functions(region: "me-central1") }

    /// One report through `reportContent`. The server keeps the daily count itself (contract v2.1 #2:
    /// no app-side counter bump on this path). Throws the server's own message on refusal.
    static func submit(_ t: ReportTarget, category: String, sub: String?, note: String,
                       block: Bool, shareText: Bool) async throws {
        var data: [String: Any] = ["kind": t.kind.rawValue, "category": category, "block": block,
                                   "platform": "ios"]
        // Which build sent it, for the admin panel: "1.4 (57)".
        let info = Bundle.main.infoDictionary
        if let v = info?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            let b = info?["CFBundleVersion"] as? String ?? ""
            data["appVersion"] = String((b.isEmpty ? v : "\(v) (\(b))").prefix(40))
        }
        if let sub, !sub.isEmpty { data["sub"] = sub }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { data["note"] = String(n.prefix(500)) }
        if !t.targetId.isEmpty { data["id"] = t.targetId }
        if !t.cid.isEmpty { data["cid"] = t.cid }
        if !t.mid.isEmpty { data["mid"] = t.mid }
        if !t.aid.isEmpty { data["aid"] = t.aid }
        if t.kind == .reply, !t.targetId.isEmpty { data["rid"] = t.targetId }
        if !t.personUid.isEmpty { data["uid"] = t.personUid }
        if t.kind == .message, shareText, let words = t.messageText, !words.isEmpty {
            data["messageText"] = String(words.prefix(1000))
        }
        _ = try await fn.httpsCallable("reportContent").call(data)
    }
}

struct ReportSheet: View {
    let target: ReportTarget
    @Environment(\.dismiss) private var dismiss

    private enum Page: Hashable {
        case reasons
        case subs(String)                 // a category's sub-reasons
        case confirm(String, String?)     // category, sub
        case done(String, String?)
    }

    /// The pages walked so far; the last one is on screen. Never empty.
    @State private var stack: [Page] = [.reasons]
    /// Which way the next page change slides: forward = the new page comes in from the trailing edge.
    @State private var forward = true
    @State private var note = ""
    @State private var block = false
    @State private var shareText = true
    @State private var sending = false
    @State private var failure: String?
    @State private var blockedNow = false
    @State private var blockBusy = false
    @State private var mutedNow = false
    @State private var left = false
    /// Each page's natural height (its rows and padding, no header), by page.
    @State private var fits: [Page: CGFloat] = [:]
    /// The sheet's height inside its safe area, as last laid out.
    @State private var shownHeight: CGFloat = 0
    @State private var safeBottom: CGFloat = 0
    /// Points the system keeps back from our detent height (see calibrate()). Normally 0.
    @State private var slack: CGFloat = 0
    @State private var calibration: Task<Void, Never>?
    @FocusState private var noteFocused: Bool
    @Environment(\.displayScale) private var displayScale

    /// The rows' fill on the solid sheet: light grey in light mode, dark grey in dark.
    private static let rowFill = Color(.secondarySystemBackground)
    /// ⛔ ONE MOTION (owner 2026-11-08: "move like the reference app"). The page slide and the
    /// sheet's height change run in the same spring, so the sheet grows or shrinks while the page
    /// moves, never after it. The reference sheet uses one ~0.45 s spring for both.
    private static let motion = Animation.spring(response: 0.42, dampingFraction: 0.9)
    /// Our own header: 12 top, the 44 pt round button, 8 under it.
    private static let headerHeight: CGFloat = 64
    private static let groupRadius: CGFloat = 22

    private var page: Page { stack.last ?? .reasons }
    private var isDone: Bool { if case .done = page { return true }; return false }
    private var showsBack: Bool { stack.count > 1 && !isDone }
    private var cap: CGFloat { UIScreen.main.bounds.height * 0.92 }

    /// The most a page may take before it scrolls: the cap, or with the keyboard up (the note on
    /// "Something else", sheet large) whatever is left above it.
    private var bodyCap: CGFloat {
        if noteFocused, shownHeight > 0 { return max(shownHeight - Self.headerHeight, 120) }
        return cap - Self.headerHeight
    }

    /// ⛔ THE SHEET FITS ITS PAGE (owner 2026-11-08: empty band of 60-90 pt under the last row, and
    /// a blank, clipped bottom while the height changed). The old List pages counted their bars and
    /// the bottom safe area into the height, and the system then added the safe area again: that was
    /// the band. Now a page is a plain VStack whose height is exact; the detent is header + page,
    /// and the system adds the home-indicator area under it.
    private var sheetHeight: CGFloat? {
        fits[page].map { min(Self.headerHeight + $0 + slack, cap) }
    }

    private var detents: Set<PresentationDetent> {
        guard let h = sheetHeight else { return [.fraction(0.82)] }
        return noteFocused ? [.height(h), .large] : [.height(h)]
    }

    /// Large while typing the note; the page's own height otherwise. Dragging down from large
    /// closes the keyboard.
    private var detentChoice: Binding<PresentationDetent> {
        Binding(
            get: {
                guard let h = sheetHeight else { return .fraction(0.82) }
                return noteFocused ? .large : .height(h)
            },
            set: { new in if new != .large, noteFocused { noteFocused = false } }
        )
    }

    private var shownName: String { target.name.isEmpty ? "They" : target.name }
    private var canBlock: Bool {
        target.kind.hasPerson && !target.personUid.isEmpty && target.personUid != ChatService.uid
    }
    private var alreadyBlocked: Bool { target.preBlocked || BlockList.shared.contains(target.personUid) }

    var body: some View {
        VStack(spacing: 0) {
            header
            // ⛔ NO NAVIGATIONSTACK (owner 2026-11-08: the height change clipped the list and left
            // the bottom blank, then snapped). One container, the page on screen inside it, pages
            // swapped with a push slide. Pages keep their own height and sit at the top, so while
            // the sheet's frame animates nothing is re-laid out to the new size: a shrinking sheet
            // slides over the old page instead of cutting it off.
            ZStack(alignment: .top) {
                pageView(page)
                    .id(page)
                    .zIndex(Double(stack.count))
                    .transition(forward ? Self.pushTransition : Self.popTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Swipe from the leading edge goes back, like a pushed screen.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { v in
                    if v.startLocation.x < 40, v.translation.width > 70,
                       abs(v.translation.height) < abs(v.translation.width) { back() }
                },
                including: showsBack ? .all : .subviews
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            shownHeight = h
            calibrate()
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
        .presentationDetents(detents, selection: detentChoice)
        .presentationDragIndicator(.visible)
        // ⛔ SOLID, NOT GLASS (owner 2026-11-08: "white in light mode, black in dark, now it looks
        // like a mirror"). The system sheet is see-through glass on iOS 26; this one is the plain
        // background, its rows one step off it.
        .presentationBackground(Color(.systemBackground))
        .interactiveDismissDisabled(sending)
    }

    // MARK: Moving between pages

    /// Forward: the new page slides in over the old one from the trailing edge; the old one drifts
    /// a little to the leading side and fades. Back is the same in reverse.
    private static let pushTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing),
        removal: .offset(x: -90).combined(with: .opacity))
    private static let popTransition = AnyTransition.asymmetric(
        insertion: .offset(x: -90).combined(with: .opacity),
        removal: .move(edge: .trailing))

    /// A view that leaves uses the transition it was last drawn with, so a change of direction is
    /// drawn first and the page change runs on the next turn of the main loop.
    private func go(forward fwd: Bool, _ change: @escaping () -> Void) {
        noteFocused = false
        if forward != fwd {
            forward = fwd
            DispatchQueue.main.async { withAnimation(Self.motion) { change() } }
        } else {
            withAnimation(Self.motion) { change() }
        }
    }

    private func push(_ p: Page) {
        guard !sending, page != p else { return }
        go(forward: true) { stack.append(p) }
    }

    private func back() {
        guard showsBack, !sending else { return }
        go(forward: false) { if stack.count > 1 { stack.removeLast() } }
    }

    /// A page measured itself. The page on screen moves the sheet in the same spring as the slide
    /// (its first measure lands one frame after the push, inside the slide).
    private func setFit(_ p: Page, _ h: CGFloat) {
        guard h > 0, abs((fits[p] ?? 0) - h) > 0.5 else { return }
        if p == page { withAnimation(Self.motion) { fits[p] = h } } else { fits[p] = h }
    }

    /// The system is meant to put the home-indicator area UNDER a `.height` detent. If a build of
    /// iOS counts it inside instead, the page would come out short by that much; after the sheet
    /// settles, the laid-out height is compared with header + page and the difference is added.
    private func calibrate() {
        calibration?.cancel()
        calibration = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, !noteFocused, let fit = fits[page] else { return }
            guard Self.headerHeight + fit + slack < cap else { return }
            let gap = (Self.headerHeight + fit) - shownHeight
            if gap > 1, gap < 60 {
                withAnimation(Self.motion) { slack += gap }
            } else if gap < -1, slack > 0 {
                withAnimation(Self.motion) { slack = max(0, slack + gap) }
            }
        }
    }

    // MARK: Header and page frame

    /// ⛔ AN X ON THE FIRST PAGE (owner 2026-11-08: "add x button"); a back chevron on the pages
    /// after it; X again on the thanks page. "Report" centred. Drawn by us, it stays put while the
    /// pages slide under it.
    private var header: some View {
        ZStack {
            Text("Report").font(.headline)
            HStack {
                Button {
                    if showsBack { back() } else { dismiss() }
                } label: {
                    Image(systemName: showsBack ? "chevron.backward" : "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .background(Self.rowFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsBack ? "Back" : "Close")
                .disabled(sending)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: Self.headerHeight)
    }

    /// One page: its content at its natural height, scrolling only when that is over the cap.
    private func pageView(_ p: Page) -> some View {
        ScrollView {
            pageContent(p)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                // The last row rests just above the home indicator (the system adds that area
                // under the detent); a phone without one gets a normal margin.
                .padding(.bottom, safeBottom > 0 ? 8 : 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { setFit(p, $0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .frame(height: fits[p].map { min($0, bodyCap) })
        .background(Color(.systemBackground))
    }

    @ViewBuilder private func pageContent(_ p: Page) -> some View {
        switch p {
        case .reasons: reasonsPage
        case .subs(let cat): subsPage(cat)
        case .confirm(let cat, let sub): confirmPage(cat, sub)
        case .done(let cat, let sub): donePage(cat, sub)
        }
    }

    // MARK: Grouped rows (our own, so a page's height is exact)

    private func heading(_ title: String, _ subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    private func group<C: View>(@ViewBuilder _ rows: () -> C) -> some View {
        VStack(spacing: 0) { rows() }
            .background(Self.rowFill)
            .clipShape(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
    }

    private func separator(inset: CGFloat = 16) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1 / displayScale)
            .padding(.leading, inset)
    }

    private func footnote(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.footnote).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 6)
    }

    /// Rows that each open the next page, chevron on the trailing side.
    private func navRows<T: Identifiable>(_ items: [T], title: @escaping (T) -> String,
                                          tap: @escaping (T) -> Void) -> some View {
        group {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { tap(item) } label: {
                    HStack(spacing: 8) {
                        Text(title(item))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ReportRowStyle())
                if i < items.count - 1 { separator() }
            }
        }
    }

    // MARK: Page 1, the reasons

    private var reasonsPage: some View {
        VStack(spacing: 0) {
            heading("Why are you reporting this \(target.kind.noun)?",
                    "Reports are private. \(shownName) won't know it was you.")
            navRows(ReportReason.all, title: { $0.title }) { r in
                push(r.subs.isEmpty ? .confirm(r.id, nil) : .subs(r.id))
            }
        }
    }

    // MARK: Page 1b, the sub-reasons

    private func subsPage(_ cat: String) -> some View {
        let r = ReportReason.find(cat)
        return VStack(spacing: 0) {
            heading(r?.subTitle ?? "")
            navRows(r?.subs ?? [], title: { $0.title }) { s in push(.confirm(cat, s.id)) }
        }
    }

    // MARK: Page 2, confirm

    /// What goes to the server: involves_minor under nudity is filed as child_safety.
    private func sent(_ cat: String, _ sub: String?) -> String {
        guard let sub, let s = ReportReason.find(cat)?.subs.first(where: { $0.id == sub }) else { return cat }
        return s.category ?? cat
    }

    private func reasonLine(_ cat: String, _ sub: String?) -> String {
        guard let r = ReportReason.find(cat) else { return "" }
        guard let sub, let s = r.subs.first(where: { $0.id == sub }) else { return r.title }
        return "\(r.title) › \(s.title)"
    }

    private func confirmPage(_ cat: String, _ sub: String?) -> some View {
        VStack(spacing: 0) {
            heading("Report this \(target.kind.noun)?")
            group {
                Text(reasonLine(cat, sub))
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            if cat == "other" {
                group {
                    TextField("Tell us what's wrong", text: $note, axis: .vertical)
                        .lineLimit(4...8)
                        .focused($noteFocused)
                        .onChange(of: note) { _, v in if v.count > 500 { note = String(v.prefix(500)) } }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .padding(.top, 20)
                HStack {
                    Spacer()
                    Text("\(note.count)/500").monospacedDigit()
                }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 6)
            }
            if target.kind == .message, let words = target.messageText, !words.isEmpty {
                group {
                    Toggle("Share this message with Fariin's review team", isOn: $shareText).tint(.green)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .padding(.top, 20)
                footnote("Only this one message is shared. Your chat stays private.")
            }
            if canBlock, !alreadyBlocked {
                group {
                    Toggle("Block \(shownName)", isOn: $block).tint(.green)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .padding(.top, 20)
            }
            Button { submit(cat, sub) } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(.white) }
                    Text("Submit report").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sending)
            .padding(.top, 24)
            if let failure { footnote(failure, color: .red) }
        }
    }

    private func submit(_ cat: String, _ sub: String?) {
        guard !sending else { return }
        sending = true
        failure = nil
        let wantsBlock = block && canBlock && !alreadyBlocked
        let category = sent(cat, sub)
        Task { @MainActor in
            do {
                try await ReportService.submit(target, category: category, sub: sub,
                                               note: cat == "other" ? note : "", block: wantsBlock || target.preBlocked,
                                               shareText: shareText)
                if wantsBlock { await doBlock() }
                sending = false
                target.onReported?()
                push(.done(category, sub))
            } catch {
                sending = false
                failure = Self.words(error)
            }
        }
    }

    /// The existing block path (BlockList), then the screen's own update.
    @MainActor private func doBlock() async {
        let ok = await BlockList.shared.setBlocked(target.personUid, true)
        if ok { blockedNow = true; target.onBlocked?() } else { failure = "Couldn't block. Try again." }
    }

    private static func words(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: e.code) {
            switch code {
            case .resourceExhausted, .permissionDenied, .failedPrecondition, .invalidArgument:
                return e.localizedDescription
            default: break
            }
        }
        return "Couldn't send the report. Check your connection and try again."
    }

    // MARK: Page 3, thanks

    private func donePage(_ cat: String, _ sub: String?) -> some View {
        let showBlock = canBlock && (!alreadyBlocked || blockedNow)
        let showLeave = target.leaveTitle != nil && target.onLeave != nil
        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(.green)
                Text("Thanks for letting us know").font(.title3.weight(.semibold))
                Text("We'll review it. If it breaks our rules, we'll take it down. You can see what happened in Settings > Privacy > My reports.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            if let box = safetyNote(cat, sub) {
                group {
                    Label { Text(box).font(.subheadline) } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .padding(.top, 20)
            }
            if hasActions {
                group {
                    if showBlock {
                        Button {
                            guard !blockedNow, !blockBusy else { return }
                            blockBusy = true
                            Task { @MainActor in await doBlock(); blockBusy = false }
                        } label: {
                            actionRow(blockedNow ? "Blocked" : "Block \(shownName)", "hand.raised", red: true)
                        }
                        .buttonStyle(ReportRowStyle())
                        .disabled(blockedNow || blockBusy)
                    }
                    if let title = target.leaveTitle, target.onLeave != nil {
                        if showBlock { separator(inset: 56) }
                        Button {
                            left = true
                            dismiss()
                            // After the sheet is gone: a leave closes the screen under it.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { target.onLeave?() }
                        } label: { actionRow(title, "rectangle.portrait.and.arrow.right", red: true) }
                        .buttonStyle(ReportRowStyle())
                        .disabled(left)
                    }
                    if let m = target.muteCid {
                        if showBlock || showLeave { separator(inset: 56) }
                        Button {
                            mutedNow = true
                            Task { await ChatService.setMuted(m, true) }
                        } label: { actionRow(mutedNow ? "Muted" : "Mute \(shownName)", "bell.slash", red: false) }
                        .buttonStyle(ReportRowStyle())
                        .disabled(mutedNow)
                    }
                }
                .padding(.top, 20)
            }
            Button { dismiss() } label: {
                Text("Done").font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
        }
    }

    private var hasActions: Bool {
        (canBlock && (!alreadyBlocked || blockedNow)) || (target.leaveTitle != nil && target.onLeave != nil) || target.muteCid != nil
    }

    private func actionRow(_ title: String, _ icon: String, red: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 26)
            Text(title)
            Spacer()
        }
        .foregroundStyle(red ? Color.red : Color.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private func safetyNote(_ cat: String, _ sub: String?) -> String? {
        switch cat {
        case "child_safety": return "If a child is in danger right now, call your local emergency number."
        case "self_harm": return "If someone may hurt themselves, contact your local emergency number or a crisis line near you. You're not alone."
        case "violence" where sub == "threat": return "If anyone is in danger right now, call your local emergency number."
        default: return nil
        }
    }
}

/// `.sheet(item:)` for the report sheet, as a modifier for view chains already near the
/// type-checker's limit (the story viewer).
struct ReportSheetHost: ViewModifier {
    @Binding var target: ReportTarget?
    func body(content: Content) -> some View {
        content.sheet(item: $target) { ReportSheet(target: $0) }
    }
}

/// The menu icon every Report entry uses (owner 2026-11-08: one outline icon, not a flag).
enum ReportIcon {
    static let symbol = "exclamationmark.bubble"
}

/// A row of the Report sheet: the group's own fill, a grey wash while pressed.
private struct ReportRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemGray4) : Color.clear)
    }
}

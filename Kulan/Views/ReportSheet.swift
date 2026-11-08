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
        var data: [String: Any] = ["kind": t.kind.rawValue, "category": category, "block": block]
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
        case subs(String)                 // a category's sub-reasons
        case confirm(String, String?)     // category, sub
        case done(String, String?)
    }

    @State private var path: [Page] = []
    @State private var note = ""
    @State private var block = false
    @State private var shareText = true
    @State private var sending = false
    @State private var failure: String?
    @State private var blockedNow = false
    @State private var blockBusy = false
    @State private var mutedNow = false
    @State private var left = false
    /// Each page's measured height, by its depth in the stack (0 = the reasons).
    @State private var fits: [Int: CGFloat] = [:]
    /// The rows' fill on the solid sheet: light grey in light mode, dark grey in dark.
    private static let rowFill = Color(.secondarySystemBackground)

    /// ⛔ THE SHEET FITS ITS PAGE (owner 2026-11-08: the sexual-content page sat in a big sheet with
    /// an empty white half under four rows). It was a fixed 82% for every page. Now each page's
    /// list reports its own height (content + bars) and the sheet takes that, up to the large one.
    private var fitHeight: CGFloat? {
        fits[path.count].map { min($0 + 8, UIScreen.main.bounds.height * 0.92) }
    }

    private func depth(_ page: Page) -> Int { (path.firstIndex(of: page) ?? path.count - 1) + 1 }

    private var shownName: String { target.name.isEmpty ? "They" : target.name }
    private var canBlock: Bool {
        target.kind.hasPerson && !target.personUid.isEmpty && target.personUid != ChatService.uid
    }
    private var alreadyBlocked: Bool { target.preBlocked || BlockList.shared.contains(target.personUid) }

    var body: some View {
        NavigationStack(path: $path) {
            reasonsPage
                .modifier(ReportPageFit(depth: 0, fits: $fits))
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .subs(let cat): subsPage(cat).modifier(ReportPageFit(depth: depth(page), fits: $fits))
                    case .confirm(let cat, let sub): confirmPage(cat, sub).modifier(ReportPageFit(depth: depth(page), fits: $fits))
                    case .done(let cat, let sub): donePage(cat, sub).modifier(ReportPageFit(depth: depth(page), fits: $fits))
                    }
                }
        }
        // The first page has an X (owner 2026-11-08); the grabber closes it too.
        .presentationDetents(fitHeight.map { [.height($0), .large] } ?? [.fraction(0.82), .large])
        .animation(.snappy(duration: 0.25), value: fitHeight)
        .presentationDragIndicator(.visible)
        // ⛔ SOLID, NOT GLASS (owner 2026-11-08: "white in light mode, black in dark, now it looks
        // like a mirror"). The system sheet is see-through glass on iOS 26; this one is the plain
        // background, its rows one step off it.
        .presentationBackground(Color(.systemBackground))
        .interactiveDismissDisabled(sending)
    }

    // MARK: Page 1, the reasons

    private var reasonsPage: some View {
        List {
            Group {
            Section {
                ForEach(ReportReason.all) { r in
                    NavigationLink(value: r.subs.isEmpty ? Page.confirm(r.id, nil) : Page.subs(r.id)) {
                        Text(r.title)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why are you reporting this \(target.kind.noun)?")
                        .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text("Reports are private. \(shownName) won't know it was you.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
            }
            .listRowBackground(Self.rowFill)   // rows a step off the sheet (a row's own clear wins)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        // ⛔ AN X ON THE FIRST PAGE (owner 2026-11-08: "add x button"). Overrides the earlier
        // grabber-only rule for this sheet; the pages after it keep their back button.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
                    .disabled(sending)
            }
        }
    }

    // MARK: Page 1b, the sub-reasons

    private func subsPage(_ cat: String) -> some View {
        let r = ReportReason.find(cat)
        return List {
            Group {
            Section {
                ForEach(r?.subs ?? []) { s in
                    NavigationLink(value: Page.confirm(cat, s.id)) { Text(s.title) }
                }
            } header: {
                Text(r?.subTitle ?? "")
                    .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .textCase(nil).padding(.bottom, 8)
            }
            }
            .listRowBackground(Self.rowFill)   // rows a step off the sheet (a row's own clear wins)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
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
        List {
            Group {
            Section {
                Text(reasonLine(cat, sub))
            } header: {
                Text("Report this \(target.kind.noun)?")
                    .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .textCase(nil).padding(.bottom, 8)
            }
            if cat == "other" {
                Section {
                    TextField("Tell us what's wrong", text: $note, axis: .vertical)
                        .lineLimit(4...8)
                        .onChange(of: note) { _, v in if v.count > 500 { note = String(v.prefix(500)) } }
                } footer: {
                    HStack { Spacer(); Text("\(note.count)/500").monospacedDigit() }
                }
            }
            if target.kind == .message, let words = target.messageText, !words.isEmpty {
                Section {
                    Toggle("Share this message with Fariin's review team", isOn: $shareText).tint(.green)
                } footer: {
                    Text("Only this one message is shared. Your chat stays private.")
                }
            }
            if canBlock, !alreadyBlocked {
                Section {
                    Toggle("Block \(shownName)", isOn: $block).tint(.green)
                }
            }
            Section {
                Button { submit(cat, sub) } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(.white) }
                        Text("Submit report").font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            }
            .listRowBackground(Self.rowFill)   // rows a step off the sheet (a row's own clear wins)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
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
                path.append(.done(category, sub))
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
        List {
            Group {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.green)
                    Text("Thanks for letting us know").font(.title3.weight(.semibold))
                    Text("We'll review it. If it breaks our rules, we'll take it down. You can see what happened in Settings > Privacy > My reports.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if let box = safetyNote(cat, sub) {
                Section {
                    Label { Text(box).font(.subheadline) } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            if hasActions {
                Section {
                    if canBlock, !alreadyBlocked || blockedNow {
                        Button {
                            guard !blockedNow, !blockBusy else { return }
                            blockBusy = true
                            Task { @MainActor in await doBlock(); blockBusy = false }
                        } label: {
                            actionRow(blockedNow ? "Blocked" : "Block \(shownName)", "hand.raised", red: true)
                        }
                        .disabled(blockedNow || blockBusy)
                    }
                    if let title = target.leaveTitle, target.onLeave != nil {
                        Button {
                            left = true
                            dismiss()
                            // After the sheet is gone: a leave closes the screen under it.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { target.onLeave?() }
                        } label: { actionRow(title, "rectangle.portrait.and.arrow.right", red: true) }
                        .disabled(left)
                    }
                    if let m = target.muteCid {
                        Button {
                            mutedNow = true
                            Task { await ChatService.setMuted(m, true) }
                        } label: { actionRow(mutedNow ? "Muted" : "Mute \(shownName)", "bell.slash", red: false) }
                        .disabled(mutedNow)
                    }
                }
            }
            Section {
                Button { dismiss() } label: {
                    Text("Done").font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            }
            .listRowBackground(Self.rowFill)   // rows a step off the sheet (a row's own clear wins)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
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

/// A page of the Report sheet saying how tall it is: its list's content plus the bars above and
/// below it (the scroll view's insets), so the sheet can fit it with no empty space.
private struct ReportPageFit: ViewModifier {
    let depth: Int
    @Binding var fits: [Int: CGFloat]

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { g in
            g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom
        } action: { _, h in
            if h > 0, abs((fits[depth] ?? 0) - h) > 1 { fits[depth] = h }
        }
    }
}

import SwiftUI
import FirebaseFunctions

// Settings > Privacy & Security > My Reports (owner 2026-11-08, report flow v2): what I reported and
// what came of it. The list comes from the `myReports` callable; nobody can read `reports` directly.

struct MyReport: Identifiable, Hashable {
    let id: String
    let kind: ReportKind
    let category: String
    let sub: String
    let createdAt: Date
    let status: String       // received | action_taken | no_violation
    let targetName: String
    let targetThumb: String
    let note: String

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        self.id = id
        kind = ReportKind(rawValue: d["kind"] as? String ?? "") ?? .user
        category = d["category"] as? String ?? ""
        sub = d["sub"] as? String ?? ""
        createdAt = Date(timeIntervalSince1970: ((d["createdAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        status = d["status"] as? String ?? "received"
        targetName = d["targetName"] as? String ?? ""
        targetThumb = d["targetThumb"] as? String ?? ""
        note = d["note"] as? String ?? ""
    }

    var reason: String { category.isEmpty ? "Reported" : ReportReason.label(category: category, sub: sub) }
    var what: String {
        let noun = kind.noun.prefix(1).uppercased() + kind.noun.dropFirst()
        return targetName.isEmpty ? noun : "\(noun): \(targetName)"
    }
    var statusText: String {
        switch status {
        case "action_taken": return "Action taken"
        case "no_violation": return "No rule broken"
        default: return "Received"
        }
    }
    var statusColor: Color { status == "action_taken" ? .green : .secondary }
    var kindIcon: String {
        switch kind {
        case .user: return "person"
        case .story: return "circle.dashed"
        case .channel: return "megaphone"
        case .group: return "person.3"
        case .post, .message: return "text.bubble"
        case .reply: return "arrowshape.turn.up.left"
        }
    }
}

struct MyReportsView: View {
    @State private var items: [MyReport] = []
    @State private var more = false
    @State private var loading = false
    @State private var loaded = false
    @State private var failed = false

    private static var fn: Functions { Functions.functions(region: "me-central1") }

    var body: some View {
        List {
            if loaded && items.isEmpty && !failed {
                Section {
                    Text("You haven't reported anything.").foregroundStyle(.secondary)
                } footer: {
                    Text("When you report something, you can follow it here. Reports are private: nobody is told who sent them.")
                }
            }
            if failed && items.isEmpty {
                Section {
                    Button("Couldn't load your reports. Try again") { Task { await load(reset: true) } }
                }
            }
            if !items.isEmpty {
                Section {
                    ForEach(items) { r in
                        NavigationLink { MyReportDetail(report: r) } label: { row(r) }
                            .onAppear { if r.id == items.last?.id, more { Task { await load(reset: false) } } }
                    }
                } footer: {
                    Text("Reports are private. Nobody is told who sent them.")
                }
            }
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .listStyle(.insetGrouped)
        .navigationTitle("My Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load(reset: true) } }
        .refreshable { await load(reset: true) }
    }

    private func row(_ r: MyReport) -> some View {
        HStack(spacing: 12) {
            ReportThumb(url: r.targetThumb, icon: r.kindIcon)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.what).lineLimit(1)
                Text(r.reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(r.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            StatusPill(text: r.statusText, color: r.statusColor)
        }
        .padding(.vertical, 2)
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var data: [String: Any] = [:]
        if !reset, let last = items.last { data["before"] = last.createdAt.timeIntervalSince1970 * 1000 }
        do {
            let res = try await Self.fn.httpsCallable("myReports").call(data)
            let d = res.data as? [String: Any] ?? [:]
            let page = (d["items"] as? [[String: Any]] ?? []).compactMap(MyReport.init)
            if reset { items = page } else { items += page.filter { p in !items.contains { $0.id == p.id } } }
            more = d["more"] as? Bool ?? false
            failed = false
        } catch {
            failed = true
        }
        loaded = true
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct ReportThumb: View {
    let url: String
    let icon: String
    var body: some View {
        Group {
            if url.hasPrefix("https://"), let u = URL(string: url) {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { glyph }
            } else {
                glyph
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var glyph: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            Image(systemName: icon).foregroundStyle(.secondary)
        }
    }
}

private struct MyReportDetail: View {
    let report: MyReport
    var body: some View {
        List {
            Section {
                LabeledContent("What", value: report.what)
                LabeledContent("Reason", value: report.reason)
                LabeledContent("Sent", value: report.createdAt.formatted(date: .long, time: .shortened))
                LabeledContent("Status") { StatusPill(text: report.statusText, color: report.statusColor) }
            }
            if !report.note.isEmpty {
                Section("Your note") { Text(report.note) }
            }
            Section {
                Text(explain).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var explain: String {
        switch report.status {
        case "action_taken": return "We reviewed your report and took action. Thanks for helping keep Fariin safe."
        case "no_violation": return "We reviewed your report and found it doesn't break our rules. You can still block or mute them."
        default: return "We got your report and will review it. If it breaks our rules, we'll take it down."
        }
    }
}

import SwiftUI
import UIKit

// ⛔ CREATE / EDIT ONE INVITE LINK (groups v2 step 4, 2026-10-19), laid out like the reference app's
// link editor, our own words: a name only admins see (32 at most), Approve New Members, a time limit,
// a usage limit (hidden while approval is on: an approved link has no count to run out), and on an
// existing link Revoke Link. Saved through the server (createGroupLink / editGroupLink); a failure
// stays on the page with the server's words.

struct GroupLinkEditPage: View {
    let cid: String
    /// nil = a new link.
    let link: GroupLink?
    let onSaved: () -> Void

    enum TimeChoice: Hashable { case keep, hour, day, week, none }
    enum UsesChoice: Hashable { case keep, one, ten, hundred, none }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var approval = false
    @State private var time: TimeChoice = .none
    @State private var uses: UsesChoice = .none
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmRevoke = false
    @State private var filled = false

    private static let nameMax = 32

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                Section {
                    Toggle("Approve New Members", isOn: $approval)
                } footer: {
                    Text("An admin approves each person who asks to join with this link.")
                }
                timeSection
                if !approval { usesSection }
                if link != nil { revokeSection }
            }
            .navigationTitle(link == nil ? "New Link" : "Edit Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .disabled(saving)
            .onAppear(perform: fill)
            .alert("Couldn't save the link",
                   isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(saveError ?? "") }
            .alert("Revoke Link", isPresented: $confirmRevoke) {   // centred, not a bubble (audit)
                Button("Revoke", role: .destructive) { revoke() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The link stops working at once. It moves to Revoked Links.") }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("Link name (optional)", text: Binding(
                get: { name },
                set: { name = String($0.prefix(Self.nameMax)) }))
        } header: {
            Text("Name")
        } footer: {
            Text("Only admins see the name. \(name.count)/\(Self.nameMax)")
        }
    }

    // ⛔ A STEP SLIDER, AS SLOW MODE (owner 2026-10-20: "use the slow mode design"). Short marks
    // over a slider that stops on each one, in its own card; the footer says the pick in full.
    // A limit the link already has stays as the last mark ("Kept").
    private var timeSection: some View {
        var opts: [(TimeChoice, String)] = [(.none, "None"), (.hour, "1h"), (.day, "1d"), (.week, "1w")]
        if keptExpiry != nil { opts.append((.keep, "Kept")) }
        return Section {
            stepSlider(opts, selected: time) { time = $0 }
        } header: {
            Text("Time Limit")
        } footer: {
            Text(timeFooter)
        }
    }

    private var timeFooter: String {
        switch time {
        case .none: return "The link works until you turn it off."
        case .hour: return "The link stops working after 1 hour."
        case .day: return "The link stops working after 1 day."
        case .week: return "The link stops working after 1 week."
        case .keep: return keptExpiry.map { "The link stops working on \(Self.dateText($0))." } ?? ""
        }
    }

    private var usesSection: some View {
        var opts: [(UsesChoice, String)] = [(.none, "None"), (.one, "1"), (.ten, "10"), (.hundred, "100")]
        if keptUses != nil { opts.append((.keep, "Kept")) }
        return Section {
            stepSlider(opts, selected: uses) { uses = $0 }
        } header: {
            Text("Usage Limit")
        } footer: {
            Text(usesFooter)
        }
    }

    private var usesFooter: String {
        func after(_ n: Int) -> String { "The link stops working once \(n) \(n == 1 ? "person has" : "people have") joined with it." }
        switch uses {
        case .none: return "Any number of people can join with this link."
        case .one: return after(1)
        case .ten: return after(10)
        case .hundred: return after(100)
        case .keep: return keptUses.map(after) ?? ""
        }
    }

    private func stepSlider<T: Hashable>(_ opts: [(T, String)], selected: T,
                                         pick: @escaping (T) -> Void) -> some View {
        let index = opts.firstIndex { $0.0 == selected } ?? 0
        return VStack(spacing: 6) {
            HStack {
                ForEach(opts.indices, id: \.self) { i in
                    Text(opts[i].1).font(.caption)
                        .foregroundStyle(i == index ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            Slider(value: Binding(
                get: { Double(index) },
                set: { v in
                    let i = min(max(Int(v.rounded()), 0), opts.count - 1)
                    if i != index { pick(opts[i].0); UISelectionFeedbackGenerator().selectionChanged() }
                }),
                in: 0...Double(max(opts.count - 1, 1)), step: 1)
        }
        .padding(.vertical, 4)
    }

    private var revokeSection: some View {
        Section {
            Button("Revoke Link", role: .destructive) { confirmRevoke = true }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) {
            if saving { ProgressView() } else {
                Button(link == nil ? "Create" : "Save") { save() }.fontWeight(.semibold)
            }
        }
    }

    // MARK: - Values

    /// An existing limit that is not one of the choices stays selectable as "Keep".
    private var keptExpiry: Double? { (link?.expireAt ?? 0) > 0 ? link?.expireAt : nil }
    private var keptUses: Int? { (link?.usageLimit ?? 0) > 0 ? link?.usageLimit : nil }

    private func fill() {
        guard !filled else { return }
        filled = true
        guard let link else { return }
        name = link.name
        approval = link.requestApproval
        time = keptExpiry != nil ? .keep : .none
        uses = keptUses != nil ? .keep : .none
    }

    private func expireAt(now: Double) -> Double? {
        switch time {
        case .keep: return nil
        case .hour: return now + 3_600_000
        case .day: return now + 86_400_000
        case .week: return now + 604_800_000
        case .none: return 0
        }
    }

    private func usageLimit() -> Int? {
        if approval { return 0 }
        switch uses {
        case .keep: return nil
        case .one: return 1
        case .ten: return 10
        case .hundred: return 100
        case .none: return 0
        }
    }

    /// What goes to the server: the name and approval always, a limit only when it was chosen.
    private func fields() -> [String: Any] {
        var f: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "requestApproval": approval,
        ]
        if let e = expireAt(now: Date().timeIntervalSince1970 * 1000) { f["expireAt"] = e }
        if let u = usageLimit() { f["usageLimit"] = u }
        return f
    }

    private static func dateText(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // MARK: - Work

    private func save() {
        guard !saving else { return }
        saving = true
        let f = fields()
        Task {
            do {
                if let link {
                    _ = try await GroupInviteService.editLink(cid: cid, code: link.code, changes: f)
                } else {
                    _ = try await GroupInviteService.createLink(cid: cid, options: f)
                }
                onSaved()
                dismiss()
            } catch {
                saveError = GroupInviteService.errorText(error, "The link was not saved. Try again.")
            }
            saving = false
        }
    }

    private func revoke() {
        guard let link, !saving else { return }
        saving = true
        Task {
            do {
                _ = try await GroupInviteService.revokeLink(cid: cid, code: link.code)
                onSaved()
                dismiss()
            } catch {
                saveError = GroupInviteService.errorText(error, "The link was not revoked. Try again.")
            }
            saving = false
        }
    }
}

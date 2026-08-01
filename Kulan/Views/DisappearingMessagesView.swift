import SwiftUI

// Full-screen "Disappearing Messages" picker (standard style): a description, a radio list
// of durations, and a Custom Time sub-picker. X cancels, checkmark commits the highlighted timer.
struct DisappearingMessagesView: View {
    let cid: String
    var onApply: (Int) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int
    @State private var showCustom = false

    private var dark: Bool { scheme == .dark }

    // Preset durations (seconds), matching the mockup.
    private let presets: [(String, Int)] = [
        ("Off", 0), ("4 weeks", 2_419_200), ("1 week", 604_800), ("1 day", 86_400),
        ("8 hours", 28_800), ("1 hour", 3_600), ("5 minutes", 300), ("30 seconds", 30),
    ]

    init(cid: String, current: Int, onApply: @escaping (Int) -> Void) {
        self.cid = cid; self.onApply = onApply
        _selected = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            // Native inset-grouped List (not a custom card): standard rows, dividers, checkmark + chevron.
            List {
                Section {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, opt in
                        optionRow(opt.0, opt.1)
                    }
                    Button { showCustom = true } label: {
                        HStack(spacing: 0) {
                            checkSlot(isCustomSelected)
                            Text("Custom Time").foregroundStyle(.primary)
                            Spacer()
                            // Selected custom duration as a trailing gray value (native detail style),
                            // not inline parentheses.
                            if isCustomSelected {
                                Text(ChatService.disappearLabel(selected))
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 6)
                            }
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("When enabled, new messages sent and received in this chat will disappear after they have been seen.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .textCase(nil)   // keep normal case (not the uppercased section-header style)
                        .padding(.bottom, 6)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Disappearing Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onApply(selected); dismiss() } label: { Image(systemName: "checkmark").font(.headline) }
                }
            }
            .sheet(isPresented: $showCustom) {
                CustomTimePicker(seconds: selected) { selected = $0 }
            }
        }
    }

    // Fixed-width leading checkmark GUTTER (native picker-list style): every row's text shares the
    // same indent whether or not it's selected — the old inline checkmark shifted only the selected
    // row's text to the right.
    @ViewBuilder private func checkSlot(_ on: Bool) -> some View {
        ZStack {
            if on { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor) }
        }
        .frame(width: 34, alignment: .leading)
    }

    private func optionRow(_ label: String, _ seconds: Int) -> some View {
        Button { selected = seconds } label: {
            HStack(spacing: 0) {
                checkSlot(selected == seconds)
                Text(label).foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // The custom row is selected when the value isn't one of the presets.
    private var isCustomSelected: Bool { selected != 0 && !presets.contains { $0.1 == selected } }
}

// A value + unit wheel picker for a custom disappearing timer.
private struct CustomTimePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: Int
    @State private var unit: Unit
    var onDone: (Int) -> Void

    enum Unit: String, CaseIterable, Identifiable {
        case seconds, minutes, hours, days, weeks
        var id: String { rawValue }
        var mult: Int { switch self { case .seconds: 1; case .minutes: 60; case .hours: 3600; case .days: 86400; case .weeks: 604800 } }
    }

    init(seconds: Int, onDone: @escaping (Int) -> Void) {
        self.onDone = onDone
        // Seed the wheels from the current value (largest whole unit that fits).
        let s = max(1, seconds)
        let u: Unit = [.weeks, .days, .hours, .minutes, .seconds].first { s % $0.mult == 0 && s / $0.mult >= 1 } ?? .seconds
        _unit = State(initialValue: u)
        _value = State(initialValue: max(1, s / u.mult))
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("", selection: $value) {
                    ForEach(1...99, id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.wheel).frame(maxWidth: .infinity)
                Picker("", selection: $unit) {
                    ForEach(Unit.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.wheel).frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Custom Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { onDone(value * unit.mult); dismiss() }.fontWeight(.semibold)
                }
            }
            .presentationDetents([.height(320)])
        }
    }
}

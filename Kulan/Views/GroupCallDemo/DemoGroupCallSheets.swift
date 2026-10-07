import SwiftUI
import UIKit

// GROUP CALL DEMO SHEETS (owner, 2026-10-07): the people list (the real GroupCallParticipantsSheet's
// content, rebuilt here on demo state) and the Scenario panel that drives the simulation, with the
// event log he can copy into a report.

// MARK: - People list

struct DemoPeopleSheet: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("In call · \(engine.state.isLive || engine.state == .reconnecting ? engine.inCallCount : 0)") {
                    meRow
                    ForEach(sortedInCall) { person in
                        row(person)
                    }
                }
                if !engine.ringing.isEmpty {
                    Section("Ringing") {
                        ForEach(engine.ringing) { person in
                            HStack(spacing: 12) {
                                AvatarView(name: person.name, photoUrl: person.photoUrl, size: 40)
                                Text(person.name)
                                Spacer()
                                Text("Ringing…").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !engine.departed.isEmpty {
                    Section("Left") {
                        ForEach(Array(engine.departed.enumerated()), id: \.offset) { _, person in
                            HStack(spacing: 12) {
                                AvatarView(name: person.name, photoUrl: person.photoUrl, size: 40)
                                    .opacity(0.5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name).foregroundStyle(.secondary)
                                    Text([person.role.badge, "Left"].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if engine.myRole == .owner && (engine.state.isLive || engine.state == .reconnecting) {
                    Section {
                        Button(role: .destructive) {
                            engine.endForEveryone()
                            dismiss()
                        } label: {
                            Text("End Call for Everyone")
                        }
                    }
                }
            }
            .navigationTitle("Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .modifier(DemoRemovalAlert(engine: engine, enabled: true))
    }

    private var sortedInCall: [DemoPerson] {
        engine.inCall.sorted { a, b in
            if a.joinedAt != b.joinedAt { return a.joinedAt < b.joinedAt }
            return a.id < b.id
        }
    }

    private var meRow: some View {
        HStack(spacing: 12) {
            AvatarView(name: engine.myName, photoUrl: engine.myPhotoUrl, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(engine.myName) (You)")
                let badge = [engine.myRole.badge, engine.state == .reconnecting ? "Reconnecting…" : nil,
                             engine.handRaised ? "Hand raised" : nil].compactMap { $0 }
                if !badge.isEmpty {
                    Text(badge.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            mediaIcons(mic: engine.micOn, camera: engine.cameraOn)
        }
    }

    private func row(_ person: DemoPerson) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: person.name, photoUrl: person.photoUrl, size: 40)
                .overlay(
                    Circle().strokeBorder(Color.green, lineWidth: 2)
                        .opacity(engine.speakingIds.contains(person.id) ? 1 : 0)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.name).lineLimit(1)
                    if engine.activeSpeakerId == person.id {
                        Image(systemName: "waveform").font(.caption).foregroundStyle(.green)
                    }
                }
                let status = statusWords(person)
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(person.link == .poor || person.link == .lost ? Color.orange : Color.secondary)
                }
            }
            Spacer()
            mediaIcons(mic: person.micOn, camera: person.cameraOn)
            if engine.canModerate(person.id) || engine.canPromote(person.id) {
                Menu {
                    DemoPersonActions(id: person.id, includePin: false)
                        .environmentObject(engine)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            engine.togglePin(person.id)
            dismiss()
        }
    }

    private func statusWords(_ p: DemoPerson) -> String {
        var parts: [String] = []
        if let badge = p.role.badge { parts.append(badge) }
        switch p.link {
        case .connecting: parts.append("Connecting…")
        case .poor: parts.append("Poor network")
        case .lost: parts.append("Reconnecting…")
        case .ringing, .connected: break
        }
        if p.handRaised { parts.append("Hand raised") }
        if engine.pinnedId == p.id { parts.append("Pinned") }
        return parts.joined(separator: " · ")
    }

    private func mediaIcons(mic: Bool, camera: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: camera ? "video.fill" : "video.slash.fill")
                .foregroundStyle(camera ? Color.primary : Color.secondary)
            Image(systemName: mic ? "mic.fill" : "mic.slash.fill")
                .foregroundStyle(mic ? Color.primary : Color.red)
        }
        .font(.subheadline)
    }
}

// MARK: - Scenario panel

struct DemoScenarioSheet: View {
    @EnvironmentObject private var engine: DemoGroupCallEngine
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(statusLine).font(.footnote.monospaced())
                }
                Section("Start") {
                    HStack {
                        presetButton(2)
                        presetButton(3)
                        presetButton(10)
                    }
                    action("Ring 3 people (ringing state)", "phone.arrow.up.right") { engine.startRinging() }
                    Toggle("Call full on next join", isOn: Binding(get: { engine.callFullOnJoin },
                                                                    set: { engine.setCallFull($0) }))
                    action("Reset", "arrow.counterclockwise") { engine.reset() }
                }
                Section("Roles") {
                    Toggle("I am the owner", isOn: Binding(get: { engine.iAmOwner },
                                                           set: { engine.setIAmOwner($0) }))
                    action("\(DemoGroupCallEngine.ownerHandle) mutes me", "mic.slash") { engine.hostMutesMe() }
                    action("\(DemoGroupCallEngine.ownerHandle) removes me", "person.fill.xmark") { engine.hostRemovesMe() }
                    action("Host ends the call", "phone.down") { engine.hostEndsCall() }
                }
                Section("People") {
                    action("Add participant", "person.badge.plus") { engine.addParticipant() }
                    action("Remove a random participant", "person.badge.minus") { engine.removeRandom() }
                    action("Someone leaves", "figure.walk") { engine.someoneLeaves() }
                    action("Owner leaves", "crown") { engine.ownerLeaves() }
                    action("Active speaker leaves", "waveform.slash") { engine.activeSpeakerLeaves() }
                    action("Pinned person leaves", "pin.slash") { engine.pinnedLeaves() }
                    action("Someone raises a hand", "hand.raised") { engine.someoneRaisesHand() }
                }
                Section("Network") {
                    action("Drop someone (comes back)", "wifi.exclamationmark") { engine.dropSomeone(recovers: true) }
                    action("Drop someone (times out)", "wifi.slash") { engine.dropSomeone(recovers: false) }
                    action("Drop my connection (comes back)", "antenna.radiowaves.left.and.right") { engine.dropMe(recovers: true) }
                    action("Drop my connection (never comes back)", "antenna.radiowaves.left.and.right.slash") { engine.dropMe(recovers: false) }
                }
                Section("Media") {
                    action("Someone starts talking now", "waveform") { engine.someoneTalksNow() }
                    action("Everyone stops talking", "speaker.slash") { engine.everyoneStopsTalking() }
                    action("Everyone mutes", "mic.slash.fill") { engine.everyoneMutes() }
                    action("Toggle someone's camera", "video") { engine.toggleSomeonesCamera() }
                    action("Someone's video fails", "video.slash") { engine.breakSomeonesVideo() }
                }
                Section("Speed") {
                    Picker("Speed", selection: Binding(get: { engine.speed }, set: { engine.setSpeed($0) })) {
                        Text("1x").tag(1.0)
                        Text("3x").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    ForEach(engine.log.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.stamp).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Text(entry.text).font(.caption).foregroundStyle(color(entry.kind))
                        }
                    }
                } header: {
                    HStack {
                        Text("Event log · newest first")
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            UIPasteboard.general.string = engine.logText
                            copied = true
                        }
                        Button("Clear") { engine.clearLog() }
                    }
                    .textCase(nil)
                }
            }
            .navigationTitle("Scenarios")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // With the panel at half height the tiles behind still take long presses.
        .modifier(DemoRemovalAlert(engine: engine, enabled: true))
    }

    private var statusLine: String {
        let speaker = engine.activeSpeakerId.flatMap { id in engine.person(id)?.name } ?? "none"
        let pinned = engine.pinnedId.flatMap { id in engine.person(id)?.name } ?? "none"
        return "state: \(engine.state.rawValue)  in call: \(engine.inCallCount)  ringing: \(engine.ringing.count)\n"
            + "speaker: \(speaker)  pinned: \(pinned)\n"
            + "me: mic \(engine.micOn ? "on" : "off"), camera \(engine.cameraOn ? "on" : "off"), "
            + "\(engine.isVideoCall ? "video" : "voice") call, role \(engine.myRole.rawValue)"
    }

    private func presetButton(_ total: Int) -> some View {
        Button("\(total)") { engine.startPreset(total: total) }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
        }
    }

    private func color(_ kind: DemoLogEntry.Kind) -> Color {
        switch kind {
        case .state: return .blue
        case .event: return .primary
        case .warning: return .orange
        }
    }
}

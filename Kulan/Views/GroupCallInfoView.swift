import SwiftUI

// "Call info" for a multi-person call, opened from the (i) on its Calls-tab row. Same cards and
// greys as the 1:1 call info (ContactInfoView with source .calls): stacked avatars, the title,
// "N invited", Voice / Video to start a new call with the same people, the entry under its day,
// then who joined and who did not. A person row pushes the same profile the 1:1 list opens.
struct GroupCallInfoView: View {
    let entry: CallEntry

    private var info: AdhocCallInfo? { entry.adhoc }
    private var me: String { AuthService.shared.uid ?? "" }
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private var pageBackground: Color { Color(uiColor: .systemGroupedBackground) }

    /// Same gate as the calls list: no new call while one is already up.
    private var callsEnabled: Bool {
        let s = CallService.shared.state
        return (s == .idle || s == .ended) && !GroupCallService.shared.isActive
    }

    var body: some View {
        ScrollView {
            if let info {
                VStack(spacing: 22) {
                    header(info)
                    actions(info)
                    entrySection(info)
                    let joined = ordered(info.members.filter { info.joined.contains($0) })
                    let missing = ordered(info.members.filter { !info.joined.contains($0) })
                    if !joined.isEmpty {
                        peopleSection("Joined", joined, info)
                    }
                    if !missing.isEmpty {
                        peopleSection("Did not join · \(missing.count) \(missing.count == 1 ? "person" : "people")",
                                      missing, info)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(pageBackground.ignoresSafeArea())
        .navigationTitle("Call info")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Me first, then everyone else in invite order.
    private func ordered(_ uids: [String]) -> [String] {
        uids.filter { $0 == me } + uids.filter { $0 != me }
    }

    // MARK: Header

    private func header(_ info: AdhocCallInfo) -> some View {
        let people = Array(info.titleUids(me).prefix(3))
        let invited = info.others(me).count
        return VStack(spacing: 10) {
            HStack(spacing: -22) {
                ForEach(people, id: \.self) { uid in
                    AvatarView(name: info.name(uid), photoUrl: info.photo(uid), size: 76)
                        .overlay(Circle().stroke(pageBackground, lineWidth: 3))
                }
            }
            Text(entry.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("\(invited) invited")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func actions(_ info: AdhocCallInfo) -> some View {
        HStack(spacing: 10) {
            actionTile("Voice", icon: "phone.fill") { info.callAgain(video: false) }
            actionTile("Video", icon: "video.fill") { info.callAgain(video: true) }
        }
    }

    private func actionTile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .profileSurface(plain: cardColor, radius: 16)
        .disabled(!callsEnabled)
        .opacity(callsEnabled ? 1 : 0.45)
    }

    // MARK: The entry

    private var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(entry.date) { return "Today" }
        if cal.isDateInYesterday(entry.date) { return "Yesterday" }
        return entry.date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func entryText(_ info: AdhocCallInfo) -> String {
        let kind = entry.video ? "video call" : "voice call"
        let label = entry.video ? "Video call" : "Voice call"
        if entry.mine && entry.missed && info.joinedOthers(me).isEmpty { return "Unanswered \(kind)" }
        if entry.missedIncoming { return "Missed \(kind)" }
        if entry.outcome == "ringing" { return "Ongoing \(kind)" }
        let secs = entry.durationSec
        guard secs > 0 else { return label }
        if secs < 60 { return "\(label) · \(secs) sec" }
        let mins = secs / 60
        if mins < 60 { return "\(label) · \(mins) min" }
        let hours = mins / 60, rest = mins % 60
        return rest == 0 ? "\(label) · \(hours) hr" : "\(label) · \(hours) hr \(rest) min"
    }

    private func entrySection(_ info: AdhocCallInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(dayTitle)
            HStack(spacing: 10) {
                Image(systemName: entry.missedIncoming
                      ? (entry.video ? "video.slash.fill" : "phone.down.fill")
                      : (entry.mine ? "phone.arrow.up.right" : "phone.arrow.down.left"))
                    .foregroundStyle(entry.missedIncoming ? .red : .secondary)
                Text(entryText(info))
                    .foregroundStyle(entry.missedIncoming ? Color.red : Color.primary)
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .profileSurface(plain: cardColor)
        }
    }

    // MARK: People

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
    }

    private func peopleSection(_ title: String, _ uids: [String], _ info: AdhocCallInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title)
            VStack(spacing: 0) {
                ForEach(Array(uids.enumerated()), id: \.element) { i, uid in
                    personRow(uid, info)
                    if i < uids.count - 1 {
                        Divider().padding(.leading, 66)
                    }
                }
            }
            .profileSurface(plain: cardColor)
        }
    }

    @ViewBuilder
    private func personRow(_ uid: String, _ info: AdhocCallInfo) -> some View {
        if uid == me {
            personLabel(uid, info, chevron: false)
        } else {
            NavigationLink {
                ContactInfoView(cid: [me, uid].sorted().joined(separator: "_"),
                                name: info.name(uid), photoUrl: info.photo(uid), source: .calls)
            } label: {
                personLabel(uid, info, chevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func personLabel(_ uid: String, _ info: AdhocCallInfo, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: info.name(uid), photoUrl: info.photo(uid), size: 40)
            HStack(spacing: 0) {
                Text(uid == me ? "You" : info.name(uid))
                    .foregroundStyle(Color.primary)
                if uid == info.startedBy {
                    Text(" · Creator").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 17))
            .lineLimit(1)
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Two overlapping avatars for a multi-person call: the first person top-left, the second smaller,
/// bottom-right, ringed in the colour of whatever it sits on so the two read as separate circles.
/// One person left on the call → one plain avatar.
struct GroupCallAvatars: View {
    let info: AdhocCallInfo
    let me: String
    var size: CGFloat = 46
    var ring: Color = Color(uiColor: .systemBackground)

    var body: some View {
        let uids = info.titleUids(me)
        if uids.count >= 2 {
            ZStack(alignment: .topLeading) {
                AvatarView(name: info.name(uids[0]), photoUrl: info.photo(uids[0]), size: size * 0.74)
                AvatarView(name: info.name(uids[1]), photoUrl: info.photo(uids[1]), size: size * 0.6)
                    .overlay(Circle().stroke(ring, lineWidth: 2.5))
                    .frame(width: size, height: size, alignment: .bottomTrailing)
            }
            .frame(width: size, height: size)
        } else {
            let uid = uids.first ?? ""
            AvatarView(name: info.name(uid), photoUrl: info.photo(uid), size: size)
        }
    }
}

extension AdhocCallInfo {
    /// A new multi-person call with the same people (everyone invited last time except me).
    @MainActor func callAgain(video: Bool) {
        let me = AuthService.shared.uid ?? ""
        let people = others(me).map { CallMember(uid: $0, name: name($0), photoUrl: photo($0)) }
        guard !people.isEmpty else { return }
        Task { _ = await GroupCallService.shared.startAdhoc(with: people, video: video) }
    }
}

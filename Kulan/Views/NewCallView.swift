import SwiftUI

// New Call, the Calls tab's new-call button (owner 2026-11-08: the same page as the Android app).
// "Create a Call Link" first, then the people from my 1:1 chats (newest chat first) with a tick
// circle on each row, then the groups I may start a call in with voice and video buttons. Picked
// people line up in a strip under the title with the video and voice buttons pinned at its end:
// one pick is a 1:1 call, two or more a multi-person call (GroupCallService.startAdhoc). A group's
// buttons call that group at once, no picking. Search filters both lists.

/// One picked person: the profile name goes into the call (audit M-151: never my private contact
/// name, the room doc is shared), the name I see goes on screen.
struct NewCallPick: Identifiable, Equatable {
    let member: CallMember
    let shown: String
    var id: String { member.uid }
}

struct NewCallView: View {
    /// A group's voice or video button. The Calls tab closes this sheet and starts the call with
    /// its own checks and cover (`CallsView.callGroupAgain`).
    var onCallGroup: (_ cid: String, _ title: String, _ video: Bool) -> Void = { _, _, _ in }
    /// "Create a Call Link": the Calls tab closes this sheet and runs its own link flow.
    var onCreateLink: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var picked: [NewCallPick] = []   // in the order picked
    private var me: String { AuthService.shared.uid ?? "" }

    /// People I may pick besides me: the multi-person room's cap (AddPeopleSheet.maxInCall, the
    /// rules allow 32 members) less me. One when multi-person calls are switched off.
    private var maxPick: Int { CallFeatures.groupCalls ? AddPeopleSheet.maxInCall - 1 : 1 }

    private var trimmedQuery: String {
        let t = query.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("@") ? String(t.dropFirst()) : t
    }

    /// My 1:1 chats, newest first, one per person. Not: deleted accounts, people I blocked, demo
    /// chats, requests still waiting for my answer.
    private struct Person: Identifiable {
        let conv: Conversation
        let pick: NewCallPick
        var id: String { pick.id }
    }

    private var people: [Person] {
        var seen = Set<String>()
        return repo.conversations
            .filter { !$0.isGroup && !$0.isChannel && !DemoMode.isDemoConversation($0.id) }
            .filter { c in
                let other = c.otherUid(me)
                return !other.isEmpty && other != me && !c.isDeletedAccount(other) && !c.isBlockedByMe(me)
                    && MessageRequests.stance(c, myUid: me) != .incoming
            }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
            .compactMap { c in
                let other = c.otherUid(me)
                guard seen.insert(other).inserted else { return nil }
                let member = CallMember(uid: other, name: c.names[other] ?? "User", photoUrl: c.photoUrl(for: me))
                return Person(conv: c, pick: NewCallPick(member: member, shown: c.displayName(me)))
            }
    }

    /// Groups I am in and may start a call in (admins only when the group says so).
    private var groups: [Conversation] {
        guard CallFeatures.groupCalls else { return [] }
        return repo.conversations
            .filter { $0.isGroup && !$0.isChannel && $0.users.contains(me) && $0.canStartCall(me) }
            .filter { !DemoMode.isDemoConversation($0.id) }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    private func matches(_ name: String) -> Bool {
        trimmedQuery.isEmpty || name.localizedCaseInsensitiveContains(trimmedQuery)
    }
    private var shownPeople: [Person] { people.filter { matches($0.pick.shown) } }
    private var shownGroups: [Conversation] { groups.filter { matches($0.displayName(me)) } }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty && CallFeatures.callLinks {
                    Section { linkRow }
                }
                if !shownPeople.isEmpty {
                    Section {
                        ForEach(shownPeople) { personRow($0.conv, $0.pick) }
                    } header: {
                        sectionTitle(trimmedQuery.isEmpty ? "Recent Chats" : "People")
                    }
                }
                if !shownGroups.isEmpty {
                    Section {
                        ForEach(shownGroups) { groupRow($0) }
                    } header: {
                        sectionTitle("Groups")
                    }
                }
                if shownPeople.isEmpty && shownGroups.isEmpty {
                    if trimmedQuery.isEmpty {
                        ContentUnavailableView("No contacts", systemImage: "phone",
                                               description: Text("Start a chat first, then you can call them."))
                    } else {
                        ContentUnavailableView.search(text: trimmedQuery)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)              // owner 2026-10-04: "spaces look big"
            .environment(\.defaultMinListRowHeight, 44)
            // The picked strip rides under the title, so it stays put while the list scrolls.
            .safeAreaInset(edge: .top, spacing: 0) {
                if !picked.isEmpty {
                    PickedCallStrip(picks: picked,
                                    onRemove: { p in picked.removeAll { $0.id == p.id } },
                                    onVoice: { callPicked(video: false) },
                                    onVideo: { callPicked(video: true) })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: picked.isEmpty)
            .navigationTitle("New Call")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary)
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary).textCase(nil)
    }

    private var linkRow: some View {
        Button { onCreateLink() } label: {
            HStack(spacing: 12) {
                Image("ic_link_copy").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Create a Call Link").font(.system(size: 17))
                    Text("Share a link for a call on Fariin").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    /// Tapping the row picks the person; the app's own tick circle (AddPeopleSheet) says so.
    private func personRow(_ c: Conversation, _ p: NewCallPick) -> some View {
        let on = picked.contains { $0.id == p.id }
        return Button { toggle(p) } label: {
            HStack(spacing: 12) {
                AvatarView(name: p.shown, photoUrl: c.displayPhoto(me), size: 40)
                Text(p.shown).font(.system(size: 17)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
    }

    /// A group calls at once from its own two buttons, as the chat header does.
    private func groupRow(_ c: Conversation) -> some View {
        let name = c.displayName(me)
        return HStack(spacing: 12) {
            AvatarView(name: name, photoUrl: c.displayPhoto(me), size: 40)
            Text(name).font(.system(size: 17)).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                glyph("ic_call_voice", "Group voice call") { onCallGroup(c.id, name, false) }
                glyph("ic_call_video", "Group video call") { onCallGroup(c.id, name, true) }
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
    }

    private func glyph(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 22, height: 22).foregroundStyle(.primary)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func toggle(_ p: NewCallPick) {
        if picked.contains(where: { $0.id == p.id }) {
            picked.removeAll { $0.id == p.id }
            return
        }
        guard picked.count < maxPick else {
            Haptics.notify(.warning)
            let message = maxPick == 1 ? "You can call one person at a time."
                                       : "A call can have up to \(maxPick + 1) people, you included."
            GroupCallService.presentOverTop(.init(title: "Limit Reached", message: message))
            return
        }
        picked.append(p)
    }

    /// 2026-09-24 audit: `startCall` refuses silently while a call is up, so say it here.
    private var callsEnabled: Bool {
        let s = CallService.shared.state
        return s == .idle || s == .ended
    }

    private func callPicked(video: Bool) {
        let list = picked
        guard let first = list.first else { return }
        if list.count == 1 {
            guard callsEnabled else { GroupCallService.presentOverTop(GroupCallService.busyNotice); return }
            CallService.shared.startCall(to: first.member.uid, name: first.shown,
                                         photo: first.member.photoUrl, video: video)
            dismiss()
        } else {
            // The room screen comes up from IncomingGroupCallLayer once this sheet is gone.
            let people = list.map(\.member)
            dismiss()
            Task { _ = await GroupCallService.shared.startAdhoc(with: people, video: video) }
        }
    }
}

// MARK: - Picked strip

/// The picked people under New Call's title, each face with a grey x, and the video and voice
/// buttons pinned at the end. The motion is the Android app's (owner's reference video, 2026-11-07):
/// - anchored at its END: while the faces fit they sit at the left; past that the newest stays at
///   the right edge and the oldest slide off the left, a swipe brings them back;
/// - a pick when the row is full: the row slides left one slot (150 ms), then the new face grows
///   from 20% on a soft spring in the freed slot; while it fits, the face grows at once;
/// - a removal (x, or unticked in the list): the face dims while pressed, fades out (150 ms), then
///   the row slides right to close the gap and a hidden face comes back in at the left.
/// Laid out by hand (each face at its own x) rather than in a ScrollView, so every one of those
/// steps is an explicit animation and nothing snaps when the content width changes.
struct PickedCallStrip: View {
    let picks: [NewCallPick]
    let onRemove: (NewCallPick) -> Void
    let onVoice: () -> Void
    let onVideo: () -> Void

    private enum Phase { case hidden, shown, leaving }

    @State private var faces: [NewCallPick] = []     // what is drawn: `picks` plus faces still fading out
    @State private var phase: [String: Phase] = [:]
    @State private var width: CGFloat = 0
    @State private var shift: CGFloat = 0            // swiped right by this much (shows older faces)
    @State private var dragStart: CGFloat?
    @State private var dragged = false               // a swipe ending on a face is not a tap on its x

    private static let slot: CGFloat = 66
    private static let pad: CGFloat = 8
    private static let height: CGFloat = 86
    private static let slide = Animation.easeInOut(duration: 0.15)
    /// Android's spring (damping ratio 0.72, stiffness 520): damping = 2 x 0.72 x sqrt(520).
    private static let grow = Animation.interpolatingSpring(mass: 1, stiffness: 520, damping: 33)
    private static let fade = Animation.easeOut(duration: 0.15)

    private var contentWidth: CGFloat { Self.pad * 2 + CGFloat(faces.count) * Self.slot }
    private var maxShift: CGFloat { max(0, contentWidth - width) }
    /// Left-aligned while it fits, end-anchored once it does not.
    private var baseX: CGFloat { width > 0 ? min(0, width - contentWidth) : 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(faces.enumerated()), id: \.element.id) { i, p in
                    face(p)
                        .offset(x: baseX + shift + Self.pad + CGFloat(i) * Self.slot)
                        .transition(.identity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(drag)
            HStack(spacing: 10) {
                callButton("ic_call_video", picks.count > 1 ? "Video call with \(picks.count) people" : "Video call", onVideo)
                callButton("ic_call_voice", picks.count > 1 ? "Voice call with \(picks.count) people" : "Voice call", onVoice)
            }
            .padding(.top, 12)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Color(.systemGroupedBackground))
        .onAppear { sync(picks) }
        .onChange(of: picks) { _, now in sync(now) }
    }

    private func face(_ p: NewCallPick) -> some View {
        let ph = phase[p.id] ?? .hidden
        return Button { remove(p) } label: {
            VStack(spacing: 4) {
                AvatarView(name: p.shown, photoUrl: p.member.photoUrl, size: 52)
                    .frame(width: 54, height: 54)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                            .background(Circle().fill(Color(.systemGroupedBackground)).padding(-2))
                            .offset(x: 2, y: -2)
                    }
                Text(firstName(p.shown))
                    .font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .frame(width: Self.slot)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickedFacePress())
        .scaleEffect(ph == .shown ? 1 : (ph == .hidden ? 0.2 : 0.6))
        .opacity(ph == .shown ? 1 : 0)
        .allowsHitTesting(ph == .shown)
        .accessibilityLabel("Remove \(p.shown)")
    }

    private func firstName(_ s: String) -> String {
        let first = s.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? s : first
    }

    private func callButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(Color.onFariinAction)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(Color.fariinAction)
        .accessibilityLabel(label)
    }

    // MARK: Motion

    private func sync(_ now: [NewCallPick]) {
        let ids = Set(now.map(\.id))
        // Picked again before its fade finished: it goes back on at the end, as a new pick.
        let returning = faces.filter { ids.contains($0.id) && phase[$0.id] == .leaving }.map(\.id)
        if !returning.isEmpty {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                faces.removeAll { returning.contains($0.id) }
                for id in returning { phase[id] = nil }
            }
        }
        for f in faces where !ids.contains(f.id) && phase[f.id] != .leaving { leave(f.id) }
        for p in now where !faces.contains(where: { $0.id == p.id }) { add(p) }
    }

    private func add(_ p: NewCallPick) {
        let full = width > 0 && (Self.pad * 2 + CGFloat(faces.count + 1) * Self.slot > width || shift > 0)
        if full && !faces.isEmpty {
            // The row slides left one slot (and back to its end if it was swiped), then the face grows.
            phase[p.id] = .hidden
            withAnimation(Self.slide) { faces.append(p); shift = 0 }
            after(0.15) { grow(p.id) }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { phase[p.id] = .hidden; faces.append(p) }
            // One frame drawn at 20% and invisible first, so the spring has a start to grow from.
            after(0.02) { grow(p.id) }
        }
    }

    private func grow(_ id: String) {
        guard phase[id] == .hidden else { return }
        withAnimation(Self.grow) { phase[id] = .shown }
    }

    private func leave(_ id: String) {
        withAnimation(Self.fade) { phase[id] = .leaving }
        after(0.15) {
            guard phase[id] == .leaving else { return }
            withAnimation(Self.slide) {
                faces.removeAll { $0.id == id }
                phase[id] = nil
                shift = min(shift, maxShift)
            }
        }
    }

    private func remove(_ p: NewCallPick) {
        guard !dragged else { return }
        onRemove(p)
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            work()
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let start = dragStart ?? shift
                if dragStart == nil { dragStart = start; dragged = true }
                shift = rubberBand(start + v.translation.width)
            }
            .onEnded { v in
                let start = dragStart ?? shift
                dragStart = nil
                let target = min(max(start + v.predictedEndTranslation.width, 0), maxShift)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { shift = target }
                after(0.2) { dragged = false }
            }
    }

    /// Past either end the row follows the finger at a third of the way, as a scroll view does.
    private func rubberBand(_ x: CGFloat) -> CGFloat {
        if x < 0 { return x / 3 }
        if x > maxShift { return maxShift + (x - maxShift) / 3 }
        return x
    }
}

/// A pressed face dims (Android's 60% while held).
private struct PickedFacePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

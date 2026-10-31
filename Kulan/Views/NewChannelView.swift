import SwiftUI
import FirebaseFunctions

/// NEW CHANNEL (owner 2026-10-28). The reference app's order, our words and our parts:
/// 1. what a channel is, 2. photo + name + description on one page (Next lights up with a name),
/// 3. Channel Type (`GroupTypeView` in setup mode: public link or private invite link, restrict
/// saving), then the channel opens, its owner card holding Share (2026-10-29).
/// The channel is made at step 2's Next: a group created the normal way, then turned into a channel
/// by the server (`makeChannel`). From there on there is no going back, only forward.
struct NewChannelView: View {
    let onOpen: (ChatTarget) -> Void
    /// ⛔ PUSHED INSIDE NEW MESSAGE, NOT A SHEET ON A SHEET (owner 2026-10-31: "New channel opens from
    /// the bottom over New chat, two cards stacked; the large apps slide it in from the right"). When
    /// true there is no stack of its own: the page and its steps ride New Message's stack, the X is
    /// the system's Back, and Channel Type has no Back (a second Next could make a second channel).
    var embedded = false
    @State private var embeddedDetails = false
    @State private var embeddedTypeCid: String?

    private enum Step: Hashable { case details, type(String) }

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var name = ""
    @State private var about = ""
    @State private var avatarData: Data?
    @State private var showPhotoOptions = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var pickedImage: UIImage?
    @State private var cropItem: GroupCropItem?
    @State private var creating = false
    @State private var error: String?
    @State private var createdCid: String?
    /// The group made by a try whose channel step failed: the next try finishes THIS one instead of
    /// making another (owner 2026-10-30 audit: each "Try again" left a plain group behind).
    @State private var halfMadeCid: String?
    /// The owned-count check, asked as the page opens rather than at Next (owner 2026-10-31: Next
    /// "takes a bit longer"). Its answer is waiting by the time the name is typed.
    @State private var earlyCheck: Task<[String: Any]?, Never>?
    @FocusState private var nameFocused: Bool

    /// The reference app's limits: 255 for the description; our group names already stop at 100.
    static let nameMax = 100
    static let aboutMax = 255

    private var trimmedName: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameMax))
    }

    var body: some View {
        if embedded {
            intro
                .navigationDestination(isPresented: $embeddedDetails) {
                    details
                        .navigationDestination(item: $embeddedTypeCid) { cid in
                            typePage(cid).navigationBarBackButtonHidden(true)
                        }
                }
                .interactiveDismissDisabled(creating || createdCid != nil)
        } else {
            NavigationStack(path: $path) {
                intro
                    .navigationDestination(for: Step.self) { step in
                        switch step {
                        case .details: details
                        case .type(let cid): typePage(cid)
                        }
                    }
            }
            // No swipe-away once the channel is being made or made (owner 2026-10-30 audit): a swipe on
            // Channel Type skipped `finish()`, and one mid-creation landed on a page that then jumped.
            .interactiveDismissDisabled(creating || createdCid != nil)
        }
    }

    /// Next opens the channel (owner 2026-10-29: a Share sheet that came up by itself and finished the
    /// same whether used or swiped away was confusing). Sharing is the Share button on the owner's card.
    private func typePage(_ cid: String) -> some View {
        GroupTypeView(cid: cid, setupNext: { finish() }, localPhoto: avatarData.flatMap(UIImage.init(data:)))
    }

    // MARK: 1. What a channel is

    // ⛔ MINIMAL, THE REFERENCE APP'S LAYOUT (owner 2026-10-29, later: "make it minimalist exactly
    // like the reference app"). Its intro (ComposeController.openCreateNewChannel -> a splash
    // PermissionController) is one picture, a title, one sentence and one button, centred, no list.
    // The picture stays ours: the small post preview (the owner found a lone icon cheap earlier the
    // same day; the reference's is an animation we do not have). The three feature rows are gone.
    // Our words, not theirs. The guidelines line stays (agreeing to them is ours to keep).
    private var intro: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    ChannelIntroPreview()
                        .padding(.top, 8)
                    VStack(spacing: 10) {
                        Text("Start a channel")
                            .font(.largeTitle.bold())
                        Text("Share news, photos and videos with as many people as you like.")
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            VStack(spacing: 12) {
                Text("By creating a channel you agree to the [Channel Guidelines](https://help.fariin.com/channels/channel-guidelines).")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .tint(Color.fariinAction)
                Button { if embedded { embeddedDetails = true } else { path.append(.details) } } label: {
                    Text("Create Channel").fontWeight(.semibold).foregroundStyle(Color.onFariinAction)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .liquidGlass(Capsule(), interactive: true, tint: Color.fariinAction)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .toolbar {
            // Pushed: the system's Back is the way out, so no X of its own.
            if !embedded {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    // MARK: 2. Photo, name, description

    private var details: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Button { nameFocused = false; showPhotoOptions = true } label: { avatarThumb }
                        .buttonStyle(.plain)
                        .accessibilityLabel(avatarData == nil ? "Set Channel Photo" : "Change Channel Photo")
                        // On the photo itself, so the choices point at what was tapped (owner
                        // 2026-10-29: on the page they hung over the name).
                        .confirmationDialog("Channel Photo", isPresented: $showPhotoOptions, titleVisibility: .hidden) {
                            Button("Take Photo") { showCamera = true }
                            Button("Choose Photo") { showPhotoPicker = true }
                            if avatarData != nil { Button("Remove Photo", role: .destructive) { avatarData = nil } }
                        }
                    TextField("Channel Name", text: $name)
                        .font(.title3)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onChange(of: name) { _, v in if v.count > Self.nameMax { name = String(v.prefix(Self.nameMax)) } }
                }
                .padding(.vertical, 6)
            }
            Section {
                TextField("Description", text: $about, axis: .vertical)
                    .lineLimit(1...6)
                    .onChange(of: about) { _, v in if v.count > Self.aboutMax { about = String(v.prefix(Self.aboutMax)) } }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Optional. Tell people what your channel is about.")
                    // Our rules for channels, on the Help Center (owner 2026-10-29).
                    Text("By creating a channel you agree to the [Channel Guidelines](https://help.fariin.com/channels/channel-guidelines).")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("New Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Our white ring in the word's place, as New Group does (owner 2026-10-29: the system
                // spinner here was not ours).
                Button { create() } label: {
                    Text("Next").fontWeight(.semibold)
                        .opacity(creating ? 0 : 1)
                        .overlay { if creating { CreatingRing(label: "Creating channel") } }
                }
                .disabled(trimmedName.isEmpty && !creating)
                .buttonStyle(.borderedProminent).tint(Color.fariinAction)
                .foregroundStyle(Color.onFariinAction)
            }
        }
        .task {
            // ⛔ WAKE THE SERVER WHILE THE NAME IS TYPED (owner 2026-10-31). Next ran three server
            // steps in a row and each started cold, about 1.5 s apiece (logs 05:56Z: groupcreatecheck
            // then makechannel each "Starting new instance"). The check is asked now for real; the
            // two later steps get an empty call that they refuse at once, which is enough to start
            // their servers. Nothing is created by it.
            if earlyCheck == nil {
                earlyCheck = Task {
                    let r = try? await Functions.functions(region: "me-central1").httpsCallable("groupCreateCheck").call()
                    return r?.data as? [String: Any]
                }
                Task.detached(priority: .utility) {
                    let fn = Functions.functions(region: "me-central1")
                    async let a = try? fn.httpsCallable("makeChannel").call([String: Any]())
                    async let b = try? fn.httpsCallable("createGroupLink").call([String: Any]())
                    _ = await (a, b)
                }
            }
            try? await Task.sleep(for: .milliseconds(600))   // after the push (NewGroupView's lesson)
            if !Task.isCancelled { nameFocused = true }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if let ui = pickedImage { pickedImage = nil; cropItem = GroupCropItem(image: ui) }
        }) {
            CameraPicker { data in pickedImage = UIImage(data: data) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotoPicker, onDismiss: {
            if let ui = pickedImage { pickedImage = nil; cropItem = GroupCropItem(image: ui) }
        }) {
            StoryLibraryPicker(onImage: { ui, _ in pickedImage = ui; showPhotoPicker = false },
                               onVideo: { _, _ in }, photosOnly: true, pickLabel: "Set Channel Photo")
                .storyAlwaysDark()
        }
        .fullScreenCover(item: $cropItem) { c in
            ProfilePhotoCropper(image: c.image,
                                onDone: { circle, _ in cropItem = nil; setPhoto(circle) },
                                onCancel: { cropItem = nil },
                                circleOnly: true,
                                circleSubtitle: "Shown in chats and on the channel page",
                                squircle: true)
                .ignoresSafeArea()
        }
    }

    private var avatarThumb: some View {
        ZStack {
            if let avatarData, let ui = UIImage(data: avatarData) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                SquircleShape().fill(Color.fariinAction.opacity(0.12))
                Image("ic_group_camera").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 28, height: 28).foregroundStyle(Color.fariinAction)
            }
        }
        .frame(width: 64, height: 64)
        // The channel's own shape, as everywhere it is shown (owner 2026-10-30 audit).
        .clipShape(SquircleShape())
        .contentShape(SquircleShape())
    }

    private func setPhoto(_ ui: UIImage) {
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let jpeg = ui.jpegData(compressionQuality: 0.9) else { return nil }
                return ChatService.downscaledJPEG(jpeg, maxDimension: 1024, quality: 0.8)
            }.value
            if let data { avatarData = data }
        }
    }

    // MARK: Make it

    private func create() {
        guard !creating, !trimmedName.isEmpty else { return }
        guard Flags.groupCreateEnabled else { error = "Creating new channels isn't available right now."; return }
        nameFocused = false
        creating = true; error = nil
        let title = trimmedName
        let desc = about.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = avatarData
        Task {
            // The same "at most N owned" check a new group asks (a channel counts as one).
            // The answer asked when the page opened; a fresh ask only when there is none.
            var answer = await earlyCheck?.value
            earlyCheck = nil   // used once: a later try asks again
            if answer == nil {
                answer = (try? await Functions.functions(region: "me-central1").httpsCallable("groupCreateCheck").call())?.data as? [String: Any]
            }
            if let d = answer, d["ok"] as? Bool == false {
                let max = (d["max"] as? Int) ?? AppLimits.shared.groupsOwnedMax
                error = "You can own up to \(max) groups and channels. Delete one to create a new one."
                creating = false
                return
            }
            do {
                // Only me in it, and only admins send, from the very first write.
                let cid: String
                if let half = halfMadeCid {
                    cid = half
                } else {
                    cid = try await ChatService.createGroup(title: title, memberIds: [], permissions: ["onlyAdminsSend": true],
                                                            createdText: "Channel created")
                    halfMadeCid = cid
                }
                // The group's write may still be on its way to the server: a few tries.
                var made = false
                for attempt in 0..<6 {
                    if (try? await ChannelService.makeChannel(cid: cid)) != nil { made = true; break }
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                }
                guard made else {
                    error = "Could not create the channel. Try again."
                    creating = false
                    return
                }
                halfMadeCid = nil
                createdCid = cid
                // The photo after the channel exists; a failed photo never undoes the channel.
                if let photo {
                    Task.detached(priority: .utility) {
                        if (try? await ChatService.uploadGroupAvatar(cid: cid, data: photo)) != nil { return }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if (try? await ChatService.uploadGroupAvatar(cid: cid, data: photo)) != nil { return }
                        await MainActor.run { ToastNotice.show("The channel photo was not saved. Set it in Edit.") }
                    }
                }
                // The description and the invite link at the same time (owner 2026-10-29: Next took
                // too long; they went one after the other). The link is made BEFORE the Channel Type
                // page opens, which shows it (and its approval switch). One retry; the page can still
                // make one if both fail.
                async let described: Void = Self.describe(cid, desc)
                async let linked: Void = Self.makeLink(cid)
                _ = await (described, linked)
                creating = false
                // Step 3 REPLACES this page: Back can never make a second channel.
                if embedded { embeddedTypeCid = cid } else { path = [.type(cid)] }
            } catch {
                self.error = "Could not create the channel. Try again."
                creating = false
            }
        }
    }

    private static func describe(_ cid: String, _ text: String) async {
        if !text.isEmpty { try? await ChatService.setGroupDescription(cid: cid, text: text) }
    }

    private static func makeLink(_ cid: String) async {
        if (try? await GroupInviteService.createPrimaryLink(cid: cid)) == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = try? await GroupInviteService.createPrimaryLink(cid: cid)
        }
    }

    /// Done: into the channel.
    private func finish() {
        guard let cid = createdCid else { return }
        let target = ChatTarget(id: cid, name: trimmedName, photo: nil)
        // Pushed: New Message's own close (in `onOpen`) takes this page down with it.
        if !embedded { dismiss() }
        onOpen(target)
    }
}

/// New Channel's opening picture (owner 2026-10-29; 2026-10-30: "add fake photos, high end, not AI
/// slop"). What a channel looks like, all drawn here, no image files: one post on the front card with
/// a drawn sunset coast, its caption, reactions and views; two earlier posts fanned behind it (a
/// night city, a mountain lake). Landscapes only, no people. Decorative: VoiceOver skips it.
struct ChannelIntroPreview: View {
    private let blue = Color.fariinAction

    var body: some View {
        ZStack {
            photoCard { NightCityScene() }
                .rotationEffect(.degrees(-11)).offset(x: -78, y: -6)
            photoCard { LakeScene() }
                .rotationEffect(.degrees(10)).offset(x: 80, y: 4)
            post
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// An earlier post peeking out behind: just its photo, in a white frame.
    private func photoCard<S: View>(@ViewBuilder _ scene: () -> S) -> some View {
        scene()
            .frame(width: 150, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(5)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private var post: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ZStack {
                    SquircleShape().fill(LinearGradient(colors: [blue, Color(hex: 0x6C5CE7)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "megaphone.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your channel").font(.footnote.weight(.semibold))
                    Text("12.4K followers").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            SunsetScene()
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Golden hour on the coast tonight")
                .font(.footnote).lineLimit(1)
            HStack(spacing: 6) {
                chip("👍 248"); chip("❤️ 96")
                Spacer(minLength: 0)
                Image(systemName: "eye").font(.system(size: 10))
                Text("9.1K").font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(width: 214)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: blue.opacity(0.22), radius: 22, y: 10)
        .rotationEffect(.degrees(-1.5))
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

/// A ridge line across a scene: `points` are (x, y) in 0...1 of the box, filled down to the bottom.
private struct Ridge: Shape {
    let points: [CGPoint]
    func path(in r: CGRect) -> Path {
        func at(_ q: CGPoint) -> CGPoint { CGPoint(x: r.minX + q.x * r.width, y: r.minY + q.y * r.height) }
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        guard let first = points.first else { return p }
        p.addLine(to: at(first))
        for k in 1..<points.count {
            let a = at(points[k - 1]), b = at(points[k])
            p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        if let last = points.last { p.addLine(to: at(last)) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private func ridgePoints(_ a: [(CGFloat, CGFloat)]) -> [CGPoint] { a.map { CGPoint(x: $0.0, y: $0.1) } }

/// Sun low over the sea, headlands either side, the sun's path on the water.
private struct SunsetScene: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3B2A6B), Color(hex: 0xC8507A), Color(hex: 0xF6A35B), Color(hex: 0xFFD89A)],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.64))
                Circle().fill(RadialGradient(colors: [Color(hex: 0xFFF3C4).opacity(0.85), .clear],
                                             center: .center, startRadius: 0, endRadius: h * 0.55))
                    .frame(width: h * 1.1, height: h * 1.1).position(x: w * 0.6, y: h * 0.62)
                Circle().fill(Color(hex: 0xFFF1C9)).frame(width: h * 0.26, height: h * 0.26)
                    .position(x: w * 0.6, y: h * 0.6)
                // the sea, from the horizon down
                Rectangle().fill(LinearGradient(colors: [Color(hex: 0xE58A6A), Color(hex: 0x5A3D7A), Color(hex: 0x2A2350)],
                                                startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h * 0.36).position(x: w / 2, y: h * 0.82)
                ForEach(0..<5, id: \.self) { k in
                    Capsule().fill(Color(hex: 0xFFE3A8).opacity(0.75 - Double(k) * 0.12))
                        .frame(width: h * (0.24 - CGFloat(k) * 0.03), height: 2)
                        .position(x: w * 0.6, y: h * (0.69 + CGFloat(k) * 0.055))
                }
                Ridge(points: ridgePoints([(0, 0.5), (0.12, 0.44), (0.26, 0.56), (0.36, 0.65), (0.42, 0.66)]))
                    .fill(Color(hex: 0x2B1E45))
                    .frame(width: w * 0.42, height: h).position(x: w * 0.21, y: h / 2)
                Ridge(points: ridgePoints([(0, 0.66), (0.4, 0.56), (0.8, 0.48), (1, 0.5)]))
                    .fill(Color(hex: 0x33244F))
                    .frame(width: w * 0.22, height: h).position(x: w * 0.89, y: h / 2)
            }
        }
    }
}

/// Towers at night with lit windows, stars and a moon.
private struct NightCityScene: View {
    private let towers: [(x: CGFloat, w: CGFloat, top: CGFloat)] =
        [(0.0, 0.2, 0.5), (0.17, 0.16, 0.34), (0.32, 0.2, 0.58), (0.5, 0.15, 0.26), (0.63, 0.2, 0.46), (0.81, 0.19, 0.38)]

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: 0x0B1330), Color(hex: 0x23306B), Color(hex: 0x6B4E9B)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(0..<14, id: \.self) { k in
                    Circle().fill(Color.white.opacity(0.4 + Double(k % 3) * 0.2))
                        .frame(width: 1.6 + CGFloat(k % 2), height: 1.6 + CGFloat(k % 2))
                        .offset(x: CGFloat((k * 37) % 100) / 100 * w, y: CGFloat((k * 23) % 30) / 100 * h + 6)
                }
                Circle().fill(Color(hex: 0xF3EEDB)).frame(width: w * 0.16, height: w * 0.16)
                    .shadow(color: Color(hex: 0xF3EEDB).opacity(0.7), radius: 10)
                    .offset(x: w * 0.7, y: h * 0.1)
                ForEach(0..<towers.count, id: \.self) { k in
                    tower(seed: k)
                        .frame(width: towers[k].w * w, height: (1 - towers[k].top) * h)
                        .offset(x: towers[k].x * w, y: towers[k].top * h)
                }
            }
        }
    }

    private func tower(seed: Int) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(LinearGradient(colors: [Color(hex: 0x1C2350), Color(hex: 0x0E1230)],
                                            startPoint: .top, endPoint: .bottom))
            VStack(spacing: 5) {
                ForEach(0..<14, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill((r * 7 + c * 5 + seed * 3) % 4 != 0
                                      ? Color(hex: 0xFFD27A).opacity(0.85) : Color.white.opacity(0.06))
                                .frame(height: 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 4).padding(.top, 6)
        }
        .clipped()
    }
}

/// Snow peaks over a still lake, their faded reflection, and a dark tree line.
private struct LakeScene: View {
    private let peaks = ridgePoints([(0, 0.52), (0.18, 0.3), (0.32, 0.42), (0.52, 0.16), (0.7, 0.4), (0.86, 0.3), (1, 0.46)])

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x6FB7F2), Color(hex: 0xBFE3FA), Color(hex: 0xEAF6FD)],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))
                Ridge(points: peaks)
                    .fill(LinearGradient(colors: [.white, Color(hex: 0x9CB3C9), Color(hex: 0x5E7891)],
                                         startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6)))
                Ridge(points: ridgePoints([(0, 0.6), (0.25, 0.55), (0.5, 0.6), (0.75, 0.54), (1, 0.58)]))
                    .fill(Color(hex: 0x2F5D50))
                // the lake below the tree line
                Rectangle().fill(LinearGradient(colors: [Color(hex: 0x4F8FBF), Color(hex: 0x24506F)],
                                                startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h * 0.36).position(x: w / 2, y: h * 0.82)
                Ridge(points: peaks)
                    .fill(Color.white.opacity(0.16))
                    .frame(width: w, height: h * 0.6)
                    .scaleEffect(x: 1, y: -1)
                    .position(x: w / 2, y: h * 0.64 + h * 0.3)
                    .mask(Rectangle().frame(width: w, height: h * 0.36).position(x: w / 2, y: h * 0.82))
                ForEach(0..<3, id: \.self) { k in
                    Capsule().fill(Color.white.opacity(0.35)).frame(width: w * 0.3, height: 1.2)
                        .position(x: w * (0.3 + CGFloat(k) * 0.2), y: h * (0.74 + CGFloat(k) * 0.07))
                }
            }
        }
    }
}

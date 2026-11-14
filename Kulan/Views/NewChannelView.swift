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
    /// The name that half-made group was created with: a retry after the name changed renames it.
    @State private var halfMadeTitle = ""
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
    // The picture stays ours: since 2026-11-09 the "grow your channel" illustration with its gently
    // swaying bouquet (ChannelIntroPreview). The three feature rows are gone.
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
                        Text("Plant an idea. Watch it grow.")
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
                    .font(.caption).foregroundStyle(.secondary)   // owner 2026-11-09: one size smaller
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
                    // No photo yet: straight to the library, no Take/Choose menu (owner 2026-11-11).
                    // With one set, the menu stays so it can be changed or removed.
                    Button {
                        nameFocused = false
                        if avatarData == nil { showPhotoPicker = true } else { showPhotoOptions = true }
                    } label: { avatarThumb }
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
            // Owner 2026-11-14: the keyboard did not open here. One set of the focus can be dropped
            // while the Form cell is still being laid out after the push, so ask again until it
            // holds (three tries, 250 ms apart). Going back cancels the task, so no keyboard opens
            // over the page being left.
            for _ in 0..<3 {
                if Task.isCancelled || nameFocused { break }
                nameFocused = true
                try? await Task.sleep(for: .milliseconds(250))
            }
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
                    // The name may have changed since the failed try: the group takes the new one.
                    // (The description is written after the channel step, so it is always the current one.)
                    if title != halfMadeTitle {
                        try await ChatService.renameGroup(cid: half, title: title)
                        halfMadeTitle = title
                    }
                } else {
                    cid = try await ChatService.createGroup(title: title, memberIds: [], permissions: ["onlyAdminsSend": true],
                                                            createdText: "Channel created")
                    halfMadeCid = cid
                    halfMadeTitle = title
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
                // Reactions start ON with the default set picked (owner 2026-11-07), the same switch the
                // Reactions page shows. Best effort: a channel without it reads as any emoji until changed.
                let newCid = cid
                Task {
                    _ = try? await ChannelService.setReactions(
                        cid: newCid, mode: "some",
                        list: Array(ChannelReactionsSettingsView.palette.prefix(ChannelReactionsSettingsView.perRow)))
                }
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

/// New Channel's opening picture (owner 2026-11-09, approved on the Pixel first): a woman waters a
/// phone planted in a pot, and a bouquet of posts grows out of it. One illustration in two layers of
/// the same canvas (ChannelIntro-base, ChannelIntro-bouquet). The bouquet sways gently from the soil
/// line, a horizontal skew anchored there, so that row never moves and the two layers never part.
/// It sits straight on the page in light and dark; its white sticker edge outlines it on black.
/// Still under Reduce Motion. Decorative: VoiceOver skips it.
struct ChannelIntroPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The soil line, as a fraction of the picture's height (920 of 1657 px in the source art).
    fileprivate static let pivot: CGFloat = 920.0 / 1657.0
    /// How far the top row travels each way, as a fraction of the picture's width (18 of 1329 px).
    fileprivate static let reach: CGFloat = 18.0 / 1329.0
    private static let period: Double = 4

    var body: some View {
        // 30 frames a second is plenty for a 4 s sway and half the work of 60.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let s = reduceMotion ? 0 : CGFloat(sin(t * 2 * .pi / Self.period))
            ZStack {
                Image("ChannelIntro-base").resizable().scaledToFit()
                Image("ChannelIntro-bouquet").resizable().scaledToFit()
                    .modifier(ChannelIntroSway(amount: s))
            }
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// The sway: row y moves sideways by `amount * reach * width * (pivotY - y) / pivotY`, so the soil
/// row (pivotY) stays put and the top row moves the most. `amount` runs -1...1.
private struct ChannelIntroSway: GeometryEffect {
    var amount: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let py = ChannelIntroPreview.pivot * size.height
        guard py > 0 else { return ProjectionTransform() }
        let k = -amount * ChannelIntroPreview.reach * size.width / py
        // x' = x + k * (y - py)
        return ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: k, d: 1, tx: -k * py, ty: 0))
    }
}

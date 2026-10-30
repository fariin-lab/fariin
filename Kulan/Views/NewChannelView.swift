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
    @FocusState private var nameFocused: Bool

    /// The reference app's limits: 255 for the description; our group names already stop at 100.
    static let nameMax = 100
    static let aboutMax = 255

    private var trimmedName: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameMax))
    }

    var body: some View {
        NavigationStack(path: $path) {
            intro
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .details: details
                    case .type(let cid):
                        // Next opens the channel (owner 2026-10-29: a Share sheet that came up by itself
                        // and finished the same whether used or swiped away was confusing). Sharing is
                        // the Share button on the owner's card at the top of the channel.
                        GroupTypeView(cid: cid, setupNext: { finish() },
                                      localPhoto: avatarData.flatMap(UIImage.init(data:)))
                    }
                }
        }
        // No swipe-away once the channel is being made or made (owner 2026-10-30 audit): a swipe on
        // Channel Type skipped `finish()`, and one mid-creation landed on a page that then jumped.
        .interactiveDismissDisabled(creating || createdCid != nil)
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
                    .tint(Color(hex: 0x2392FE))
                Button { path.append(.details) } label: {
                    Text("Create Channel").fontWeight(.semibold).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .liquidGlass(Capsule(), interactive: true, tint: Color(hex: 0x2392FE))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
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
                .buttonStyle(.borderedProminent).tint(.blue)
            }
        }
        .task {
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
                SquircleShape().fill(Color.accentColor.opacity(0.12))
                Image("ic_group_camera").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 28, height: 28).foregroundStyle(Color.accentColor)
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
            if let r = try? await Functions.functions(region: "me-central1").httpsCallable("groupCreateCheck").call(),
               let d = r.data as? [String: Any], d["ok"] as? Bool == false {
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
                path = [.type(cid)]
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
        dismiss()
        onOpen(target)
    }
}

/// New Channel's opening picture (owner 2026-10-29): what a channel looks like, drawn from our own
/// parts. A channel's header, one post with lines for its words, its reactions and its views, on a
/// soft blue card. Decorative: VoiceOver skips it, the three points under it say the same.
struct ChannelIntroPreview: View {
    private let blue = Color(hex: 0x2392FE)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [blue, blue.opacity(0.65)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "megaphone.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your channel").font(.subheadline.weight(.semibold))
                    Text("12.4K followers").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "bell").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [blue.opacity(0.35), blue.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 74)
                    .overlay(Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(blue.opacity(0.7)))
                line(0.92); line(0.7)
                HStack(spacing: 6) {
                    chip("👍 248"); chip("❤️ 96")
                    Spacer(minLength: 0)
                    Image(systemName: "eye").font(.system(size: 11))
                    Text("9.1K").font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(14)
        .frame(maxWidth: 300)
        .background(blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(blue.opacity(0.15), lineWidth: 1))
        .rotationEffect(.degrees(-2))
        .shadow(color: blue.opacity(0.18), radius: 18, y: 8)
        .accessibilityHidden(true)
    }

    private func line(_ fraction: CGFloat) -> some View {
        GeometryReader { g in
            Capsule().fill(Color(.tertiarySystemFill)).frame(width: g.size.width * fraction, height: 8)
        }
        .frame(height: 8)
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

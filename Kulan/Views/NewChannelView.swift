import SwiftUI
import FirebaseFunctions

/// NEW CHANNEL (owner 2026-10-28). The reference app's order, our words and our parts:
/// 1. what a channel is, 2. photo + name + description on one page (Next lights up with a name),
/// 3. Channel Type (`GroupTypeView` in setup mode: public link or private invite link, restrict
/// saving), 4. add followers (`AddPeopleSheet`, skippable), then the channel opens.
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
    @State private var addFollowers = false
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
                        GroupTypeView(cid: cid) { addFollowers = true }
                    }
                }
        }
        .sheet(isPresented: $addFollowers, onDismiss: finish) {
            AddPeopleSheet(alreadyIn: [], actionTitle: "Add Followers") { people in
                guard let cid = createdCid else { return }
                let uids = people.map(\.uid)
                Task {
                    guard let r = try? await ChannelService.addFollowers(cid: cid, uids: uids) else {
                        ToastNotice.show("Could not add followers. Try again from the channel.")
                        return
                    }
                    if !r.refused.isEmpty {
                        ToastNotice.show(r.refused.count == 1
                            ? "1 person's settings don't allow being added."
                            : "\(r.refused.count) people's settings don't allow being added.")
                    }
                }
            }
        }
    }

    // MARK: 1. What a channel is

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "megaphone.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color(hex: 0x2392FE))
                .frame(width: 132, height: 132)
                .background(Circle().fill(Color(hex: 0x2392FE).opacity(0.12)))
            Text("Channels").font(.title.bold())
            Text("Share news and updates with as many people as you like. Only you and your admins post; everyone else follows.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button { path.append(.details) } label: {
                Text("Create Channel").fontWeight(.semibold).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .liquidGlass(Capsule(), interactive: true, tint: Color(hex: 0x2392FE))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
                Text("Optional. Tell people what your channel is about.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("New Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { create() } label: {
                    Text("Next").fontWeight(.semibold)
                        .opacity(creating ? 0 : 1)
                        .overlay { if creating { ProgressView().tint(.white) } }
                }
                .disabled(trimmedName.isEmpty && !creating)
                .buttonStyle(.borderedProminent).tint(.blue)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(600))   // after the push (NewGroupView's lesson)
            if !Task.isCancelled { nameFocused = true }
        }
        .confirmationDialog("Channel Photo", isPresented: $showPhotoOptions, titleVisibility: .hidden) {
            Button("Take Photo") { showCamera = true }
            Button("Choose Photo") { showPhotoPicker = true }
            if avatarData != nil { Button("Remove Photo", role: .destructive) { avatarData = nil } }
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
                                circleSubtitle: "Shown in chats and on the channel page")
                .ignoresSafeArea()
        }
    }

    private var avatarThumb: some View {
        ZStack {
            if let avatarData, let ui = UIImage(data: avatarData) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Circle().fill(Color.accentColor.opacity(0.12))
                Image("ic_group_camera").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 28, height: 28).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .contentShape(Circle())
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
                let cid = try await ChatService.createGroup(title: title, memberIds: [], permissions: ["onlyAdminsSend": true],
                                                           createdText: "Channel created")
                // The group's write may still be on its way to the server: a few tries.
                var made = false
                for attempt in 0..<6 {
                    if (try? await ChannelService.makeChannel(cid: cid)) != nil { made = true; break }
                    try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
                }
                guard made else {
                    error = "Could not create the channel. Try again."
                    creating = false
                    return
                }
                createdCid = cid
                if !desc.isEmpty { try? await ChatService.setGroupDescription(cid: cid, text: desc) }
                // The photo after the channel exists; a failed photo never undoes the channel.
                if let photo {
                    Task.detached(priority: .utility) {
                        if (try? await ChatService.uploadGroupAvatar(cid: cid, data: photo)) != nil { return }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if (try? await ChatService.uploadGroupAvatar(cid: cid, data: photo)) != nil { return }
                        await MainActor.run { ToastNotice.show("The channel photo was not saved. Set it in Edit.") }
                    }
                }
                // Its invite link, made BEFORE the Channel Type page opens, which shows it (and its
                // approval switch). One retry; the page can still make one if both fail.
                if (try? await GroupInviteService.createPrimaryLink(cid: cid)) == nil {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    _ = try? await GroupInviteService.createPrimaryLink(cid: cid)
                }
                creating = false
                // Step 3 REPLACES this page: Back can never make a second channel.
                path = [.type(cid)]
            } catch {
                self.error = "Could not create the channel. Try again."
                creating = false
            }
        }
    }

    /// Done (followers added, or skipped): into the channel.
    private func finish() {
        guard let cid = createdCid else { return }
        let target = ChatTarget(id: cid, name: trimmedName, photo: nil)
        dismiss()
        onOpen(target)
    }
}

import SwiftUI
import PhotosUI
import FirebaseFirestore   // Timestamp, for building the live preview out of the draft

// THE SENDING SCREENS. The reference app has no equivalent — its release notes are a JSON file somebody
// uploads to a CDN by hand — so none of this is a copy of anything. What it must not do is invent a
// second design language: every screen here is a plain grouped List with the same rows, the same
// section footers and the same confirmation style as Settings, because that is what it is a part of.
//
// The screens are hidden unless this account has a row in `admins`, and every write behind them is
// refused independently by the Firestore rules. Hiding is for tidiness; the rules are the security.

struct AnnouncementAdminView: View {
    private var admin = AdminStore.shared
    private var config = OfficialConfig.shared

    @State private var history: [Announcement] = []
    @State private var loading = true
    @State private var compose = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button { compose = true } label: {
                    Label("New Announcement", systemImage: "square.and.pencil")
                }
                .disabled(!admin.can(.send))
            } footer: {
                if !admin.can(.send) {
                    Text("Your account cannot send announcements. Ask the owner for permission.")
                }
            }

            if loading {
                Section { HStack { ProgressView(); Text("Loading").foregroundStyle(.secondary) } }
            } else if history.isEmpty {
                Section {
                    Text("Nothing sent yet.").foregroundStyle(.secondary)
                }
            } else {
                Section("Sent") {
                    ForEach(history) { a in
                        NavigationLink { AnnouncementDetailView(announcement: a, onChanged: reload) } label: {
                            AnnouncementHistoryRow(announcement: a)
                        }
                    }
                }
            }

            if admin.isOwner {
                Section {
                    NavigationLink { AdminTeamView() } label: {
                        Label("Admins", systemImage: "person.2")
                    }
                    NavigationLink { AppStoreLinkView() } label: {
                        HStack {
                            Label("Update Link", systemImage: "arrow.down.app")
                            Spacer()
                            // Both branches spelled as Color. A bare `.secondary` is a
                            // HierarchicalShapeStyle and `.red` is a Color, so the ternary has no
                            // common type and the compiler says so at length.
                            Text(config.hasAppStoreUrl ? "Set" : "Not set")
                                .foregroundStyle(config.hasAppStoreUrl ? Color.secondary : Color.red)
                        }
                    }
                } header: {
                    Text("Owner")
                } footer: {
                    Text("The Update Link is where an \"Update Now\" button sends people. Until it is set, announcements cannot use that button.")
                }
            }
        }
        .navigationTitle("Announcements")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $compose) {
            AnnouncementComposeView(draft: AnnouncementAdmin.Draft(), onDone: reload)
        }
        .alert("Could not load", isPresented: Binding(get: { error != nil },
                                                      set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func reload() { Task { await load() } }

    private func load() async {
        history = await AnnouncementAdmin.history()
        loading = false
    }
}

// MARK: - One row in the history

private struct AnnouncementHistoryRow: View {
    let announcement: Announcement

    private var status: (String, Color) {
        if announcement.deleted { return ("Deleted", .red) }
        if announcement.publishAt > Date() { return ("Scheduled", .orange) }
        if let e = announcement.expiresAt, e <= Date() { return ("Expired", .secondary) }
        return ("Sent", .green)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: announcement.kind.icon).font(.caption)
                Text(announcement.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            }
            Text(announcement.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Text(status.0).font(.caption2.weight(.semibold)).foregroundStyle(status.1)
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                Text(announcement.audience.summary).font(.caption2).foregroundStyle(.secondary)
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                Text(announcement.sortAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - One announcement, after the fact

private struct AnnouncementDetailView: View {
    let announcement: Announcement
    var onChanged: () -> Void

    private var admin = AdminStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var reads: Int?
    @State private var confirmDelete = false
    @State private var editing = false
    @State private var error: String?
    @State private var working = false

    init(announcement: Announcement, onChanged: @escaping () -> Void) {
        self.announcement = announcement
        self.onChanged = onChanged
    }

    var body: some View {
        List {
            Section("How it looks") {
                AnnouncementRow(announcement: announcement, dark: scheme == .dark,
                                onImageTap: { _ in }, onButtonTap: { _ in })
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section("Delivery") {
                LabeledContent("Sent to", value: announcement.audience.summary)
                LabeledContent("When", value: announcement.sortAt.formatted(date: .abbreviated, time: .shortened))
                if announcement.audience.minBuild > 0 {
                    LabeledContent("Minimum build", value: "\(announcement.audience.minBuild)")
                }
                if let e = announcement.expiresAt {
                    LabeledContent("Stops showing", value: e.formatted(date: .abbreviated, time: .shortened))
                }
                if let editedAt = announcement.editedAt {
                    LabeledContent("Edited", value: editedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                HStack {
                    Text("Opened by")
                    Spacer()
                    if let reads { Text("\(reads)").foregroundStyle(.secondary) }
                    else { ProgressView() }
                }
            } footer: {
                // Say plainly what this number is and is not, because "read receipts" in a messenger
                // normally means names, and here it deliberately never can.
                Text("How many people have opened this announcement. For a broadcast only the count is recorded, never who.")
            }

            if admin.can(.edit) || admin.can(.remove) {
                Section {
                    if admin.can(.edit) && !announcement.deleted {
                        Button("Edit") { editing = true }
                    }
                    if admin.can(.remove) && !announcement.deleted {
                        Button("Delete for everyone", role: .destructive) { confirmDelete = true }
                            .disabled(working)
                    }
                } footer: {
                    if announcement.deleted {
                        Text("This announcement has been taken back. It no longer shows in anybody's chat.")
                    } else if announcement.audience.scope == .chosen {
                        Text("This went to chosen people. Deleting it here removes the copy every one of them holds.")
                    }
                }
            }
        }
        .navigationTitle(announcement.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { reads = await AnnouncementStats.readTotal(announcement.id) }
        .sheet(isPresented: $editing) {
            AnnouncementComposeView(draft: draftFromExisting(), editing: true, onDone: {
                onChanged()
                dismiss()
            })
        }
        .alert("Delete this announcement?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It disappears from everybody's Fariin chat. Phones that are offline right now will remove it when they come back.")
        }
        .alert("Could not do that", isPresented: Binding(get: { error != nil },
                                                         set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func draftFromExisting() -> AnnouncementAdmin.Draft {
        var d = AnnouncementAdmin.Draft()
        d.id = announcement.id
        d.kind = announcement.kind
        d.title = announcement.title
        d.body = announcement.body
        d.buttons = announcement.buttons
        d.audience = announcement.audience
        d.publishAt = announcement.publishAt
        d.expiresAt = announcement.expiresAt
        d.mediaUrl = announcement.mediaUrl
        d.mediaWidth = announcement.mediaWidth
        d.mediaHeight = announcement.mediaHeight
        return d
    }

    private func remove() {
        working = true
        Task {
            do {
                // A chosen send also left a copy in each recipient's own collection, and this screen
                // cannot know who they are — the shared document deliberately does not carry the
                // list. The tombstone therefore goes only on the shared document, and the phone's
                // merge is what makes that enough: a deletion on either copy deletes the announcement
                // (see OfficialChannelStore.recompute).
                try await AnnouncementAdmin.remove(announcement)
                await MainActor.run { onChanged(); dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; working = false }
            }
        }
    }
}

// MARK: - Writing one

struct AnnouncementComposeView: View {
    @State var draft: AnnouncementAdmin.Draft
    var editing: Bool = false
    var onDone: () -> Void

    private var admin = AdminStore.shared
    private var config = OfficialConfig.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var photoItem: PhotosPickerItem?
    @State private var scheduleOn = false
    @State private var expiryOn = false
    @State private var sending = false
    @State private var error: String?
    @State private var confirmSend = false

    init(draft: AnnouncementAdmin.Draft, editing: Bool = false, onDone: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.editing = editing
        self.onDone = onDone
        _scheduleOn = State(initialValue: draft.publishAt.timeIntervalSinceNow > 60)
        _expiryOn = State(initialValue: draft.expiresAt != nil)
    }

    /// The announcement as the reader will see it, built from the live draft. Not a mock-up: it is
    /// the same view the chat renders, so what is on this screen is what goes out.
    private var previewAnnouncement: Announcement {
        var map: [String: Any] = [
            "kind": draft.kind.rawValue,
            "title": draft.title.isEmpty ? "Title" : draft.title,
            "body": draft.body.isEmpty ? "Your message goes here." : draft.body,
            "buttons": draft.buttons.filter(\.isUsable).map(\.asMap),
            "audience": draft.audience.asMap,
            "publishAt": Timestamp(date: draft.publishAt),
        ]
        if let url = draft.mediaUrl { map["mediaUrl"] = url }
        if let w = draft.mediaWidth { map["mediaWidth"] = w }
        if let h = draft.mediaHeight { map["mediaHeight"] = h }
        return Announcement(id: draft.id, data: map)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Preview") {
                    // The picked-but-not-yet-uploaded picture cannot come from a url, so it is drawn
                    // here above the bubble rather than inside it. Everything else is the real thing.
                    if let image = draft.image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    AnnouncementRow(announcement: previewAnnouncement, dark: scheme == .dark,
                                    onImageTap: { _ in }, onButtonTap: { _ in })
                        .allowsHitTesting(false)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section("Type") {
                    Picker("Type", selection: $draft.kind) {
                        // Security is simply not offered to an admin who may not send one, rather
                        // than offered and refused later. The rules refuse it too.
                        ForEach(AnnouncementKind.allCases.filter { $0 != .security || admin.can(.security) }) { k in
                            Label(k.label, systemImage: k.icon).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Message") {
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .font(.system(size: 17, weight: .semibold))
                    TextField("Write the announcement", text: $draft.body, axis: .vertical)
                        .lineLimit(4...14)
                }

                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(draft.image == nil && draft.mediaUrl == nil ? "Add a Picture" : "Change Picture",
                              systemImage: "photo")
                    }
                    if draft.image != nil || draft.mediaUrl != nil {
                        Button("Remove Picture", role: .destructive) {
                            draft.image = nil
                            draft.mediaUrl = nil
                            draft.mediaWidth = nil
                            draft.mediaHeight = nil
                            photoItem = nil
                        }
                    }
                }

                buttonsSection

                Section {
                    NavigationLink {
                        AnnouncementAudienceView(audience: $draft.audience, chosen: $draft.chosen)
                    } label: {
                        HStack {
                            Text("Send to")
                            Spacer()
                            Text(audienceLabel).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(audienceFooter)
                }

                Section {
                    Toggle("Send later", isOn: $scheduleOn)
                        .disabled(!admin.can(.schedule))
                        .onChange(of: scheduleOn) { _, on in
                            draft.publishAt = on ? max(Date().addingTimeInterval(3600), draft.publishAt) : Date()
                        }
                    if scheduleOn {
                        DatePicker("Send at", selection: $draft.publishAt, in: Date()...)
                    }
                    Toggle("Stop showing after a date", isOn: $expiryOn)
                        .onChange(of: expiryOn) { _, on in
                            draft.expiresAt = on ? Date().addingTimeInterval(60 * 60 * 24 * 30) : nil
                        }
                    if expiryOn {
                        DatePicker("Stop at", selection: Binding(
                            get: { draft.expiresAt ?? Date().addingTimeInterval(60 * 60 * 24 * 30) },
                            set: { draft.expiresAt = $0 }), in: Date()...)
                    }
                } header: {
                    Text("Timing")
                } footer: {
                    if scheduleOn {
                        // Say it plainly. Scheduling here is convenience, not secrecy — the words are
                        // on the server the moment Send is tapped, exactly as the reference app's release-notes
                        // file is public the moment it is uploaded.
                        Text("The announcement is written to the server now and appears on phones at the time you pick. Do not schedule anything that must stay secret until then.")
                    }
                }

                if !admin.can(.schedule) {
                    Section { Text("Your account cannot schedule announcements.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(editing ? "Edit Announcement" : "New Announcement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Save" : (draft.isScheduled ? "Schedule" : "Send")) {
                        confirmSend = true
                    }
                    .fontWeight(.semibold)
                    .disabled(sending || draft.problem != nil)
                }
            }
            .overlay {
                if sending {
                    ZStack { Color.black.opacity(0.12).ignoresSafeArea(); ProgressView() }
                }
            }
            .onChange(of: photoItem) { _, item in loadPicked(item) }
            .alert(confirmTitle, isPresented: $confirmSend) {
                Button(editing ? "Save" : "Send") { send() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
            .alert("Could not send", isPresented: Binding(get: { error != nil },
                                                          set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .safeAreaInset(edge: .bottom) {
                if let problem = draft.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttonsSection: some View {
        Section {
            ForEach($draft.buttons) { $button in
                NavigationLink {
                    AnnouncementButtonEditor(button: $button)
                } label: {
                    HStack {
                        Text(button.label.isEmpty ? "Untitled button" : button.label)
                        Spacer()
                        Text(button.action.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { draft.buttons.remove(atOffsets: $0) }

            if draft.buttons.count < 3 {
                Button {
                    draft.buttons.append(AnnouncementButton(label: "", action: .link, value: ""))
                } label: {
                    Label("Add a Button", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Buttons")
        } footer: {
            // The reference app allows exactly one. Three is where a row of buttons stops fitting a phone, and
            // the owner asked for "Update Now / Learn More / View Features", which is three.
            Text(config.hasAppStoreUrl
                 ? "Up to three. They appear under the message."
                 : "Up to three. \"Update the app\" is unavailable until the owner sets the Update Link.")
        }
    }

    // MARK: Audience labels

    private var audienceLabel: String {
        switch draft.audience.scope {
        case .everyone:  return draft.audience.ppm >= 1_000_000 ? "Everyone" : "Some of everyone"
        case .countries: return draft.audience.countries.isEmpty ? "Pick countries" : draft.audience.summary
        case .chosen:    return draft.chosen.isEmpty ? "Pick people" : "\(draft.chosen.count) chosen"
        }
    }

    private var audienceFooter: String {
        switch draft.audience.scope {
        case .everyone:
            return "One message, read by every phone. Sending to a million people costs the same as sending to one."
        case .countries:
            // Be honest about what "country" means here. We have no location and not every account
            // has a phone number, so the only country we know is the one the phone is set to.
            return "Matched against the country each phone is set to. People who have their phone set to another country will not see it."
        case .chosen:
            return "A private copy for each person, and nobody else can read it. Use this to test an announcement on yourself before it goes to everybody."
        }
    }

    private var confirmTitle: String {
        if editing { return "Save changes?" }
        return draft.isScheduled ? "Schedule this announcement?" : "Send to \(audienceLabel.lowercased())?"
    }

    private var confirmMessage: String {
        if editing {
            return "Phones that already have this announcement will show the new words."
        }
        if draft.isScheduled {
            return "It will appear at \(draft.publishAt.formatted(date: .abbreviated, time: .shortened))."
        }
        switch draft.audience.scope {
        case .everyone:  return "This goes to everybody using Fariin. It cannot be unsent, only deleted afterwards."
        case .countries: return "This goes to \(draft.audience.summary). It cannot be unsent, only deleted afterwards."
        case .chosen:    return "This goes to \(draft.chosen.count) \(draft.chosen.count == 1 ? "person" : "people")."
        }
    }

    // MARK: Doing it

    private func loadPicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let ui = UIImage(data: data) else { return }
            await MainActor.run {
                draft.image = ui
                draft.mediaWidth = Double(ui.size.width)
                draft.mediaHeight = Double(ui.size.height)
            }
        }
    }

    private func send() {
        sending = true
        Task {
            do {
                try await AnnouncementAdmin.publish(draft, editing: editing)
                await MainActor.run { sending = false; onDone(); dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; sending = false }
            }
        }
    }
}

// MARK: - One button

private struct AnnouncementButtonEditor: View {
    @Binding var button: AnnouncementButton
    private var config = OfficialConfig.shared

    init(button: Binding<AnnouncementButton>) { _button = button }

    var body: some View {
        List {
            Section("Label") {
                TextField("Update Now", text: $button.label)
            }
            Section("What it does") {
                Picker("Action", selection: $button.action) {
                    ForEach(AnnouncementButton.Action.allCases) { a in
                        Text(a.label).tag(a)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            switch button.action {
            case .link:
                Section {
                    TextField("https://fariin.com/...", text: $button.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("Must start with http or https. People are asked to confirm before it opens.")
                }
            case .appStore:
                Section {
                    if config.hasAppStoreUrl {
                        Text(config.appStoreUrl).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("The owner has not set the Update Link yet, so this button would open nothing. Set it in Announcements → Update Link.")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Opens")
                }
            case .screen:
                Section("Opens") {
                    Picker("Screen", selection: Binding(
                        get: { AnnouncementButton.Screen(rawValue: button.value) ?? .appearance },
                        set: { button.value = $0.rawValue })) {
                        ForEach(AnnouncementButton.Screen.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
        .navigationTitle("Button")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Who gets it

private struct AnnouncementAudienceView: View {
    @Binding var audience: AnnouncementAudience
    @Binding var chosen: [UserProfile]

    private var admin = AdminStore.shared
    @State private var search = ""
    @State private var results: [UserProfile] = []
    @State private var searching = false
    @State private var countrySearch = ""

    init(audience: Binding<AnnouncementAudience>, chosen: Binding<[UserProfile]>) {
        _audience = audience
        _chosen = chosen
    }

    /// A struct rather than a tuple because Swift has no key paths into tuple elements, and `ForEach`
    /// needs one to identify a row.
    private struct Country: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// Regions the phone can name, sorted by name. Not a hardcoded list: the system already knows
    /// every country and how to spell it in the reader's language.
    ///
    /// Built ONCE. As a computed property this ran on every body evaluation, which means roughly
    /// three hundred locale lookups and a sort on every single keystroke in the search field below.
    private static let allCountries: [Country] = Locale.Region.isoRegions
        .filter { $0.subRegions.isEmpty }   // real countries, not continents
        .compactMap { r in
            guard let name = Locale.current.localizedString(forRegionCode: r.identifier) else { return nil }
            return Country(code: r.identifier, name: name)
        }
        .sorted { $0.name < $1.name }

    private var filteredCountries: [Country] {
        let q = countrySearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.allCountries }
        return Self.allCountries.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section {
                ForEach(AnnouncementAudience.Scope.allCases) { scope in
                    Button {
                        audience.scope = scope
                    } label: {
                        HStack {
                            Text(scope.label).foregroundStyle(.primary)
                            Spacer()
                            if audience.scope == scope {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .disabled(!allowed(scope))
                }
            } footer: {
                if !admin.can(.targetCountry) || !admin.can(.targetChosen) {
                    Text("Some options are off for your account. Ask the owner for permission.")
                }
            }

            switch audience.scope {
            case .everyone:
                rolloutSection
            case .countries:
                Section {
                    TextField("Search countries", text: $countrySearch)
                    ForEach(Array(filteredCountries.prefix(60))) { c in
                        Button {
                            if let i = audience.countries.firstIndex(of: c.code) {
                                audience.countries.remove(at: i)
                            } else {
                                audience.countries.append(c.code)
                            }
                        } label: {
                            HStack {
                                Text(c.name).foregroundStyle(.primary)
                                Spacer()
                                if audience.countries.contains(c.code) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text(audience.countries.isEmpty ? "Countries" : "Countries (\(audience.countries.count))")
                }
                rolloutSection
            case .chosen:
                Section {
                    TextField("Search by username", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: search) { _, q in runSearch(q) }
                    if searching { ProgressView() }
                    ForEach(results) { person in
                        Button {
                            toggle(person)
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: person.name, photoUrl: person.photoUrl, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(person.name).foregroundStyle(.primary)
                                        VerifiedMark(uid: person.id, size: 12)
                                    }
                                    Text("@\(person.handle)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chosen.contains(where: { $0.id == person.id }) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Find people")
                }
                if !chosen.isEmpty {
                    Section("Chosen (\(chosen.count))") {
                        ForEach(chosen) { person in
                            HStack(spacing: 10) {
                                AvatarView(name: person.name, photoUrl: person.photoUrl, size: 32)
                                Text(person.name)
                                VerifiedMark(uid: person.id, size: 12)
                                Spacer()
                                Text("@\(person.handle)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { chosen.remove(atOffsets: $0) }
                    }
                }
            }
        }
        .navigationTitle("Send to")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The reference app's unit, kept because it is the right one: a percentage of PEOPLE, decided by hashing
    /// each person's id with the announcement's, so the same people stay in the rollout every launch
    /// and the server never has to remember who was picked.
    @ViewBuilder private var rolloutSection: some View {
        Section {
            let percent = Double(audience.ppm) / 10_000
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("How many")
                    Spacer()
                    Text(audience.ppm >= 1_000_000 ? "Everyone" : String(format: "%.0f%%", percent))
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(audience.ppm) },
                    set: { audience.ppm = Int($0) }), in: 10_000...1_000_000, step: 10_000)
            }
        } footer: {
            Text("Below 100%, each phone decides for itself using its own id, so the same people keep getting it and nobody has to be tracked.")
        }
    }

    private func allowed(_ scope: AnnouncementAudience.Scope) -> Bool {
        switch scope {
        case .everyone:  return true
        case .countries: return admin.can(.targetCountry)
        case .chosen:    return admin.can(.targetChosen)
        }
    }

    private func toggle(_ person: UserProfile) {
        if let i = chosen.firstIndex(where: { $0.id == person.id }) { chosen.remove(at: i) }
        else { chosen.append(person) }
    }

    private func runSearch(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { results = []; return }
        searching = true
        Task {
            let found = await AnnouncementAdmin.searchPeople(query)
            await MainActor.run {
                // Only overwrite if this is still the query being typed, or a slow round trip
                // repopulates the list with stale results after the person has moved on.
                guard query == search.trimmingCharacters(in: .whitespaces) else { return }
                results = found
                searching = false
            }
        }
    }
}

// MARK: - The admin team (owner only)

private struct AdminTeamView: View {
    @State private var admins: [AdminRecord] = []
    @State private var loading = true
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                Section { HStack { ProgressView(); Text("Loading").foregroundStyle(.secondary) } }
            } else {
                Section {
                    ForEach(admins) { record in
                        if record.isOwner {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(record.name.isEmpty ? "Owner" : record.name)
                                        VerifiedMark(uid: record.id, size: 13)
                                    }
                                    Text("@\(record.handle)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Owner").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        } else {
                            NavigationLink {
                                AdminPermissionsView(record: record, onChanged: reload)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(record.name.isEmpty ? "Admin" : record.name)
                                        VerifiedMark(uid: record.id, size: 13)
                                    }
                                    Text(permissionSummary(record)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Admins")
                } footer: {
                    // The rule worth stating out loud, because it is the one that keeps this safe.
                    Text("Only you can add or remove admins, and nobody can be made an owner. Your own row cannot be changed from inside the app.")
                }

                Section {
                    Button { adding = true } label: { Label("Add an Admin", systemImage: "person.badge.plus") }
                }
            }
        }
        .navigationTitle("Admins")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) { AddAdminView(onDone: reload) }
        .alert("Could not do that", isPresented: Binding(get: { error != nil },
                                                         set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func permissionSummary(_ r: AdminRecord) -> String {
        if r.perms.isEmpty { return "No permissions" }
        if r.perms.count == AdminPermission.allCases.count { return "Everything" }
        return "\(r.perms.count) of \(AdminPermission.allCases.count) permissions"
    }

    private func reload() { Task { await load() } }

    private func load() async {
        admins = await AnnouncementAdmin.admins()
        loading = false
    }
}

private struct AdminPermissionsView: View {
    let record: AdminRecord
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var perms: Set<String>
    @State private var confirmRemove = false
    @State private var error: String?

    init(record: AdminRecord, onChanged: @escaping () -> Void) {
        self.record = record
        self.onChanged = onChanged
        _perms = State(initialValue: Set(record.perms))
    }

    var body: some View {
        List {
            Section {
                ForEach(AdminPermission.allCases) { p in
                    Toggle(isOn: Binding(
                        get: { perms.contains(p.rawValue) },
                        set: { on in
                            if on { perms.insert(p.rawValue) } else { perms.remove(p.rawValue) }
                            save()
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.label)
                            Text(p.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("What \(record.name.isEmpty ? "this admin" : record.name) can do")
            } footer: {
                Text("Turning everything off leaves the account an admin who can do nothing, which is a way to stand somebody down without removing them.")
            }

            Section {
                Button("Remove Admin", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(record.handle.isEmpty ? "Admin" : "@\(record.handle)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Remove this admin?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They keep their Fariin account. They just stop being able to send announcements.")
        }
        .alert("Could not save", isPresented: Binding(get: { error != nil },
                                                      set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func save() {
        Task {
            do {
                try await AnnouncementAdmin.setPermissions(record, perms: AdminPermission.allCases.filter { perms.contains($0.rawValue) })
                onChanged()
            } catch {
                await MainActor.run { self.error = error.localizedDescription; perms = Set(record.perms) }
            }
        }
    }

    private func remove() {
        Task {
            do {
                try await AnnouncementAdmin.removeAdmin(record)
                await MainActor.run { onChanged(); dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

private struct AddAdminView: View {
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [UserProfile] = []
    @State private var picked: UserProfile?
    @State private var perms: Set<String> = Set(AdminPermission.starter.map(\.rawValue))
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Find the person") {
                    TextField("Username", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: search) { _, q in runSearch(q) }
                    ForEach(results) { person in
                        Button { picked = person } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: person.name, photoUrl: person.photoUrl, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(person.name).foregroundStyle(.primary)
                                        VerifiedMark(uid: person.id, size: 12)
                                    }
                                    Text("@\(person.handle)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if picked?.id == person.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                Section {
                    ForEach(AdminPermission.allCases) { p in
                        Toggle(isOn: Binding(
                            get: { perms.contains(p.rawValue) },
                            set: { on in if on { perms.insert(p.rawValue) } else { perms.remove(p.rawValue) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.label)
                                Text(p.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("What they can do")
                } footer: {
                    Text("A new admin starts with sending and scheduling. Hand over the rest as you trust them with it.")
                }
            }
            .navigationTitle("Add an Admin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .disabled(picked == nil || saving)
                }
            }
            .alert("Could not add", isPresented: Binding(get: { error != nil },
                                                         set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func runSearch(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { results = []; return }
        Task {
            let found = await AnnouncementAdmin.searchPeople(query)
            await MainActor.run {
                guard query == search.trimmingCharacters(in: .whitespaces) else { return }
                results = found
            }
        }
    }

    private func add() {
        guard let picked else { return }
        saving = true
        Task {
            do {
                try await AnnouncementAdmin.addAdmin(picked, perms: AdminPermission.allCases.filter { perms.contains($0.rawValue) })
                await MainActor.run { onDone(); dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; saving = false }
            }
        }
    }
}

// MARK: - Where "Update Now" points

private struct AppStoreLinkView: View {
    private var config = OfficialConfig.shared
    @State private var url = ""
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("https://apps.apple.com/app/id...", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text("Fariin is not on the App Store yet, so this cannot be built into the app. Set it once the app is published and every \"Update Now\" button will work from then on.")
            }
            Section {
                Button(saving ? "Saving" : "Save") { save() }
                    .disabled(saving || url.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved { Text("Saved").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Update Link")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if url.isEmpty { url = config.appStoreUrl } }
        .alert("Could not save", isPresented: Binding(get: { error != nil },
                                                      set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await OfficialConfig.shared.setAppStoreUrl(url)
                await MainActor.run { saving = false; saved = true }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; saving = false }
            }
        }
    }
}

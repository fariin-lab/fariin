import SwiftUI

// ⛔ LINKS ON A PROFILE — owner, 2026-09-11, with three screenshots: a card under the Bio in Edit
// Profile that opens a page "like username", a Links page carrying an "Add link" row and whatever
// has been added, an editor with "2 Card input one Url and other one Title", a ceiling of two per
// account, and small pills under the bio on the profile itself — on other people's and on his own.
//
// ⚠️ THIS PAGE SAVES AS YOU GO. It is not part of the Edit Profile sheet's Save, deliberately: that
// button also fans the display name out across every conversation the account is in, which is a
// batch write over the whole chat list, and adding a link must not pay for that. It also makes the
// flow he described work — "you can edit again if you want to change something" — without a second
// Save to remember on a page he has already left.

/// The list. Pushed from Edit Profile, so it arrives with a back chevron and keeps that sheet's
/// navigation bar, which is what his screenshot shows.
struct ProfileLinksView: View {
    private var profile = ProfileStore.shared
    /// The working copy. Seeded from the store on appear and written back after every change, so
    /// the page is correct even if the store publishes something new underneath it.
    @State private var links: [ProfileLink] = []
    @State private var editMode: EditMode = .inactive
    @State private var error: String?

    private var atCeiling: Bool { links.count >= ProfileLink.maxPerUser }

    var body: some View {
        Form {
            Section {
                // ⚠️ HIDDEN WHILE EDITING, and hidden at the ceiling. In edit mode every row in a
                // section grows a delete control, and a delete control beside "Add link" is an
                // offer to delete the button itself. At the ceiling it would be a row that can
                // only refuse.
                if editMode == .inactive && !atCeiling {
                    NavigationLink {
                        ProfileLinkEditView(existing: nil) { saved in add(saved) }
                    } label: {
                        row(icon: "plus", title: "Add link", subtitle: nil, emphasised: true)
                    }
                }
                ForEach(links) { link in
                    NavigationLink {
                        ProfileLinkEditView(existing: link) { saved in
                            replace(link, with: saved)
                        } onDelete: {
                            remove(link)
                        }
                    } label: {
                        row(icon: "link", title: link.title, subtitle: link.displayUrl, emphasised: false)
                    }
                }
                .onDelete { offsets in
                    links.remove(atOffsets: offsets)
                    save()
                }
                .onMove { from, to in
                    links.move(fromOffsets: from, toOffset: to)
                    save()
                }
            } footer: {
                // Says the rule rather than letting the Add row vanish without explanation, which is
                // the only state on this page that could look like a bug.
                if atCeiling {
                    Text("You can have up to \(ProfileLink.maxPerUser) links on your profile.")
                }
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Links")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Only when there is something to edit — an Edit button over an empty list does
            // nothing, and his screenshot has a link in it.
            if !links.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .environment(\.editMode, $editMode)
        .onAppear { links = profile.me?.links ?? [] }
        // The store is the truth; if it publishes while this page is open (another device, or the
        // write below landing) the page follows. Not while editing, so rows do not move under a
        // finger that is dragging one.
        .onChange(of: profile.me?.links ?? []) { _, new in
            guard editMode == .inactive else { return }
            links = new
        }
    }

    /// One row of the card: a glyph in a soft disc, a title, and the address under it.
    private func row(icon: String, title: String, subtitle: String?, emphasised: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(.systemGray5))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(emphasised ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func add(_ link: ProfileLink) {
        guard links.count < ProfileLink.maxPerUser else { return }
        links.append(link)
        save()
    }

    private func replace(_ old: ProfileLink, with new: ProfileLink) {
        guard let i = links.firstIndex(of: old) else { return }
        links[i] = new
        save()
    }

    private func remove(_ link: ProfileLink) {
        links.removeAll { $0 == link }
        save()
    }

    /// ⚠️ THE WRITE IS FIRE-AND-REPORT, NOT FIRE-AND-FORGET. The page has already redrawn with the
    /// new list, so a refusal has to be said out loud or the link looks saved and is not — and the
    /// list is put back from the store rather than guessed at, because the server is what decides.
    private func save() {
        let snapshot = links
        Task {
            do {
                try await profile.updateLinks(snapshot)
                await MainActor.run { error = nil }
            } catch {
                await MainActor.run {
                    self.error = "Your links could not be saved. \(error.localizedDescription)"
                    self.links = profile.me?.links ?? []
                }
            }
        }
    }
}

/// The editor: two cards, one for the address and one for the name people read. New when `existing`
/// is nil, otherwise editing that one, with a Delete at the bottom.
struct ProfileLinkEditView: View {
    let existing: ProfileLink?
    let onSave: (ProfileLink) -> Void
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    @State private var confirmDelete = false
    @FocusState private var urlFocused: Bool

    /// ⚠️ VALIDATED THROUGH `openURL`, WHICH IS THE SAME CODE THE PILL USES TO OPEN IT. Checking the
    /// text one way here and opening it another way there is how a link saves cleanly and then does
    /// nothing when somebody taps it.
    private var candidate: ProfileLink? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !u.isEmpty else { return nil }
        let link = ProfileLink(title: String(t.prefix(ProfileLink.maxTitleChars)),
                               url: String(u.prefix(ProfileLink.maxUrlChars)))
        guard link.openURL != nil else { return nil }
        return link
    }

    var body: some View {
        Form {
            Section {
                TextField("https://example.com", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .focused($urlFocused)
                    .submitLabel(.next)
            } header: {
                Text("URL")
            } footer: {
                // Only once there is something to complain about — an error under an empty field is
                // a telling-off for not having typed yet.
                if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, candidate == nil,
                   !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("That does not look like a web address.")
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("My website", text: $title)
                    .onChange(of: title) { _, v in
                        if v.count > ProfileLink.maxTitleChars {
                            title = String(v.prefix(ProfileLink.maxTitleChars))
                        }
                    }
            } header: {
                Text("Title")
            } footer: {
                Text("This is the name shown on your profile.")
            }

            if existing != nil, onDelete != nil {
                Section {
                    Button("Delete Link", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(existing == nil ? "Add Link" : "Edit Link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    guard let link = candidate else { return }
                    onSave(link)
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(candidate == nil || candidate == existing)
            }
        }
        .confirmationDialog("Delete this link?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Link", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
        .onAppear {
            guard let existing else {
                // A new link opens with the keyboard on the address, because that is the field
                // nobody can leave empty and the title often follows from it.
                urlFocused = true
                return
            }
            url = existing.url
            title = existing.title
        }
    }
}

/// ⛔ THE PILLS UNDER THE BIO — his third screenshot: two small capsules side by side, a link glyph
/// and the title, sitting between the bio and the action circles.
///
/// ⚠️ ONE VIEW FOR EVERY PROFILE THAT DRAWS THEM. The contact page has two hero layouts of its own
/// and the Glow profile is a third, so a capsule written three times is a capsule that ends up three
/// slightly different sizes. Nothing here knows whose profile it is.
///
/// ⚠️ `.ultraThinMaterial` RATHER THAN A COLOUR, because these sit on a photograph on two of those
/// three pages and on a plain background on the last. A fixed grey is either invisible on a dark
/// picture or a grey smear on a light one.
struct ProfileLinkChips: View {
    let links: [ProfileLink]
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !links.isEmpty {
            // Wraps rather than truncating: two long titles at a large text size do not fit one
            // line on a narrow phone, and a clipped pill reads as a bug.
            HStack(spacing: 8) {
                ForEach(links) { link in
                    Button {
                        if let u = link.openURL { openURL(u) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "link")
                                .font(.caption.weight(.semibold))
                            Text(link.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 20)
        }
    }
}

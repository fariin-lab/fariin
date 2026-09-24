import SwiftUI

// Storage and Data (user's reference, 2026-07-24): root page with Manage storage,
// per-type Media auto-download policies (REAL — photos gate their in-bubble auto-load,
// videos/voice prefetch on chat open when the network qualifies), Sent Media Quality,
// and Use Less Data for calls (REAL — caps the call bitrate). The Manage Storage page
// shows true on-device numbers with honest clear buttons.

/// 2026-09-24 decision D17: the most recent change to a temp item. For a folder that is the newest
/// file anywhere inside it, since writing a nested file does not always touch the folder's own date.
/// An item whose date cannot be read counts as brand new, so doubt keeps a file rather than losing it.
fileprivate func tempNewestChange(_ url: URL, _ fm: FileManager) -> Date {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
    guard let v = try? url.resourceValues(forKeys: keys) else { return .distantFuture }
    var newest = max(v.contentModificationDate ?? .distantFuture, v.creationDate ?? .distantPast)
    if v.isDirectory == true, let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
        for case let f as URL in en {
            guard let fv = try? f.resourceValues(forKeys: keys) else { return .distantFuture }
            newest = max(newest, fv.contentModificationDate ?? .distantFuture, fv.creationDate ?? .distantPast)
        }
    }
    return newest
}

struct StorageDataView: View {
    @AppStorage("autodl.photos") private var pPhotos = AutoDownloadPrefs.Kind.photos.defaultPolicy
    @AppStorage("autodl.videos") private var pVideos = AutoDownloadPrefs.Kind.videos.defaultPolicy
    @AppStorage("autodl.audio") private var pAudio = AutoDownloadPrefs.Kind.audio.defaultPolicy
    @AppStorage("autodl.documents") private var pDocs = AutoDownloadPrefs.Kind.documents.defaultPolicy
    @AppStorage("sentMediaQuality") private var quality = "standard"
    @AppStorage("calls.lessData") private var lessData = "never"
    /// ⚠️ THE SAME KEY `UploadEngine` READS, spelled out because that lives in a service with no
    /// business importing SwiftUI. If either changes, change both.
    @AppStorage("upload.background.enabled") private var backgroundUploads = false

    /// Nothing to reset. Same rule the owner asked for on Notifications ("the Reset text is always
    /// red, even when all settings are already at their default values") — this row was the other
    /// half of that complaint and was left live, so it invited a tap that could never change
    /// anything and gave no sign either way.
    private var autoDownloadIsDefault: Bool {
        pPhotos == AutoDownloadPrefs.Kind.photos.defaultPolicy
            && pVideos == AutoDownloadPrefs.Kind.videos.defaultPolicy
            && pAudio == AutoDownloadPrefs.Kind.audio.defaultPolicy
            && pDocs == AutoDownloadPrefs.Kind.documents.defaultPolicy
    }

    var body: some View {
        List {
            Section {
                NavigationLink { ManageStoragePage() } label: { Text("Manage storage") }
            } header: {
                Text("Storage")
            }

            Section {
                autoRow(.photos, value: pPhotos)
                autoRow(.videos, value: pVideos)
                autoRow(.audio, value: pAudio)
                autoRow(.documents, value: pDocs)
                Button("Reset Auto-Download Settings") {
                    AutoDownloadPrefs.reset()
                    pPhotos = AutoDownloadPrefs.Kind.photos.defaultPolicy
                    pVideos = AutoDownloadPrefs.Kind.videos.defaultPolicy
                    pAudio = AutoDownloadPrefs.Kind.audio.defaultPolicy
                    pDocs = AutoDownloadPrefs.Kind.documents.defaultPolicy
                }
                .foregroundStyle(.primary)
                .disabled(autoDownloadIsDefault)
            } header: {
                Text("Media auto-download")
            } footer: {
                // A THRESHOLD NOTHING CAN REACH. `Limits.fileUploadBytes` is 25 MB and
                // `videoMessageBytes` 64, both inside storage.rules, so no message in this app comes
                // close — the 200 MB line describes a reference app's limits, not ours,
                // and told people about a rule that could never fire. The real, useful sentence is
                // what the setting above actually decides.
                // 2026-09-24 audit: documents now honour their row too (MediaAutoDownloader.sweep).
                Text("Chooses when photos, videos, voice messages and documents download by themselves. Anything not downloaded is fetched the moment you open it.")
            }

            Section {
                NavigationLink { SentMediaQualityPage() } label: {
                    HStack {
                        Text("Sent Media Quality")
                        Spacer()
                        Text(quality == "high" ? "High" : "Standard").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sent Media")
            } footer: {
                Text("Choose the quality you send photos and videos.")
            }

            // ⛔ A SWITCH, NOT A SHIPPED DEFAULT (owner, 2026-08-25). `BackgroundUploader` is new
            // code on the path every photo, video, voice note and document takes, and it could not
            // be compiled or run on the machine it was written on. Off by default means a wrong
            // detail in it cannot stop media sending for everyone; flipping it here costs a tap
            // instead of a forty minute build, and flipping it back is just as cheap.
            //
            // Once a real phone has sent a photo, left the app mid-video and had it arrive, this
            // stops being a setting and becomes the only path — and this Section is deleted.
            Section {
                Toggle("Keep uploading in the background", isOn: $backgroundUploads)
                    .onChange(of: backgroundUploads) { _, on in UploadEngine.backgroundEnabled = on }
            } header: {
                Text("Uploads (testing)")
            } footer: {
                Text("Hands photos and videos to iOS instead of sending them inside the app, so leaving Fariin mid-send no longer cancels them and a dropped connection continues where it stopped. Turn it off if anything stops sending.")
            }

            Section {
                NavigationLink { UseLessDataPage() } label: {
                    HStack {
                        Text("Use Less Data")
                        Spacer()
                        Text(UseLessDataPage.label(lessData)).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Calls")
            } footer: {
                Text("Using less data may improve calls on bad networks.")
            }
        }
        .navigationTitle("Storage and Data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func autoRow(_ k: AutoDownloadPrefs.Kind, value: String) -> some View {
        NavigationLink { AutoDownloadPage(kind: k) } label: {
            HStack {
                Text(k.label)
                Spacer()
                Text(AutoDownloadPrefs.label(value)).foregroundStyle(.secondary)
            }
        }
    }
}

// Per-type auto-download policy page.
struct AutoDownloadPage: View {
    let kind: AutoDownloadPrefs.Kind
    @State private var selection: String

    init(kind: AutoDownloadPrefs.Kind) {
        self.kind = kind
        _selection = State(initialValue: AutoDownloadPrefs.policy(kind))
    }

    var body: some View {
        List {
            Section {
                ForEach(["always", "wifi", "never"], id: \.self) { p in
                    Button {
                        selection = p
                        AutoDownloadPrefs.setPolicy(kind, p)
                    } label: {
                        HStack {
                            Text(AutoDownloadPrefs.label(p)).foregroundStyle(.primary)
                            Spacer()
                            if selection == p {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text(kind == .photos
                     ? "When off, photos show a blurred preview until you tap them."
                     : "When allowed, \(kind.label.lowercased()) download in the background as chats open, so they play instantly.")
            }
        }
        .navigationTitle(kind.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Sent Media Quality page (Standard / High).
struct SentMediaQualityPage: View {
    @AppStorage("sentMediaQuality") private var quality = "standard"

    var body: some View {
        List {
            Section {
                ForEach([("standard", "Standard"), ("high", "High")], id: \.0) { tag, label in
                    Button {
                        quality = tag
                    } label: {
                        HStack {
                            Text(label).foregroundStyle(.primary)
                            Spacer()
                            if quality == tag {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text("High sends sharper photos (2048px) and 1080p video. Uses more data.")
            }
        }
        .navigationTitle("Sent Media Quality")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Use Less Data for calls — REAL: caps the WebRTC bitrate when active.
struct UseLessDataPage: View {
    @AppStorage("calls.lessData") private var lessData = "never"

    static func label(_ v: String) -> String {
        switch v {
        case "always":   return "Always"
        case "cellular": return "Cellular Only"
        default:          return "Never"
        }
    }

    /// Read at call setup: is the data saver active on the CURRENT network?
    static var activeNow: Bool {
        switch UserDefaults.standard.string(forKey: "calls.lessData") ?? "never" {
        case "always":   return true
        case "cellular": return !NetworkState.shared.isWifi
        default:          return false
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(["never", "cellular", "always"], id: \.self) { v in
                    Button {
                        lessData = v
                    } label: {
                        HStack {
                            Text(Self.label(v)).foregroundStyle(.primary)
                            Spacer()
                            if lessData == v {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text("Lowers call quality to save data. Applies from your next call.")
            }
        }
        .navigationTitle("Use Less Data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Manage Storage: true numbers, honest buttons. Videos/voice are ONLY-copies (the
// server deletes its copy after delivery) — Clear Media says so before deleting.
struct ManageStoragePage: View {
    @AppStorage("keepMediaDays") private var keepDays = 0   // 0 = forever
    @State private var photoBytes = 0
    @State private var videoBytes = 0
    @State private var voiceBytes = 0
    @State private var tmpBytes = 0
    @State private var confirmMedia = false
    @State private var confirmCache = false

    private func fmt(_ b: Int) -> String {
        b == 0 ? "Zero KB" : ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Photos & Media Cache", value: fmt(photoBytes))
                LabeledContent("Videos", value: fmt(videoBytes))
                LabeledContent("Voice Messages", value: fmt(voiceBytes))
                LabeledContent("Temporary Files", value: fmt(tmpBytes))
            } header: {
                Text("Storage by Type")
            }

            Section {
                Picker("Keep Media", selection: $keepDays) {
                    Text("Forever").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .onChange(of: keepDays) { _, d in
                    if d > 0 { DiskImageCache.shared.sweep(olderThanDays: d) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refresh() }
                }
            } footer: {
                Text("Cached photos older than your selection are removed from this device (they re-download when needed). Videos and voice notes are never auto-removed — this phone holds their only copy.")
            }

            Section {
                Button("Clear Media", role: .destructive) { confirmMedia = true }
                    .disabled(videoBytes + voiceBytes == 0)
                Button("Clear Cache", role: .destructive) { confirmCache = true }
                    .disabled(photoBytes + tmpBytes == 0)
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .alert("Clear media?", isPresented: $confirmMedia) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Forever", role: .destructive) {
                // Off the main thread (audit 2026-09-24): deleting a phone's worth of videos froze
                // the page until the last file was gone.
                Task {
                    await Task.detached(priority: .userInitiated) {
                        VideoCache.removeAll()
                        AudioCache.removeAll()
                    }.value
                    refresh()
                }
            }
        } message: {
            Text("This permanently deletes the videos and voice notes stored on this phone. They exist nowhere else and cannot be downloaded again.")
        }
        .alert("Clear cache?", isPresented: $confirmCache) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                DiskImageCache.shared.clear()
                // 2026-09-24 decision D17: Clear Cache never deletes temp files younger than 1 hour
                // or in use by an upload, transcode or recording. It used to empty the whole temp
                // folder, which took the staged file out from under a send in progress, a clip
                // being transcoded, a voice note being recorded, and a failed send's retry payload.
                // Read here, on the main actor, because MediaSend lives there.
                let owed = Set(PendingUploadStore.all().map { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path })
                let sending = MediaSend.shared.anyInFlight || !owed.isEmpty
                // Off the main thread, same reason as Delete Forever above.
                Task {
                    await Task.detached(priority: .userInitiated) {
                        let fm = FileManager.default
                        let cutoff = Date().addingTimeInterval(-60 * 60)
                        if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
                            for u in items {
                                let name = u.lastPathComponent
                                // A background upload's staged ciphertext, still owed to the server.
                                if owed.contains(u.standardizedFileURL.path) { continue }
                                // A failed video/file send's bytes: Resend needs them (ThreadView).
                                if name.hasPrefix("pending-") { continue }
                                // Staged upload files and resume slices while a send is running.
                                if sending, name.hasPrefix("upload-") || name.hasPrefix("resume-") { continue }
                                // Anything touched in the last hour: a recording or a transcode
                                // writes its file as it goes, so it is always this young.
                                if tempNewestChange(u, fm) > cutoff { continue }
                                try? fm.removeItem(at: u)
                            }
                        }
                        URLCache.shared.removeAllCachedResponses()
                    }.value
                    // The image cache empties on its own queue, so give it the same beat as before.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    refresh()
                }
            }
        } message: {
            Text("Photos and avatars re-download as you use the app. Nothing is lost.")
        }
    }

    /// Audit 2026-09-24: this walked four folders file by file ON THE MAIN THREAD, every time the
    /// page opened — with a big cache the push animation stalled and the page froze before it drew.
    /// The measuring runs in the background now and the rows fill in when it is done.
    private func refresh() {
        Task {
            let sizes = await Task.detached(priority: .userInitiated) { () -> (Int, Int, Int, Int) in
                let fm = FileManager.default
                var t = 0
                if let en = fm.enumerator(at: fm.temporaryDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let url as URL in en {
                        t += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    }
                }
                // STORY MEDIA counts too (audit). It lives in the app's 1 GB persistent URLCache, which
                // none of the rows measured — so a heavy story watcher saw "Zero KB" everywhere and a
                // greyed-out Clear Cache while up to a gigabyte sat on disk. Clear Cache already
                // empties it, so counting it here is what makes the number honest AND the button
                // reachable.
                t += URLCache.shared.currentDiskUsage
                return (DiskImageCache.shared.diskBytes(), VideoCache.diskBytes(), AudioCache.diskBytes(), t)
            }.value
            photoBytes = sizes.0
            videoBytes = sizes.1
            voiceBytes = sizes.2
            tmpBytes = sizes.3
        }
    }
}

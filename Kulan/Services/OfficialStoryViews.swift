import Foundation
import SwiftUI
import UIKit
import CryptoKit
import FirebaseAuth
import FirebaseFunctions
import FirebaseFirestore
import StoryUI

// ⛔ VIEWS OF FARIIN'S STORIES — owner 2026-10-18: "official stories need view counts, and admins must
// see who viewed: in the admin panel, and in the app for admin users".
//
// WHAT IS WRITTEN. Opening an official story frame writes one document,
// `officialStories/{id}/views/{viewId}`, once per story per account (the local set below, and the
// rules refuse a second write to the same document anyway). Everyone is counted; a viewer is NAMED
// only if their own story view receipts are on (`StoryReceiptPrefs`), the same switch that decides
// whether a friend's story gets a receipt:
//   on:  id = my uid, {at, named: true}
//   off: id = sha256(salt + uid) in lowercase hex, {at, named: false}. No uid is stored; the hash
//        only keeps one account from counting twice. The server's copy of the salt is
//        functions-admin lib/ostories.js `VIEW_SALT`; the two must stay the same.
// A view made with receipts off stays unnamed if receipts are turned on later (unlike a friend's
// story, where the server turns hidden views into receipts): there is no uid kept to turn back.
//
// WHO SEES THE LIST. Admins holding 'send', through the `officialStoryViews` callable (the panel has
// its own op). Here: a views pill in the official story's bottom row, the sheet below. Nobody else
// sees anything new.
enum OfficialStoryViews {
    static let salt = "fariin-oview-v1:"
    private static let prefix = "official-"

    /// The record's own id for an app-side official story id ("official-<id>"), or nil.
    static func rawId(_ storyId: String) -> String? {
        guard storyId.hasPrefix(prefix) else { return nil }
        let raw = String(storyId.dropFirst(prefix.count))
        return raw.isEmpty ? nil : raw
    }

    static func hashedId(uid: String) -> String {
        SHA256.hash(data: Data((salt + uid).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writing my view

    private static func seenKey(_ uid: String) -> String { "officialStoryViewed.\(uid)" }

    /// Called when an official story frame is actually watched (`StoriesService.markViewed`).
    /// Best effort: Firestore queues the write offline and sends it later; a refusal (the document
    /// is already there, from this account on another phone) is the right answer and is ignored.
    @MainActor
    static func record(_ story: Story) {
        guard let uid = Auth.auth().currentUser?.uid, let raw = rawId(story.id) else { return }
        let d = UserDefaults.standard
        // id -> expiry, so the set drops stories that have gone and never grows without end.
        var seen = (d.dictionary(forKey: seenKey(uid)) as? [String: Double]) ?? [:]
        guard seen[raw] == nil else { return }
        let now = Date().timeIntervalSince1970
        seen = seen.filter { $0.value > now - 86_400 }
        seen[raw] = story.expiresAt.timeIntervalSince1970
        d.set(seen, forKey: seenKey(uid))

        let named = StoryReceiptPrefs.isOn
        let viewId = named ? uid : hashedId(uid: uid)
        FirestoreHub.db.collection("officialStories").document(raw)
            .collection("views").document(viewId)
            .setData(["at": FieldValue.serverTimestamp(), "named": named]) { err in
                if let err { print("official story view not written:", err.localizedDescription) }
            }
        // My own view moves the count an admin is looking at.
        OfficialStoryViewsModel.shared.forget(raw)
    }

    // MARK: - Reading, for admins

    struct Viewer: Identifiable, Equatable {
        let id: String      // uid
        let name: String
        let handle: String
        var photoUrl: String = ""   // 2026-10-18 (owner): the sheet showed no faces
        let at: Date
    }
    struct Summary: Equatable {
        let count: Int
        let viewers: [Viewer]
        var unnamed: Int { max(0, count - viewers.count) }
    }

    static func fetch(rawId: String) async throws -> Summary {
        let result = try await Functions.functions(region: "me-central1")
            .httpsCallable("officialStoryViews").call(["id": rawId])
        let data = result.data as? [String: Any] ?? [:]
        let count = (data["count"] as? NSNumber)?.intValue ?? 0
        let rows = data["viewers"] as? [[String: Any]] ?? []
        let viewers: [Viewer] = rows.compactMap { r in
            guard let uid = r["uid"] as? String, !uid.isEmpty else { return nil }
            let at = (r["at"] as? NSNumber)?.doubleValue ?? 0
            return Viewer(id: uid, name: r["name"] as? String ?? "", handle: r["handle"] as? String ?? "",
                          photoUrl: r["photoUrl"] as? String ?? "",
                          at: Date(timeIntervalSince1970: at / 1000))
        }
        return Summary(count: count, viewers: viewers)
    }

    /// The pill the story's bottom row shows (`StoryFooterAccessory`): only on an official story, only
    /// for an admin holding 'send'. Read inside the row's body, so `AdminStore` being @Observable
    /// brings the pill in or takes it away when a permission changes.
    @MainActor
    static func installPill() {
        StoryFooterAccessory.view = { storyId in
            guard let raw = rawId(storyId) else { return nil }
            let canSee = AdminStore.shared.can(.send), canDelete = AdminStore.shared.can(.remove)
            guard canSee || canDelete else { return nil }
            // ⛔ THE ADMIN'S FOOTER (owner 2026-10-18): views on the left, Delete on the right, and no
            // "You can't reply" bar (MessageView leaves it out when this row is there).
            return AnyView(OfficialStoryAdminFooter(rawId: raw, storyId: storyId,
                                                    showsViews: canSee, canDelete: canDelete))
        }
    }

    /// The list, over the story, which holds still meanwhile (tagged, so only this sheet's close
    /// lifts that pause; same arrangement as a caption link's browser).
    @MainActor
    static func presentSheet(rawId: String) {
        guard let host = WebLink.topViewController() else { return }
        NotificationCenter.default.post(name: .init("pauseStory"), object: "officialViews")
        // ⛔ SOLID DARK GREY, NEVER GLASS (owner 2026-10-18, build 969: "the sheet is glass, I can't read
        // the names"). Over a bright story the see-through sheet put white text on a light picture.
        let ground = UIColor(white: 0.11, alpha: 1)
        let vc = UIHostingController(rootView: OfficialStoryViewersSheet(rawId: rawId)
            .preferredColorScheme(.dark)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: ground).ignoresSafeArea()))
        vc.overrideUserInterfaceStyle = .dark
        vc.view.backgroundColor = ground
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(vc, animated: true)
    }
}

/// Counts per story while the viewer is open, so the pill and the sheet agree and a page drawn
/// again does not ask the server again. Thirty seconds old is asked again.
@Observable
@MainActor
final class OfficialStoryViewsModel {
    static let shared = OfficialStoryViewsModel()
    private init() {}

    private(set) var summaries: [String: OfficialStoryViews.Summary] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    func forget(_ rawId: String) { fetchedAt[rawId] = nil }

    func load(_ rawId: String, force: Bool = false) {
        guard !inFlight.contains(rawId) else { return }
        if !force, let at = fetchedAt[rawId], Date().timeIntervalSince(at) < 30 { return }
        inFlight.insert(rawId)
        Task {
            defer { inFlight.remove(rawId) }
            do {
                let s = try await OfficialStoryViews.fetch(rawId: rawId)
                summaries[rawId] = s
                fetchedAt[rawId] = Date()
            } catch {
                print("official story views: fetch failed:", error.localizedDescription)
            }
        }
    }
}

/// Eye and "N Views", the look of my own story's footer (`StoryOwnerBarView`), at the left of the
/// official story's bottom row.
struct OfficialStoryViewsPill: View {
    let rawId: String
    @State private var m = OfficialStoryViewsModel.shared

    var body: some View {
        let count = m.summaries[rawId]?.count
        Button { OfficialStoryViews.presentSheet(rawId: rawId) } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye").font(.subheadline).foregroundStyle(.white)
                Text(count.map { "\($0) View\($0 == 1 ? "" : "s")" } ?? "Views")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onAppear { m.load(rawId) }
    }
}

/// Who watched: the named viewers, newest first, and one line for everybody counted without a name.
struct OfficialStoryViewersSheet: View {
    let rawId: String
    @State private var m = OfficialStoryViewsModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = m.summaries[rawId]
        NavigationStack {
            Group {
                if let s {
                    List {
                        if s.viewers.isEmpty {
                            Text(s.count == 0 ? "Nobody has watched this story yet." : "Nobody to name yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(s.viewers) { v in
                            HStack(spacing: 12) {
                                AvatarView(name: v.name, photoUrl: v.photoUrl.isEmpty ? nil : v.photoUrl, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name.isEmpty ? "No name" : v.name).font(.body).lineLimit(1)
                                    if !v.handle.isEmpty {
                                        Text("@\(v.handle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(v.at.formatted(.relative(presentation: .named)))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Section {
                        } footer: {
                            Text(footer(s))
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(s.map { "\($0.count) View\($0.count == 1 ? "" : "s")" } ?? "Views")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { m.load(rawId, force: true) }
        .onDisappear {
            NotificationCenter.default.post(name: .init("resumeStory"), object: "officialViews")
        }
    }

    private func footer(_ s: OfficialStoryViews.Summary) -> String {
        let n = s.unnamed
        if n == 0 { return "People who turned story view receipts off are counted but not listed." }
        return n == 1 ? "1 more person viewed with view receipts off."
                      : "\(n) more people viewed with view receipts off."
    }
}

/// Views pill, then Delete: what an admin sees under one of Fariin's stories.
struct OfficialStoryAdminFooter: View {
    let rawId: String
    let storyId: String
    let showsViews: Bool
    let canDelete: Bool
    @State private var asking = false
    @State private var deleting = false
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 12) {
            if showsViews { OfficialStoryViewsPill(rawId: rawId) }
            Spacer(minLength: 0)
            if canDelete {
                Button {
                    NotificationCenter.default.post(name: .init("pauseStory"), object: "officialDelete")
                    asking = true
                } label: {
                    Group {
                        if deleting { ProgressView().tint(.white) }
                        else { Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(.white) }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(deleting)
                .accessibilityLabel("Delete story")
            }
        }
        // The system alert in the middle of the screen (owner 2026-10-18), not the popover off the bin.
        .alert("Delete Story?", isPresented: $asking) {
            Button("Cancel", role: .cancel) { resume() }
            Button("Delete", role: .destructive) { delete() }
        } message: { Text("This story will be deleted for everyone.") }
        .alert("Couldn't delete", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { resume() }
        } message: { Text(failure ?? "") }
    }

    private func resume() {
        NotificationCenter.default.post(name: .init("resumeStory"), object: "officialDelete")
    }

    /// The server withdraws it for everyone (`officialStoryRemove`); this phone drops it at once.
    private func delete() {
        deleting = true
        Task { @MainActor in
            do {
                _ = try await Functions.functions(region: "me-central1")
                    .httpsCallable("officialStoryRemove").call(["id": rawId])
                deleting = false
                OfficialStories.shared.refresh(force: true)
                if !StoryDoor.dropStory(storyId) { StoryDoor.dismiss() }
            } catch {
                deleting = false
                let ns = error as NSError
                failure = ns.domain == FunctionsErrorDomain && !ns.localizedDescription.isEmpty
                    ? ns.localizedDescription : "Check your connection and try again."
            }
        }
    }
}

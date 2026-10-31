import Foundation
import UIKit
import Observation

/// ⛔ LEAVING A GROUP HAS AN UNDO (owner 2026-10-25, from the reference app's "You left the group.
/// Undo" bar). Tapping Leave used to run the leave at once and close only the info page, so he sat in
/// the chat of a group he had just left. Now: the group leaves the list and the screen at once, a bar
/// says so for 5 s, and the REAL leave only runs when that time is up, or the moment the app leaves
/// the screen, so an Undo costs nothing and a close within the window cannot lose the leave.
///
/// Why delayed and not "leave now, rejoin on Undo": a private group cannot be re-entered by its
/// ex-member (only an admin adds people), so a rejoin would fail for most groups.
///
/// ⛔ DELETING HAS THE SAME UNDO (owner 2026-10-31: "it takes a bit late to delete, and there is no
/// way to undo if you change your mind within seconds"). Delete Group / Delete Channel ride the same
/// path: gone from the screen and the list at the tap, "Group deleted. Undo" for 5 s, and the real
/// delete only after that, so Undo never has anything to put back on the server.
@MainActor @Observable
final class LeaveGroupUndo {
    static let shared = LeaveGroupUndo()

    enum Kind: String { case leave, deleteGroup, deleteChannel }

    /// Groups hidden from my lists and screens while their leave is waiting.
    private(set) var hiddenIds: Set<String> = []
    /// The bar: the group that was left and can still be taken back.
    private(set) var barTitle: String?
    /// What the bar is about: a leave or a delete.
    private(set) var barKind: Kind = .leave
    /// A leave that failed when it finally ran: shown so it is never silent.
    var failure: String?

    @ObservationIgnored private var pending: (cid: String, title: String, kind: Kind)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var resign: NSObjectProtocol?

    private init() {
        resign = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.commit() }
        }
        resumeLeftover()
    }

    // ⛔ A LEAVE IS NEVER LOST (audit 2026-10-25): the waiting leave is written down on the phone, so a
    // crash or a force-quit inside the 5 s runs it at the next launch, for the same account.
    private static let savedKey = "leaveGroupPending.v1"

    private func save(_ p: (cid: String, title: String, kind: Kind)?) {
        if let p, let uid = AuthService.shared.uid {
            UserDefaults.standard.set(["uid": uid, "cid": p.cid, "title": p.title, "kind": p.kind.rawValue],
                                      forKey: Self.savedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        }
    }

    private func resumeLeftover() {
        guard let d = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: String],
              let uid = d["uid"], let cid = d["cid"] else { return }
        let title = d["title"] ?? "the group"
        let kind = Kind(rawValue: d["kind"] ?? "") ?? .leave
        hiddenIds.insert(cid)
        Task { @MainActor [weak self] in
            // Signed in as that account first (up to 30 s); another account never runs it.
            for _ in 0..<60 where AuthService.shared.uid == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self else { return }
            guard AuthService.shared.uid == uid else {
                self.hiddenIds.remove(cid)
                if AuthService.shared.uid != nil { self.save(nil) }
                return
            }
            self.pending = (cid, title, kind)
            self.commit()
        }
    }

    /// A group or channel I deleted (owner 2026-10-29): off my list and screens at once, which closes
    /// its chat (ThreadView watches `hiddenIds`). Nothing to undo; the server already removed it.
    func closeChat(_ cid: String) { hiddenIds.insert(cid) }
    /// Back in it (a channel followed again): it shows in the list again.
    func reopen(_ cid: String) { if pending?.cid != cid { hiddenIds.remove(cid) } }

    /// Hide the group now; leave for real in 5 s unless `undo()` comes first. A second leave while one
    /// is waiting commits the first straight away, so two bars never stack.
    func start(cid: String, title: String, kind: Kind = .leave) {
        if pending != nil { commit() }
        pending = (cid, title, kind)
        save(pending)
        hiddenIds.insert(cid)
        barKind = kind
        barTitle = title
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    /// Taken back: nothing was ever sent to the server, so the group simply comes back.
    func undo() {
        timer?.cancel(); timer = nil
        if let p = pending { hiddenIds.remove(p.cid) }
        pending = nil
        save(nil)
        barTitle = nil
    }

    /// Run the leave. The group stays hidden through it; on a failure it comes back, with the reason.
    func commit() {
        timer?.cancel(); timer = nil
        guard let p = pending else { return }
        pending = nil
        barTitle = nil
        // Time to finish when this runs because the app is going away (audit 2026-10-25).
        let bg = BackgroundTime(name: "group-leave")
        Task { @MainActor [weak self] in
            defer { bg.end() }
            do {
                switch p.kind {
                case .leave: try await ChatService.leaveGroup(cid: p.cid)
                case .deleteGroup, .deleteChannel: try await GroupInviteService.deleteGroup(cid: p.cid)
                }
                self?.save(nil)
                // Leave it hidden a moment longer: the list drops it when the server's copy arrives.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.hiddenIds.remove(p.cid)
            } catch {
                // Shown and given back; not retried at every launch.
                self?.save(nil)
                self?.hiddenIds.remove(p.cid)
                let what = p.kind == .leave ? "leave" : "delete"
                self?.failure = "Couldn't \(what) \"\(p.title)\". Check your connection and try again."
            }
        }
    }
}

/// One stretch of background time, ended once whichever comes first: the work or the system's limit.
@MainActor private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

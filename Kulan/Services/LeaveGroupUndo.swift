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
@MainActor @Observable
final class LeaveGroupUndo {
    static let shared = LeaveGroupUndo()

    /// Groups hidden from my lists and screens while their leave is waiting.
    private(set) var hiddenIds: Set<String> = []
    /// The bar: the group that was left and can still be taken back.
    private(set) var barTitle: String?
    /// A leave that failed when it finally ran: shown so it is never silent.
    var failure: String?

    @ObservationIgnored private var pending: (cid: String, title: String)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var resign: NSObjectProtocol?

    private init() {
        resign = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.commit() }
        }
    }

    /// Hide the group now; leave for real in 5 s unless `undo()` comes first. A second leave while one
    /// is waiting commits the first straight away, so two bars never stack.
    func start(cid: String, title: String) {
        if pending != nil { commit() }
        pending = (cid, title)
        hiddenIds.insert(cid)
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
        barTitle = nil
    }

    /// Run the leave. The group stays hidden through it; on a failure it comes back, with the reason.
    func commit() {
        timer?.cancel(); timer = nil
        guard let p = pending else { return }
        pending = nil
        barTitle = nil
        Task { @MainActor [weak self] in
            do {
                try await ChatService.leaveGroup(cid: p.cid)
                // Leave it hidden a moment longer: the list drops it when the server's copy arrives.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.hiddenIds.remove(p.cid)
            } catch {
                self?.hiddenIds.remove(p.cid)
                self?.failure = "Couldn't leave \"\(p.title)\". \(error.localizedDescription)"
            }
        }
    }
}

import SwiftUI
import UIKit

/// ⏱ WHERE OPENING A CHAT SPENDS ITS TIME, ON SCREEN (owner 2026-10-28). One restored group froze
/// about half a second between the tap and the push, with a black band under the tab bar, and
/// neither the wallpaper nor the long message was it. Admins only: a small box at the top of the
/// chat lists each step after the tap in ms, plus the longest frame gap (the freeze) and when it
/// ended. Tap the box to hide it. Also written to DiagLog. Remove once the cause is found.
@MainActor final class ChatOpenTimer: NSObject, ObservableObject {
    static let shared = ChatOpenTimer()

    @Published private(set) var lines: [String] = []
    @Published var visible = false
    private var tapAt: CFTimeInterval = 0
    private var running = false
    private var once: Set<String> = []
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var worstGap: CFTimeInterval = 0
    private var worstEnd: CFTimeInterval = 0
    private var hideTask: Task<Void, Never>?

    static var enabled: Bool { AdminStore.shared.isAdmin }

    func begin(_ what: String) {
        guard Self.enabled else { return }
        tapAt = CACurrentMediaTime()
        running = true
        once = []
        lines = ["tap \(what)"]
        worstGap = 0; worstEnd = 0
        lastFrame = tapAt
        link?.invalidate()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        DiagLog.add("CHATOPEN +0ms tap \(what)")
    }

    /// A step, with the ms since the tap. Ignored when no open is being timed.
    func mark(_ what: String) {
        guard running else { return }
        let ms = Int((CACurrentMediaTime() - tapAt) * 1000)
        lines.append("+\(ms) \(what)")
        DiagLog.add("CHATOPEN +\(ms)ms \(what)")
    }

    /// The same, the first time only (for code that runs on every update).
    func markOnce(_ what: String) {
        guard running, !once.contains(what) else { return }
        once.insert(what)
        mark(what)
    }

    @objc private func tick(_ l: CADisplayLink) {
        MainActor.assumeIsolated {
            let now = l.timestamp
            let gap = now - lastFrame
            if gap > worstGap { worstGap = gap; worstEnd = now }
            lastFrame = now
            // Three seconds is long past any push; then the summary and the box.
            guard now - tapAt > 3 else { return }
            link?.invalidate(); link = nil
            mark("longest freeze \(Int(worstGap * 1000))ms, ended at +\(Int((worstEnd - tapAt) * 1000))")
            running = false
            visible = true
            DiagLog.flagForUpload(after: 2)
            hideTask?.cancel()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self?.visible = false
            }
        }
    }
}

/// The box at the top of the chat. Nothing for anyone who is not an admin.
struct ChatOpenTimerBox: View {
    @ObservedObject private var timer = ChatOpenTimer.shared

    var body: some View {
        if timer.visible {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(timer.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 110)
            .padding(.horizontal, 12)
            .onTapGesture { timer.visible = false }
        }
    }
}

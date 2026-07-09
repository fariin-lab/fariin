import Foundation

// Where each chat was last scrolled to — kept in memory ONLY (never written to disk).
//
// This is exactly WhatsApp's behavior: while the app stays alive, reopening a chat lands you
// right where you left it (mid-history or bottom); once the app is killed the RAM is wiped, so a
// cold launch finds nothing here and falls back to the newest message. No persistence needed —
// the in-memory lifetime IS the feature.
//
// Main-actor only (touched from ThreadView's scroll callbacks).
enum ChatScrollAnchor: Equatable {
    case bottom            // was sitting on the newest message
    case message(String)   // was reading history — the id of the top-most visible message
}

final class ChatScrollStore {
    static let shared = ChatScrollStore()
    private init() {}
    private var byCid: [String: ChatScrollAnchor] = [:]

    func save(_ cid: String, _ anchor: ChatScrollAnchor) { byCid[cid] = anchor }
    func anchor(for cid: String) -> ChatScrollAnchor? { byCid[cid] }
}

// Reference box so per-row onAppear/onDisappear can update the visible-id set WITHOUT invalidating
// the SwiftUI body on every scroll tick (the same non-invalidating-box trick used elsewhere for
// gesture-adjacent flags). Reset per ThreadView instance.
final class VisibleRowsBox { var ids: Set<String> = [] }

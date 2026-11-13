import Foundation
import CoreLocation
import FirebaseAuth
import FirebaseFirestore

/// Live location (owner 2026-11-13; one contract with Android, plan 2026-11-13-live-location-plan.md).
///
/// Where a sharer is NOW lives in `conversations/{cid}/live/{uid}`, one doc per sharer per chat:
/// `{msgId, until, ended, updatedAt, pos}`, overwritten on each update, no history. In a 1:1 `pos`
/// is the JSON `{lat, lon, acc}` sealed with the chat's message crypto (the server cannot read it);
/// in a group it is a plain map. The rules allow only the sharer to write, at most 8 h, and after
/// `until` only `ended: true` with no `pos`; the server's liveSweep ends anything a phone left behind.
struct LiveSpot: Identifiable, Equatable {
    let uid: String
    let lat: Double
    let lon: Double
    let updatedAt: Date
    let until: Date
    var id: String { uid }
}

/// What a chat's card needs from a live doc. One rule with Android (2026-11-13): a card runs while its
/// own end is ahead AND (no doc; or the doc is not ended and is this share, ends within 2 s of the
/// card; or the doc belongs to an older share).
struct LiveDocState: Equatable {
    let until: Date
    let ended: Bool

    static func running(card until: Date, doc: LiveDocState?) -> Bool {
        guard until > Date() else { return false }
        guard let doc else { return true }
        if doc.ended { return false }
        if abs(doc.until.timeIntervalSince(until)) < 2 { return true }
        return doc.until < until
    }
}

enum LiveDocs {
    static func ref(cid: String, uid: String) -> DocumentReference {
        Firestore.firestore().collection("conversations").document(cid).collection("live").document(uid)
    }

    /// One live doc read into a spot, or nil when it is over or cannot be opened.
    static func spot(_ d: DocumentSnapshot, cid: String) -> LiveSpot? {
        guard let data = d.data(), (data["ended"] as? Bool) != true,
              let until = (data["until"] as? Timestamp)?.dateValue(), until > Date() else { return nil }
        var lat: Double?, lon: Double?
        if let m = data["pos"] as? [String: Any] {
            lat = (m["lat"] as? NSNumber)?.doubleValue
            lon = (m["lon"] as? NSNumber)?.doubleValue
        } else if let sealed = data["pos"] as? String {
            let plain = cid.contains("_") ? Crypto.shared.decrypt(sealed, cid: cid) : sealed
            if let obj = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any] {
                lat = (obj["lat"] as? NSNumber)?.doubleValue
                lon = (obj["lon"] as? NSNumber)?.doubleValue
            }
        }
        guard let lat, let lon else { return nil }
        let at = (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        return LiveSpot(uid: d.documentID, lat: lat, lon: lon, updatedAt: at, until: until)
    }
}

/// This phone's live shares: one CLLocationManager for all of them, background updates while any is
/// running (When-In-Use only: iOS shows the blue location pill), and each share stops at its end.
@MainActor
final class LiveLocationSharer: NSObject, CLLocationManagerDelegate {
    static let shared = LiveLocationSharer()

    struct Share { let cid: String; let msgId: String; let until: Date }
    private(set) var shares: [String: Share] = [:]   // by cid
    private let manager = CLLocationManager()
    private var last: CLLocation?
    private var lastSent: [String: Date] = [:]
    private var stopTimer: Timer?
    private var beat: Timer?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters   // balanced, not GPS-max
        manager.distanceFilter = 20
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    func isSharing(cid: String) -> Bool {
        guard let s = shares[cid] else { return false }
        return s.until > Date()
    }

    /// Starts sharing in `cid` until `until`. The card message is sent by the caller (ThreadView).
    func start(cid: String, msgId: String, until: Date, first: CLLocation?) {
        shares[cid] = Share(cid: cid, msgId: msgId, until: until)
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if let first { last = first }
        if let loc = first ?? last { Task { await write(cid: cid, loc: loc, force: true) } }
        scheduleStop()
        if beat == nil {
            beat = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.heartbeat() }
            }
        }
    }

    /// Stop (in one chat, or everywhere with nil): the doc says ended and loses its position.
    func stop(cid: String?) {
        let gone = cid.map { [$0] } ?? Array(shares.keys)
        guard let uid = Auth.auth().currentUser?.uid else { return }
        for c in gone {
            let msgId = shares[c]?.msgId ?? ""
            let end = shares[c]?.until ?? Date()   // the share's own end, as Android writes it
            shares[c] = nil
            LiveDocs.ref(cid: c, uid: uid).setData([
                "msgId": msgId, "until": Timestamp(date: end), "ended": true,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
        }
        if shares.isEmpty { quiet() }
    }

    private func quiet() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        stopTimer?.invalidate(); stopTimer = nil
        beat?.invalidate(); beat = nil
    }

    private func scheduleStop() {
        stopTimer?.invalidate()
        guard let next = shares.values.map(\.until).min() else { return }
        stopTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endExpired() }
        }
    }

    private func endExpired() {
        let over = shares.values.filter { $0.until <= Date() }.map(\.cid)
        for c in over { stop(cid: c) }
        scheduleStop()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.last = loc
            for c in self.shares.keys { await self.write(cid: c, loc: loc, force: false) }
            self.endExpired()
        }
    }

    /// One update: at most every 15 s while moving, at least every 2 min while still.
    private func write(cid: String, loc: CLLocation, force: Bool) async {
        guard let s = shares[cid], s.until > Date(), let uid = Auth.auth().currentUser?.uid else { return }
        if !force, let t = lastSent[cid], Date().timeIntervalSince(t) < 15 { return }
        lastSent[cid] = Date()
        let posMap: [String: Any] = ["lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude,
                                     "acc": loc.horizontalAccuracy]
        let pos: Any
        if cid.contains("_") {
            guard let json = try? JSONSerialization.data(withJSONObject: posMap),
                  let sealed = try? await Crypto.shared.encryptForConversation(cid, String(decoding: json, as: UTF8.self))
            else { return }
            pos = sealed
        } else {
            pos = posMap
        }
        try? await LiveDocs.ref(cid: cid, uid: uid).setData([
            "msgId": s.msgId, "until": Timestamp(date: s.until), "ended": false,
            "updatedAt": FieldValue.serverTimestamp(), "pos": pos,
        ])
    }

    /// A still phone sends nothing new by itself; this keeps "Updated" fresh (every 2 min).
    func heartbeat() {
        guard let loc = last else { return }
        for c in shares.keys { Task { await write(cid: c, loc: loc, force: true) } }
    }
}

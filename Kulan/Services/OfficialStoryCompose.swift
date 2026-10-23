import Foundation
import Observation
import UIKit
import AVFoundation
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions

/// ⛔ FARIIN'S STORY, POSTED FROM THE APP — owner 2026-10-18: "admins see an Add story button on
/// Fariin's page; it uploads the way normal stories do, the same camera and editor, but Fariin has
/// more: a link and how long it stays up, 6 / 12 / 24 / 48 h".
///
/// The camera and the editor are the normal ones. `active` is the one switch that tells the last
/// step (`ShareStorySheet`) to show Fariin's form instead of the audience list, and to post through
/// here instead of `StoriesService`. It is set by the "+" on Fariin's page and cleared when the
/// camera closes, so a normal Add Story can never land on Fariin's form.
///
/// The files go where the admin panel puts them, `officialStories/{id}/media.jpg | media.mp4 +
/// thumb.jpg` (storage.rules lets an `admins/{uid}` row write there), and then the server's
/// `officialStoryPost` checks the admin's rights, makes the record and hands out the links. No phone
/// writes the record itself.
@MainActor
enum OfficialStoryCompose {
    static private(set) var active = false

    /// The choices the server accepts (`ostories.PHONE_HOURS`).
    static let hourChoices = [6, 12, 24, 48]

    static func open() {
        guard AdminStore.shared.can(.send) else { return }
        StoryCameraDoor.open(official: true)
    }

    /// Only `StoryCameraDoor.open` sets it, once a camera has really been presented.
    static func setActive(_ on: Bool) { active = on }

    /// Called when the camera goes away, whichever way.
    static func end() { active = false }

    struct Draft {
        var buttonText = ""
        var buttonUrl = ""
        var hours = 24
        /// Who sees it, the admin panel's three (owner 2026-10-23): "everyone", "welcome" (new
        /// accounts only) or "countries" (`countries`, two-letter codes; needs Choose countries).
        var scope = "everyone"
        var countries: [String] = []
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// A picture story: the editor's rendered JPEG.
    static func postPhoto(_ jpeg: Data, caption: String, draft: Draft) async throws {
        guard let img = UIImage(data: jpeg), let cg = img.cgImage else {
            throw Failure.message("This picture could not be read.")
        }
        let id = FirestoreHub.db.collection("officialStories").document().documentID
        try await upload(jpeg, to: "officialStories/\(id)/media.jpg", type: "image/jpeg")
        try await call(id: id, kind: "image", width: cg.width, height: cg.height, duration: 0,
                       caption: caption, draft: draft)
    }

    /// A video story: the same encode a normal story video gets (trim, mute, the editor's drawing).
    static func postVideo(_ v: StoryVideoPayload, caption: String, draft: Draft) async throws {
        let range = v.trim.map {
            CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 600),
                        duration: CMTime(seconds: $0.upperBound - $0.lowerBound, preferredTimescale: 600))
        }
        let b = v.burn
        guard let p = await VideoTranscoder.prepare(v.url, maxSeconds: Double(Limits.storyVideoSeconds),
                                                    stripAudio: v.muted, range: range,
                                                    overlay: b?.overlay, cropRect: b?.cropRect,
                                                    canvasAspect: b?.canvasAspect,
                                                    contentScale: b?.contentScale ?? 1,
                                                    backdrop: b?.backdrop, storyBackdrop: true,
                                                    brightness: b?.brightness ?? 0,
                                                    holeCorner: b?.holeCorner ?? 0) else {
            throw Failure.message("Couldn't process this video.")
        }
        let id = FirestoreHub.db.collection("officialStories").document().documentID
        try await upload(p.data, to: "officialStories/\(id)/media.mp4", type: "video/mp4")
        try await upload(p.thumbnail, to: "officialStories/\(id)/thumb.jpg", type: "image/jpeg")
        try await call(id: id, kind: "video", width: Int(p.width), height: Int(p.height),
                       duration: p.duration, caption: caption, draft: draft)
    }

    private static func upload(_ data: Data, to path: String, type: String) async throws {
        let meta = StorageMetadata()
        meta.contentType = type
        do {
            _ = try await Storage.storage().reference(withPath: path).putDataAsync(data, metadata: meta)
        } catch {
            throw Failure.message("The upload did not finish. Check your connection and try again.")
        }
    }

    private static func call(id: String, kind: String, width: Int, height: Int, duration: Double,
                             caption: String, draft: Draft) async throws {
        let input: [String: Any] = [
            "id": id, "kind": kind, "width": width, "height": height, "duration": duration,
            "caption": caption,
            "buttonText": draft.buttonText.trimmingCharacters(in: .whitespacesAndNewlines),
            "buttonUrl": draft.buttonUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            "hours": draft.hours,
            "audience": ["scope": draft.scope, "countries": draft.countries],
        ]
        do {
            _ = try await Functions.functions(region: "me-central1")
                .httpsCallable("officialStoryPost").call(input)
        } catch {
            // The server's sentence when it gave one (a bad link, no permission), else a plain one.
            let ns = error as NSError
            let text = ns.domain == FunctionsErrorDomain ? ns.localizedDescription : ""
            throw Failure.message(text.isEmpty ? "The story could not be posted. Try again." : text)
        }
        OfficialStories.shared.refresh(force: true)
    }
}

/// Fariin stories going up from this phone (owner 2026-10-23: "the page is frozen until the upload
/// finishes"). The form closes at once and the upload runs here; Fariin's page rings its picture
/// while `count > 0` and shows `lastError` if the server refused.
@MainActor @Observable
final class OfficialStoryUploads {
    static let shared = OfficialStoryUploads()
    private init() {}
    var count = 0
    var lastError: String?

    func run(_ image: Data, video: StoryVideoPayload?, caption: String, extras: [StoryExtra],
             draft: OfficialStoryCompose.Draft) {
        count += 1
        lastError = nil
        Task { @MainActor in
            defer { count -= 1 }
            do {
                if let video {
                    try await OfficialStoryCompose.postVideo(video, caption: caption, draft: draft)
                } else {
                    try await OfficialStoryCompose.postPhoto(image, caption: caption, draft: draft)
                }
                for e in extras {
                    if let v = e.video {
                        try await OfficialStoryCompose.postVideo(v, caption: e.caption, draft: draft)
                    } else if let p = e.photo {
                        try await OfficialStoryCompose.postPhoto(p, caption: e.caption, draft: draft)
                    }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                lastError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

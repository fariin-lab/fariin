//
// ONE DOOR FOR EVERY STORY.
//
// WHY THIS FILE EXISTS. The viewer used to be opened five different ways from five different files,
// and each of them had written its own close: `fullScreenCover` + Apple's `.zoom` in MainShell, the
// same again with a different spring in ArchivedChatsView, `ownSwipeDismiss: true` in MyProfileView,
// `ownSwipeDismiss: false` + a zoom in ContactInfoView, a fourth arrangement in ThreadView. Five
// copies of one interaction is why a fix to the story open never reached the profile, and why the
// scroll-down felt like a different gesture depending on which circle you had tapped — the owner's
// 2026-08-07 report in as many words.
//
// The presentation itself lives in `StoryZoomPresenter` (our screen, our gesture, our animation) and
// the flight lives in `StoryCardMorph`. This is the layer between them and the app: it knows how to
// build a viewer, what a close has to put back, and nothing else. Every screen that can show a story
// calls `StoryDoor.open` and passes the key of the thing that was tapped.
//
// WHAT A CALLER OWES IT. One `MediaRectReporter(id:scope:.storyRow, cornerRadius:)` on the view that
// was tapped, reporting its REAL corner radius. That radius is the whole shape system: a card reports
// 24 and the story lands as a card; an avatar reports half its width and the story lands as a circle,
// Snapchat's way, with no branch here or in the morph. See `StoryCardMorph.applyCore`.
//

import SwiftUI
import UIKit
import StoryUI

/// "A story viewer is on screen." Observable so the stories row can hold its order still while one is
/// up (`freezeOrder`) without every door owning a copy of that state, and so a door opened from the
/// profile can freeze the row it is not even on screen with.
@Observable final class StoryDoorState {
    static let shared = StoryDoorState()
    /// The group the viewer was OPENED on, or nil. Set before the presentation, cleared after the
    /// landing. This is the door, not the position — see `activeGroupId` for where he actually is.
    var openGroup: StoryGroup?
    /// The uploading-story viewer, which has no posted group of its own to name yet.
    var uploadingOpen = false
    var isOpen: Bool { openGroup != nil || uploadingOpen }

    // MARK: - THE ONE ANSWER TO "WHOSE STORY IS ON SCREEN RIGHT NOW"
    //
    // ⚠️ READ THIS BEFORE TOUCHING THE CLOSE'S LANDING.
    //
    // The viewer pages person to person, and for a long time nothing outside it knew that. The row
    // kept the position it had at the open, and the close asked "is the person he is on visible?" —
    // if the answer was no, because their card was off to the right of a row that had never
    // scrolled, it fell back to THE PERSON THE VIEWER WAS OPENED FROM. So Abdi → Ali → Salmo → Saki,
    // pull down, and the story flew home to Abdi. That fallback is his report exactly, and he named
    // the shape of the fix: do not special-case the opener, keep one live answer instead.
    //
    // This is that answer. The viewer writes it on EVERY change of person, immediately — the open,
    // a swipe forward, a swipe back, a carousel jump — and everything else reads it: the row scrolls
    // to it, the flight lands on it, the cover decides against it. One value, so the row, the
    // carousel and the dismissal cannot disagree about where he is.
    //
    /// `MediaOpenRects` key of the active person's row card. Nil while no viewer is up.
    var activeSourceKey: String?
    /// The same person, keyed the way the ROW identifies its cards (`.id(g.authorUid)`), so the row
    /// can scroll to them. Two spellings of one fact, written in the same breath and never apart.
    var activeAuthorUid: String?

    /// Called by the viewer whenever the person on screen changes, and once at the open.
    func setActive(sourceKey: String, authorUid: String) {
        if activeSourceKey != sourceKey { activeSourceKey = sourceKey }
        if activeAuthorUid != authorUid { activeAuthorUid = authorUid }
    }

    /// WHERE TO LEAVE THE ROW ONCE THE VIEWER HAS GONE AND THE ORDER HAS RE-SORTED. Consumed once.
    ///
    /// The close hands the story back to a card, and then — 0.4s later, deliberately, so the landing
    /// is not disturbed — the repo reloads and the row re-sorts: the people he just watched move
    /// behind the ones he has not. A scroll offset does not survive that; whoever ends up at those
    /// points is who he is left looking at, and after Abdi → Ali → Salmo → Saki that is not Saki.
    ///
    /// So the person is remembered rather than the offset, and the row scrolls back to them once the
    /// new order is drawn. Once: this is cleared on use, so an unrelated re-sort an hour later can
    /// never yank the row somewhere he did not ask for.
    var restoreRowToUid: String?

    func clearActive() {
        // The row still has to be put back on him after the re-sort, so the person outlives the
        // session by exactly one reorder. `activeSourceKey` is the flight's, and dies with it.
        restoreRowToUid = activeAuthorUid
        activeSourceKey = nil
        activeAuthorUid = nil
    }
}

@MainActor
enum StoryDoor {

    /// What the open was asked for, kept so a delete-with-stories-remaining can rebuild the viewer in
    /// place without the calling screen having to hold any of it.
    private struct Request {
        var group: StoryGroup
        var siblings: [StoryGroup]
        var sourceKey: String
        var pinned: Bool
        var deliveredToMe: Bool
        var onProfile: (StoryGroup) -> Void
        var onClosed: () -> Void
    }
    private static var request: Request?

    /// True while a viewer is up. Callers guard their tap on it so a double tap cannot stack two.
    static var isOpen: Bool { StoryZoomPresenter.isActive }

    // MARK: - Opening

    /// Open `g` on the app's own presentation.
    ///
    /// - Parameters:
    ///   - siblings: the ordered bucket this story belongs to, so the viewer can page person to
    ///     person. Empty (the default) opens this group alone, which is what every door except the
    ///     stories row wants: a profile is one person's story and paging out of it into a stranger's
    ///     is not what the tap asked for.
    ///   - sourceKey: the `MediaOpenRects` id of the tapped view, in the `.storyRow` scope. It decides
    ///     what the flight lands on AND what shape it lands in.
    ///   - pinned: the anchor does not move as the viewer pages. True for every single-anchor door;
    ///     only the stories row passes false, because there the card under the story genuinely
    ///     changes as you swipe. See `StoryViewer.heroSourcePinned`.
    ///   - deliveredToMe: this story reached me through its author's audience choice, so the reply bar
    ///     is allowed. Do not pass true for a story found by other means (a public profile).
    static func open(_ g: StoryGroup,
                     among siblings: [StoryGroup] = [],
                     from sourceKey: String,
                     pinned: Bool = true,
                     deliveredToMe: Bool = false,
                     onProfile: @escaping (StoryGroup) -> Void = { _ in },
                     onClosed: @escaping () -> Void = {}) {
        guard !StoryZoomPresenter.isActive else { return }   // one viewer at a time
        let req = Request(group: g, siblings: siblings, sourceKey: sourceKey, pinned: pinned,
                          deliveredToMe: deliveredToMe, onProfile: onProfile, onClosed: onClosed)
        request = req
        StoryDoorState.shared.openGroup = g
        // A fresh session starts on the person who was tapped, and owes nothing to the last one. The
        // pending row restore goes too: it belongs to a visit that is over, and letting it survive
        // into this one would scroll the row out from under the story that is opening.
        StoryDoorState.shared.restoreRowToUid = nil
        StoryDoorState.shared.setActive(sourceKey: sourceKey, authorUid: g.authorUid)
        // The tapped view is photographed HERE, at tap time, while it is definitely on screen: the
        // snapshot rides the flight as the cover the open wears. Nil (nothing registered, or the view
        // scrolled away) degrades to an open with no cover, which is still a correct flight.
        StoryZoomPresenter.present(viewer(req), coverFrom: liveView(sourceKey),
                                   coverRadius: sourceRadius(sourceKey), coverKey: sourceKey)
    }

    /// THE HOLE AND THE COVER FOLLOW THE SWIPE, so the close after paging to another person is the
    /// SAME close the tapped person gets — his 2026-08-08 report: "after swiping to the next story,
    /// scrolling down does not behave the same way." The tapped card's slot empties at the open and
    /// its picture rides the flight; a person you swiped to had neither, so the close fell back to
    /// a fade landing onto their still-visible card — a visibly different return.
    ///
    /// Called by the viewer on every change of person (through `publishActive`, the one write).
    /// Order matters twice over: the new card is photographed BEFORE it is hidden (an alpha-0 card
    /// renders blank), from its OWN layer tree (the window is the story right now — see
    /// `StoryCardShot.render`). Hiding the new key reveals the old one in the same write —
    /// `MediaSourceVisibility` holds one id — and that reveal happens behind the presenter's
    /// opaque wall, where nobody can see the exchange.
    ///
    /// If the photograph fails (no registered card, not in a window yet), NOTHING moves: the old
    /// hole and cover stay, `coverSourceKey` keeps naming the old person, and the close falls back
    /// to the fade landing exactly as before — a wrong-picture landing is worse than either.
    static func retarget(to sourceKey: String) {
        guard StoryZoomPresenter.isActive else { return }
        // Already wearing him: nothing to do. This is also what keeps the OPEN out of here — the
        // first person's cover was photographed at tap time and his slot is the flight's to hide
        // (`stageHeroOpen`), and re-photographing the card mid-dip would trade a clean picture
        // for a shrunken one.
        guard StoryZoomPresenter.coverSourceKey != sourceKey else { return }
        guard let view = liveView(sourceKey),
              let shot = StoryCardShot.render(view, cornerRadius: sourceRadius(sourceKey))
        else { return }
        StoryZoomPresenter.retargetCover(shot, sourceKey: sourceKey)
        MediaSourceVisibility.shared.hide(MediaOpenRects.key(.storyRow, sourceKey))
    }

    /// The live viewer for a story still being uploaded. Same presentation, same flight, same close —
    /// it differs only in that its content is a handoff view that swaps itself for the real viewer
    /// when the upload lands.
    static func openUploading(meName: String, mePhoto: String?,
                              from sourceKey: String = uploadingSourceKey,
                              onProfile: @escaping (StoryGroup) -> Void = { _ in },
                              onClosed: @escaping () -> Void = {}) {
        guard !StoryZoomPresenter.isActive else { return }
        request = nil
        StoryDoorState.shared.uploadingOpen = true
        let finish: () -> Void = {
            StoryDoorState.shared.uploadingOpen = false
            MediaSourceVisibility.shared.reveal()
            onClosed()
        }
        StoryZoomPresenter.present(
            UploadingStoryHandoff(meName: meName, mePhoto: mePhoto,
                                  heroSourceKey: sourceKey,
                                  onHeroClose: {
                                      // Same order as every other hero close: the source comes back
                                      // BEFORE the copy goes away, so the card lands on something
                                      // already identical to it. See `heroClose` below.
                                      MediaSourceVisibility.shared.reveal()
                                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                                          StoryZoomPresenter.finish()
                                          finish()
                                      }
                                  },
                                  onClose: {
                                      StoryZoomPresenter.closeWithDrift()
                                      finish()
                                  },
                                  onProfile: { grp in
                                      StoryZoomPresenter.finish()
                                      finish()
                                      DispatchQueue.main.async { onProfile(grp) }
                                  }),
            coverFrom: liveView(sourceKey), coverRadius: sourceRadius(sourceKey),
            coverKey: sourceKey)
    }

    /// The uploading card's own rect key. One constant so the card that registers it and the door that
    /// flies to it cannot drift apart.
    static let uploadingSourceKey = "my-story-uploading"

    /// Take any open viewer away NOW, with no flight: a notification tap that has to land on a chat
    /// underneath, and anything else that needs the stack clear. Safe when nothing is open.
    ///
    /// This used to be two binding writes (`viewerGroup = nil`, `showUploadViewer = false`) on the
    /// screen that owned the covers. A presented screen cannot be dismissed that way, so every such
    /// site has to come through here or it silently stops working the day its door migrates.
    static func dismiss() {
        guard StoryZoomPresenter.isActive || StoryDoorState.shared.isOpen else { return }
        StoryZoomPresenter.finish()
        StoryDoorState.shared.uploadingOpen = false
        closed()
    }

    // MARK: - The viewer, and the three ways out of it

    private static func liveView(_ key: String) -> UIView? {
        MediaOpenRects.liveView(MediaOpenRects.key(.storyRow, key))
    }

    /// The radius the source is drawn with, so the cover shot can be cut to it and its corners can
    /// never carry the chat list into the flight. 14 is `MediaOpenRects`' "nobody said", which is the
    /// chat bubble's number and not this screen's — fall back to the story card's 24.
    private static func sourceRadius(_ key: String) -> CGFloat {
        let r = MediaOpenRects.cornerRadius(MediaOpenRects.key(.storyRow, key))
        return r == 14 ? 24 : r
    }

    /// Every exit runs this: put the tapped view back, release the row order, and reload the rings
    /// only AFTER the landing has settled. The just-seen bucket moves when the repo reloads, and
    /// re-sorting while the card is still settling makes the landing look like it missed.
    private static func closed() {
        let req = request
        request = nil
        StoryDoorState.shared.openGroup = nil
        // Hands the last person he watched to the row, to be restored once the re-sort below lands.
        StoryDoorState.shared.clearActive()
        MediaSourceVisibility.shared.reveal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Task { await StoriesRepository.shared.load(force: true) }
        }
        req?.onClosed()
    }

    /// `refeed: true` builds the replacement viewer for a delete-with-stories-remaining swap: the
    /// screen is already up, so the new viewer must not replay the open flight (`heroStageOpen`).
    @ViewBuilder
    private static func viewer(_ req: Request, refeed: Bool = false) -> some View {
        // THE HERO CLOSE'S EXIT: the card has already flown home by the time this runs, so the screen
        // leaves with no animation of its own — anything else plays a second close over the one the
        // finger just drew.
        //
        // THE SOURCE COMES BACK BEFORE THE COPY GOES AWAY. The card had been landing on an EMPTY slot
        // and the slot was refilled in the same breath as the screen was torn down — two changes in
        // one frame, and whichever landed second was a visible swap. Revealing first is free: the
        // flying card is sitting exactly on top of the slot wearing its picture, so the real view
        // comes back underneath where nobody can see it.
        let heroClose: () -> Void = {
            MediaSourceVisibility.shared.reveal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                StoryZoomPresenter.finish()
                closed()
            }
        }
        // The close with nowhere to fly (the source scrolled away, or the viewers sheet was up): the
        // presenter answers with its short drift-away, then the same teardown.
        let close: () -> Void = {
            StoryZoomPresenter.closeWithDrift()
            closed()
        }
        // A profile cannot be presented from under our screen, so leave first and open on the next
        // tick. (The viewer's own header tap uses its INTERNAL profile sheet and never reaches this;
        // this is the belt for the paths that do.)
        let profile: (StoryGroup) -> Void = { grp in
            let onProfile = req.onProfile
            StoryZoomPresenter.finish()
            closed()
            DispatchQueue.main.async { onProfile(grp) }
        }
        if let idx = req.siblings.firstIndex(where: { $0.id == req.group.id }), req.siblings.count > 1 {
            StoryViewer(groups: req.siblings, startIndex: idx,
                        heroDismiss: true, heroSourceKey: req.sourceKey, heroSourcePinned: req.pinned,
                        deliveredToMe: req.deliveredToMe,
                        heroStageOpen: !refeed,
                        onHeroClose: heroClose,
                        onClose: close,
                        onProfile: profile)
        } else {
            StoryViewer(group: req.group,
                        heroDismiss: true, heroSourceKey: req.sourceKey, heroSourcePinned: req.pinned,
                        deliveredToMe: req.deliveredToMe,
                        heroStageOpen: !refeed,
                        onHeroClose: heroClose,
                        onClose: close,
                        onProfile: profile,
                        onDeletedRemaining: { fresh in
                            // A story was deleted but more remain: swap the viewer for one fed the
                            // remaining bucket, in place. `replaceContent` forces a fresh identity,
                            // which is what the old cover's nil→fresh dance existed to do.
                            guard var next = request else { return }
                            next.group = fresh
                            next.siblings = []
                            request = next
                            StoryDoorState.shared.openGroup = fresh
                            StoryZoomPresenter.replaceContent(viewer(next, refeed: true))
                        })
        }
    }
}

import LiveKit

/// The screen sharing extension (2026-10-07). iOS runs it in its own process once the person taps
/// Start in the system's broadcast sheet, and it is the only way an app can see the whole screen.
///
/// LiveKit's handler does all the work: it turns each screen frame into a JPEG and writes it to a
/// unix socket (`rtc_SSFD`) inside the App Group container `group.com.kulan.messenger.native`.
/// The app reads that socket: group calls through LiveKit's own receiver, 1:1 calls through ours,
/// which speaks the same protocol. No call connection lives here, so the extension stays well
/// under the ~50 MB memory cap iOS gives it.
///
/// Stopping is handled by the base class too. The app posts the stop request when the call ends,
/// and if the app side closes the socket (call over, app killed) the next frame fails and the
/// broadcast finishes without an error sheet.
///
/// Ids follow LiveKit's defaults (extension = app id + ".broadcast", group = "group." + app id),
/// so neither Info.plist carries an override. Change the ids and both plists need them.
final class SampleHandler: LKSampleHandler {}

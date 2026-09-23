# Fariin — App Store Review Notes

> ## ⛔ DO NOT PASTE THE TEST ROUTE FROM THIS FILE. USE `AppStore/SUBMIT.md` §5.
>
> Checked against the source on 2026-09-23. The "How to test" section below claimed **"No email or
> phone needed"** and **"anonymous accounts are created automatically"**. Neither is true any more.
> `AuthService` has three doors and all three are credentials: Sign in with Apple, Google, and email
> with password. Anonymous sessions are legacy, adopted if one already exists, never created.
>
> Telling a reviewer no sign-in is needed and then showing them a sign-in wall is the commonest way
> a first submission comes back. The section is corrected below, but `SUBMIT.md` is the file kept in
> step with the code, and it has the blanks for the account credentials you must supply.
>
> The rest of this file, the safeguards, deletion, privacy, encryption and permissions sections, was
> re-checked the same day and is accurate.

Paste the relevant parts into **App Store Connect → your version → App Review Information → Notes**,
and fill the **Sign-In Information** / demo fields as described.

## How to test (the reviewer needs two accounts, and credentials for one)

Fariin is a 1:1 messenger with no public timeline, so testing requires two accounts. The reviewer
cannot make their own instantly, because the app requires a real sign-in.

1. **Supply an email-and-password account** in App Store Connect's Sign-In Information field. Sign
   in with Apple and Google are also offered in the app, but neither is usable by a reviewer on a
   shared test device, so the email door is the one to hand over.
2. On first sign-in the app asks for a profile (a display name and a username). Tapping **Continue**
   requires agreeing to the Terms (zero-tolerance policy) and the Privacy Policy.
3. **Supply a second account's username** for them to message. Tap the compose button, search that
   username, send a message, and the end-to-end-encrypted delivery, reactions, photos and voice
   notes can all be exercised in that chat.

> Note: Fariin is end-to-end encrypted. A person can only be messaged **after** they have opened the
> app at least once, so that their public key is published. **Both accounts you hand over must have
> been opened once**, or the reviewer meets an error that looks like a broken app.

⚠️ An earlier version of this file named a ready-made account `ayaan` for the reviewer to message.
**Do not rely on it without checking it still exists and has opened the app.** Create the pair fresh
and know they work.

## User-Generated Content safeguards (Guideline 1.2)

- **EULA / agreement:** the onboarding screen requires agreeing to the Terms before posting. The Terms
  state a zero-tolerance policy for objectionable content and abusive users.
  - Terms: https://fariin.com/terms
- **Block:** any user can be blocked from their profile (tap the contact name → **…** → Block) or from
  the in-chat block bar.
- **Report content:** long-press any incoming message → **Report** (or **Report and Block**).
- **Report users:** open a contact's profile → **…** → **Report**.
- **Moderation:** reports are written to a server-side `reports` collection and reviewed within 24
  hours; offending content/users are removed or banned.
- **Contact:** support@fariin.com (also linked in **Settings → Help & About → Report a Problem**).

## Account deletion (Guideline 5.1.1(v))

In-app: **Settings → Account → Delete Account** permanently deletes the account and profile.

## Privacy

- Privacy Policy: https://fariin.com/privacy
- Data collected, matching `Kulan/PrivacyInfo.xcprivacy`: the email address the account was created
  with, the chosen display name and username (and optional photo and bio), the messages and media
  you send (end-to-end encrypted in chats, but still transmitted, so still declared), the account
  and per-device identifiers and the push-notification token, and a precise location **only** when
  someone chooses to share a place in a chat or tag one on a story.
- No ads, no data selling, no third-party sharing, no tracking. Neither Analytics nor Crashlytics is
  compiled in.

## Encryption / export compliance

Fariin uses only **standard encryption** (libsodium / NaCl) to protect users' messages. It qualifies for
the export exemption for apps using standard cryptography, so `ITSAppUsesNonExemptEncryption` is set to
`false` in the build. (If France availability prompts otherwise, a self-classification report can be
filed.)

## Permissions (why each prompt appears)

- **Camera / Photos:** to take or attach photos in chats.
- **Microphone:** to record voice messages and for voice calls.
- **Face ID:** optional App Lock to unlock the app.
- **Notifications:** to alert you to new messages.
- **Location (when in use):** only if the person chooses to share a place in a chat or tag one on a
  story. It is never read in the background and there is no always-on permission.

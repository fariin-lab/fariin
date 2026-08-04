# Fariin — App Store Review Notes

Paste the relevant parts into **App Store Connect → your version → App Review Information → Notes**,
and fill the **Sign-In Information** / demo fields as described.

## How to test (the reviewer needs two accounts)

Fariin is a 1:1 messenger, so testing requires two people. Easiest path for the reviewer:

1. Launch the app. On first launch you create a profile (name + username). No email or phone needed.
   Tapping **Continue** requires agreeing to the Terms (zero-tolerance policy) and Privacy Policy.
2. To message someone, tap the compose button and search a username, then send a message.
3. A ready-made test account already exists to message:
   - **Username: `ayaan`** (display name "Ayaan").
   - Search `ayaan`, open the chat, and send a message to see end-to-end-encrypted delivery,
     reactions, photos, and voice notes.
   - (If you prefer two of your own accounts, install on a second device/simulator, create a second
     profile, and message between them — anonymous accounts are created automatically.)

> Note: Fariin is end-to-end encrypted. You can only message a user **after** they have opened the app
> at least once (so their public key is published). `ayaan` has already done this.

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
- Data collected: chosen display name/username (and optional photo/bio), the messages/media you send
  (end-to-end encrypted in chats), an anonymous sign-in ID, and a push-notification token.
- No ads, no data selling, no third-party sharing.

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

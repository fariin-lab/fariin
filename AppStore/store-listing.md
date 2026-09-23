# Fariin, App Store submission pack (v1.0)

> ## ⛔ PASTE FROM `AppStore/SUBMIT.md`, NOT FROM THIS FILE.
>
> Prepared 2026-07-19 and parts of it went out of date as the app changed. Checked against the
> source on 2026-09-23; **three of its six sections were wrong**, and each one was wrong in a way
> that would have put a false statement in front of Apple:
>
> - **§2, the privacy label**, listed fewer data types than `Kulan/PrivacyInfo.xcprivacy` declares,
>   and said chat media is not collected.
> - **§3, encryption**, said the flag is `true` and told you to answer "no exemption". The build
>   says `false` and the exemption was already answered in ASC for build 363.
> - **§5, the review notes**, told Apple a reviewer can sign up with no credentials. The app has
>   required Apple, Google or email and password for some time now.
>
> All three are corrected in place below so this file is not a trap, but `SUBMIT.md` is the one
> kept in step with the code. **This file is worth reading for the reasoning behind the copy.**

Everything to copy-paste into App Store Connect. Prepared 2026-07-19.
v1 scope: 1-to-1 E2EE messenger. Groups are compiled out (`Flags.groupsEnabled = false`).

---

## 1. Listing texts

**Name:** Fariin

**Subtitle** (max 30 chars):
`Private, simple messaging`

**Promotional text** (max 170 chars, changeable without review):
`Private messaging without a phone number. End-to-end encrypted chats, voice and video calls, and 24-hour stories. Fariin is the Somali word for message.`

**Description** (max 4000 chars):

```
Fariin is a private messenger built on one idea: your conversations belong to you.

NO PHONE NUMBER NEEDED
Create an account in seconds with just a name and a username. No phone number, no email, no contact list upload. Find friends by username or by scanning their QR code in person.

END-TO-END ENCRYPTED
Every message is encrypted on your device before it is sent. Texts, photos, videos, voice messages and files can only be read by you and the person you send them to. Fariin cannot read them, and neither can anyone else.

VOICE AND VIDEO CALLS
Free, private 1-to-1 voice and video calls over the internet.

STORIES
Share photo and video stories that disappear after 24 hours. You choose who can see them, and you can see who viewed them.

ALL THE ESSENTIALS
• Voice messages with waveforms and playback speed
• Photos, videos, albums and file sharing
• Message reactions, replies, forwarding and pinned messages
• Disappearing messages
• Read receipts and typing indicators
• Chat wallpapers and appearance options
• Archive, mute and pin chats

BUILT-IN PROTECTION
• App Lock with Face ID
• Screen security (hide app preview in the app switcher)
• Block and report users
• Delete your account and data at any time

Fariin is the Somali word for message. That is what the app is meant to be: a private place to talk with the people who matter to you.
```

**Keywords** (max 100 chars, comma-separated):
`somali,chat,private,secure,encrypted,messaging,texting,calls,video,stories,voice`

**Category:** Social Networking
**Support URL:** https://fariin.com/support
**Privacy Policy URL:** https://fariin.com/privacy

---

## 2. Privacy nutrition label (App Privacy section)

> ⛔ **CORRECTED 2026-09-23. The list this section used to carry was short by three data types and
> rested on a reading that does not hold.** The original argued that because chats are E2EE and we
> cannot read them, they are not "collected". Apple's question is whether data leaves the device,
> not whether you can read it. `Kulan/PrivacyInfo.xcprivacy` already makes that call in writing, and
> the label must agree with the manifest. **The full, checked answers are in `SUBMIT.md` §3.**

Ground truth: no analytics or crash SDKs are compiled in. The linked products are Firestore, Auth,
Storage, Messaging, Functions, Sodium, WebRTC, LiveKit and StoryUI. No ads, no tracking, no
advertising identifier, no attribution SDK. Contacts are never uploaded: people are found by typing
an exact username.

Answers:
- **Data used to track you:** NONE.
- **Data linked to you**, all of it App Functionality only, none of it used for tracking:
  - Contact Info → Email Address (sign-in is Apple, Google or email, so an address reaches the account)
  - Contact Info → Name (the display name the user types; may be a nickname)
  - Identifiers → User ID (the account id every document is keyed by, plus the username)
  - Identifiers → Device ID (the per-install id behind Settings, Devices, and the push tokens)
  - User Content → Photos or Videos (chat media **and** stories and the profile photo)
  - User Content → Other User Content (messages, captions, voice notes, "about" text)
  - Location → Precise Location (only when someone shares a place in a chat or tags one on a story,
    never in the background)
- **Data not linked to you:** none to declare.

Purposes for all of the above: App Functionality only.

---

## 3. Encryption export compliance (the questionnaire that appears on upload)

> ⛔ **CORRECTED 2026-09-23. This section said the flag is `true` and that the app does NOT qualify
> for an exemption. Both are wrong and following it would have contradicted the build.**
> `project.yml` carries `ITSAppUsesNonExemptEncryption: false`, under a comment recording the
> account owner's determination of 2026-07-24: standard publicly available crypto (libsodium),
> mass-market, France distribution No, and it was already answered in ASC for build 363. The
> original text below is replaced rather than kept, because a stale answer here is one a tired
> person pastes at midnight.

**Nothing to do. The build clears compliance by itself**, which is the whole point of the plist key.

If the upload asks anyway, the answers that match what is on file are:
1. "Is your app designed to use cryptography…?" → **Yes**
2. "Does your app qualify for any of the exemptions…?" → **Yes** (standard, publicly available
   algorithms in a mass-market app)
3. "Does your app implement any encryption algorithms that are proprietary or not accepted as standard…?" → **No** (libsodium = published standard algorithms: Curve25519, XSalsa20/ChaCha20, Poly1305)

⚠️ The exemption is written on the understanding that **France is not in the availability list**.
France wants its own declaration to ANSSI. Adding France without filing it breaks the determination
this flag rests on.

Two follow-ups outside Apple:
- **US annual self-classification report** (simple email/CSV to crypt@bis.doc.gov and
  enc@nsa.gov, due Feb 1 each year) — standard for mass-market encryption apps.
- **France** requires a separate encryption declaration (ANSSI). Easiest v1 option:
  exclude France from the availability list at launch, add it after filing.

---

## 4. Age rating questionnaire guidance

Key answers: unrestricted user-to-user communication → Yes; user-generated content → Yes;
no gambling/violence/etc. Expected result: **12+ or 17+** (accept whatever the
questionnaire computes; do not understate).

---

## 5. Review notes (paste into "Notes" for the reviewer)

> ⛔ **CORRECTED 2026-09-23, and this was the dangerous one.** The text here told Apple that "no
> login credentials are required" and that a reviewer can "create an account instantly with any name
> and username". **That has not been true for some time.** `AuthService` has three doors, all of
> them credentials: Sign in with Apple, Google, and email with password. A reviewer who is told no
> sign-in is needed, then meets a sign-in wall, files the rejection that says "we were unable to
> review your app". It is the commonest first-submission rejection there is.
>
> **The corrected notes, with the blanks you have to fill, are in `SUBMIT.md` §5**, together with
> the Sign-In Information fields that must not be left empty. The old text is removed rather than
> corrected in place, so nobody can paste it by accident.

---

## 6. Remaining manual steps (owner)

> Updated 2026-09-23. Step 1 below is **done** and needs nothing from you: the flag has been
> `false` since 2026-07-24 and builds clear compliance on their own. The live list is in
> `SUBMIT.md` §0.

1. ~~Ship a build with the new encryption flag and answer the questionnaire.~~ **Done.**
2. **Create the two review accounts** by email and password, open each one once so its public key
   publishes, and send one message between them. Their credentials go in App Store Connect's
   Sign-In Information, which cannot be left blank.
3. **Take screenshots at 6.9 inch** (1320 x 2868). The website shots are the wrong size.
4. **Decide the description line** that still promises "no email" (see `SUBMIT.md` §2).
5. Fill the forms in App Store Connect, price Free, countries minus France, submit.

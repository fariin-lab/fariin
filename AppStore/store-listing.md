# Fariin, App Store submission pack (v1.0)

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

Ground truth: chats (text, media, voice, files) are E2EE → NOT accessible to us → per
Apple's definition they are NOT "collected". Stories, profile photos and profile info are
stored server-side readable → they ARE collected. No analytics or crash SDKs are compiled
in (Firebase: Firestore/Auth/Storage/Messaging/Functions only). No ads, no tracking.

Answers:
- **Data used to track you:** NONE.
- **Data linked to you:**
  - Contact Info → Name (the display name the user types; may be a nickname)
  - User Content → Photos or Videos (stories + profile photo only; chat media is E2EE and not collected)
  - User Content → Other User Content (username, "about" text, story captions)
  - Identifiers → User ID (anonymous Firebase UID, push token)
- **Data not linked to you:** none to declare.

Purposes for all of the above: App Functionality only.

---

## 3. Encryption export compliance (the questionnaire that appears on upload)

`ITSAppUsesNonExemptEncryption` is now `true` (project.yml) — correct for our libsodium E2EE.

One-time answers in App Store Connect:
1. "Is your app designed to use cryptography…?" → **Yes**
2. "Does your app qualify for any of the exemptions…?" → **No**
3. "Does your app implement any encryption algorithms that are proprietary or not accepted as standard…?" → **No** (libsodium = published standard algorithms: Curve25519, XSalsa20/ChaCha20, Poly1305)
4. Mass-market self-classification (5A992/5D992) → **Yes**

After this, App Store Connect issues a compliance code → add it to project.yml as
`ITSEncryptionExportComplianceCode` so future TestFlight/App Store uploads auto-clear
(until then, each upload needs one "Manage Compliance" click in ASC).

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

```
Fariin is an end-to-end encrypted 1-to-1 messenger. No phone number, email or
login credentials are required — the reviewer can create an account instantly
with any name and username.

How to test:
1. Sign up with any name + username (e.g. "reviewer1").
2. On a second device/simulator, sign up as "reviewer2".
3. Tap the compose button → type the other username → chat. Photos, voice
   messages, reactions, replies etc. all work in the chat.
4. Voice/video calls: open a chat → phone/video icon in the header.
5. Stories: on the Chats tab, tap "My Story +".

Safety: users can block and report from a chat's contact screen (reports are
reviewed within 24 hours), and Settings → Delete Account permanently removes
the account and its data. Message content is end-to-end encrypted (libsodium);
the service cannot read it.
```

---

## 6. Remaining manual steps (owner)

1. Ship a build with the new encryption flag; answer the one-time compliance
   questionnaire in ASC; send me the code Apple issues → I add it to project.yml.
2. Take screenshots on the phone (chat, stories, a call, settings) — 6.9" size.
3. Fill sections 1–5 into App Store Connect, set price (Free) + countries
   (decide France), submit for review.

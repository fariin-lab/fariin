# Fariin, App Store submission sheet

**This is the file to work from.** It follows the order App Store Connect asks in, so you can go
down it form by form. Where something is still a decision or still missing, it says so in a box
instead of guessing for you.

The other two files are kept for their reasoning, not for pasting:
`AppStore/store-listing.md` (why the copy says what it says) and `APP_STORE_REVIEW.md` (the longer
safeguards write-up). Where any of them disagrees with this sheet, this sheet is the one that was
checked against the code on 2026-09-23.

Version: **1.0**, build **749** is the one on the phone (`a3c68327`). Scope is the 1-to-1 messenger.
Groups are compiled out (`Flags.groupsEnabled = false`).

---

## 0. Before you open App Store Connect

Three things only you can do. Nothing below works without them.

### 0a. Create the two review accounts

The app does **not** let anyone in with just a name and a username. Sign-up is Apple, Google or
email and password (`AuthService`, three doors). An Apple reviewer cannot use Sign in with Apple on
a shared test device, so they need an **email and password** account from you, and a second account
to send a message to.

1. On your phone, sign out. Create an account with the **email door**, something like
   `review@fariin.com` and a password you are willing to put in a form.
2. Open it once so its public key gets published. This matters: nobody can be messaged until they
   have opened the app at least once.
3. Create a second account the same way, note its **username**, and open it once too.
4. Send one message between them so the reviewer lands in a chat that already has something in it.

> **Waiting on you:** the two usernames, the review email, and its password. The Sign-In
> Information form in section 5 has blanks for them.

### 0b. Screenshots

Apple needs them at **6.9 inch** (1320 x 2868). The ones on fariin.com are website size and will be
rejected. Minimum is one, but the listing looks empty under three.

Suggested set, all of which the demo data already stages for you (Settings, "Demo chats"):

1. The chat list
2. A conversation with a voice note in it
3. A conversation with a photo in it
4. A story open
5. A call running (this one is not demo data, shoot a real call)

> **Waiting on you:** the image files. Tell me where you put them and I will check the sizes before
> you upload.

### 0c. One decision about France

France requires its own encryption declaration to ANSSI, separate from Apple. Your 2026-07-24
determination in `project.yml` says France distribution is No, which is why
`ITSAppUsesNonExemptEncryption` is `false` and builds clear compliance automatically.

So in section 7, **leave France out of the availability list**, or file the ANSSI declaration first
and then add it. Picking France without filing is the version that causes trouble.

---

## 1. App Information

| Field | Value |
|---|---|
| Name | `Fariin` |
| Subtitle (30 max) | `Private, simple messaging` |
| Category, primary | Social Networking |
| Category, secondary | leave empty |
| Content rights | Does not contain, show or access third-party content |
| Age rating | see section 4 |

Support URL: `https://fariin.com/support`
Marketing URL: `https://fariin.com`
Privacy Policy URL: `https://fariin.com/privacy`

All three are live. `support@fariin.com` and `abuse@fariin.com` are published on the support, terms
and privacy pages, which is what Guideline 1.2 asks for.

---

## 2. Version information

### Promotional text (170 max, changeable later without review)

```
Private messaging without a phone number. End-to-end encrypted chats, voice and video calls, and 24-hour stories. Fariin is the Somali word for message.
```

### Description (4000 max)

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

> ### ⚠️ One line in that description no longer matches the app. Your call.
>
> **"Create an account in seconds with just a name and a username. No phone number, no email, no
> contact list upload."**
>
> No phone number is true. No contact upload is true. **No email is not true any more** for two of
> the three doors: sign-up is Sign in with Apple, Google, or email and password. Apple's own Hide My
> Email means a person can still get in without handing over a real address, so the claim is
> defensible for that one door, but as written it promises something the email and Google doors do
> not do.
>
> A reviewer who reads the description, opens the app and is asked to sign in has found a mismatch
> between your marketing and your app. That is a 2.3.1 rejection, and it is a cheap one to avoid.
>
> **This is your copy and I am not going to rewrite it for you.** Tell me how you want that line to
> read and I will put it in. If it helps, the thing that is actually true and still sells the point
> is that no phone number is ever asked for and no contact list is ever uploaded.

### Keywords (100 max, comma separated, no spaces after commas)

```
somali,chat,private,secure,encrypted,messaging,texting,calls,video,stories,voice
```

### What's New in This Version

First release, so this field does not appear. Nothing to write.

---

## 3. App Privacy (the nutrition label)

**These answers are taken from `Kulan/PrivacyInfo.xcprivacy`, which was measured against the source.
The label you fill in here must match that file.** If the two disagree, Apple sees the contradiction
and it reads as carelessness at best.

Opening questions:

- **Do you or your third-party partners collect data from this app?** → **Yes**
- **Do you or your partners use data for tracking?** → **No** (the manifest says
  `NSPrivacyTracking = false` and there are no tracking domains, which is honest: no Analytics, no
  Crashlytics, no ad SDK, no attribution SDK is compiled in. The linked products are Firestore,
  Auth, Storage, Messaging, Functions, Sodium, WebRTC, LiveKit and StoryUI.)

Data types to tick. **Every one of these is "Linked to you", "Not used for tracking", and purpose
"App Functionality" only.** Nothing is used for advertising, analytics, personalisation or product
improvement.

| Apple's category | Tick | Why it is collected |
|---|---|---|
| Contact Info → Email Address | ✅ | Sign-in is Apple, Google or email, so an address reaches the account |
| Contact Info → Name | ✅ | The display name on the profile |
| Identifiers → User ID | ✅ | The account id every document is keyed by, plus the username people are found with |
| Identifiers → Device ID | ✅ | The per-install id behind Settings, Devices, and the push tokens |
| User Content → Photos or Videos | ✅ | Pictures and clips sent in chats or posted as stories |
| User Content → Other User Content | ✅ | Messages, captions, voice notes |
| Location → Precise Location | ✅ | Only when someone chooses to share a place in a chat or tag one on a story. Never in the background |

**Everything else is left unticked**: no contacts, no browsing history, no search history, no
purchases, no financial info, no health, no fitness, no sensitive info, no diagnostics, no usage
data, no advertising data.

> **On messages and media being ticked at all.** They are end-to-end encrypted and the server holds
> only ciphertext that nobody at Fariin can read. Apple's question is not whether you can read it,
> it is whether it leaves the device. It does, so it is declared. The manifest already makes that
> call in writing and the label has to agree with it. An earlier draft of `store-listing.md` said
> chat media is "not collected"; that reading is the clever kind that gets an app pulled later.

---

## 4. Age rating

Answer the questionnaire honestly. The answers that drive the result:

- **Unrestricted web access** → No (there is no in-app browser that reaches the open web)
- **User-generated content** → Yes
- **Does the app allow users to communicate with each other?** → Yes, and it is **unrestricted**
  one-to-one messaging between people who find each other by username
- Gambling, contests, violence, horror, profanity, sexual content, drugs, alcohol → No to all

**Accept whatever the questionnaire computes and do not try to talk it down.** An
unrestricted-communication app lands in the higher bands, and understating it is its own violation.
Apple reworked these bands, so the number the form gives you now is the one that counts, not any
number written in an older document.

---

## 5. App Review Information

### Sign-In Information

- **Sign-in required** → **Yes**

| Field | Value |
|---|---|
| Username | `________________` (the review email from step 0a) |
| Password | `________________` |

> **Waiting on you.** Do not skip this and do not write "not required". The app genuinely cannot be
> used signed out, and "we could not get past the sign-in screen" is the single most common way a
> first submission comes back.

### Contact Information

Your name, phone number and an email you actually read. Apple uses it when they have a question, and
answering within a day is often the difference between a fix and a rejection.

### Notes

```
Fariin is an end-to-end encrypted 1-to-1 messenger. The Somali word "fariin" means "message".

SIGNING IN
The app requires an account. Three ways in are offered: Sign in with Apple, Google,
or email and password. Please use the email and password in the Sign-In Information
field above.

HOW TO TEST A CONVERSATION
Messaging needs two accounts, because this is a 1-to-1 messenger with no public
timeline. A second account has been prepared for you:

  Username: ________________

  1. Sign in with the credentials above.
  2. Tap the compose button, type that username in the search field, open the chat.
  3. A conversation is already waiting there. You can send text, photos, voice
     messages, reactions and replies.

Note: because messages are end-to-end encrypted, a person can only be messaged after
they have opened the app at least once, so that their public key is published. Both
prepared accounts have done this.

CALLS
Open a chat and use the phone or video button in the header.

STORIES
On the Chats tab, tap "My Story +". Stories expire after 24 hours and the poster
chooses the audience.

SAFETY AND USER-GENERATED CONTENT (Guideline 1.2)
  · Agreement: the onboarding screen requires agreeing to the Terms, which state a
    zero-tolerance policy for objectionable content and abusive users.
    https://fariin.com/terms
  · Block: from a contact's profile, or from the block bar inside a chat.
  · Report content: long-press any incoming message, then Report, or Report and Block.
  · Report users: open a contact's profile, then Report.
  · Moderation: reports arrive in a server-side collection and are reviewed within 24
    hours by a moderator using a private console. Offending stories are removed and
    offending accounts are banned server-side, which stops them posting anything other
    people can find.
  · Published contact: support@fariin.com and abuse@fariin.com, shown on
    https://fariin.com/support and in the app under Settings, Help and About.

ACCOUNT DELETION (Guideline 5.1.1(v))
Settings, Account, Delete Account. It permanently deletes the account and its data.

ENCRYPTION
Standard published algorithms only, via libsodium (Curve25519, XSalsa20, ChaCha20,
Poly1305). No proprietary cryptography.
```

---

## 6. Export compliance

**Already settled, and the build clears itself.** `project.yml` carries
`ITSAppUsesNonExemptEncryption: false`, which is the account owner's determination of 2026-07-24:
the app uses standard, publicly available cryptography (libsodium), is offered mass-market, and is
not distributed in France. That was answered in App Store Connect for build 363 and the plist key is
what keeps every later build from sitting in "Missing Compliance".

**So there is nothing to do here.** If the upload asks anyway, the answers are: uses cryptography
Yes, qualifies for an exemption Yes, proprietary algorithms No.

> `AppStore/store-listing.md` §3 says the flag is now `true` and walks you through answering
> "qualifies for exemption: No". **That section is stale and following it would contradict both the
> build and the answer already on file.** It has been corrected in that file.

One thing that is genuinely still open and has nothing to do with Apple: the **US annual
self-classification report** for mass-market encryption, a short email to `crypt@bis.doc.gov` and
`enc@nsa.gov`, due 1 February each year.

---

## 7. Pricing and Availability

- **Price:** Free
- **Availability:** all countries **except France**, per section 0c. If you would rather launch
  everywhere, the ANSSI declaration has to be filed first and the `project.yml` comment updated,
  because the exemption determination written there names France as No.

---

## 8. Build, then submit

The build to attach is whatever TestFlight processed last, currently **1.0 (749)**. It is a normal
App Store Connect build already, so no new upload or new lane is needed. Pick it under Build, then
Add for Review.

The demo data cannot reach it. `DemoMode.isAvailable` resolves through
`DemoStoryMedia.isAvailable`, which is a sandbox-receipt check, and an App Store build has a real
receipt. There is no switch anyone has to remember to flip.

---

## Still open, and not in this sheet

Two backend items. Neither stops you filling the forms above, but both are worth closing before the
app is public, and the moderation one is the sort of thing Apple asks about after an incident rather
than before.

1. **Anonymous sign-in is still enabled** in the Firebase project. The app no longer creates
   anonymous accounts, but the provider being on means a session can be minted straight against the
   Auth REST API. The old demo and story accounts still ride on it, so they have to be retired
   before it can be switched off.
2. **A ban does not disable the account.** `banned = true` stops a banned person posting anything
   findable, server-side, which is the part that matters most. It does not disable their Firebase
   Auth login. A real disable needs a small Cloud Function, which is not written yet.

Both are tracked in more detail in the moderation notes.

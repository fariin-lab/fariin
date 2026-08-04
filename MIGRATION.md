# Fariin — Native iOS (Swift / SwiftUI) Migration Blueprint

**Status:** RN/Expo sunset decided. This is the single source of truth for the native rebuild.
**Backend stays identical** — same Firebase project (`kulan-2ef85`), same Firestore schema, same
Storage layout. The rewrite is a **client** rewrite. Native and RN clients interoperate during the
transition (shared backend), so we can roll out screen-by-screen with no hard cutover.

---

## 0. Decisions locked before Day 1

| Decision | Choice | Why |
|---|---|---|
| E2EE library | **swift-sodium (libsodium)**, NOT CryptoKit | Our ciphertext is tweetnacl `box` (Curve25519 + XSalsa20-Poly1305). libsodium `crypto_box_easy` is byte-compatible; CryptoKit is not. |
| Private-key continuity | Generate fresh device keys on native, re-publish public key | Keys live in `expo-secure-store`; reading them from a new binary is fragile. We have no key backup already (reinstall loses history), so treat native as a new device. |
| Bundle ID | Dev on `com.kulan.messenger.native`, switch to `com.kulan.messenger` at cutover | Run native in TestFlight alongside RN during the rebuild. |
| Min iOS | **17** (26 for Liquid Glass `.glassEffect()`) | `@Observable`, SwiftData, `PhotosPicker`, `scrollPosition`. |

---

## 1. Project & Tooling

- SwiftUI App lifecycle (`@main struct FariinApp: App`), Swift 6 (or 5.9 + incremental strict concurrency).
- **Swift Package Manager** only (no CocoaPods).
- `GoogleService-Info.plist`; capabilities: Push Notifications, Background Modes → Remote notifications.
- Folders: `App/`, `Models/`, `Repositories/`, `Services/` (Crypto, Storage, Push), `Features/`
  (Auth, Chats, Thread, Settings), `DesignSystem/`.

**Framework map**

| RN / Expo | Native |
|---|---|
| React Navigation | `TabView` + `NavigationStack` |
| Modals | `.sheet` / `.fullScreenCover` + `.presentationDetents`, `.presentationCornerRadius(36)` |
| AsyncStorage / MMKV caches | **Firestore native offline persistence** + `UserDefaults`/SwiftData for prefs |
| react-native-keyboard-controller | `.safeAreaInset(edge:.bottom)` + `@FocusState` + `ScrollViewReader` |
| expo-image / SDWebImage | **Nuke** (or Kingfisher) |
| expo-blur / glass | `.ultraThinMaterial` / iOS 26 `.glassEffect()` |
| tweetnacl | **swift-sodium** |
| expo-secure-store | **Keychain** |
| expo-image-picker | **PhotosPicker** (PhotosUI) |
| expo-notifications | FirebaseMessaging + UNUserNotificationCenter |
| expo-haptics | `.sensoryFeedback` / UIImpactFeedbackGenerator |
| Reanimated / gesture-handler | SwiftUI animation + `DragGesture` (render thread) |

---

## 2. Core structural components

- **Persistent header / tabs:** SwiftUI `TabView` keeps each tab's view tree alive — switching tabs
  never unmounts or re-fetches, so the avatar blink is structurally impossible. Avatar comes from an
  `@Observable ProfileStore` injected via `.environment`, loaded once at launch. Settings is a `.sheet`
  over the shell.
- **Floating glass tab bar:** custom bar in `.safeAreaInset(edge:.bottom)`, `.glassEffect()` /
  `.ultraThinMaterial`, capsule shape; moving pill via `matchedGeometryEffect` + `.spring`.
- **Media pipeline (kills the ArrayBuffer crash):** `PhotosPicker` → `loadTransferable(type: Data.self)`
  → `StorageReference.putDataAsync(data)`. Pure `Data`, no blobs/bridge. Encrypted images: seal `Data`
  with libsodium secretbox, upload ciphertext `Data` to `chat/{cid}/{id}.enc`.
- **Keyboard:** composer pinned with `.safeAreaInset(edge:.bottom)` (moves with the keyboard on the
  render thread, zero lag). List = `ScrollView` + `ScrollViewReader`, `.defaultScrollAnchor(.bottom)`,
  `.scrollDismissesKeyboard(.interactively)`. `@FocusState` drives focus + scroll-to-latest.

---

## 3. Database & real-time

```swift
let settings = FirestoreSettings()
settings.cacheSettings = PersistentCacheSettings()   // REAL on-disk persistence (default ON natively)
Firestore.firestore().settings = settings
```
- Native SDK has true disk persistence — deletes our entire manual cache layer (`warmCache`,
  `fromCache` guards, MMKV). Airplane mode, cold-start, offline writes all handled automatically.
- Repository pattern: one `@Observable` repo per domain (`ConversationsRepository`, `ThreadRepository`,
  `ProfileStore`). `addSnapshotListener` → decrypt on a background `Task.detached` → publish on
  `@MainActor`. `includeMetadataChanges` gives sending/sent state (no optimistic-reconcile hack needed).

---

## 4. Phase-by-phase rebuild order

| Phase | Scope |
|---|---|
| **0 — Foundation** | SPM deps, Firebase init + offline persistence, design tokens, Avatar+Nuke. |
| **1 — Crypto** | libsodium wrapper matching `crypto.ts` (`Services/Crypto.swift`); Keychain keys; publish public key. **Verify an RN-sent message decrypts on native before any UI.** |
| **2 — Models & Repos** | `User`, `Conversation`, `Message` Codable (exact field names); repositories. |
| **3 — Auth/Onboarding** | Anonymous `signInAnonymously`; profile setup (name/handle). |
| **4 — Main shell** | `TabView` + persistent header + floating glass bar + Settings sheet. |
| **5 — Chat list** | Rows, swipe actions, native `.contextMenu` (blur+lift preview free), pin/mute/read/delete. |
| **6 — Thread view** | Messages, keyboard anchor, swipe-to-reply (`DragGesture`), reply quote, scroll physics. |
| **7 — Media** | PhotosPicker → encrypted `Data` upload; secure image viewer. |
| **8 — Settings/Profile** | `.insetGrouped` `List` (= our card look free), edit profile, photo upload, appearance. |
| **9 — Push** | FCM token, UNUserNotificationCenter, optional decrypt-preview Notification Service Extension. |
| **10 — Polish & ship** | Haptics, Liquid Glass, 44pt targets (native), QA vs RN parity, TestFlight cutover. |

---

## Schema reference (unchanged — match field names exactly)

- `users/{uid}`: `name`, `handle`, `handleLower`, `photoUrl`, `publicKey` (b64), `createdAt`.
- `conversations/{cid}` (cid = sorted `uidA_uidB`): `users[]`, `names{uid}`, `photos{uid}`,
  `lastMessage` (cipher), `unreadCount{uid}`, `typing{uid}`, `mutedBy{uid}` (ms), `pinnedBy{uid}`,
  `archivedBy{uid}`, `clearedAt{uid}` (ms, delete-for-me), `blockedBy{uid}`, `updatedAt`.
- `conversations/{cid}/messages/{id}`: `text` (cipher), `authorId`, `createdAt`, `clientId`,
  `replyTo{id, authorId, text(cipher)}`, image: `type:'image'`, `imageUrl`, `enc{v,n,k,kn}`.
- Storage: `profiles/{uid}.jpg` (plain), `chat/{cid}/{id}.enc` (encrypted bytes).

## Wire format (must match tweetnacl exactly)
- Text: `enc1:<b64 nonce>:<b64 box>`, `box = crypto_box_easy(utf8(text), nonce, recipientPub, senderSec)`.
- Image: ciphertext bytes in Storage; meta `{ v:1, n:b64(dataNonce), k:b64(wrappedFileKey), kn:b64(keyNonce) }`,
  `wrappedFileKey = crypto_box_easy(fileKey, keyNonce, recipientPub, senderSec)`,
  ciphertext = `crypto_secretbox_easy(data, dataNonce, fileKey)`.
- Base64 = **standard, padded** (Foundation default). Nonce = 24B. MAC = 16B prepended to ciphertext.

## Honest risks
1. **E2EE compatibility** — validate libsodium↔tweetnacl in Phase 1 first.
2. **On-device history** — native = new device unless Keychain key is migrated (accepted: no key backup today).
3. **Photos not E2EE in RN** — native is the moment to add it (libsodium makes it trivial; scheme already designed in `encryptBytes`).
4. Multi-week rebuild, not a port; parallel shared-backend rollout mitigates risk.

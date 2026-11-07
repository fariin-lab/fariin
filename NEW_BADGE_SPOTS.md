# "New" badge spots

Every place in the app that can show the green "New" pill. The admin panel sets
`config/features.newBadges = { "<id>": <end time, ms> }`; a spot shows the pill while the end
time is ahead. Opening it does not clear it. The server catalog is
`functions-admin/functions/lib/newBadgeSpots.js` (Kulan repo); iOS mirrors it in
`Kulan/Services/NewBadgeSpots.swift`. Android should use the same ids.

The first 12 ids are the old Settings row keys, kept unchanged.

115 spots.

| id | title | where |
|---|---|---|
| `subscriptions` | Subscriptions | Settings |
| `account` | Account | Settings |
| `devices` | Devices | Settings |
| `notifications` | Notifications | Settings |
| `appearance` | Appearance | Settings |
| `chats` | Chats | Settings |
| `stories` | Stories | Settings |
| `privacy` | Privacy & Security | Settings |
| `storage` | Storage and Data | Settings |
| `invite` | Invite Friends | Settings |
| `safety` | Safety | Settings |
| `help` | Help & About | Settings |
| `myProfile` | My Profile | Settings |
| `account.email` | Email address | Settings > Account |
| `account.password` | Password | Settings > Account |
| `account.username` | Username | Settings > Account |
| `account.passkeys` | Passkeys | Settings > Account |
| `account.twoStep` | Two-step verification | Settings > Account |
| `account.securityNotifications` | Security notifications | Settings > Account |
| `account.accountData` | Your Account Data | Settings > Account |
| `account.logOut` | Log out | Settings > Account |
| `notifications.show` | Show Notifications | Settings > Notifications |
| `notifications.preview` | Message Preview | Settings > Notifications |
| `notifications.sound` | Sound | Settings > Notifications |
| `notifications.inAppSounds` | In-App Sounds | Settings > Notifications |
| `notifications.inAppVibrate` | In-App Vibrate | Settings > Notifications |
| `notifications.inAppPreview` | In-App Preview | Settings > Notifications |
| `notifications.sentSound` | Sound When Sent | Settings > Notifications |
| `notifications.resetAll` | Reset All Notifications | Settings > Notifications |
| `appearance.chatWallpaper` | Chat Wallpaper | Settings > Appearance |
| `appearance.chatColor` | Chat Color | Settings > Appearance |
| `appearance.bubbleStyles` | Bubble Styles | Settings > Appearance |
| `appearance.appIcon` | App Icon | Settings > Appearance |
| `appearance.quickReaction` | Quick Reaction | Settings > Appearance |
| `appearance.nightMode` | Night Mode | Settings > Appearance |
| `chats.chatKey` | Chat Key | Settings > Chats |
| `chats.saveToPhotos` | Save to Photos | Settings > Chats |
| `chats.linkPreviews` | Link Previews | Settings > Chats |
| `chats.autoArchive` | Automatically Archive | Settings > Chats |
| `chats.clearHistory` | Clear Chat History | Settings > Chats |
| `stories.viewReceipts` | View Receipts | Settings > Stories |
| `privacy.lastSeen` | Last seen & online | Settings > Privacy & Security |
| `privacy.photo` | Profile photo | Settings > Privacy & Security |
| `privacy.bio` | Bio | Settings > Privacy & Security |
| `privacy.groups` | Groups & Channels | Settings > Privacy & Security |
| `privacy.messages` | Messages | Settings > Privacy & Security |
| `privacy.calls` | Calls | Settings > Privacy & Security |
| `privacy.blocked` | Blocked Users | Settings > Privacy & Security |
| `privacy.alwaysRelay` | Always Relay Calls | Settings > Privacy & Security |
| `privacy.callsInRecents` | Show Calls in Recents | Settings > Privacy & Security |
| `privacy.disappearing` | Disappearing Messages | Settings > Privacy & Security |
| `privacy.appLock` | App Lock | Settings > Privacy & Security |
| `privacy.safetyTips` | Safety Tips | Settings > Privacy & Security |
| `privacy.profileLayout` | Profile Layout | Settings > Privacy & Security |
| `storage.manage` | Manage storage | Settings > Storage and Data |
| `storage.autoDownload.photos` | Photos (auto-download) | Settings > Storage and Data |
| `storage.autoDownload.videos` | Videos (auto-download) | Settings > Storage and Data |
| `storage.autoDownload.audio` | Audio (auto-download) | Settings > Storage and Data |
| `storage.autoDownload.documents` | Documents (auto-download) | Settings > Storage and Data |
| `storage.sentMediaQuality` | Sent Media Quality | Settings > Storage and Data |
| `storage.useLessData` | Use Less Data | Settings > Storage and Data |
| `help.helpCenter` | Help Center | Settings > Help & About |
| `help.privacyPolicy` | Privacy Policy | Settings > Help & About |
| `help.terms` | Terms & Conditions | Settings > Help & About |
| `channelSettings.reactions` | Reactions | Channel Settings |
| `channelSettings.replies` | Replies | Channel Settings |
| `channelSettings.followers` | Followers | Channel Settings |
| `channelSettings.scheduledPosts` | Scheduled Posts | Channel Settings |
| `groupSettings.disappearing` | Disappearing Messages | Group / Channel Settings |
| `groupSettings.chatHistory` | Chat History | Group / Channel Settings |
| `groupSettings.recentActions` | Recent Actions | Group / Channel Settings |
| `groupSettings.type` | Group Type / Channel Type | Group / Channel Settings |
| `groupSettings.inviteLink` | Invite Link | Group / Channel Settings |
| `groupSettings.requests` | Join Requests / Follow Requests | Group / Channel Settings |
| `groupSettings.members` | Members | Group / Channel Settings |
| `groupSettings.admins` | Administrators | Group / Channel Settings |
| `groupSettings.banned` | Banned Users | Group / Channel Settings |
| `groupSettings.permissions` | Permissions | Group / Channel Settings |
| `groupSettings.media` | Media & content | Group / Channel Settings |
| `groupSettings.protectContent` | Protect Content | Group / Channel Settings |
| `groupInfo.sounds` | Sounds & Notifications | Group / Channel info page |
| `groupInfo.storage` | Storage Used | Group / Channel info page |
| `groupInfo.statistics` | Statistics | Group / Channel info page |
| `groupInfo.followers` | Followers | Group / Channel info page |
| `groupInfo.settings` | Group Settings / Channel Settings | Group / Channel info page |
| `profile.disappearing` | Disappearing Messages | Profile page (a person's info page) |
| `profile.restricted` | Restricted Chat | Profile page (a person's info page) |
| `profile.sounds` | Sounds & Notifications | Profile page (a person's info page) |
| `profile.verifyEncryption` | Verify Encryption | Profile page (a person's info page) |
| `attach.gif` | GIF | Chat > attach menu |
| `attach.files` | Files | Chat > attach menu |
| `attach.location` | Location | Chat > attach menu |
| `attach.poll` | Poll | Chat > attach menu |
| `storyEditor.text` | Text (Aa) | Story editor > tools |
| `storyEditor.trim` | Trim video | Story editor > tools |
| `storyEditor.crop` | Crop | Story editor > tools |
| `storyEditor.stickers` | Stickers | Story editor > tools |
| `storyEditor.draw` | Draw | Story editor > tools |
| `storyStickers.location` | Location | Story editor > Stickers |
| `storyStickers.link` | Link | Story editor > Stickers |
| `storyStickers.time` | Time | Story editor > Stickers |
| `chatMenu.reply` | Reply | Chat > message long-press menu |
| `chatMenu.forward` | Forward | Chat > message long-press menu |
| `chatMenu.quote` | Quote | Chat > message long-press menu |
| `chatMenu.replies` | Turn Off / On Replies (channel post) | Chat > message long-press menu |
| `chatMenu.copy` | Copy | Chat > message long-press menu |
| `chatMenu.bubbleStyle` | Bubble Style | Chat > message long-press menu |
| `chatMenu.edit` | Edit | Chat > message long-press menu |
| `chatMenu.editHistory` | Edit History | Chat > message long-press menu |
| `chatMenu.saveImage` | Save Image | Chat > message long-press menu |
| `chatMenu.info` | Info | Chat > message long-press menu |
| `chatMenu.pin` | Pin / Unpin | Chat > message long-press menu |
| `chatMenu.report` | Report | Chat > message long-press menu |

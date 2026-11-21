---
title: Notifications
order: 4
description: Get a popup, a sound or a push notification when a reply finishes or a memory needs review, and set up push on your phone.
---

Mythweaver tells you when something you are waiting for is ready: a character's reply finishes, or a memory draft waits for your review. You choose, per kind of event, whether you get a browser popup, a sound and, where the site has Web Push set up, a push notification on your devices. The settings are in **Settings** at `/settings/notifications`.

## The notifications inbox

The bell button in the top bar, **Notifications**, opens your inbox. It shows a count of new items. The inbox lists notifications whether or not you have muted them: the settings only decide popups, sounds and push.

- A finished reply stays while its chat is unread, and goes when you read the chat or after 7 days.
- Items that ask something of you, such as a memory draft to **Review** or an invite to **Accept** or **Decline**, stay until you deal with them or dismiss that one item.
- **Clear all** dismisses everything except the items that still ask something of you.

## Popups and sounds

Popups and sounds reach your open Mythweaver tabs.

- **Notification** is a browser popup. You don't get one for the chat you are looking at. The browser asks for permission the first time you click in the app.
- **Sound** plays a sound for the event, even while you watch the chat.

### To choose what notifies you

1. Open **Settings** at `/settings/notifications`.
2. In the **Events** grid, tick or clear the **Notification**, **Sound** and **Push** cell for each row.
3. To hear a sound, select its speaker button (**Play this sound**).

To silence everything for a while, turn on **Mute all notifications**. Each row keeps its settings for when you unmute.

| Event | When it fires |
| --- | --- |
| **New messages** | A character's new reply finishes. |
| **Regenerations** | A regenerated swipe or a rewrite finishes. Several swipes from one request notify once, after the last. |
| **Continues** | A continued message finishes. |
| **Memory reviews** | A memory draft is waiting for your review in the chat's Memory → Reviews. |

> [!NOTE]
> Popups need the page in a secure context in most browsers: an `https://` address, or `http://localhost` on the same computer. On a plain `http://` network address you may get sounds but no popups.

## Push notifications

Push notifications reach a device even with Mythweaver closed, including a phone with the app installed. They are available only when the site's admin has set up Web Push (see [Web Push](../administration/push.md)); until then the **Push** column and the **Push devices** panel don't appear.

Nothing is pushed while one of your Mythweaver tabs is visible and focused. If a tab is open but hidden, its popup and the push show as one notification.

### To enable push on a device

Each phone or computer enables push for itself, from that device:

1. Open Mythweaver on the device, over `https://` (or `http://localhost` on the same computer).
2. Go to **Settings** at `/settings/notifications`.
3. Under **Push devices**, select **Enable push on this browser**, and allow notifications when the browser asks.
4. Select **Send test** beside the device to check that it works.

The **Push** column of the **Events** grid decides which kinds are pushed. To keep reply text off a lock screen others can see, turn off **Show message text in push notifications**: a push then names the chat and character but not what they wrote.

### iPhone and iPad

On iPhone and iPad, push works only in the installed app:

1. Open the site in Safari.
2. Tap **Share**, then **Add to Home Screen**.
3. Open Mythweaver from the Home Screen.
4. Enable push from inside the installed app, as above.

### Managing devices

The **Push devices** list shows every device with push on, marking **This browser**, with the time of its **Last push**.

| Control | What it does |
| --- | --- |
| **Enable push on this browser** | Asks the browser for permission and adds it to the list. |
| **Disable on this browser** | Stops push to the browser you are using. |
| **Send test** | Sends a test notification to that device. |
| **Remove** | Stops push to that device and removes it from the list. |

You can have at most 10 devices. Enabling another drops the one used least recently. A device that no longer accepts push is removed when a push or test to it fails.

> [!WARNING]
> If notifications are blocked for the site in the browser, the panel says so. Allow them in the browser's site settings, then reload the page. If the admin replaces the site's push keys, every device stops receiving push and has to be enabled again.

## Settings reference

| Setting | Key | What it does |
| --- | --- | --- |
| **Mute all notifications** | `notifications.muted` | Silences every popup, sound and push. The inbox still lists notifications. |
| **Show message text in push notifications** | `notifications.push_preview` | Off, a push names the chat and character but not the text. |
| **Notify for …** | `notifications.<kind>.popup` | A browser popup for that kind. |
| **Sound for …** | `notifications.<kind>.sound` | A sound for that kind. |
| **Push for …** | `notifications.<kind>.push` | A push notification for that kind. |

The kinds are `new_message`, `regenerate`, `continue` and `memory_review`. All are on by default. An admin can set site values and lock any of them; see [Settings](settings.md#site-settings-and-locks).

---
title: Web Push
order: 5
description: Turning on push notifications for devices with the app closed.
---

Every install notifies users in their open tabs with a popup and a sound. Web Push adds notifications on devices where the app is closed, including phones with the app installed. Push stays off until you set VAPID keys, and the app works exactly as without it until then. For what users do, see [Notifications](../account/notifications.md).

## To turn on push

1. Run `mix web_push_ex.vapid`. It prints a public and a private key.
2. Set all three variables:

| Variable | Value |
| --- | --- |
| `MYTHWEAVER_VAPID_PUBLIC_KEY` | The public key. |
| `MYTHWEAVER_VAPID_PRIVATE_KEY` | The private key. |
| `MYTHWEAVER_VAPID_SUBJECT` | A `mailto:` address or `https:` URL push services may contact, for example `mailto:admin@example.org`. |

3. Restart the server. Setting only one or two of the variables stops it at boot.
4. Make sure users reach the site over a secure origin (below).

> [!WARNING]
> Keep the key pair. New keys invalidate every registered device, and each user must enable push again on every device.

## Secure origin requirement

Push, the service worker (`/sw.js`) and, in most browsers, the notification popups need the page in a secure context: `https://…`, or `http://localhost` on the same machine. A plain `http://<lan-ip>` or `http://<hostname>` address gets neither push nor popups.

Any TLS-terminating reverse proxy works: the compose stack's nginx (see [HTTPS and client IPs](https-and-proxies.md)), Caddy, nginx with a certificate, Traefik, Tailscale Serve or Services, or Cloudflare Tunnel. Mythweaver assumes none of them.

## iPhone and iPad

iOS and iPadOS deliver push only to the installed app. Users open the site in Safari, choose **Share** → **Add to Home Screen**, then enable push from inside the installed app.

## How devices are registered

Each device enables itself from **Settings** → **Notifications** → **Push devices**. An account can have at most 10 devices; enabling another drops the least recently used one. Nothing is pushed while one of the user's app tabs is visible and focused.

/// <reference lib="webworker" />

/**
 * The push service worker, served as `/sw.js` (built by `assets/build.ts`). It only shows
 * notifications: no `fetch` handler and no cache, so loading the app never goes through it.
 *
 *   * `push`: a Web Push from `Mythweaver.Notifications.Channels.Push`, JSON
 *     `{id, title, body, icon, path}`, shown with `tag: id` so an in-app popup for the same
 *     notification (the `.Notifications` hook, which also shows through this worker when it is
 *     active) replaces rather than doubles it.
 *   * `notificationclick`: focuses an open app window (a focused one first) and tells it to go to
 *     the notification's path (`app.ts` navigates on `{type: "navigate", path}`), or opens one.
 */
// A module, so this `self` (the service-worker scope) shadows the library's generic worker one.
export {};
declare const self: ServiceWorkerGlobalScope;

type Payload = { id: string; title: string; body?: string; icon?: string; path?: string };

const BADGE = "/images/icons/icon-192.png";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  const payload = (event.data?.json() ?? null) as Payload | null;
  if (!payload) return;

  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      icon: payload.icon,
      badge: BADGE,
      tag: payload.id,
      data: { path: payload.path ?? "/" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const path: string = event.notification.data?.path ?? "/";

  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      const client = windows.find((w) => w.focused) ?? windows[0];
      if (!client) {
        await self.clients.openWindow(path);
        return;
      }
      client.postMessage({ type: "navigate", path });
      await client.focus();
    })(),
  );
});

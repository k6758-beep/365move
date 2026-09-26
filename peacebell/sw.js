/* 厝邊平安鈴 v2 ─ 志工工作台推播（Service Worker） */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "厝邊平安鈴", {
    body: d.body || "",
    tag: d.tag || undefined,
    renotify: !!d.tag,
    requireInteraction: true,
    icon: "icon-192.png",
    badge: "icon-192.png",
    data: { url: d.url || "care.html" }
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL(e.notification.data.url || "care.html", self.registration.scope).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.includes("care.html")) { await w.navigate(url).catch(() => {}); return w.focus(); }
    }
    return self.clients.openWindow(url);
  })());
});

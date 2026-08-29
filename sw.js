// ============================================================
// Cambio turni — service worker
//
// Serve SOLO a ricevere le notifiche. Di proposito non mette niente in
// cache: l'app deve restare sempre quella pubblicata, senza sorprese da
// versioni vecchie rimaste in memoria.
// ============================================================

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; }
  catch { d = { title: "Cambio turni", body: e.data ? e.data.text() : "" }; }

  e.waitUntil(self.registration.showNotification(d.title || "Cambio turni", {
    body: d.body || "",
    icon: "icon-512.png",
    badge: "icon-512.png",
    tag: d.tag || "cambio-turni",
    renotify: true,
    data: { url: d.url || "./" },
  }));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  e.waitUntil((async () => {
    const aperte = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    // se l'app è già aperta la portiamo davanti invece di aprirne un'altra
    for (const c of aperte) {
      if (c.url.includes("cambio-turni")) { await c.focus(); return; }
    }
    await self.clients.openWindow(e.notification.data?.url || "./");
  })());
});

// Service worker za obaveštenja na telefonu (Web Push).
// Prima obaveštenje od servera i prikazuje ga i kad je aplikacija zatvorena;
// dodir na obaveštenje otvara aplikaciju (i sto, ako je naveden).

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let msg = { title: 'Poker klub Triling', body: '' };
  try {
    msg = Object.assign(msg, event.data ? event.data.json() : {});
  } catch (_) {
    if (event.data) msg.body = event.data.text();
  }
  const base = self.registration.scope; // npr. https://sajt/igra/
  const url = msg.tableId ? `${base}?table=${encodeURIComponent(msg.tableId)}` : base;
  event.waitUntil(
    self.registration.showNotification(msg.title, {
      body: msg.body,
      icon: `${base}icons/Icon-192.png`,
      badge: `${base}icons/Icon-192.png`,
      tag: msg.tag || undefined,
      renotify: !!msg.tag,
      vibrate: [120, 60, 120],
      data: { url, tableId: msg.tableId || null },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const { url, tableId } = event.notification.data || {};
  event.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const c of all) {
        if (c.url.startsWith(self.registration.scope)) {
          // Aplikacija je već otvorena: prebaci se na nju i reci joj koji sto da otvori.
          await c.focus();
          if (tableId) c.postMessage({ type: 'open-table', tableId });
          return;
        }
      }
      await self.clients.openWindow(url || self.registration.scope);
    })(),
  );
});

// Zamena za stari Flutter service worker: telefoni koji su ranije sačuvali aplikaciju
// (stara verzija u kešu) odmah brišu keš i učitavaju novu verziju sa servera.
// Posle toga aplikacija registruje push-sw.js za obaveštenja.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
      await self.clients.claim();
      const all = await self.clients.matchAll({ type: 'window' });
      for (const c of all) c.navigate(c.url).catch(() => {});
    })(),
  );
});

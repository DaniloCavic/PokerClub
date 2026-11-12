// Pomoćne funkcije za obaveštenja (pozivaju se iz Flutter-a).
(function () {
  const isIos = /iphone|ipad|ipod/i.test(navigator.userAgent);
  const standalone =
    window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
  let registration = null;
  let pendingTable = null;
  const tableListeners = [];

  function b64ToBytes(b64) {
    const pad = '='.repeat((4 - (b64.length % 4)) % 4);
    const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
    return Uint8Array.from(raw, (c) => c.charCodeAt(0));
  }

  async function reg() {
    if (registration) return registration;
    if (!('serviceWorker' in navigator)) return null;
    registration = await navigator.serviceWorker.register('push-sw.js');
    return registration;
  }

  if ('serviceWorker' in navigator) {
    reg().catch(() => {});
    navigator.serviceWorker.addEventListener('message', (e) => {
      if (e.data && e.data.type === 'open-table') {
        if (tableListeners.length) tableListeners.forEach((f) => f(e.data.tableId));
        else pendingTable = e.data.tableId;
      }
    });
  }

  window.trilingPush = {
    /** "unsupported", "ios-install" (iPhone: prvo dodati na početni ekran), "default", "granted", "denied" */
    status() {
      if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
        return isIos && !standalone ? 'ios-install' : 'unsupported';
      }
      return Notification.permission;
    },
    /** Traži dozvolu i pretplaćuje uređaj; vraća pretplatu kao JSON tekst (ili prazno). */
    async subscribe(publicKey) {
      try {
        const r = await reg();
        if (!r) return '';
        const perm = await Notification.requestPermission();
        if (perm !== 'granted') return '';
        await navigator.serviceWorker.ready;
        let sub = await r.pushManager.getSubscription();
        if (!sub) sub = await r.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(publicKey) });
        return JSON.stringify(sub);
      } catch (e) {
        console.warn('Obaveštenja:', e);
        return '';
      }
    },
    /** Kad je sto otvoren dodirom na obaveštenje dok je aplikacija bila otvorena. */
    onOpenTable(cb) {
      tableListeners.push(cb);
      if (pendingTable) {
        cb(pendingTable);
        pendingTable = null;
      }
    },
  };
})();

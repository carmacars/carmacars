// CarmaCars alerts (migration 0300). This service worker only shows the alerts the site sends and opens their page.
// It has no fetch handler and caches nothing: every page always comes from the site, and nothing personal is kept on
// the device. The alerts card registers it with scope "/" when a person turns alerts on.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch { d = { body: event.data ? event.data.text() : '' }; }
  const title = typeof d.title === 'string' && d.title ? d.title : 'CarmaCars';
  event.waitUntil(self.registration.showNotification(title, {
    body: typeof d.body === 'string' ? d.body : '',
    tag: typeof d.tag === 'string' ? d.tag : undefined,
    data: { url: typeof d.url === 'string' ? d.url : '/' },
    icon: '/icons/icon-192.png',
    badge: '/icons/badge-96.png'
  }));
});

// a tap opens the page in a CarmaCars window already open, or a new one; only pages of this site
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  let url = new URL('/', self.location.origin);
  try {
    const u = new URL((event.notification.data && event.notification.data.url) || '/', self.location.origin);
    if (u.origin === self.location.origin) url = u;
  } catch { /* the portal */ }
  event.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of open) {
      if (new URL(c.url).origin !== self.location.origin) continue;
      await c.focus();
      if ('navigate' in c) { try { await c.navigate(url.href); return; } catch { /* not controlled: open a new one */ } }
      break;
    }
    await self.clients.openWindow(url.href);
  })());
});

// the browser replaced the push address: subscribe again with the same key; the alerts card sends the new address to
// the site the next time the person opens it (it compares the browser's address with the ones the site knows)
self.addEventListener('pushsubscriptionchange', (event) => {
  const options = event.oldSubscription && event.oldSubscription.options;
  if (options) event.waitUntil(self.registration.pushManager.subscribe(options).catch(() => undefined));
});

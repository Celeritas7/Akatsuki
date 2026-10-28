// Akatsuki service worker. Cache name = AKATSUKI_BUILD from js/config.js — bump that, nothing here.
self.window = self; // config.js writes to window.*; a worker has no window — without this the SW never installs
try { importScripts('./js/config.js'); } catch (e) { console.warn('[akatsuki sw] config.js failed', e); }
const CACHE = 'akatsuki-' + (self.AKATSUKI_BUILD || 'dev');
const DS = '_ds/scriptura-design-system-72b4840c-4eb9-43ac-b161-8ce4436f9707';
const SHELL = [
  './', './index.html', './support.js', './manifest.json', './js/config.js', './js/akatsuki-client.js', './js/akatsuki-location.js', './js/akatsuki-broadcast.js', './js/akatsuki-broadcast-panel.js',
  DS + '/styles.css', DS + '/_ds_bundle.js', DS + '/tokens/fonts.css', DS + '/tokens/colors.css', DS + '/tokens/typography.css', DS + '/tokens/spacing.css', DS + '/tokens/effects.css',
  './assets/favicon.png', './assets/apple-touch-icon.png', './assets/logo-moon-3a.png', './assets/icon-192.png', './assets/icon-512.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'
];
const CACHED_ORIGINS = [self.location.origin, 'https://cdn.jsdelivr.net', 'https://fonts.googleapis.com', 'https://fonts.gstatic.com'];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => null)))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const u = new URL(e.request.url);
  if (!CACHED_ORIGINS.includes(u.origin) || u.hostname.endsWith('.supabase.co')) return; // hub data is never cached
  // network first, cache fallback — never a stale shell while online
  e.respondWith(fetch(e.request).then(r => {
    if (r.ok || r.type === 'opaque') { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
    return r;
  }).catch(() => caches.match(e.request, { ignoreSearch: u.origin === self.location.origin })));
});

// R054 · broadcast push.  The payload is {title, body, url, tag}.  Tapping focuses an open hub tab or opens one;
// the overlay there (and in every other app) is what gets answered.
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch { d = { title: 'Akatsuki', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Akatsuki', {
    body: d.body || '', tag: d.tag || 'akatsuki', renotify: true, requireInteraction: true,
    icon: './assets/icon-192.png', badge: './assets/icon-192.png', data: { url: d.url || './#broadcast' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './#broadcast', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    const hub = list.find(c => c.url.startsWith(self.registration.scope));
    return hub ? hub.focus() : self.clients.openWindow(url);
  }));
});

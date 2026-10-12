// Akatsuki service worker. Cache name = AKATSUKI_BUILD from js/config.js — bump that, nothing here.
importScripts('./js/config.js');
const CACHE = 'akatsuki-' + (self.AKATSUKI_BUILD || 'dev');
const DS = '_ds/scriptura-design-system-72b4840c-4eb9-43ac-b161-8ce4436f9707';
const SHELL = [
  './', './index.html', './support.js', './manifest.json', './js/config.js', './js/akatsuki-client.js', './js/akatsuki-location.js',
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
    if (r.ok || r.type === 'opaque') caches.open(CACHE).then(c => c.put(e.request, r.clone()));
    return r;
  }).catch(() => caches.match(e.request, { ignoreSearch: u.origin === self.location.origin })));
});

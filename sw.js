/* Service Worker — Emergencia Sísmica Venezuela
 * Objetivo: que la app abra y funcione aunque la red falle (contexto de emergencia).
 * Estrategia:
 *   - App shell (HTML, manifest, iconos): cache-first con actualización en segundo plano.
 *   - Municipios y librerías de CDN: se cachean la primera vez que se usan.
 *   - API de Supabase (reportes): SIEMPRE por red, sin caché (no mostrar datos viejos en una emergencia).
 */
const VERSION = 'ev-v2';
const SHELL_CACHE = `shell-${VERSION}`;
const RUNTIME_CACHE = `runtime-${VERSION}`;

const SHELL_ASSETS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon.svg',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
      .catch(() => {}) // si algún asset falla, no abortar la instalación
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k !== SHELL_CACHE && k !== RUNTIME_CACHE).map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

// Permite que la página fuerce la activación de una nueva versión
self.addEventListener('message', (event) => {
  if (event.data === 'skipWaiting') self.skipWaiting();
});

// Push (avisos con la app cerrada). El servidor envía { title, body, url, tag }.
self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; }
  catch (e) { data = { body: (event.data && event.data.text) ? event.data.text() : '' }; }
  const title = data.title || 'Emergencia Sísmica · Venezuela';
  const options = {
    body: data.body || '',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    tag: data.tag || 'ev-push',
    renotify: true,
    data: { url: data.url || './index.html' }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

// Al tocar el aviso: enfocar una pestaña abierta o abrir la app
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || './index.html';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      for (const w of wins) { if ('focus' in w) return w.focus(); }
      if (clients.openWindow) return clients.openWindow(target);
    })
  );
});

function isSupabase(url) { return /supabase\.co$/i.test(url.hostname); }
function isTile(url) { return /(basemaps\.cartocdn\.com|tile\.openstreetmap)/i.test(url.hostname); }

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (e) { return; }

  // 1) Datos de reportes: siempre red, nunca caché (evita información obsoleta)
  if (isSupabase(url)) return; // deja pasar a la red por defecto

  // 2) Teselas del mapa: cache-first (son estáticas y pesan datos)
  if (isTile(url)) {
    event.respondWith(cacheFirst(req, RUNTIME_CACHE));
    return;
  }

  // 3) Navegaciones (abrir la app): red con respaldo al shell cacheado
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).catch(() => caches.match('./index.html').then((r) => r || caches.match('./')))
    );
    return;
  }

  // 4) Resto (CDN de librerías, municipios, iconos, css): stale-while-revalidate
  event.respondWith(staleWhileRevalidate(req, RUNTIME_CACHE));
});

async function cacheFirst(req, cacheName) {
  const cached = await caches.match(req);
  if (cached) return cached;
  try {
    const res = await fetch(req);
    if (res && (res.ok || res.type === 'opaque')) {
      const cache = await caches.open(cacheName);
      cache.put(req, res.clone());
    }
    return res;
  } catch (e) {
    return cached || Response.error();
  }
}

async function staleWhileRevalidate(req, cacheName) {
  const cached = await caches.match(req);
  const network = fetch(req)
    .then((res) => {
      if (res && (res.ok || res.type === 'opaque')) {
        caches.open(cacheName).then((cache) => cache.put(req, res.clone())).catch(() => {});
      }
      return res;
    })
    .catch(() => null);
  return cached || (await network) || Response.error();
}

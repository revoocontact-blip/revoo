/* Orleoo — mémoire hors ligne (service worker)
   - Pages : réseau d'abord, copie en mémoire si pas de connexion.
   - Polices, logos, icônes, bibliothèque : mémoire d'abord (rapide).
   - Base de données et paiements : jamais mis en mémoire. */
const VERSION = "orleoo-v1";
const STATIC = ["./", "./index.html", "./manifest.webmanifest", "./vendor/supabase-js-2.117.3.js",
  "./fonts/dm-sans-latin-400-normal.woff2", "./fonts/dm-sans-latin-600-normal.woff2", "./fonts/dm-sans-latin-700-normal.woff2",
  "./logos/orleoo-logo.png", "./logos/orleoo-icone-192.png", "./logos/favicon-32.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(STATIC)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin) return;          // Supabase, photos, Mangopay : réseau uniquement
  if (req.mode === "navigate" || url.pathname.endsWith("/index.html") || url.pathname.endsWith("/")) {
    e.respondWith(fetch(req).then(r => { const copy = r.clone(); caches.open(VERSION).then(c => c.put("./index.html", copy)); return r; })
      .catch(() => caches.match("./index.html")));
    return;
  }
  if (/\/(fonts|logos|vendor)\//.test(url.pathname) || url.pathname.endsWith(".webmanifest")) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => { if (r.ok) { const copy = r.clone(); caches.open(VERSION).then(c => c.put(req, copy)); } return r; })));
  }
});

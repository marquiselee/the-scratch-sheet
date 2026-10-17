// The Scratch Sheet service worker: always load the newest app when online (network first, no HTTP cache),
// and fall back to the last copy when offline. Nothing else is intercepted.
const CACHE = "ss-shell-v1";
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));
self.addEventListener("fetch", e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin) return;
  const page = req.mode === "navigate" || req.destination === "document" || url.pathname.endsWith("/manifest.webmanifest");
  if (!page) return;
  e.respondWith((async () => {
    try {
      const res = await fetch(url.href, { cache: "no-store", credentials: "same-origin" });
      if (res.ok) { const c = await caches.open(CACHE); c.put(url.origin + url.pathname, res.clone()); }
      return res;
    } catch (err) {
      return (await caches.match(url.origin + url.pathname)) || (await caches.match(new URL("./", location).href)) || Response.error();
    }
  })());
});

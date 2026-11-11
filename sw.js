// Folha da Casa: funciona sem internet depois da primeira visita.
// Página: busca na rede primeiro (para receber atualizações) e usa o cache se estiver offline.
// Demais arquivos (ícones, fontes, gerador de PDF): cache primeiro, atualizando em segundo plano.
const CACHE = "folha-da-casa-736913faea";
const ESSENCIAIS = [
  "/",
  "/manifest.webmanifest",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/config.js",
  "https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"
];
// Só estes endereços passam pelo cache; a API da nuvem (Supabase) vai sempre direto à rede.
const CACHEAVEIS = [self.location.origin, "https://cdnjs.cloudflare.com", "https://cdn.jsdelivr.net", "https://fonts.googleapis.com", "https://fonts.gstatic.com"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ESSENCIAIS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  if (!CACHEAVEIS.includes(new URL(req.url).origin)) return;
  if (req.mode === "navigate" || new URL(req.url).pathname === "/config.js") {
    e.respondWith(
      fetch(req)
        .then((res) => { const copia = res.clone(); const k = req.mode === "navigate" ? "/" : req; caches.open(CACHE).then((c) => c.put(k, copia)); return res; })
        .catch(() => caches.match(req.mode === "navigate" ? "/" : req))
    );
    return;
  }
  e.respondWith(
    caches.match(req).then((emCache) => {
      const daRede = fetch(req)
        .then((res) => {
          if (res && (res.ok || res.type === "opaque")) { const copia = res.clone(); caches.open(CACHE).then((c) => c.put(req, copia)); }
          return res;
        })
        .catch(() => emCache);
      return emCache || daRede;
    })
  );
});

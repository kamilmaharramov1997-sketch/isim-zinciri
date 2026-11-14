// İsim Zinciri: önce internetten yeni sürümü al, internet yoksa kayıtlı sürümü aç
const C = 'isim-zinciri-v14', WPC = 'iz-duvar-v1';
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(C).then(c => c.addAll(['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png']))); });
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const u = new URL(e.request.url);
  // Duvar kağıdı fotoğrafları: bir kez indir, sonra telefondan aç (internetsiz de görünür)
  if (u.hostname === 'images.unsplash.com'){
    e.respondWith(caches.open(WPC).then(c => c.match(e.request).then(hit => hit || fetch(e.request).then(r => { c.put(e.request, r.clone()); return r; }))));
    return;
  }
  if (u.origin !== location.origin) return;
  e.respondWith(fetch(e.request).then(r => { const copy = r.clone(); caches.open(C).then(c => c.put(e.request, copy)); return r; })
    .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html'))));
});

// Bildirimler: davet, arkadaşlık isteği, geri bildirim (kilit ekranında ve bildirim panelinde görünür)
self.addEventListener('push', e => {
  let d = {};
  try { const j = e.data ? e.data.json() : {}; d = j.data || j; } catch(_){}
  if (!d.title) return;
  const actions = d.a1 ? [{ action:'go', title:d.a1 }, { action:'no', title:d.a2 || '✕' }] : [];
  e.waitUntil(self.registration.showNotification(d.title, {
    body: d.body || '', icon: 'icon-192.png', badge: 'icon-192.png', tag: d.tag || d.type, renotify: true,
    requireInteraction: d.type === 'invite', vibrate: [200, 100, 200], data: { url: d.url || './' }, actions
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  if (e.action === 'no') return;
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list){ if (c.url.startsWith(self.registration.scope)){ c.postMessage({ iz:'nav', url }); return c.focus(); } }
    return self.clients.openWindow(url);
  }));
});

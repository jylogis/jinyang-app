// 진양 기사앱 서비스워커: 항상 최신 버전을 먼저 받고, 인터넷이 끊기면 저장해 둔 화면을 보여줘요.
var CACHE = 'jinyang-app-v17';
self.addEventListener('install', function (e) { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function (e) {
  if (e.request.method !== 'GET') return;
  e.respondWith(
    fetch(e.request).then(function (res) {
      var copy = res.clone();
      caches.open(CACHE).then(function (c) { c.put(e.request, copy); });
      return res;
    }).catch(function () { return caches.match(e.request); })
  );
});

// 알림을 누르면 앱을 열어요
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = (e.notification.data && e.notification.data.url) || './?source=noti';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) { if ('focus' in list[i]) return list[i].focus(); }
    return self.clients.openWindow(url);
  }));
});

// 서버에서 보낸 알림 받기
self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || '진양로지스틱스', {
    body: d.body || '', icon: 'icon-192.png', badge: 'badge-96.png', tag: d.tag || undefined,
    renotify: !!d.tag, vibrate: [200, 100, 200], data: { url: d.url || './?source=noti' }
  }));
});

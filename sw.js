// 진양 기사앱 서비스워커: 항상 최신 버전을 먼저 받고, 인터넷이 끊기면 저장해 둔 화면을 보여줘요.
var CACHE = 'jinyang-app-v6';
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

// Service worker mínimo: apenas repassa a rede (NÃO faz cache), para não travar
// atualizações. Serve só para o app ser instalável (ícone na tela / tela cheia).
self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => self.clients.claim());
self.addEventListener('fetch', e => { e.respondWith(fetch(e.request).catch(() => new Response('', {status: 504}))); });

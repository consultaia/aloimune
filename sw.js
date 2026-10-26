// Service worker mínimo: apenas repassa a rede (NÃO faz cache), para não travar
// atualizações. Serve só para o app ser instalável (ícone na tela / tela cheia).
// Páginas pedem confirmação ao servidor (no-cache): versão nova aparece ao abrir o app.
self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => self.clients.claim());
self.addEventListener('fetch', e => {
  const r = e.request;
  const pagina = r.method === 'GET' && (r.mode === 'navigate' || r.destination === 'document' || r.destination === 'iframe');
  e.respondWith((pagina ? fetch(r.url, { cache: 'no-cache', credentials: 'same-origin' }) : fetch(r)).catch(() => new Response('', {status: 504})));
});

/* ============================================================================
 *  Worker de Acessos da Clínica
 *  Guarda a chave secreta (service_role) e só obedece se quem pediu for GESTOR.
 *  A tela "Acessos" (acessos.html) chama este Worker para criar/editar logins.
 *
 *  DEPLOY (Cloudflare):
 *   1. dash.cloudflare.com > Workers & Pages > Create > Worker. Cole este código.
 *   2. Em Settings > Variables and Secrets, adicione (como Secret):
 *        SB_URL      = https://SEU-PROJETO.supabase.co
 *        SB_SERVICE  = a chave "service_role" (Settings > API > service_role) — SECRETA!
 *   3. Deploy. Copie a URL do Worker (ex.: https://acessos.SEU.workers.dev)
 *      e cole em WORKER_URL no topo do acessos.html.
 *
 *  A chave service_role NUNCA vai para o navegador — fica só aqui no Worker.
 * ========================================================================== */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

export default {
  async fetch(req, env) {
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
    if (req.method !== "POST") return json({ error: "Use POST" }, 405);

    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (!token) return json({ error: "Sem autenticação." }, 401);

    // Quem está chamando?
    const who = await fetch(env.SB_URL + "/auth/v1/user", {
      headers: { apikey: env.SB_SERVICE, authorization: "Bearer " + token },
    }).then((r) => r.json()).catch(() => null);
    if (!who || !who.id) return json({ error: "Sessão inválida." }, 401);

    // É gestor?
    const perfil = await rest(env, "GET", "/rest/v1/perfis?select=papel&id=eq." + who.id)
      .then((a) => (Array.isArray(a) ? a[0] : null));
    if (!perfil || perfil.papel !== "gestor")
      return json({ error: "Apenas o gestor pode gerenciar acessos." }, 403);

    const body = await req.json().catch(() => ({}));
    try {
      switch (body.action) {
        case "listar": {
          const rows = await rest(env, "GET", "/rest/v1/perfis?select=id,papel,nome&order=nome.asc");
          // junta o e-mail de login (auth) para a tela mostrar "código 483920" ou o e-mail
          const users = await adminAuth(env, "GET", "/auth/v1/admin/users?per_page=1000", null);
          const mapa = {}; ((users && users.users) || []).forEach((u) => { mapa[u.id] = u.email; });
          return json({ ok: true, usuarios: (Array.isArray(rows) ? rows : []).map((r) => ({ ...r, email: mapa[r.id] || null })) });
        }
        case "criar": {
          const { nome, email, senha, papel, criarColaborador, funcao, carga_horaria, regime } = body;
          if (!email || !senha || !papel) return json({ error: "Preencha nome, código/e-mail, senha e perfil." }, 400);
          const u = await adminAuth(env, "POST", "/auth/v1/admin/users", { email, password: senha, email_confirm: true });
          if (!u || !u.id) return json({ error: (u && (u.msg || u.error_description || u.message)) || "Não consegui criar (código/e-mail já existe?)." }, 400);
          await rest(env, "POST", "/rest/v1/perfis", { id: u.id, papel, nome: nome || email });
          if (criarColaborador) {
            await rest(env, "POST", "/rest/v1/colaboradores", {
              nome: nome || email, funcao: funcao || null,
              carga_horaria: (carga_horaria === "" || carga_horaria == null) ? null : Number(carga_horaria),
              regime: regime || null, ativo: true,
            });
          }
          return json({ ok: true, id: u.id });
        }
        case "papel": {
          if (!body.id || !body.papel) return json({ error: "Faltam dados." }, 400);
          await rest(env, "PATCH", "/rest/v1/perfis?id=eq." + body.id, { papel: body.papel });
          return json({ ok: true });
        }
        case "senha": {
          if (!body.id || !body.senha) return json({ error: "Faltam dados." }, 400);
          await adminAuth(env, "PUT", "/auth/v1/admin/users/" + body.id, { password: body.senha });
          return json({ ok: true });
        }
        case "remover": {
          if (!body.id) return json({ error: "Faltam dados." }, 400);
          if (body.id === who.id) return json({ error: "Você não pode remover a si mesmo." }, 400);
          await rest(env, "DELETE", "/rest/v1/perfis?id=eq." + body.id);
          await adminAuth(env, "DELETE", "/auth/v1/admin/users/" + body.id);
          return json({ ok: true });
        }
        default:
          return json({ error: "Ação desconhecida." }, 400);
      }
    } catch (e) {
      return json({ error: String(e) }, 500);
    }
  },
};

// Helpers -------------------------------------------------------------------
function headers(env, extra) {
  return { apikey: env.SB_SERVICE, authorization: "Bearer " + env.SB_SERVICE, "Content-Type": "application/json", ...extra };
}
async function rest(env, method, path, body) {
  const r = await fetch(env.SB_URL + path, {
    method,
    headers: headers(env, { Prefer: "return=representation" }),
    body: body ? JSON.stringify(body) : undefined,
  });
  const txt = await r.text();
  try { return JSON.parse(txt); } catch { return txt; }
}
async function adminAuth(env, method, path, body) {
  const r = await fetch(env.SB_URL + path, {
    method,
    headers: headers(env),
    body: body ? JSON.stringify(body) : undefined,
  });
  const txt = await r.text();
  try { return JSON.parse(txt); } catch { return txt; }
}

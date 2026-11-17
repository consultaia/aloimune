/* ==========================================================================
   ERROS DO SUPABASE EM PORTUGUÊS
   Carregado logo depois do supabase-js em todas as telas. Quando o banco
   responde com erro, troca a mensagem técnica em inglês ("relation ... does
   not exist", "row-level security", "duplicate key"...) por uma frase em
   português dizendo o que aconteceu e o que fazer. O texto original vai no
   fim, entre colchetes, para o suporte identificar o problema.
   ========================================================================== */
(function(){
  if(!window.fetch || window.__supabasePt) return;
  window.__supabasePt = true;
  const ORIG = window.fetch.bind(window);

  function traduzir(e){
    const msg = String(e.message || e.error_description || e.error || "");
    const code = String(e.code || "");
    const nome = (re) => { const m = msg.match(re); return m ? m[1].replace(/^public\./, "") : ""; };
    if(code === "42P01" || code === "PGRST205" || /relation .* does not exist|Could not find the table/i.test(msg))
      return `O banco de dados ainda n\u00e3o foi atualizado para esta fun\u00e7\u00e3o${nome(/(?:relation|table) ["']?([\w.]+)/i) ? ` (falta a tabela ${nome(/(?:relation|table) ["']?([\w.]+)/i)})` : ""}. Avise o suporte t\u00e9cnico.`;
    if(code === "PGRST204" || code === "42703" || /Could not find the '.*' column|column .* does not exist|has no field/i.test(msg))
      return `O banco de dados ainda n\u00e3o foi atualizado para esta fun\u00e7\u00e3o${nome(/(?:the '|column ["']?|field ["'])([\w.]+)/i) ? ` (falta o campo ${nome(/(?:the '|column ["']?|field ["'])([\w.]+)/i)})` : ""}. Avise o suporte t\u00e9cnico.`;
    if(code === "42883" || code === "PGRST202" || /function .* does not exist|Could not find the function/i.test(msg))
      return "O banco de dados ainda n\u00e3o foi atualizado para esta fun\u00e7\u00e3o (falta uma rotina do banco). Avise o suporte t\u00e9cnico.";
    if(code === "42501" || /row-level security|permission denied/i.test(msg))
      return "Seu perfil n\u00e3o tem permiss\u00e3o para fazer isso. Se precisar, fale com a gestora.";
    if(code === "23505" || /duplicate key/i.test(msg))
      return "Esse registro j\u00e1 existe \u2014 n\u00e3o foi salvo de novo.";
    if(code === "23503" || /foreign key/i.test(msg))
      return "N\u00e3o deu para salvar: o registro est\u00e1 ligado a outro que n\u00e3o existe mais (ou ainda est\u00e1 em uso).";
    if(code === "23502" || /null value in column/i.test(msg))
      return `Falta preencher um campo obrigat\u00f3rio${nome(/column ["']([\w]+)["']/i) ? ` (${nome(/column ["']([\w]+)["']/i)})` : ""}.`;
    if(code === "23514" || /check constraint/i.test(msg))
      return "Um dos campos tem um valor que n\u00e3o \u00e9 aceito. Confira e tente de novo.";
    if(code === "22P02" || code === "22007" || code === "22008" || /invalid input syntax|date\/time field value out of range/i.test(msg))
      return "Um dos campos est\u00e1 num formato inv\u00e1lido (data, hora ou n\u00famero). Confira e tente de novo.";
    if(/JWT expired|invalid JWT|refresh token/i.test(msg))
      return "Sua sess\u00e3o expirou. Saia e entre de novo na plataforma.";
    if(/Invalid login credentials/i.test(msg))
      return "E-mail ou senha incorretos.";
    return null;
  }

  window.fetch = async function(input, init){
    const resp = await ORIG(input, init);
    try{
      const url = typeof input === "string" ? input : (input && input.url) || "";
      if(resp.ok || !/\.supabase\.co\/(rest|auth|storage)\/v1\//.test(url)) return resp;
      const ct = resp.headers.get("content-type") || "";
      if(!/json/.test(ct)) return resp;
      const corpo = await resp.clone().json();
      const pt = traduzir(corpo || {});
      if(!pt) return resp;
      const original = corpo.message || corpo.error_description || corpo.error || "";
      const novo = { ...corpo, message: `${pt} [detalhe t\u00e9cnico: ${original}]` };
      if(corpo.error_description) novo.error_description = novo.message;
      return new Response(JSON.stringify(novo), { status: resp.status, statusText: resp.statusText, headers: resp.headers });
    }catch(_){ return resp; }
  };
})();

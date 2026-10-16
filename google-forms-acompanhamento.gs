/* ============================================================================
   ALOIMUNE | ACOMPANHAMENTO PÓS-CONSULTA — Google Forms → Plataforma
   Cada resposta enviada no formulário vira um acompanhamento na plataforma
   (módulo Acompanhamento). A planilha de respostas do Forms continua igual.

   COMO INSTALAR (uma vez só):
   1. No Supabase, rode acompanhamento-schema.sql (SQL Editor) e depois:
        select valor from public.clinica_integracoes where chave = 'acomp_forms_segredo';
      Copie o valor que aparecer.
   2. Abra o formulário no Google Forms (modo edição) → menu ⋮ → Editor de scripts
      (ou Extensões → Apps Script). Apague o que tiver lá e cole este arquivo inteiro.
   3. Cole a senha copiada no passo 1 em SEGREDO, logo abaixo. Salve (Ctrl+S).
   4. No topo do editor, escolha a função "instalar" e clique em Executar.
      O Google vai pedir autorização: escolha sua conta → Avançado → Acessar
      (não seguro) → Permitir. É o seu próprio script.
   5. Pronto. Para trazer as respostas que já existem, execute
      "enviarRespostasAntigas" (pode repetir; nenhuma resposta é duplicada).

   As perguntas são reconhecidas pelo título (Paciente, Telefone/WhatsApp, Data da
   consulta, Próximo passo, Prazo, Responsável, Situação, Observações). Perguntas
   que não forem reconhecidas vão para "Observações", nada se perde.
   Se algum envio falhar, o Google manda um e-mail para o dono do formulário.
   ============================================================================ */

const SUPABASE_URL = "https://lnzvkfbcpnfmfvbdafab.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxuenZrZmJjcG5mbWZ2YmRhZmFiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk0ODg2OTgsImV4cCI6MjA5NTA2NDY5OH0.EE1PF8moQPawVpsrM87iKa8IrD2yJ6tYKb0zAl17tbg";
const SEGREDO = "COLE_AQUI_A_SENHA_DO_SUPABASE";

/* ------------------------------------------------------------- instalação */
function instalar() {
  if (!SEGREDO || SEGREDO.indexOf("COLE_AQUI") === 0) throw new Error("Cole a senha do Supabase em SEGREDO antes de instalar.");
  const form = FormApp.getActiveForm();
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === "aoEnviar")
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger("aoEnviar").forForm(form).onFormSubmit().create();
  Logger.log("Instalado. Cada nova resposta de \"" + form.getTitle() + "\" vai para a plataforma.");
}

// chamado pelo Google a cada resposta enviada
function aoEnviar(e) {
  enviar_(e.response);
}

// manda para a plataforma todas as respostas que já existem (não duplica)
function enviarRespostasAntigas() {
  const respostas = FormApp.getActiveForm().getResponses();
  let ok = 0, repetidas = 0, erros = [];
  respostas.forEach(function (r, i) {
    try { const res = enviar_(r); if (res && res.repetida) repetidas++; else ok++; }
    catch (err) { erros.push("Resposta " + (i + 1) + ": " + err.message); }
  });
  Logger.log(ok + " enviada(s), " + repetidas + " já estavam na plataforma, " + erros.length + " com erro.");
  if (erros.length) Logger.log(erros.join("\n"));
}

// testa com a última resposta do formulário
function testarUltimaResposta() {
  const rs = FormApp.getActiveForm().getResponses();
  if (!rs.length) throw new Error("O formulário ainda não tem respostas.");
  Logger.log(JSON.stringify(montarDados_(rs[rs.length - 1]), null, 2));
  Logger.log(JSON.stringify(enviar_(rs[rs.length - 1])));
}

/* ------------------------------------------------------------- envio */
function enviar_(resposta) {
  const dados = montarDados_(resposta);
  const res = UrlFetchApp.fetch(SUPABASE_URL + "/rest/v1/rpc/acomp_receber_forms", {
    method: "post",
    contentType: "application/json",
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: "Bearer " + SUPABASE_ANON_KEY },
    payload: JSON.stringify({ segredo: SEGREDO, dados: dados }),
    muteHttpExceptions: true,
  });
  const codigo = res.getResponseCode();
  if (codigo >= 300) throw new Error("Plataforma respondeu " + codigo + ": " + res.getContentText());
  return JSON.parse(res.getContentText() || "{}");
}

/* ------------------------------------------------------------- leitura das respostas */
function normalizar_(s) {
  return String(s || "")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .replace(/ª/g, "a").replace(/º/g, "o")
    .toLowerCase()
    .replace(/[^a-z0-9/ ]+/g, " ")
    .replace(/\s+/g, " ").trim();
}

// qual campo da plataforma é cada pergunta (pelo título)
function campoDaPergunta_(titulo) {
  const t = normalizar_(titulo);
  if (/proximo passo|proximos passos/.test(t)) return "passos";
  if (/responsavel/.test(t)) return "responsavel";          // antes de telefone: "Responsável pelo contato"
  if (/telefone|whatsapp|celular/.test(t)) return "telefone";
  if (/data da consulta|data consulta/.test(t)) return "data_consulta";
  if (/prazo/.test(t)) return "prazo";
  if (/situacao|status/.test(t)) return "situacao";
  if (/observac/.test(t)) return "observacoes";
  if (/paciente|nome/.test(t)) return "paciente";
  return null;
}

// opção marcada → código usado na plataforma
function codigoDoPasso_(opcao) {
  const t = normalizar_(opcao);
  if (/^1a etapa|primeira etapa/.test(t)) return "etapa1";
  if (/^2a etapa|segunda etapa/.test(t)) return "etapa2";
  if (/^3a etapa|terceira etapa/.test(t)) return "etapa3";
  if (/crossmatch|cross match/.test(t)) return "reforco_crossmatch";
  if (/intralipid/.test(t)) return "reforco_intralipid";
  if (/exame/.test(t)) return "exames_pre";
  if (/vacina/.test(t)) return "vacina";
  if (/^usg|ultrass/.test(t)) return "usg";
  if (/^retorno/.test(t)) return "retorno";
  if (/^consulta/.test(t)) return "consulta";
  if (/^outro/.test(t)) return "outro";
  return null; // texto livre da opção "Outro" do Forms
}

function codigoDaSituacao_(v) {
  const t = normalizar_(v);
  if (/conclu/.test(t)) return "concluido";
  if (/andamento/.test(t)) return "em_andamento";
  return "pendente";
}

// aceita "2026-10-16" (pergunta tipo Data) ou "16/10/2026" (pergunta de texto)
function dataISO_(v) {
  if (v instanceof Date) return Utilities.formatDate(v, Session.getScriptTimeZone(), "yyyy-MM-dd");
  const s = String(v || "").trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return m[1] + "-" + m[2] + "-" + m[3];
  m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);
  if (m) {
    const ano = m[3].length === 2 ? "20" + m[3] : m[3];
    return ano + "-" + ("0" + m[2]).slice(-2) + "-" + ("0" + m[1]).slice(-2);
  }
  return null;
}

function montarDados_(resposta) {
  const dados = { passos: [], outro: "", observacoes: "", resposta_id: resposta.getId(),
                  enviado_em: resposta.getTimestamp().toISOString(), email: "" };
  try { dados.email = resposta.getRespondentEmail() || ""; } catch (e) {}
  const extras = [], outros = [];

  resposta.getItemResponses().forEach(function (ir) {
    const titulo = ir.getItem().getTitle();
    const valor = ir.getResponse();
    const campo = campoDaPergunta_(titulo);
    const lista = Array.isArray(valor) ? valor : [valor];
    const texto = lista.filter(function (x) { return x !== null && x !== ""; }).join(", ");
    if (!texto) return;

    if (campo === "passos") {
      lista.forEach(function (op) {
        const c = codigoDoPasso_(op);
        if (c) { if (dados.passos.indexOf(c) < 0) dados.passos.push(c); }
        else if (String(op).trim()) outros.push(String(op).trim());    // "Outro: ____" do Forms
        if (c === "outro") { const resto = String(op).replace(/^[^:]*:?/, "").replace(/_+/g, "").trim(); if (resto) outros.push(resto); }
      });
    } else if (campo === "data_consulta" || campo === "prazo") {
      dados[campo] = dataISO_(valor);
      if (!dados[campo]) extras.push(titulo + ": " + texto);
    } else if (campo === "situacao") {
      dados.situacao = codigoDaSituacao_(texto);
    } else if (campo === "observacoes") {
      dados.observacoes = texto;
    } else if (campo && !dados[campo]) {
      dados[campo] = texto;
    } else {
      extras.push(titulo + ": " + texto);  // pergunta não reconhecida: não perde a informação
    }
  });

  if (outros.length) {
    if (dados.passos.indexOf("outro") < 0) dados.passos.push("outro");
    dados.outro = outros.join(", ");
  }
  if (extras.length) dados.observacoes = [dados.observacoes].concat(extras).filter(String).join("\n");
  return dados;
}

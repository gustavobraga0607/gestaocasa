// Folha da Casa — envio dos recibos para assinatura na ZapSign.
// Roda como função da Vercel. Segredos ficam nas variáveis de ambiente do projeto:
//   ZAPSIGN_TOKEN        token de API da ZapSign (nunca vai para o navegador)
//   SUPABASE_SECRET_KEY  chave secreta (service_role) do Supabase, para gravar o status dos recibos
//   ZAPSIGN_SANDBOX=1    opcional: usa o ambiente de testes da ZapSign
// Este app não cria nem altera webhooks da ZapSign: o status é consultado direto na API.

const SUPA_URL = process.env.SUPABASE_URL || "https://nhldtadtnpzlytdlxtxb.supabase.co";
const SUPA_ANON = process.env.SUPABASE_ANON_KEY || "sb_publishable_n5AaVvDdhfxb7jMFBp9lDA_Oc6yHVUi";
const ZAP_BASE = process.env.ZAPSIGN_SANDBOX === "1"
  ? "https://sandbox.api.zapsign.com.br/api/v1"
  : "https://api.zapsign.com.br/api/v1";
const PASTA = "/Folha da Casa/";

class Erro extends Error { constructor(status, msg) { super(msg); this.status = status; } }

async function supa(caminho, { method = "GET", body, jwt, chave, prefer } = {}) {
  const key = chave || SUPA_ANON;
  const headers = { apikey: key, Authorization: "Bearer " + (jwt || key), "Content-Type": "application/json" };
  if (prefer) headers.Prefer = prefer;
  let r;
  try { r = await fetch(SUPA_URL + caminho, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }); }
  catch (e) { throw new Erro(502, "Não foi possível conectar ao banco de dados."); }
  const txt = await r.text();
  let dados = null; try { dados = txt ? JSON.parse(txt) : null; } catch (e) { dados = txt; }
  if (!r.ok) throw new Erro(r.status >= 500 ? 502 : r.status, "Banco de dados: " + ((dados && (dados.message || dados.msg)) || r.status));
  return dados;
}
const secreta = () => {
  const k = (process.env.SUPABASE_SECRET_KEY || "").trim().split(/\s+/)[0];
  if (!k) throw new Erro(500, "Falta configurar SUPABASE_SECRET_KEY na Vercel.");
  return k;
};
const db = (caminho, opt = {}) => supa(caminho, { ...opt, chave: secreta() });

async function zap(caminho, { method = "GET", body } = {}) {
  // Usa só o primeiro trecho do valor (tolera espaços, quebras de linha ou token colado duas vezes)
  const t = (process.env.ZAPSIGN_TOKEN || "").trim().split(/\s+/)[0];
  if (!t) throw new Erro(500, "Falta configurar ZAPSIGN_TOKEN na Vercel.");
  let r;
  try {
    r = await fetch(ZAP_BASE + caminho, {
      method, headers: { Authorization: "Bearer " + t, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body)
    });
  } catch (e) { throw new Erro(502, "Não foi possível conectar à ZapSign."); }
  const txt = await r.text();
  let dados = null; try { dados = txt ? JSON.parse(txt) : null; } catch (e) { dados = txt; }
  if (!r.ok) throw new Erro(502, "ZapSign: " + ((dados && (dados.detail || dados.message || JSON.stringify(dados))) || r.status));
  return dados;
}

// Confere que quem chamou é um empregador logado e membro da casa.
async function empregador(req, casaId) {
  const jwt = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!jwt) throw new Erro(401, "Entre na sua conta para continuar.");
  const user = await supa("/auth/v1/user", { jwt }).catch(() => null);
  if (!user || !user.id) throw new Erro(401, "Sessão expirada. Entre de novo.");
  const ok = await supa("/rest/v1/rpc/eh_membro", { method: "POST", body: { c: casaId }, jwt });
  if (ok !== true) throw new Erro(403, "Sem permissão para esta casa.");
  return user;
}

// Lê o documento na ZapSign e atualiza o recibo no banco.
async function sincronizar(rec) {
  if (!rec.zapsign_doc || rec.status !== "pendente") return rec;
  const doc = await zap("/docs/" + rec.zapsign_doc + "/");
  const s = (doc.signers || [])[0] || {};
  let status = "pendente", assinado_em = null;
  // Documentação: documento "pending" | "signed" (e "refused" quando recusado); signatário "new" | "link-opened" | "signed"
  if (doc.status === "signed" || s.status === "signed") { status = "assinado"; assinado_em = s.signed_at || doc.last_update_at || new Date().toISOString(); }
  else if (doc.status === "refused" || s.status === "refused" || doc.deleted) status = doc.deleted ? "cancelado" : "recusado";
  if (status === rec.status) return rec;
  const [novo] = await db("/rest/v1/recibos_publicados?id=eq." + rec.id, {
    method: "PATCH", body: { status, assinado_em }, prefer: "return=representation"
  });
  return novo;
}

async function publicar(req, b) {
  const { casa_id, func_id, competencia, nome, dados, pdf_base64, app_url } = b;
  if (!casa_id || !func_id || !/^\d{4}-\d{2}$/.test(competencia || "") || !pdf_base64) throw new Erro(400, "Dados do recibo incompletos.");
  if (pdf_base64.length > 4_000_000) throw new Erro(413, "PDF grande demais.");
  const user = await empregador(req, casa_id);
  // Cancela versões pendentes do mesmo mês (o recibo foi refeito)
  const antigos = await db(`/rest/v1/recibos_publicados?casa_id=eq.${casa_id}&func_id=eq.${encodeURIComponent(func_id)}&competencia=eq.${competencia}&status=eq.pendente&select=id,zapsign_doc`);
  for (const a of antigos) {
    if (a.zapsign_doc) await zap("/docs/" + a.zapsign_doc + "/", { method: "DELETE" }).catch(() => {});
    await db("/rest/v1/recibos_publicados?id=eq." + a.id, { method: "PATCH", body: { status: "cancelado" } });
  }
  const [ano, mes] = competencia.split("-");
  const doc = await zap("/docs/", {
    method: "POST",
    body: {
      name: `Recibo ${mes}/${ano} - ${nome}`.slice(0, 250),
      base64_pdf: pdf_base64,
      lang: "pt-br",
      disable_signer_emails: true,
      folder_path: PASTA,
      external_id: `folhadacasa:${casa_id}:${func_id}:${competencia}`,
      brand_primary_color: "#2c49b0",
      signers: [{
        name: nome,
        auth_mode: "assinaturaTela",
        require_selfie_photo: true,
        require_document_photo: false,
        send_automatic_email: false,
        send_automatic_whatsapp: false,
        lock_name: true,
        redirect_link: (app_url || "").startsWith("https://") ? app_url : undefined
      }]
    }
  });
  const signer = (doc.signers || [])[0] || {};
  const [rec] = await db("/rest/v1/recibos_publicados", {
    method: "POST", prefer: "return=representation",
    body: { casa_id, func_id, competencia, dados: dados || {}, status: "pendente", zapsign_doc: doc.token, sign_url: signer.sign_url, criado_por: user.id }
  });
  return { recibo: rec };
}

async function cancelar(req, b) {
  const { casa_id, competencia } = b;
  await empregador(req, casa_id);
  const pend = await db(`/rest/v1/recibos_publicados?casa_id=eq.${casa_id}&competencia=eq.${competencia}&status=eq.pendente&select=id,zapsign_doc`);
  for (const a of pend) {
    if (a.zapsign_doc) await zap("/docs/" + a.zapsign_doc + "/", { method: "DELETE" }).catch(() => {});
    await db("/rest/v1/recibos_publicados?id=eq." + a.id, { method: "PATCH", body: { status: "cancelado" } });
  }
  return { cancelados: pend.length };
}

async function statusCasa(req, b) {
  const { casa_id } = b;
  await empregador(req, casa_id);
  const lista = await db(`/rest/v1/recibos_publicados?casa_id=eq.${casa_id}&status=in.(pendente,assinado,recusado)&order=criado_em.desc&limit=200&select=id,func_id,competencia,status,zapsign_doc,assinado_em,criado_em`);
  const out = [];
  for (const r of lista) out.push(await sincronizar(r).catch(() => r));
  return { recibos: out.map(({ zapsign_doc, ...r }) => r) };
}

// Funcionária: confere a sessão pelo banco e atualiza o status do recibo dela.
async function statusFunc(b) {
  const sess = await supa("/rest/v1/rpc/meu_recibo", { method: "POST", body: { p_token: b.sessao } });
  if (!sess || sess.erro) throw new Erro(401, "Sessão expirada. Entre de novo.");
  if (!sess.recibo) return sess;
  const [rec] = await db(`/rest/v1/recibos_publicados?id=eq.${sess.recibo.id}&select=id,status,zapsign_doc,assinado_em`);
  const novo = await sincronizar(rec).catch(() => rec);
  return { ...sess, recibo: { ...sess.recibo, status: novo.status, assinado_em: novo.assinado_em } };
}

// Link novo (temporário) do PDF assinado.
async function arquivo(req, b) {
  let rec;
  if (b.sessao) {
    const sess = await supa("/rest/v1/rpc/meu_recibo", { method: "POST", body: { p_token: b.sessao } });
    if (!sess || sess.erro || !sess.recibo) throw new Erro(401, "Sessão expirada. Entre de novo.");
    [rec] = await db(`/rest/v1/recibos_publicados?id=eq.${sess.recibo.id}&select=id,zapsign_doc,status`);
  } else {
    await empregador(req, b.casa_id);
    [rec] = await db(`/rest/v1/recibos_publicados?id=eq.${encodeURIComponent(b.id)}&casa_id=eq.${b.casa_id}&select=id,zapsign_doc,status`);
  }
  if (!rec || !rec.zapsign_doc) throw new Erro(404, "Recibo não encontrado.");
  const doc = await zap("/docs/" + rec.zapsign_doc + "/");
  const url = doc.signed_file || doc.original_file;
  if (!url) throw new Erro(404, "O arquivo ainda não está pronto. Tente em alguns segundos.");
  return { url, assinado: !!doc.signed_file };
}

// Verificação da configuração: só leituras, nada é criado. Não devolve dados, apenas se cada chave funciona.
async function teste() {
  const out = { ok: true, zapsign: !!process.env.ZAPSIGN_TOKEN, supabase: !!process.env.SUPABASE_SECRET_KEY, sandbox: process.env.ZAPSIGN_SANDBOX === "1" };
  if (out.zapsign) { try { await zap("/docs/?page=1"); out.zapsign_ok = true; } catch (e) { out.zapsign_ok = false; out.zapsign_erro = e instanceof Erro ? e.message.slice(0, 120) : "erro inesperado"; } }
  if (out.supabase) { try { await db("/rest/v1/recibos_publicados?select=id&limit=1"); out.supabase_ok = true; } catch (e) { out.supabase_ok = false; out.supabase_erro = e instanceof Erro ? e.message.slice(0, 120) : "erro inesperado"; } }
  return out;
}

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") { res.status(405).json({ erro: "Use POST." }); return; }
  try {
    const b = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    let out;
    switch (b.acao) {
      case "publicar": out = await publicar(req, b); break;
      case "cancelar": out = await cancelar(req, b); break;
      case "status": out = await statusCasa(req, b); break;
      case "status_func": out = await statusFunc(b); break;
      case "arquivo": out = await arquivo(req, b); break;
      case "teste": out = await teste(); break;
      default: throw new Erro(400, "Ação desconhecida.");
    }
    res.status(200).json(out);
  } catch (e) {
    res.status(e instanceof Erro ? e.status : 500).json({ erro: e instanceof Erro ? e.message : "Erro inesperado no servidor do app." });
  }
};

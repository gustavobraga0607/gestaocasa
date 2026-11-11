// Folha da Casa — conclusão de tarefas com foto.
// A funcionária envia a foto e o horário; o servidor confere a sessão dela, guarda a foto
// na pasta privada "tarefas" do Supabase Storage e registra a conclusão.
// Usa a mesma variável SUPABASE_SECRET_KEY da função da ZapSign.

const SUPA_URL = process.env.SUPABASE_URL || "https://nhldtadtnpzlytdlxtxb.supabase.co";
const BUCKET = "tarefas";

class Erro extends Error { constructor(status, msg) { super(msg); this.status = status; } }

function chave() {
  const k = (process.env.SUPABASE_SECRET_KEY || "").trim().split(/\s+/)[0];
  if (!k) throw new Erro(500, "Falta configurar SUPABASE_SECRET_KEY na Vercel.");
  return k;
}

async function rpc(fn, args) {
  const k = chave();
  let r;
  try {
    r = await fetch(`${SUPA_URL}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: { apikey: k, Authorization: "Bearer " + k, "Content-Type": "application/json" },
      body: JSON.stringify(args)
    });
  } catch (e) { throw new Erro(502, "Não foi possível conectar ao banco de dados."); }
  const txt = await r.text();
  let d = null; try { d = txt ? JSON.parse(txt) : null; } catch (e) { d = txt; }
  if (!r.ok) {
    const msg = (d && d.message) || "";
    if (/sessao/.test(msg)) throw new Erro(401, "Sua sessão terminou. Entre de novo.");
    if (/Could not find the function|PGRST202/.test(msg + (d && d.code))) throw new Erro(503, "O envio de fotos ainda não foi ativado pelo empregador.");
    throw new Erro(400, msg || "Não foi possível concluir a tarefa.");
  }
  return d;
}

async function guardarFoto(caminho, bytes, tipo) {
  const k = chave();
  let r;
  try {
    r = await fetch(`${SUPA_URL}/storage/v1/object/${BUCKET}/${caminho}`, {
      method: "POST",
      headers: { apikey: k, Authorization: "Bearer " + k, "Content-Type": tipo, "x-upsert": "true" },
      body: bytes
    });
  } catch (e) { throw new Erro(502, "Não foi possível enviar a foto."); }
  if (!r.ok) {
    const t = await r.text();
    if (/Bucket not found/i.test(t)) throw new Erro(503, "O envio de fotos ainda não foi ativado pelo empregador.");
    throw new Erro(502, "Não foi possível guardar a foto. Tente de novo.");
  }
}

async function concluir(b) {
  const { sessao, tarefa_id, data, hora, foto_base64, foto_tipo } = b;
  if (!sessao || !tarefa_id || !/^\d{4}-\d{2}-\d{2}$/.test(data || "")) throw new Erro(400, "Dados incompletos.");
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(hora || "")) throw new Erro(400, "Informe o horário em que terminou.");
  if (!foto_base64) throw new Erro(400, "Envie a foto da tarefa.");
  const tipo = ["image/jpeg", "image/png", "image/webp"].includes(foto_tipo) ? foto_tipo : "image/jpeg";
  const bytes = Buffer.from(foto_base64, "base64");
  if (bytes.length < 1000) throw new Erro(400, "A foto não chegou inteira. Tente de novo.");
  if (bytes.length > 3 * 1024 * 1024) throw new Erro(413, "Foto grande demais. Tente de novo.");
  const info = await rpc("tarefa_da_sessao", { p_token: sessao, p_tarefa: tarefa_id, p_data: data });
  const ext = tipo === "image/png" ? "png" : tipo === "image/webp" ? "webp" : "jpg";
  const caminho = `${info.casa_id}/${encodeURIComponent(info.func_id)}/${info.data}/${tarefa_id}-${Date.now()}.${ext}`;
  await guardarFoto(caminho, bytes, tipo);
  await rpc("concluir_tarefa", { p_token: sessao, p_tarefa: tarefa_id, p_data: data, p_hora: hora, p_foto: caminho });
  return { ok: true };
}

async function teste() {
  const out = { ok: true, supabase: !!process.env.SUPABASE_SECRET_KEY };
  if (out.supabase) {
    try {
      const k = chave();
      const r = await fetch(`${SUPA_URL}/storage/v1/bucket/${BUCKET}`, { headers: { apikey: k, Authorization: "Bearer " + k } });
      out.pasta_fotos = r.ok;
    } catch (e) { out.pasta_fotos = false; }
  }
  return out;
}

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") { res.status(405).json({ erro: "Use POST." }); return; }
  try {
    const b = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    let out;
    if (b.acao === "concluir_tarefa") out = await concluir(b);
    else if (b.acao === "teste") out = await teste();
    else throw new Erro(400, "Ação desconhecida.");
    res.status(200).json(out);
  } catch (e) {
    res.status(e instanceof Erro ? e.status : 500).json({ erro: e instanceof Erro ? e.message : "Erro inesperado no servidor do app." });
  }
};

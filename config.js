// Conexão com a nuvem (Supabase). Estes dois valores são públicos por natureza:
// a segurança vem das regras do banco (supabase/schema.sql), que só deixam cada
// pessoa ver as casas às quais tem acesso.
// Deixe em branco para usar o app só com os dados salvos no navegador.
window.FOLHA_NUVEM = {
  url: "https://nhldtadtnpzlytdlxtxb.supabase.co",
  anonKey: "sb_publishable_n5AaVvDdhfxb7jMFBp9lDA_Oc6yHVUi"
};

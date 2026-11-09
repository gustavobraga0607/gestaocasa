-- Folha da Casa: acesso das funcionárias e recibos para assinatura
-- Rode DEPOIS do schema.sql. Cole este arquivo inteiro no Supabase:
-- SQL Editor → New query → Run. Pode rodar de novo sem problema.

create extension if not exists pgcrypto with schema extensions;

-- Acesso da funcionária: entra com CPF e a senha que o empregador cria.
create table if not exists public.acessos_func (
  casa_id uuid not null references public.casas on delete cascade,
  func_id text not null,
  cpf text not null unique check (cpf ~ '^[0-9]{11}$'),
  nome text not null,
  senha_hash text not null,
  ativo boolean not null default true,
  tentativas int not null default 0,
  bloqueado_ate timestamptz,
  atualizado_em timestamptz not null default now(),
  primary key (casa_id, func_id)
);

-- Sessões da funcionária (válidas por 12 horas).
create table if not exists public.sessoes_func (
  token uuid primary key default gen_random_uuid(),
  casa_id uuid not null,
  func_id text not null,
  expira_em timestamptz not null default now() + interval '12 hours',
  foreign key (casa_id, func_id) references public.acessos_func (casa_id, func_id) on delete cascade
);

-- Recibos publicados quando o empregador salva a folha. A funcionária vê só o mais recente.
create table if not exists public.recibos_publicados (
  id uuid primary key default gen_random_uuid(),
  casa_id uuid not null references public.casas on delete cascade,
  func_id text not null,
  competencia text not null check (competencia ~ '^[0-9]{4}-[0-9]{2}$'),
  dados jsonb not null,
  status text not null default 'pendente' check (status in ('pendente', 'assinado', 'recusado', 'cancelado', 'erro')),
  zapsign_doc text,
  sign_url text,
  assinado_em timestamptz,
  erro text,
  criado_em timestamptz not null default now(),
  criado_por uuid default auth.uid()
);
create index if not exists recibos_publicados_busca
  on public.recibos_publicados (casa_id, func_id, competencia desc, criado_em desc);

alter table public.acessos_func enable row level security;
alter table public.sessoes_func enable row level security;
alter table public.recibos_publicados enable row level security;

-- Empregador (membro da casa) vê os recibos publicados da casa. Gravação só pelo servidor do app.
drop policy if exists recibos_ver on public.recibos_publicados;
create policy recibos_ver on public.recibos_publicados for select to authenticated
  using (public.eh_membro(casa_id));
-- acessos_func e sessoes_func não têm políticas: só as funções abaixo mexem nelas.

-- Empregador cria ou troca a senha de acesso da funcionária.
create or replace function public.definir_acesso(p_casa uuid, p_func text, p_cpf text, p_nome text, p_senha text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_cpf text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
begin
  if not public.eh_membro(p_casa) then raise exception 'Sem permissão para esta casa.'; end if;
  if length(v_cpf) <> 11 then raise exception 'Informe o CPF completo da funcionária no cadastro.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if exists (select 1 from public.acessos_func a where a.cpf = v_cpf and not (a.casa_id = p_casa and a.func_id = p_func)) then
    raise exception 'Este CPF já tem acesso em outro cadastro.';
  end if;
  insert into public.acessos_func (casa_id, func_id, cpf, nome, senha_hash)
  values (p_casa, p_func, v_cpf, coalesce(nullif(trim(p_nome), ''), 'Funcionária'), crypt(p_senha, gen_salt('bf')))
  on conflict (casa_id, func_id) do update
    set cpf = excluded.cpf, nome = excluded.nome, senha_hash = excluded.senha_hash,
        ativo = true, tentativas = 0, bloqueado_ate = null, atualizado_em = now();
  delete from public.sessoes_func where casa_id = p_casa and func_id = p_func;
end $$;

-- Empregador bloqueia o acesso (ex.: desligamento).
create or replace function public.bloquear_acesso(p_casa uuid, p_func text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_membro(p_casa) then raise exception 'Sem permissão para esta casa.'; end if;
  update public.acessos_func set ativo = false, atualizado_em = now() where casa_id = p_casa and func_id = p_func;
  delete from public.sessoes_func where casa_id = p_casa and func_id = p_func;
end $$;

-- Empregador consulta quem tem acesso.
create or replace function public.acessos_da_casa(p_casa uuid)
returns table (func_id text, cpf text, ativo boolean, atualizado_em timestamptz)
language plpgsql security definer stable set search_path = public as $$
begin
  if not public.eh_membro(p_casa) then raise exception 'Sem permissão para esta casa.'; end if;
  return query select a.func_id, a.cpf, a.ativo, a.atualizado_em from public.acessos_func a where a.casa_id = p_casa;
end $$;

-- Login da funcionária com CPF e senha. Bloqueia 15 minutos após 5 senhas erradas.
create or replace function public.login_funcionaria(p_cpf text, p_senha text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cpf text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  a public.acessos_func;
  v_token uuid;
begin
  select * into a from public.acessos_func where cpf = v_cpf;
  if not found or not a.ativo then
    return json_build_object('erro', 'CPF ou senha incorretos.');
  end if;
  if a.bloqueado_ate is not null and a.bloqueado_ate > now() then
    return json_build_object('erro', 'Muitas tentativas erradas. Espere 15 minutos e tente de novo.');
  end if;
  if a.senha_hash <> crypt(coalesce(p_senha, ''), a.senha_hash) then
    update public.acessos_func
      set tentativas = case when a.tentativas + 1 >= 5 then 0 else a.tentativas + 1 end,
          bloqueado_ate = case when a.tentativas + 1 >= 5 then now() + interval '15 minutes' else null end
      where casa_id = a.casa_id and func_id = a.func_id;
    return json_build_object('erro', 'CPF ou senha incorretos.');
  end if;
  update public.acessos_func set tentativas = 0, bloqueado_ate = null where casa_id = a.casa_id and func_id = a.func_id;
  delete from public.sessoes_func where expira_em < now();
  insert into public.sessoes_func (casa_id, func_id) values (a.casa_id, a.func_id) returning token into v_token;
  return json_build_object('token', v_token, 'nome', a.nome);
end $$;

-- Recibo mais recente da funcionária logada (só o último mês publicado).
create or replace function public.meu_recibo(p_token uuid)
returns json language plpgsql security definer stable set search_path = public as $$
declare s public.sessoes_func; a public.acessos_func; r public.recibos_publicados;
begin
  select * into s from public.sessoes_func where token = p_token and expira_em > now();
  if not found then return json_build_object('erro', 'sessao'); end if;
  select * into a from public.acessos_func where casa_id = s.casa_id and func_id = s.func_id and ativo;
  if not found then return json_build_object('erro', 'sessao'); end if;
  select * into r from public.recibos_publicados
    where casa_id = s.casa_id and func_id = s.func_id and status in ('pendente', 'assinado', 'recusado')
    order by competencia desc, criado_em desc limit 1;
  if not found then return json_build_object('nome', a.nome, 'recibo', null); end if;
  return json_build_object('nome', a.nome, 'recibo', json_build_object(
    'id', r.id, 'competencia', r.competencia, 'dados', r.dados, 'status', r.status,
    'sign_url', r.sign_url, 'assinado_em', r.assinado_em));
end $$;

create or replace function public.sair_funcionaria(p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.sessoes_func where token = p_token;
$$;

revoke all on function public.definir_acesso(uuid, text, text, text, text) from public, anon;
revoke all on function public.bloquear_acesso(uuid, text) from public, anon;
revoke all on function public.acessos_da_casa(uuid) from public, anon;
grant execute on function public.definir_acesso(uuid, text, text, text, text) to authenticated;
grant execute on function public.bloquear_acesso(uuid, text) to authenticated;
grant execute on function public.acessos_da_casa(uuid) to authenticated;
grant execute on function public.login_funcionaria(text, text) to anon, authenticated;
grant execute on function public.meu_recibo(uuid) to anon, authenticated;
grant execute on function public.sair_funcionaria(uuid) to anon, authenticated;

-- ===== Versão 2: visto do empregador e regra de disponibilidade =====
-- A funcionária vê todos os recibos ainda não assinados por ela e,
-- depois de assinar, cada recibo continua disponível por mais 15 dias.
-- O visto do empregador não muda esse prazo.
alter table public.recibos_publicados add column if not exists func_signer text;
alter table public.recibos_publicados add column if not exists emp_signer text;
alter table public.recibos_publicados add column if not exists emp_sign_url text;
alter table public.recibos_publicados add column if not exists emp_assinado_em timestamptz;

create or replace function public.meus_recibos(p_token uuid)
returns json language plpgsql security definer stable set search_path = public as $$
declare s public.sessoes_func; a public.acessos_func; lista json;
begin
  select * into s from public.sessoes_func where token = p_token and expira_em > now();
  if not found then return json_build_object('erro', 'sessao'); end if;
  select * into a from public.acessos_func where casa_id = s.casa_id and func_id = s.func_id and ativo;
  if not found then return json_build_object('erro', 'sessao'); end if;
  select coalesce(json_agg(json_build_object(
      'id', r.id, 'competencia', r.competencia, 'dados', r.dados, 'status', r.status,
      'sign_url', case when r.status = 'pendente' then r.sign_url end,
      'assinado_em', r.assinado_em,
      'disponivel_ate', case when r.status = 'assinado' then r.assinado_em + interval '15 days' end,
      'visto_empregador', r.emp_assinado_em is not null
    ) order by r.competencia desc, r.criado_em desc), '[]'::json)
    into lista
    from public.recibos_publicados r
    where r.casa_id = s.casa_id and r.func_id = s.func_id
      and (r.status in ('pendente', 'recusado')
           or (r.status = 'assinado' and r.assinado_em > now() - interval '15 days'));
  return json_build_object('nome', a.nome, 'recibos', lista);
end $$;
grant execute on function public.meus_recibos(uuid) to anon, authenticated;

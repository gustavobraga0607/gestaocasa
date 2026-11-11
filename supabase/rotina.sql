-- Folha da Casa: tarefas do dia, registro de ponto e recados
-- Rode DEPOIS do schema.sql e do funcionarias.sql. Cole no Supabase:
-- SQL Editor → New query → Run. Pode rodar de novo sem problema.
-- Datas do dia são calculadas no fuso de Brasília.

-- ===== Tarefas =====
-- Tarefa de um dia (data) ou repetida em dias da semana (dias: 0=domingo ... 6=sábado).
create table if not exists public.tarefas (
  id uuid primary key default gen_random_uuid(),
  casa_id uuid not null references public.casas on delete cascade,
  func_id text not null,
  texto text not null check (length(texto) between 1 and 300),
  data date,
  dias int[],
  ativa boolean not null default true,
  criado_em timestamptz not null default now(),
  check (data is not null or (dias is not null and cardinality(dias) > 0))
);
create index if not exists tarefas_func on public.tarefas (casa_id, func_id);

create table if not exists public.tarefas_feitas (
  tarefa_id uuid not null references public.tarefas on delete cascade,
  data date not null,
  feita_em timestamptz not null default now(),
  primary key (tarefa_id, data)
);

-- ===== Ponto =====
-- O horário é sempre o do servidor. A funcionária não altera nem apaga registros.
-- O empregador pode incluir ajustes (com motivo) e desconsiderar registros (com motivo); nada é apagado.
create table if not exists public.registros_ponto (
  id uuid primary key default gen_random_uuid(),
  casa_id uuid not null references public.casas on delete cascade,
  func_id text not null,
  momento timestamptz not null default now(),
  tipo text not null check (tipo in ('entrada', 'saida_almoco', 'volta_almoco', 'saida')),
  origem text not null default 'app' check (origem in ('app', 'ajuste')),
  motivo text,
  ip text,
  lat double precision,
  lng double precision,
  desconsiderado boolean not null default false,
  desconsiderado_motivo text,
  criado_por uuid default auth.uid(),
  criado_em timestamptz not null default now()
);
create index if not exists ponto_func_momento on public.registros_ponto (casa_id, func_id, momento);

-- ===== Recados =====
create table if not exists public.recados (
  id uuid primary key default gen_random_uuid(),
  casa_id uuid not null references public.casas on delete cascade,
  func_id text not null,
  de text not null check (de in ('func', 'emp')),
  categoria text not null default 'recado' check (categoria in ('recado', 'atraso', 'compras', 'outro')),
  texto text not null check (length(texto) between 1 and 2000),
  criado_em timestamptz not null default now(),
  lido_em timestamptz
);
create index if not exists recados_func on public.recados (casa_id, func_id, criado_em desc);

alter table public.tarefas enable row level security;
alter table public.tarefas_feitas enable row level security;
alter table public.registros_ponto enable row level security;
alter table public.recados enable row level security;

-- Empregador (membro da casa)
drop policy if exists tarefas_emp on public.tarefas;
create policy tarefas_emp on public.tarefas for all to authenticated
  using (public.eh_membro(casa_id)) with check (public.eh_membro(casa_id));
drop policy if exists feitas_emp on public.tarefas_feitas;
create policy feitas_emp on public.tarefas_feitas for select to authenticated
  using (exists (select 1 from public.tarefas t where t.id = tarefa_id and public.eh_membro(t.casa_id)));
drop policy if exists ponto_ver on public.registros_ponto;
create policy ponto_ver on public.registros_ponto for select to authenticated using (public.eh_membro(casa_id));
-- Ajustes e "desconsiderar" só pelas funções abaixo (não há update/delete direto)
drop policy if exists recados_ver on public.recados;
create policy recados_ver on public.recados for select to authenticated using (public.eh_membro(casa_id));
drop policy if exists recados_responder on public.recados;
create policy recados_responder on public.recados for insert to authenticated
  with check (public.eh_membro(casa_id) and de = 'emp');

-- Sessão da funcionária → (casa, funcionária). Erro se a sessão não vale mais.
create or replace function public._sessao_func(p_token uuid, out o_casa uuid, out o_func text)
language plpgsql security definer stable set search_path = public as $$
begin
  select s.casa_id, s.func_id into o_casa, o_func
    from public.sessoes_func s join public.acessos_func a on a.casa_id = s.casa_id and a.func_id = s.func_id
    where s.token = p_token and s.expira_em > now() and a.ativo;
  if o_casa is null then raise exception 'sessao' using errcode = 'P0001'; end if;
end $$;
revoke all on function public._sessao_func(uuid) from public, anon, authenticated;

create or replace function public._hoje() returns date language sql stable as $$
  select (now() at time zone 'America/Sao_Paulo')::date
$$;

-- ----- Funcionária: tarefas -----
create or replace function public.minhas_tarefas(p_token uuid)
returns json language plpgsql security definer stable set search_path = public as $$
declare c uuid; f text; d date := public._hoje(); r json;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  select coalesce(json_agg(json_build_object('id', t.id, 'texto', t.texto, 'repetida', t.dias is not null,
           'feita_em', tf.feita_em) order by tf.feita_em nulls first, t.criado_em), '[]'::json) into r
    from public.tarefas t left join public.tarefas_feitas tf on tf.tarefa_id = t.id and tf.data = d
    where t.casa_id = c and t.func_id = f and t.ativa
      and (t.data = d or (t.data is null and extract(dow from d)::int = any (t.dias)));
  return json_build_object('data', d, 'tarefas', r);
end $$;

create or replace function public.marcar_tarefa(p_token uuid, p_tarefa uuid, p_feita boolean)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid; f text; d date := public._hoje();
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  if not exists (select 1 from public.tarefas t where t.id = p_tarefa and t.casa_id = c and t.func_id = f and t.ativa
                 and (t.data = d or (t.data is null and extract(dow from d)::int = any (t.dias)))) then
    raise exception 'Tarefa não encontrada.';
  end if;
  if p_feita then insert into public.tarefas_feitas (tarefa_id, data) values (p_tarefa, d) on conflict do nothing;
  else delete from public.tarefas_feitas where tarefa_id = p_tarefa and data = d; end if;
end $$;

-- ----- Funcionária: ponto -----
create or replace function public.bater_ponto(p_token uuid, p_tipo text, p_lat double precision default null, p_lng double precision default null)
returns json language plpgsql security definer set search_path = public as $$
declare c uuid; f text; ult timestamptz; r public.registros_ponto; v_ip text;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  if p_tipo not in ('entrada', 'saida_almoco', 'volta_almoco', 'saida') then raise exception 'Tipo de registro inválido.'; end if;
  select max(momento) into ult from public.registros_ponto where casa_id = c and func_id = f and origem = 'app';
  if ult is not null and ult > now() - interval '1 minute' then
    raise exception 'Você acabou de registrar o ponto. Espere um minuto para registrar de novo.';
  end if;
  begin v_ip := split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1);
  exception when others then v_ip := null; end;
  insert into public.registros_ponto (casa_id, func_id, tipo, origem, ip, lat, lng, criado_por)
    values (c, f, p_tipo, 'app', nullif(v_ip, ''), p_lat, p_lng, null) returning * into r;
  return json_build_object('id', r.id, 'momento', r.momento, 'tipo', r.tipo);
end $$;

-- Registros dos últimos 35 dias (para a tela de hoje e o resumo do mês)
create or replace function public.meu_ponto(p_token uuid)
returns json language plpgsql security definer stable set search_path = public as $$
declare c uuid; f text; r json;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  select coalesce(json_agg(json_build_object('id', p.id, 'momento', p.momento, 'tipo', p.tipo, 'origem', p.origem,
           'motivo', p.motivo, 'desconsiderado', p.desconsiderado) order by p.momento), '[]'::json) into r
    from public.registros_ponto p
    where p.casa_id = c and p.func_id = f and p.momento > now() - interval '35 days';
  return json_build_object('agora', now(), 'registros', r);
end $$;

-- ----- Funcionária: recados -----
create or replace function public.enviar_recado(p_token uuid, p_texto text, p_categoria text default 'recado')
returns json language plpgsql security definer set search_path = public as $$
declare c uuid; f text; r public.recados;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  if length(trim(coalesce(p_texto, ''))) = 0 then raise exception 'Escreva o recado.'; end if;
  if (select count(*) from public.recados where casa_id = c and func_id = f and de = 'func' and criado_em > now() - interval '1 hour') >= 30 then
    raise exception 'Muitos recados em pouco tempo. Tente de novo mais tarde.';
  end if;
  insert into public.recados (casa_id, func_id, de, categoria, texto)
    values (c, f, 'func', case when p_categoria in ('recado', 'atraso', 'compras', 'outro') then p_categoria else 'recado' end, left(trim(p_texto), 2000))
    returning * into r;
  return json_build_object('id', r.id, 'criado_em', r.criado_em);
end $$;

-- Conversa (últimos 100 recados). Marca como lidas as respostas do empregador.
create or replace function public.meus_recados(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare c uuid; f text; r json;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  select coalesce(json_agg(x order by x.criado_em), '[]'::json) into r from (
    select id, de, categoria, texto, criado_em, lido_em from public.recados
      where casa_id = c and func_id = f order by criado_em desc limit 100) x;
  update public.recados set lido_em = now() where casa_id = c and func_id = f and de = 'emp' and lido_em is null;
  return json_build_object('recados', r);
end $$;

create or replace function public.recados_novos_func(p_token uuid)
returns int language plpgsql security definer stable set search_path = public as $$
declare c uuid; f text; n int;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  select count(*) into n from public.recados where casa_id = c and func_id = f and de = 'emp' and lido_em is null;
  return n;
end $$;

-- ----- Empregador -----
create or replace function public.ajustar_ponto(p_casa uuid, p_func text, p_momento timestamptz, p_tipo text, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_membro(p_casa) then raise exception 'Sem permissão para esta casa.'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Informe o motivo do ajuste.'; end if;
  if p_tipo not in ('entrada', 'saida_almoco', 'volta_almoco', 'saida') then raise exception 'Tipo de registro inválido.'; end if;
  insert into public.registros_ponto (casa_id, func_id, momento, tipo, origem, motivo)
    values (p_casa, p_func, p_momento, p_tipo, 'ajuste', trim(p_motivo));
end $$;

create or replace function public.desconsiderar_ponto(p_casa uuid, p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_membro(p_casa) then raise exception 'Sem permissão para esta casa.'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Informe o motivo.'; end if;
  update public.registros_ponto set desconsiderado = true, desconsiderado_motivo = trim(p_motivo)
    where id = p_id and casa_id = p_casa;
end $$;

create or replace function public.marcar_recados_lidos(p_casa uuid, p_func text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_membro(p_casa) then raise exception 'Sem permissão para esta casa.'; end if;
  update public.recados set lido_em = now() where casa_id = p_casa and func_id = p_func and de = 'func' and lido_em is null;
end $$;

grant execute on function public.minhas_tarefas(uuid), public.marcar_tarefa(uuid, uuid, boolean),
  public.bater_ponto(uuid, text, double precision, double precision), public.meu_ponto(uuid),
  public.enviar_recado(uuid, text, text), public.meus_recados(uuid), public.recados_novos_func(uuid) to anon, authenticated;
revoke all on function public.ajustar_ponto(uuid, text, timestamptz, text, text), public.desconsiderar_ponto(uuid, uuid, text),
  public.marcar_recados_lidos(uuid, text) from public, anon;
grant execute on function public.ajustar_ponto(uuid, text, timestamptz, text, text), public.desconsiderar_ponto(uuid, uuid, text),
  public.marcar_recados_lidos(uuid, text) to authenticated;

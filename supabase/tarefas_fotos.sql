-- Folha da Casa: conclusão de tarefas com horário e foto, e revisão pelo empregador
-- Rode DEPOIS do rotina.sql. Cole no Supabase: SQL Editor → New query → Run.
-- Pode rodar de novo sem problema.

alter table public.tarefas add column if not exists desativada_em timestamptz;
-- Opções por tarefa (definidas pelo empregador ao criar): exige foto? precisa de aprovação?
alter table public.tarefas add column if not exists precisa_foto boolean not null default true;
alter table public.tarefas add column if not exists precisa_aprovacao boolean not null default true;
alter table public.tarefas_feitas add column if not exists hora_informada time;
alter table public.tarefas_feitas add column if not exists foto text;
alter table public.tarefas_feitas add column if not exists revisao text;
alter table public.tarefas_feitas add column if not exists revisao_obs text;
alter table public.tarefas_feitas add column if not exists revisado_em timestamptz;
do $$ begin
  alter table public.tarefas_feitas add constraint tarefas_feitas_revisao_chk check (revisao in ('ok', 'refazer'));
exception when duplicate_object then null; end $$;

-- Pasta privada para as fotos: <casa>/<funcionária>/<data>/<tarefa>-<hora>.jpg
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tarefas', 'tarefas', false, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- Só membros da casa veem as fotos. O envio é feito pelo servidor do app.
drop policy if exists tarefas_fotos_ver on storage.objects;
create policy tarefas_fotos_ver on storage.objects for select to authenticated
  using (bucket_id = 'tarefas'
         and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.eh_membro(((storage.foldername(name))[1])::uuid));

-- Ocorrências de tarefas: no máximo UMA linha por tarefa.
-- Atraso = dia dos últimos 7 em que a tarefa valia, a funcionária trabalhou (ponto válido) e a tarefa não foi feita
-- (ou foi devolvida para refazer), sem conclusão posterior. Uma conclusão em data igual ou posterior resolve o atraso.
-- Se a tarefa vale para hoje, a linha é a de hoje (marcada como atrasada se houver atraso); senão, a do atraso mais recente.
drop function if exists public._tarefa_de_hoje(uuid, text, uuid);
drop function if exists public.tarefa_da_sessao(uuid, uuid);
drop function if exists public.concluir_tarefa(uuid, uuid, time, text);
drop function if exists public._ocorrencias(uuid, text);

create or replace function public._ocorrencias(p_casa uuid, p_func text)
returns table (tarefa_id uuid, texto text, repetida boolean, data date, atrasada boolean, atrasada_desde date, dias_atraso int,
               feita_em timestamptz, hora_informada time, foto text, revisao text, revisao_obs text, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  with hoje as (select public._hoje() as d),
  dias as (select generate_series((select d from hoje) - 7, (select d from hoje), interval '1 day')::date as dd),
  oc as (
    select t.id, t.texto, t.dias is not null as rep, x.dd, t.criado_em
    from public.tarefas t cross join dias x
    where t.casa_id = p_casa and t.func_id = p_func and t.ativa
      and x.dd >= (t.criado_em at time zone 'America/Sao_Paulo')::date
      and (t.data = x.dd or (t.data is null and extract(dow from x.dd)::int = any (t.dias)))
  ),
  abertas as (
    select oc.id, oc.dd from oc
    where oc.dd < (select d from hoje)
      and not exists (select 1 from public.tarefas_feitas f
                      where f.tarefa_id = oc.id and f.data >= oc.dd and f.revisao is distinct from 'refazer')
      and exists (select 1 from public.registros_ponto p
                  where p.casa_id = p_casa and p.func_id = p_func and not p.desconsiderado
                    and (p.momento at time zone 'America/Sao_Paulo')::date = oc.dd)
  ),
  resumo as (select id, min(dd) as desde, max(dd) as ultima, count(*)::int as n from abertas group by id),
  tarefas_oc as (select distinct id, texto, rep, criado_em from oc),
  alvo as (
    select t.id, t.texto, t.rep, t.criado_em, r.desde, coalesce(r.n, 0) as n,
           case when exists (select 1 from oc where oc.id = t.id and oc.dd = (select d from hoje)) then (select d from hoje) else r.ultima end as dd
    from tarefas_oc t left join resumo r on r.id = t.id
  )
  select a.id, a.texto, a.rep, a.dd, a.n > 0, a.desde, a.n,
         tf.feita_em, tf.hora_informada, tf.foto, tf.revisao, tf.revisao_obs, a.criado_em
  from alvo a left join public.tarefas_feitas tf on tf.tarefa_id = a.id and tf.data = a.dd
  where a.dd is not null;
$$;

-- A ocorrência (tarefa + dia) pode ser concluída agora?
create or replace function public._ocorrencia_aberta(p_casa uuid, p_func text, p_tarefa uuid, p_data date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public._ocorrencias(p_casa, p_func) o where o.tarefa_id = p_tarefa and o.data = p_data);
$$;

-- Servidor do app: confere a sessão e a tarefa antes de guardar a foto
create or replace function public.tarefa_da_sessao(p_token uuid, p_tarefa uuid, p_data date)
returns json language plpgsql security definer stable set search_path = public as $$
declare c uuid; f text;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  if not public._ocorrencia_aberta(c, f, p_tarefa, p_data) then raise exception 'Tarefa não encontrada.'; end if;
  return json_build_object('casa_id', c, 'func_id', f, 'data', p_data,
    'precisa_foto', (select precisa_foto from public.tarefas where id = p_tarefa));
end $$;

-- Servidor do app: registra a conclusão com horário informado e foto (obrigatória quando a tarefa exige)
create or replace function public.concluir_tarefa(p_token uuid, p_tarefa uuid, p_data date, p_hora time, p_foto text)
returns json language plpgsql security definer set search_path = public as $$
declare c uuid; f text; agora time := (now() at time zone 'America/Sao_Paulo')::time;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  if not public._ocorrencia_aberta(c, f, p_tarefa, p_data) then raise exception 'Tarefa não encontrada.'; end if;
  if p_hora is null then raise exception 'Informe o horário em que terminou.'; end if;
  if p_hora > agora + interval '2 minutes' then raise exception 'O horário informado ainda não chegou. Confira a hora.'; end if;
  if p_foto is not null and p_foto not like c::text || '/' || f || '/%' then raise exception 'Foto inválida.'; end if;
  if p_foto is null and (select precisa_foto from public.tarefas where id = p_tarefa) then raise exception 'Envie a foto da tarefa.'; end if;
  insert into public.tarefas_feitas (tarefa_id, data, feita_em, hora_informada, foto)
    values (p_tarefa, p_data, now(), p_hora, p_foto)
  on conflict (tarefa_id, data) do update
    set feita_em = now(), hora_informada = excluded.hora_informada, foto = excluded.foto,
        revisao = null, revisao_obs = null, revisado_em = null;
  return json_build_object('ok', true, 'feita_em', now());
end $$;

revoke all on function public._ocorrencias(uuid, text) from public, anon, authenticated;
revoke all on function public._ocorrencia_aberta(uuid, text, uuid, date) from public, anon, authenticated;
revoke all on function public.tarefa_da_sessao(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.concluir_tarefa(uuid, uuid, date, time, text) from public, anon, authenticated;
grant execute on function public.tarefa_da_sessao(uuid, uuid, date), public.concluir_tarefa(uuid, uuid, date, time, text) to service_role;

-- Funcionária: marcar como feita agora exige foto (pelo app). Ela só pode desfazer, no dia, o que ainda não foi aprovado.
create or replace function public.marcar_tarefa(p_token uuid, p_tarefa uuid, p_feita boolean)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid; f text;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  if p_feita then raise exception 'Para concluir, informe o horário e envie a foto.'; end if;
  if not exists (select 1 from public.tarefas t where t.id = p_tarefa and t.casa_id = c and t.func_id = f) then raise exception 'Tarefa não encontrada.'; end if;
  delete from public.tarefas_feitas where tarefa_id = p_tarefa and data = public._hoje() and revisao is distinct from 'ok';
end $$;

-- Funcionária: tarefas de hoje e atrasadas, com a situação de cada uma
create or replace function public.minhas_tarefas(p_token uuid)
returns json language plpgsql security definer stable set search_path = public as $$
declare c uuid; f text; r json;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  select coalesce(json_agg(json_build_object(
           'id', o.tarefa_id, 'texto', o.texto, 'repetida', o.repetida, 'data', o.data, 'atrasada', o.atrasada,
           'atrasada_desde', o.atrasada_desde, 'dias_atraso', o.dias_atraso,
           'precisa_foto', coalesce(tt.precisa_foto, true), 'precisa_aprovacao', coalesce(tt.precisa_aprovacao, true),
           'feita_em', case when o.revisao is distinct from 'refazer' then o.feita_em end,
           'hora_informada', case when o.revisao is distinct from 'refazer' then to_char(o.hora_informada, 'HH24:MI') end,
           'com_foto', o.foto is not null and o.revisao is distinct from 'refazer',
           'aprovada', o.revisao = 'ok',
           'refazer', o.revisao = 'refazer', 'obs', o.revisao_obs)
         order by (o.feita_em is not null and o.revisao is distinct from 'refazer'), o.atrasada desc, o.data, o.criado_em), '[]'::json) into r
    from public._ocorrencias(c, f) o left join public.tarefas tt on tt.id = o.tarefa_id;
  return json_build_object('data', public._hoje(), 'tarefas', r);
end $$;

-- Empregador: aprovar ou pedir para refazer
create or replace function public.revisar_tarefa(p_casa uuid, p_tarefa uuid, p_data date, p_status text, p_obs text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_membro(p_casa) then raise exception 'Sem permissão para esta casa.'; end if;
  if p_status not in ('ok', 'refazer') then raise exception 'Situação inválida.'; end if;
  if p_status = 'refazer' and length(trim(coalesce(p_obs, ''))) < 3 then raise exception 'Escreva o que precisa ser refeito.'; end if;
  if not exists (select 1 from public.tarefas t where t.id = p_tarefa and t.casa_id = p_casa) then raise exception 'Tarefa não encontrada.'; end if;
  update public.tarefas_feitas set revisao = p_status, revisao_obs = nullif(trim(coalesce(p_obs, '')), ''), revisado_em = now()
    where tarefa_id = p_tarefa and data = p_data;
end $$;
revoke all on function public.revisar_tarefa(uuid, uuid, date, text, text) from public, anon;
grant execute on function public.revisar_tarefa(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.minhas_tarefas(uuid), public.marcar_tarefa(uuid, uuid, boolean) to anon, authenticated;

-- ===== Avisos gerais (fixos no topo dos Recados da funcionária) =====
-- func_id = '*' é o aviso para todas as funcionárias da casa.
create table if not exists public.avisos (
  casa_id uuid not null references public.casas on delete cascade,
  func_id text not null default '*',
  texto text not null default '' check (length(texto) <= 3000),
  atualizado_em timestamptz not null default now(),
  primary key (casa_id, func_id)
);
alter table public.avisos enable row level security;
drop policy if exists avisos_emp on public.avisos;
create policy avisos_emp on public.avisos for all to authenticated
  using (public.eh_membro(casa_id)) with check (public.eh_membro(casa_id));

create or replace function public.meus_avisos(p_token uuid)
returns json language plpgsql security definer stable set search_path = public as $$
declare c uuid; f text; r json;
begin
  select o_casa, o_func into c, f from public._sessao_func(p_token);
  select coalesce(json_agg(json_build_object('para', case when a.func_id = '*' then 'todas' else 'voce' end,
           'texto', a.texto, 'atualizado_em', a.atualizado_em) order by (a.func_id = '*') desc), '[]'::json) into r
    from public.avisos a where a.casa_id = c and a.func_id in ('*', f) and length(trim(a.texto)) > 0;
  return json_build_object('avisos', r);
end $$;
grant execute on function public.meus_avisos(uuid) to anon, authenticated;

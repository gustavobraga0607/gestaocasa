-- Folha da Casa: banco de dados na nuvem (Supabase)
-- Cole este arquivo inteiro no Supabase: SQL Editor → New query → Run.
-- Pode rodar de novo sem problema: ele só cria o que ainda não existe.

-- Casas: cada casa tem sua folha. Quem cria vira membro automaticamente.
create table if not exists public.casas (
  id uuid primary key default gen_random_uuid(),
  nome text not null default 'Minha casa',
  criado_por uuid not null default auth.uid() references auth.users on delete cascade,
  criado_em timestamptz not null default now()
);

-- Quem tem acesso a cada casa, pelo e-mail da conta.
create table if not exists public.casa_membros (
  casa_id uuid not null references public.casas on delete cascade,
  email text not null check (email = lower(email)),
  adicionado_em timestamptz not null default now(),
  primary key (casa_id, email)
);

-- Dados da folha: uma linha por registro (config/geral, funcionarias/<id>, meses/<AAAA-MM>).
create table if not exists public.registros (
  casa_id uuid not null references public.casas on delete cascade,
  chave text not null,
  dados jsonb not null,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid(),
  primary key (casa_id, chave)
);
alter table public.registros replica identity full;

-- A pessoa logada é membro da casa?
create or replace function public.eh_membro(c uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.casa_membros m
    where m.casa_id = c and m.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- Quem cria a casa entra como membro.
create or replace function public.casa_add_dono() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.casa_membros (casa_id, email)
  values (new.id, lower(coalesce(auth.jwt() ->> 'email', '')))
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists casa_add_dono on public.casas;
create trigger casa_add_dono after insert on public.casas
  for each row execute function public.casa_add_dono();

alter table public.casas enable row level security;
alter table public.casa_membros enable row level security;
alter table public.registros enable row level security;

drop policy if exists casas_ver on public.casas;
create policy casas_ver on public.casas for select to authenticated
  using (public.eh_membro(id) or criado_por = auth.uid());
drop policy if exists casas_criar on public.casas;
create policy casas_criar on public.casas for insert to authenticated
  with check (criado_por = auth.uid());
drop policy if exists casas_editar on public.casas;
create policy casas_editar on public.casas for update to authenticated
  using (public.eh_membro(id)) with check (public.eh_membro(id));
drop policy if exists casas_apagar on public.casas;
create policy casas_apagar on public.casas for delete to authenticated
  using (criado_por = auth.uid());

drop policy if exists membros_ver on public.casa_membros;
create policy membros_ver on public.casa_membros for select to authenticated
  using (public.eh_membro(casa_id));
drop policy if exists membros_add on public.casa_membros;
create policy membros_add on public.casa_membros for insert to authenticated
  with check (public.eh_membro(casa_id));
drop policy if exists membros_rm on public.casa_membros;
create policy membros_rm on public.casa_membros for delete to authenticated
  using (public.eh_membro(casa_id));

drop policy if exists registros_tudo on public.registros;
create policy registros_tudo on public.registros for all to authenticated
  using (public.eh_membro(casa_id)) with check (public.eh_membro(casa_id));

-- Atualização em tempo real entre aparelhos.
do $$ begin
  alter publication supabase_realtime add table public.registros;
exception when duplicate_object then null; end $$;

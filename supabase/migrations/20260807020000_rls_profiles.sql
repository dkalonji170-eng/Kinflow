-- Sécurité au niveau des lignes sur profiles :
-- chaque identité (anonyme ou compte adopté) n'accède qu'à sa propre ligne.
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles for select
  to anon, authenticated
  using (auth.uid() = id);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
  on public.profiles for insert
  to anon, authenticated
  with check (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update
  to anon, authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

drop policy if exists "profiles_delete_own" on public.profiles;
create policy "profiles_delete_own"
  on public.profiles for delete
  to anon, authenticated
  using (auth.uid() = id);

-- Vérification d'unicité du code unique : contourne la RLS
-- (une identité ne peut pas lister les codes des autres).
create or replace function public.code_unique_disponible(p_code text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select not exists (
    select 1 from public.profiles
    where code = upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'))
  );
$$;

grant execute on function public.code_unique_disponible(text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

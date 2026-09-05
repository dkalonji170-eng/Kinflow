-- Signalements collaboratifs d'état de route.
-- Chaque utilisateur dépose un état + sa position + son cap (direction du
-- regard). Les statistiques se calculent à partir d'au moins 3 témoins pour
-- un même état ; chaque témoin couvre un cône de vision de
-- (30 + 10 × (temoins - 3)) mètres dans sa direction.

create table if not exists public.signalements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  etat text not null,
  latitude double precision not null,
  longitude double precision not null,
  cap double precision,
  cree_a timestamptz not null default now()
);

alter table public.signalements add column if not exists cap double precision;

alter table public.signalements enable row level security;

-- Chaque identité ne voit et n'écrit que ses propres signalements.
drop policy if exists "signalements_select_own" on public.signalements;
create policy "signalements_select_own"
  on public.signalements for select
  to anon, authenticated
  using (auth.uid() = user_id);

drop policy if exists "signalements_insert_own" on public.signalements;
create policy "signalements_insert_own"
  on public.signalements for insert
  to anon, authenticated
  with check (auth.uid() = user_id);

-- Dépose un signalement : le user_id vient de la session, jamais du client.
drop function if exists public.signaler_etat(text, double precision, double precision);
drop function if exists public.signaler_etat(text, double precision, double precision, double precision);
create or replace function public.signaler_etat(
  p_etat text,
  p_latitude double precision,
  p_longitude double precision,
  p_cap double precision default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  insert into public.signalements (user_id, etat, latitude, longitude, cap)
  values (auth.uid(), p_etat, p_latitude, p_longitude, p_cap);

  return true;
end;
$$;

grant execute on function public.signaler_etat(text, double precision, double precision, double precision)
  to anon, authenticated;

-- Signalements récents (60 min), anonymisés : état + position + cap + date.
-- L'app pondère la fiabilité selon l'ancienneté : un signalement récent
-- compte plus qu'un signalement vieilli, jusqu'à redevenir l'état simulé.
drop function if exists public.signalements_recents();
create or replace function public.signalements_recents()
returns table (etat text, latitude double precision, longitude double precision, cap double precision, cree_a timestamptz)
language sql
security definer
set search_path = public
as $$
  select s.etat, s.latitude, s.longitude, s.cap, s.cree_a
  from public.signalements s
  where s.cree_a >= now() - interval '60 minutes';
$$;

grant execute on function public.signalements_recents()
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- Fil de la ville : suite d'informations publiées par KinFlow.
-- Les utilisateurs ne publient rien : ils réagissent à chaque information
-- avec une seule réaction — VERT (l'info est confirmée/utile) ou ROUGE
-- (l'info est fausse/erronée). Retaper sur la même couleur retire la
-- réaction ; taper sur l'autre couleur la remplace.
--
-- Les infos sont créées par l'équipe KinFlow via le Table Editor Supabase
-- (la clé de service contourne la RLS) : aucune politique d'INSERT n'existe.

create table if not exists public.informations (
  id uuid primary key default gen_random_uuid(),
  contenu text not null check (char_length(contenu) between 1 and 500),
  latitude double precision,
  longitude double precision,
  cree_a timestamptz not null default now()
);

create index if not exists informations_cree_a_idx
  on public.informations (cree_a desc);

create table if not exists public.reactions (
  information_id uuid not null references public.informations(id) on delete cascade,
  user_id uuid not null,
  sens text not null check (sens in ('VERT', 'ROUGE')),
  cree_a timestamptz not null default now(),
  primary key (information_id, user_id)
);

alter table public.informations enable row level security;
alter table public.reactions enable row level security;

-- Aucune politique RLS : tout accès passe par les fonctions SECURITY
-- DEFINER ci-dessous (lecture du fil, dépôt de réaction).

-- Le fil : toutes les informations avec compteurs vert/rouge et la propre
-- réaction du visiteur. Plus récent d'abord.
drop function if exists public.fil_informations();
create or replace function public.fil_informations()
returns table (
  id uuid,
  contenu text,
  latitude double precision,
  longitude double precision,
  nb_verts bigint,
  nb_rouges bigint,
  ma_reaction text,
  cree_a timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    i.id,
    i.contenu,
    i.latitude,
    i.longitude,
    count(r.information_id) filter (where r.sens = 'VERT')::bigint as nb_verts,
    count(r.information_id) filter (where r.sens = 'ROUGE')::bigint as nb_rouges,
    (select r2.sens from public.reactions r2
      where r2.information_id = i.id and r2.user_id = auth.uid()) as ma_reaction,
    i.cree_a
  from public.informations i
  left join public.reactions r on r.information_id = i.id
  where i.cree_a >= now() - interval '48 hours'
  group by i.id, i.contenu, i.latitude, i.longitude, i.cree_a
  order by i.cree_a desc;
$$;

-- Réagir à une information : le sens vient du client, l'identité de la
-- session. Retourne le nouvel état : 'VERT', 'ROUGE', ou NULL si l'utilisateur
-- vient de retirer sa réaction.
drop function if exists public.reagir_information(uuid, text);
create or replace function public.reagir_information(p_id uuid, p_sens text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_existant text;
begin
  if v_uid is null then
    return null;
  end if;
  if p_sens not in ('VERT', 'ROUGE') then
    return null;
  end if;
  if not exists (select 1 from public.informations where id = p_id) then
    return null;
  end if;

  select sens into v_existant
  from public.reactions
  where information_id = p_id and user_id = v_uid;

  if v_existant = p_sens then
    -- Même couleur retapée : on retire la réaction.
    delete from public.reactions
    where information_id = p_id and user_id = v_uid;
    return null;
  end if;

  insert into public.reactions (information_id, user_id, sens)
  values (p_id, v_uid, p_sens)
  on conflict (information_id, user_id)
  do update set sens = excluded.sens;

  return p_sens;
end;
$$;

grant execute on function public.fil_informations()
  to anon, authenticated;
grant execute on function public.reagir_information(uuid, text)
  to anon, authenticated;

-- Deux exemples visibles immédiatement (à supprimer dans le Table Editor).
insert into public.informations (contenu)
select '⚠️ (Exemple) Manifestation prévue ce matin au rond-point Victoire — circulation difficile sur les boulevards.'
where not exists (select 1 from public.informations where contenu like '⚠️ (Exemple) Manifestation%');

insert into public.informations (contenu)
select '⚠️ (Exemple) Arrivée d''une délégation officielle à l''aéroport de N''Djili — renforts de police sur le boulevard du 30 Juin.'
where not exists (select 1 from public.informations where contenu like '⚠️ (Exemple) Arrivée d''une délégation%');

select pg_notify('pgrst', 'reload schema');
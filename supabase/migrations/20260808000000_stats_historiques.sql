-- Fondations des statistiques historiques.
-- Les signalements bruts sont conservés indéfiniment ; cette migration ajoute :
--   1. des colonnes dérivées (jour de semaine + heure locale) indexées,
--   2. une table de synthèse par créneau (période × jour × heure × état),
--   3. une fonction d'archivage à lancer chaque semaine ou chaque mois.
--
-- Fuseau horaire : Africa/Kinshasa (UTC+1, pas d'heure d'été).
-- NB : si le fuseau changeait, les colonnes stockées ne se mettraient pas
-- à jour automatiquement ; il faudrait les régénérer.

-- 1. Colonnes dérivées locales + index pour des requêtes rapides par créneau.
alter table public.signalements
  add column if not exists jour_semaine_local smallint generated always as (
    extract(isodow from cree_a at time zone 'Africa/Kinshasa')
  ) stored;

alter table public.signalements
  add column if not exists heure_locale smallint generated always as (
    extract(hour from cree_a at time zone 'Africa/Kinshasa')
  ) stored;

create index if not exists signalements_creneau_idx
  on public.signalements (jour_semaine_local, heure_locale);

create index if not exists signalements_cree_a_idx
  on public.signalements (cree_a);

-- 2. Table de synthèse : une ligne par (période, jour, heure, état).
--    'periode' = '2026-W32' (semaine ISO) ou '2026-08' (mois).
create table if not exists public.signalements_stats_creneau (
  periode text not null,
  jour_semaine smallint not null,
  heure smallint not null,
  etat text not null,
  nb bigint not null default 0,
  maj_a timestamptz not null default now(),
  primary key (periode, jour_semaine, heure, etat)
);

-- Suivi de la dernière borne archivée (évite de compter deux fois).
create table if not exists public.signalements_archive_etat (
  id integer primary key,
  derniere_fin timestamptz not null
);

insert into public.signalements_archive_etat (id, derniere_fin)
values (1, '-infinity'::timestamptz)
on conflict (id) do nothing;

-- 3. Archivage incrémental : agrège tout ce qui n'est pas encore archivé
--    dans un créneau 'semaine' ou 'mois'. À lancer par ex. chaque lundi
--    (semaine) ou le 1er du mois (mois). Les données brutes restent intactes.
drop function if exists public.signalements_archiver(text);
create or replace function public.signalements_archiver(p_granularite text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fin timestamptz;
  v_nouvelle_fin timestamptz;
  v_periode text;
begin
  select derniere_fin into v_fin from public.signalements_archive_etat where id = 1;
  if v_fin is null then
    v_fin := '-infinity'::timestamptz;
  end if;

  if lower(p_granularite) = 'semaine' then
    v_nouvelle_fin := date_trunc('week', now());
    v_periode := to_char(now(), 'IYYY"-W"IW');
  elsif lower(p_granularite) = 'mois' then
    v_nouvelle_fin := date_trunc('month', now());
    v_periode := to_char(now(), 'YYYY-MM');
  else
    raise exception 'granularite inconnue : %', p_granularite;
  end if;

  if v_fin >= v_nouvelle_fin then
    return 'rien à archiver pour ' || v_periode;
  end if;

  insert into public.signalements_stats_creneau (periode, jour_semaine, heure, etat, nb, maj_a)
  select v_periode, s.jour_semaine_local, s.heure_locale, s.etat, count(*)::bigint, now()
  from public.signalements s
  where s.cree_a >= v_fin and s.cree_a < v_nouvelle_fin
  group by 2, 3, 4
  on conflict (periode, jour_semaine, heure, etat)
  do update set nb = signalements_stats_creneau.nb + excluded.nb,
                 maj_a = now();

  update public.signalements_archive_etat set derniere_fin = v_nouvelle_fin where id = 1;

  return format('archivé %s (%s → %s)', v_periode, v_fin, v_nouvelle_fin);
end;
$$;

grant execute on function public.signalements_archiver(text) to anon, authenticated;

-- Lecture de la synthèse : une période précise, ou toutes les périodes
-- additionnées ('toutes') pour une distribution globale par jour/heure.
drop function if exists public.signalements_stats_consulter(text);
create or replace function public.signalements_stats_consulter(p_periode text default 'toutes')
returns table (jour_semaine integer, heure integer, etat text, nb bigint)
language sql
security definer
set search_path = public
as $$
  select jour_semaine, heure, etat, sum(nb)::bigint as nb
  from public.signalements_stats_creneau
  where p_periode = 'toutes' or periode = p_periode
  group by jour_semaine, heure, etat
  order by jour_semaine, heure, nb desc;
$$;

grant execute on function public.signalements_stats_consulter(text)
  to anon, authenticated;

-- Signalements bruts anonymisés d'un créneau (jour de semaine ISO 1-7,
-- heure locale 0-23) : permet de reconstruire les zones spatiales avec la
-- même logique de clustering que la carte live.
drop function if exists public.signalements_bruts_creneau(integer, integer, timestamptz);
create or replace function public.signalements_bruts_creneau(
  p_jour_semaine integer,
  p_heure integer,
  p_depuis timestamptz default null
)
returns table (etat text, latitude double precision, longitude double precision,
               cap double precision, cree_a timestamptz)
language sql
security definer
set search_path = public
as $$
  select s.etat, s.latitude, s.longitude, s.cap, s.cree_a
  from public.signalements s
  where s.jour_semaine_local = p_jour_semaine
    and s.heure_locale = p_heure
    and (p_depuis is null or s.cree_a >= p_depuis)
  order by s.cree_a desc;
$$;

grant execute on function public.signalements_bruts_creneau(integer, integer, timestamptz)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

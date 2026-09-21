-- Import automatique d'infos pour le Fil Social de KinFlow.
-- Les medias congolais (Radio Okapi, Actualite.cd, LePotentiel.cd) sont lus
-- par le robot (outils/importer_infos_rss.py) qui appelle publier_infos_rss().
--
-- Le filtrage des sujets (Kinshasa + actualite nationale utile) est fait par
-- le robot : la base verifie ici uniquement la cle privee, la longueur et le
-- dedoublonnage, pour ne pas publier de doublons ni de contenu non conforme.

-- 1) Origine de chaque info, pour dédoublonner.
--    Conservée en base uniquement (jamais affichée dans l'app).
alter table public.informations
  add column if not exists source_url text;

create unique index if not exists informations_source_url_uniq
  on public.informations (source_url);

-- 2) Clé partagée entre le robot et la base. Seule cette fonction peut la lire.
create table if not exists public.parametres_secrets (
  cle text primary key,
  valeur text not null,
  description text
);

-- Personne ne lit cette table via l'API (pas de politique) : seules les
-- fonctions SECURITY DEFINER et le propriétaire (postgres) y accèdent.
alter table public.parametres_secrets enable row level security;

insert into public.parametres_secrets (cle, valeur, description)
values (
  'cle_import_rss',
  'fcb0bf876aacdd68957c159bc685d086',
  'Clé que le robot présente pour publier une info automatique'
)
on conflict (cle) do update set valeur = excluded.valeur;

-- 3) Le robot appelle cette fonction en présentant la clé.
drop function if exists public.publier_infos_rss(text, text, text);
create or replace function public.publier_infos_rss(
  p_contenu text,
  p_url text,
  p_cle text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendu text;
  v_propre  text := trim(p_contenu);
begin
  if p_cle is null or p_contenu is null then
    return false;
  end if;

  -- Une info automatique a toujours une URL d'origine : indispensable au
  -- dédoublonnage (une info sans URL pourrait se dupliquer).
  if p_url is null or trim(p_url) = '' then
    return false;
  end if;

  select valeur into v_attendu
  from public.parametres_secrets
  where cle = 'cle_import_rss';
  if v_attendu is null or p_cle <> v_attendu then
    return false;
  end if;

  if char_length(v_propre) < 20 or char_length(v_propre) > 500 then
    return false;
  end if;

  insert into public.informations (contenu, source_url)
  values (v_propre, trim(p_url))
  on conflict (source_url) do nothing;

  return found;
end;
$$;

grant execute on function public.publier_infos_rss(text, text, text)
  to anon, authenticated;

-- 4) Recyclage : le robot supprime les infos de plus de 3 jours (avec leurs
--    réactions). Le fil n'affiche de toute façon que les 48 dernières heures.
drop function if exists public.nettoyer_anciennes_infos(text);
create or replace function public.nettoyer_anciennes_infos(p_cle text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendu text;
  v_nb      integer;
begin
  select valeur into v_attendu
  from public.parametres_secrets
  where cle = 'cle_import_rss';
  if v_attendu is null or p_cle <> v_attendu then
    return 0;
  end if;

  delete from public.informations
  where cree_a < now() - interval '3 days';

  get diagnostics v_nb = row_count;
  return v_nb;
end;
$$;

grant execute on function public.nettoyer_anciennes_infos(text)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');
-- Espaces informateurs — PHASE C : « Suivis »
--
-- Ouvrir un lien donne ACCÈS à l'espace (lecture des reportages et des photos
-- privées). « Suivre » est un choix explicite, séparé : seuls les espaces que
-- tu as acceptés apparaissent dans l'onglet « Suivis ».
--
-- À exécuter APRÈS 20261104000000_espaces_informateurs.sql et
-- 20261105000000_interactions_espaces.sql.

-- 1) Marqueur de suivi sur les abonnements --------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'abonnements'
       and column_name = 'suivi'
  ) then
    alter table public.abonnements
      add column suivi boolean not null default false;
    -- Les abonnements existants venaient d'un lien ouvert volontairement :
    -- on les considère comme suivis pour ne rien faire disparaître.
    update public.abonnements set suivi = true;
  end if;
end $$;

create index if not exists abonnements_suivis_idx
  on public.abonnements (abonne, cree_a desc)
  where suivi;

-- 2) Suivre / ne plus suivre un espace --------------------------------------
drop function if exists public.basculer_suivi_espace(text, boolean);
create or replace function public.basculer_suivi_espace(
  p_jeton text,
  p_suivre boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_informateur uuid;
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  select p.id into v_informateur
    from public.profiles p
   where p.jeton_espace = nullif(trim(p_jeton), '');
  if v_informateur is null then
    raise exception 'espace_introuvable';
  end if;
  if v_informateur = v_uid then
    raise exception 'soi_meme';
  end if;

  insert into public.abonnements (abonne, informateur, suivi)
  values (v_uid, v_informateur, coalesce(p_suivre, false))
  on conflict (abonne, informateur)
  do update set suivi = excluded.suivi;

  return coalesce(p_suivre, false);
end $$;

grant execute on function public.basculer_suivi_espace(text, boolean)
  to authenticated;

-- 3) Liste des espaces suivis ------------------------------------------------
drop function if exists public.mes_abonnements();
create or replace function public.mes_abonnements()
returns table (
  informateur uuid,
  pseudo text,
  avatar text,
  bio text,
  jeton text,
  nb_publications bigint,
  nb_abonnes bigint,
  dernier_reportage timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id,
         trim(concat_ws(' ', p.prenom, p.nom)),
         p.avatar,
         p.bio,
         p.jeton_espace,
         (select count(*) from public.publications pb
           where pb.espace = p.id and pb.statut = 'publie'),
         (select count(*) from public.abonnements a2
           where a2.informateur = p.id and a2.suivi),
         (select max(pb.cree_a) from public.publications pb
           where pb.espace = p.id and pb.statut = 'publie')
    from public.abonnements a
    join public.profiles p on p.id = a.informateur
   where a.abonne = auth.uid()
     and a.suivi
   order by dernier_reportage desc nulls last, a.cree_a desc;
$$;

grant execute on function public.mes_abonnements() to authenticated;

-- 4) Un espace lu indique si je le suis déjà ---------------------------------
drop function if exists public.espace_par_jeton(text);
create or replace function public.espace_par_jeton(p_jeton text)
returns table (
  informateur uuid,
  pseudo text,
  avatar text,
  bio text,
  ouverture text,
  mon_role text,
  je_peux_publier boolean,
  je_suis boolean,
  nb_publications bigint,
  nb_abonnes bigint
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id,
         trim(concat_ws(' ', p.prenom, p.nom)),
         p.avatar,
         p.bio,
         p.ouverture_publication,
         case
           when p.id = auth.uid() then 'proprietaire'
           when exists (
             select 1 from public.membres_espace m
              where m.informateur = p.id and m.membre = auth.uid()
           ) then 'membre'
           else 'lecteur'
         end,
         public.peut_publier_dans_espace(p.id),
         exists (
           select 1 from public.abonnements a
            where a.abonne = auth.uid()
              and a.informateur = p.id
              and a.suivi
         ),
         (select count(*) from public.publications pb
           where pb.espace = p.id and pb.statut = 'publie'),
         (select count(*) from public.abonnements a
           where a.informateur = p.id and a.suivi)
    from public.profiles p
   where p.jeton_espace = nullif(trim(p_jeton), '');
$$;

grant execute on function public.espace_par_jeton(text) to authenticated;

-- 5) Mon espace : ne compter que les vrais abonnés ---------------------------
drop function if exists public.mon_espace();
create or replace function public.mon_espace()
returns table (
  id uuid,
  jeton text,
  bio text,
  nb_publications bigint,
  nb_abonnes bigint,
  prenom text,
  nom text,
  avatar text,
  ouverture_publication text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  return query
    select p.id,
           p.jeton_espace,
           p.bio,
           (select count(*) from public.publications pb
             where pb.espace = v_uid and pb.statut = 'publie'),
           (select count(*) from public.abonnements a
             where a.informateur = v_uid and a.suivi),
           p.prenom,
           p.nom,
           p.avatar,
           p.ouverture_publication
      from public.profiles p
     where p.id = v_uid;
end $$;

grant execute on function public.mon_espace() to authenticated;

-- 6) Recharge du cache de schéma ---------------------------------------------
select pg_notify('pgrst', 'reload schema');

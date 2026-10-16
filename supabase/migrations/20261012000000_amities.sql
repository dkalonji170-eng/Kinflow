-- Amis(es) : demandes d'amitié entre comptes et partage optionnel de la
-- position en direct. Comme pour les réactions du fil, les tables sont
-- verrouillées par RLS (aucune politique) : tout passe par des fonctions
-- SECURITY DEFINER, l'identité vient toujours de la session (auth.uid()).
--
-- Le lien entre deux personnes se fait par le CODE unique du profil (celui
-- déjà utilisé pour se reconnecter), afin de ne jamais exposer la liste des
-- profils.

-- 1) Demandes / relations d'amitié ------------------------------------------
create table if not exists public.amities (
  id uuid primary key default gen_random_uuid(),
  demandeur uuid not null,
  destinataire uuid not null,
  -- 'en_attente' : demande posée ; 'accepte' : amitié confirmée.
  statut text not null default 'en_attente'
    check (statut in ('en_attente', 'accepte')),
  cree_a timestamptz not null default now(),
  repondu_a timestamptz
);

-- Une seule relation par paire, quel que soit le sens de la demande.
create unique index if not exists amities_paire_unique
  on public.amities (
    least(demandeur, destinataire),
    greatest(demandeur, destinataire)
  );

alter table public.amities enable row level security;

-- 2) Positions partagées (optionnel, activé par l'utilisateur) --------------
create table if not exists public.positions_amis (
  user_id uuid primary key,
  latitude double precision,
  longitude double precision,
  cap double precision,
  -- Désactivé par défaut : personne ne partage sa position sans le vouloir.
  partage_actif boolean not null default false,
  maj_a timestamptz
);

alter table public.positions_amis enable row level security;

-- 3) Recherche d'un profil par son code -------------------------------------
-- Ne renvoie que prénom/nom/avatar : ni l'id, ni les autres codes.
drop function if exists public.chercher_profil(text);
create or replace function public.chercher_profil(p_code text)
returns table (prenom text, nom text, avatar text)
language sql
security definer
set search_path = public
as $$
  select p.prenom, p.nom, p.avatar
  from public.profiles p
  where p.code = upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'))
  limit 1;
$$;

grant execute on function public.chercher_profil(text) to anon, authenticated;

-- 4) Envoyer une demande d'ami par code -------------------------------------
-- Retourne un code résultat :
--   'envoye'       demande posée
--   'accepte'      une demande de l'autre côté attendait : amitié créée
--   'deja_ami'     déjà amis
--   'deja_envoye'  demande déjà envoyée par moi, en attente
--   'introuvable'  aucun profil pour ce code
--   'soi_meme'     c'est mon propre code
--   'code_invalide'/'non_connecte'
drop function if exists public.envoyer_demande_ami(text);
create or replace function public.envoyer_demande_ami(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'));
  v_cible public.profiles%rowtype;
  v_existe public.amities%rowtype;
begin
  if v_uid is null then
    return 'non_connecte';
  end if;
  if v_code = '' then
    return 'code_invalide';
  end if;

  select * into v_cible from public.profiles where code = v_code limit 1;
  if v_cible is null then
    return 'introuvable';
  end if;
  if v_cible.id = v_uid then
    return 'soi_meme';
  end if;

  select * into v_existe
  from public.amities
  where (demandeur = v_uid and destinataire = v_cible.id)
     or (demandeur = v_cible.id and destinataire = v_uid)
  limit 1;

  if v_existe is not null then
    if v_existe.statut = 'accepte' then
      return 'deja_ami';
    end if;
    if v_existe.demandeur = v_uid then
      return 'deja_envoye';
    end if;
    -- Une demande de l'autre côté attend : on l'accepte directement.
    update public.amities
       set statut = 'accepte', repondu_a = now()
     where id = v_existe.id;
    return 'accepte';
  end if;

  insert into public.amities (demandeur, destinataire)
  values (v_uid, v_cible.id);

  return 'envoye';
end;
$$;

grant execute on function public.envoyer_demande_ami(text) to anon, authenticated;

-- 5) Demandes reçues en attente ---------------------------------------------
drop function if exists public.mes_demandes_amis();
create or replace function public.mes_demandes_amis()
returns table (
  id uuid,
  demandeur uuid,
  prenom text,
  nom text,
  avatar text,
  cree_a timestamptz
)
language sql
security definer
set search_path = public
as $$
  select a.id, a.demandeur, p.prenom, p.nom, p.avatar, a.cree_a
  from public.amities a
  join public.profiles p on p.id = a.demandeur
  where a.destinataire = auth.uid()
    and a.statut = 'en_attente'
  order by a.cree_a desc;
$$;

grant execute on function public.mes_demandes_amis() to anon, authenticated;

-- 6) Accepter / refuser une demande reçue -----------------------------------
drop function if exists public.repondre_demande_ami(uuid, boolean);
create or replace function public.repondre_demande_ami(p_id uuid, p_accepter boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;

  if p_accepter then
    update public.amities
       set statut = 'accepte', repondu_a = now()
     where id = p_id and destinataire = v_uid and statut = 'en_attente';
  else
    delete from public.amities
     where id = p_id and destinataire = v_uid and statut = 'en_attente';
  end if;

  return found;
end;
$$;

grant execute on function public.repondre_demande_ami(uuid, boolean)
  to anon, authenticated;

-- 7) Mes amis(es), avec leur position si partagée --------------------------
-- La position est renvoyée dès que le partage est actif : même si la dernière
-- fix est ancienne (téléphone éteint), l'âge est conservé pour l'afficher.
-- Un partage inactif (partage_actif=false) ne renvoie pas de coordonnées.
drop function if exists public.mes_amis();
create or replace function public.mes_amis()
returns table (
  ami_id uuid,
  prenom text,
  nom text,
  avatar text,
  latitude double precision,
  longitude double precision,
  cap double precision,
  maj_a timestamptz,
  partage_actif boolean
)
language sql
security definer
set search_path = public
as $$
  select
    p.id as ami_id,
    p.prenom,
    p.nom,
    p.avatar,
    case when pos.partage_actif then pos.latitude end as latitude,
    case when pos.partage_actif then pos.longitude end as longitude,
    case when pos.partage_actif then pos.cap end as cap,
    pos.maj_a,
    coalesce(pos.partage_actif, false) as partage_actif
  from public.amities a
  join public.profiles p
    on p.id = case when a.demandeur = auth.uid()
                   then a.destinataire else a.demandeur end
  left join public.positions_amis pos on pos.user_id = p.id
  where a.statut = 'accepte'
    and (a.demandeur = auth.uid() or a.destinataire = auth.uid())
  order by coalesce(p.prenom, ''), coalesce(p.nom, '');
$$;

grant execute on function public.mes_amis() to anon, authenticated;

-- 8) Retirer un ami ----------------------------------------------------------
drop function if exists public.retirer_ami(uuid);
create or replace function public.retirer_ami(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;

  delete from public.amities
   where (demandeur = v_uid and destinataire = p_id)
      or (demandeur = p_id and destinataire = v_uid);

  return found;
end;
$$;

grant execute on function public.retirer_ami(uuid) to anon, authenticated;

-- 9) Partager ma position ----------------------------------------------------
-- Publie ma position : ne met à jour une ligne existante que si le partage
-- est actif (le drapeau est modifié uniquement via definir_partage_position).
drop function if exists public.publier_ma_position(double precision, double precision, double precision);
create or replace function public.publier_ma_position(
  p_latitude double precision,
  p_longitude double precision,
  p_cap double precision default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;

  insert into public.positions_amis (user_id, latitude, longitude, cap, partage_actif, maj_a)
  values (v_uid, p_latitude, p_longitude, p_cap, true, now())
  on conflict (user_id)
  do update set
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    cap = excluded.cap,
    maj_a = now()
  where public.positions_amis.partage_actif;

  return true;
end;
$$;

grant execute on function public.publier_ma_position(double precision, double precision, double precision)
  to anon, authenticated;

-- 10) Activer / désactiver le partage de ma position -------------------------
drop function if exists public.definir_partage_position(boolean);
create or replace function public.definir_partage_position(p_actif boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;

  insert into public.positions_amis (user_id, partage_actif, maj_a)
  values (v_uid, coalesce(p_actif, false), now())
  on conflict (user_id)
  do update set partage_actif = coalesce(p_actif, false);

  return true;
end;
$$;

grant execute on function public.definir_partage_position(boolean)
  to anon, authenticated;

-- 11) Mon partage est-il actif ? ---------------------------------------------
drop function if exists public.mon_partage_position();
create or replace function public.mon_partage_position()
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce((
    select pos.partage_actif
    from public.positions_amis pos
    where pos.user_id = auth.uid()
  ), false);
$$;

grant execute on function public.mon_partage_position() to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

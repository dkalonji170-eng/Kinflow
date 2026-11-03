-- KinFlow — Application unique des corrections d’audit (points 1, 2, 3, 6, 8).
-- À exécuter dans Supabase > SQL Editor, en une seule fois.
-- Tout est dans une transaction : en cas d’erreur, rien n’est appliqué.
-- Le point 7 (compte permanent) ne nécessite aucun SQL.

begin;

-- =====================================================================
-- Fichier : 20261102000000_blocages_signalements.sql
-- =====================================================================
-- Point 3 — Blocage et signalement d'utilisateurs.
--
-- * `blocages` est symétrique dans ses effets : dès qu'une personne bloque une
--   autre, les deux ne peuvent plus se retrouver dans une demande d'ami, une
--   conversation, un aperçu, un compteur de non-lus ou un partage de position.
-- * L'amitié et les demandes existantes sont supprimées au moment du blocage.
-- * L'historique des messages n'est pas supprimé, mais il devient invisible
--   pour les deux personnes tant que le blocage est actif.
-- * `signalements_utilisateurs` conserve les signalements pour traitement
--   manuel. Aucune politique RLS : tout passe par des RPC SECURITY DEFINER.

-- 1) Tables -----------------------------------------------------------------
create table if not exists public.blocages (
  bloqueur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  bloque uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  cree_a timestamptz not null default now(),
  primary key (bloqueur, bloque),
  constraint blocages_pas_soi_meme check (bloqueur <> bloque)
);

create index if not exists blocages_bloque_idx
  on public.blocages (bloque, bloqueur);

alter table public.blocages enable row level security;

create table if not exists public.signalements_utilisateurs (
  id uuid primary key default gen_random_uuid(),
  signaleur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  cible uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  motif text not null
    check (motif in ('spam', 'harcelement', 'contenu_inapproprie',
                     'usurpation', 'autre')),
  description text,
  message_id uuid references public.messages_amis(id) on delete set null,
  statut text not null default 'en_attente'
    check (statut in ('en_attente', 'traite', 'rejete')),
  cree_a timestamptz not null default now(),
  traite_a timestamptz,
  constraint signalements_utilisateurs_pas_soi_meme check (signaleur <> cible)
);

create index if not exists signalements_utilisateurs_cible_idx
  on public.signalements_utilisateurs (cible, cree_a desc);
create index if not exists signalements_utilisateurs_statut_idx
  on public.signalements_utilisateurs (statut, cree_a);

alter table public.signalements_utilisateurs enable row level security;

-- 2) Blocage / déblocage / état ---------------------------------------------
create or replace function public.est_bloque(p_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.blocages b
     where (b.bloqueur = auth.uid() and b.bloque = p_id)
        or (b.bloqueur = p_id and b.bloque = auth.uid())
  );
$$;

grant execute on function public.est_bloque(uuid) to anon, authenticated;

create or replace function public.bloquer_utilisateur(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_id is null then return 'introuvable'; end if;
  if p_id = v_uid then return 'soi_meme'; end if;
  if not exists (select 1 from public.profiles where id = p_id) then
    return 'introuvable';
  end if;

  insert into public.blocages (bloqueur, bloque)
  values (v_uid, p_id)
  on conflict (bloqueur, bloque) do nothing;

  -- Le blocage coupe immédiatement l'amitié et les demandes en attente.
  delete from public.amities
   where (demandeur = v_uid and destinataire = p_id)
      or (demandeur = p_id and destinataire = v_uid);

  return 'bloque';
end;
$$;

grant execute on function public.bloquer_utilisateur(uuid)
  to anon, authenticated;

create or replace function public.debloquer_utilisateur(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or p_id is null then return false; end if;
  delete from public.blocages
   where bloqueur = v_uid and bloque = p_id;
  return found;
end;
$$;

grant execute on function public.debloquer_utilisateur(uuid)
  to anon, authenticated;

drop function if exists public.mes_blocages();
create or replace function public.mes_blocages()
returns table (
  user_id uuid,
  prenom text,
  nom text,
  avatar text,
  cree_a timestamptz
)
language sql
security definer
set search_path = public
as $$
  select b.bloque, p.prenom, p.nom, p.avatar, b.cree_a
  from public.blocages b
  join public.profiles p on p.id = b.bloque
  where b.bloqueur = auth.uid()
  order by b.cree_a desc;
$$;

grant execute on function public.mes_blocages() to anon, authenticated;

-- 3) Signalement -------------------------------------------------------------
create or replace function public.signaler_utilisateur(
  p_id uuid,
  p_motif text,
  p_description text default null,
  p_message_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_motif text := lower(trim(coalesce(p_motif, '')));
  v_nb integer;
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_id is null then return 'introuvable'; end if;
  if p_id = v_uid then return 'soi_meme'; end if;
  if v_motif not in ('spam', 'harcelement', 'contenu_inapproprie',
                     'usurpation', 'autre') then
    return 'motif_invalide';
  end if;
  if not exists (select 1 from public.profiles where id = p_id) then
    return 'introuvable';
  end if;

  -- Garde-fou anti-spam : 20 signalements maximum par 24 h.
  select count(*) into v_nb
  from public.signalements_utilisateurs
  where signaleur = v_uid and cree_a > now() - interval '24 hours';
  if v_nb >= 20 then return 'trop_de_signalements'; end if;

  insert into public.signalements_utilisateurs
    (signaleur, cible, motif, description, message_id)
  values
    (v_uid, p_id, v_motif, nullif(trim(coalesce(p_description, '')), ''),
     p_message_id);

  return 'envoye';
end;
$$;

grant execute on function public.signaler_utilisateur(uuid, text, text, uuid)
  to anon, authenticated;

-- 4) Recherche par code ami : ne révèle pas un compte bloqué ----------------
drop function if exists public.chercher_profil(text);
create or replace function public.chercher_profil(p_code text)
returns table (prenom text, nom text, avatar text)
language sql
security definer
set search_path = public
as $$
  select p.prenom, p.nom, p.avatar
  from public.profiles p
  where p.code_ami = upper(p_code)
    and not exists (
      select 1 from public.blocages b
       where (b.bloqueur = auth.uid() and b.bloque = p.id)
          or (b.bloqueur = p.id and b.bloque = auth.uid())
    )
  limit 1;
$$;

grant execute on function public.chercher_profil(text) to anon, authenticated;

-- 5) Demandes d'ami : un compte bloqué est introuvable ----------------------
drop function if exists public.envoyer_demande_ami(text);
create or replace function public.envoyer_demande_ami(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(p_code);
  v_cible public.profiles%rowtype;
  v_existe public.amities%rowtype;
begin
  if v_uid is null then
    return 'non_connecte';
  end if;
  if v_code is null or length(v_code) = 0 then
    return 'code_invalide';
  end if;

  select * into v_cible from public.profiles where code_ami = v_code limit 1;
  if v_cible is null then
    return 'introuvable';
  end if;
  if v_cible.id = v_uid then
    return 'soi_meme';
  end if;

  -- On ne révèle pas l'existence d'un blocage : la cible est « introuvable ».
  if exists (
    select 1 from public.blocages b
     where (b.bloqueur = v_uid and b.bloque = v_cible.id)
        or (b.bloqueur = v_cible.id and b.bloque = v_uid)
  ) then
    return 'introuvable';
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
    and not exists (
      select 1 from public.blocages b
       where (b.bloqueur = auth.uid() and b.bloque = a.demandeur)
          or (b.bloqueur = a.demandeur and b.bloque = auth.uid())
    )
  order by a.cree_a desc;
$$;

grant execute on function public.mes_demandes_amis() to anon, authenticated;

drop function if exists public.repondre_demande_ami(uuid, boolean);
create or replace function public.repondre_demande_ami(p_id uuid, p_accepter boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_demandeur uuid;
begin
  if v_uid is null then return false; end if;

  select demandeur into v_demandeur
  from public.amities
  where id = p_id and destinataire = v_uid and statut = 'en_attente';

  if not found then return false; end if;

  if exists (
    select 1 from public.blocages b
     where (b.bloqueur = v_uid and b.bloque = v_demandeur)
        or (b.bloqueur = v_demandeur and b.bloque = v_uid)
  ) then
    delete from public.amities where id = p_id;
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

-- 6) Messages : envoi, lecture, aperçus et compteurs ------------------------
drop function if exists public.envoyer_message_ami(uuid, text);
drop function if exists public.envoyer_message_ami(uuid, text, text, integer);
drop function if exists public.envoyer_message_ami(uuid, text, text, integer, jsonb);
drop function if exists public.envoyer_message_ami(uuid, text, text, integer, jsonb, text);

create or replace function public.envoyer_message_ami(
  p_ami_id uuid,
  p_contenu text,
  p_audio_chemin text default null,
  p_audio_duree_ms integer default null,
  p_audio_formes jsonb default null,
  p_image_chemin text default null,
  p_reply_to_message_id uuid default null
)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ami boolean;
  v_type text := 'texte';
  v_image text := nullif(trim(coalesce(p_image_chemin, '')), '');
  v_cible public.messages_amis%rowtype;
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_ami_id is null then return 'destinataire_invalide'; end if;
  if v_image is not null then
    v_type := 'image';
  elsif p_audio_chemin is not null and length(trim(p_audio_chemin)) > 0 then
    v_type := 'vocal';
  end if;
  if v_type = 'texte' and (p_contenu is null or length(trim(p_contenu)) = 0) then
    return 'contenu_vide';
  end if;

  if exists (
    select 1 from public.blocages b
     where (b.bloqueur = v_uid and b.bloque = p_ami_id)
        or (b.bloqueur = p_ami_id and b.bloque = v_uid)
  ) then
    return 'pas_ami';
  end if;

  select true into v_ami from public.amities a
   where a.statut='accepte'
     and ((a.demandeur=v_uid and a.destinataire=p_ami_id)
       or (a.demandeur=p_ami_id and a.destinataire=v_uid))
   limit 1;
  if v_ami is not true then return 'pas_ami'; end if;

  delete from public.messages_amis where cree_a < now() - interval '7 days';

  if p_reply_to_message_id is not null then
    select * into v_cible
      from public.messages_amis
     where id = p_reply_to_message_id;
    if not found then return 'message_introuvable'; end if;
    if not ((v_cible.expediteur = v_uid and v_cible.destinataire = p_ami_id)
         or (v_cible.expediteur = p_ami_id and v_cible.destinataire = v_uid)) then
      return 'pas_autorise';
    end if;
  end if;

  insert into public.messages_amis
    (expediteur, destinataire, contenu, type_message, audio_chemin,
     audio_duree_ms, audio_formes, image_chemin, reply_to_message_id)
  values (v_uid, p_ami_id, coalesce(trim(p_contenu), ''), v_type,
          case when v_type = 'vocal'
               then nullif(trim(coalesce(p_audio_chemin,'')), '') end,
          case when v_type = 'vocal' then p_audio_duree_ms end,
          case
            when v_type = 'vocal' and jsonb_typeof(p_audio_formes) = 'array'
              then p_audio_formes
          end,
          case when v_type = 'image' then v_image end,
          p_reply_to_message_id);
  return 'envoye';
end;
$$;
grant execute on function public.envoyer_message_ami(uuid, text, text, integer, jsonb, text, uuid)
  to anon, authenticated;

drop function if exists public.mes_messages_ami(uuid);
create or replace function public.mes_messages_ami(p_ami_id uuid)
returns setof jsonb
language sql security definer set search_path = public
as $kf$
select to_jsonb(t) from (
  select
    m.id, m.expediteur, m.contenu, m.cree_a,
    (m.expediteur = auth.uid()) as moi,
    (m.recu_a is not null) as recu,
    m.lu, m.est_systeme, m.type_systeme,
    m.latitude, m.longitude, m.info_id,
    m.type_message, m.audio_chemin, m.audio_duree_ms, m.audio_formes,
    m.image_chemin, m.modifie_a,
    m.reply_to_message_id,
    case
      when m.reply_to_message_id is null then null
      else (
        select jsonb_build_object(
          'id', r.id,
          'expediteur', r.expediteur,
          'moi', (r.expediteur = auth.uid()),
          'contenu', r.contenu,
          'type_message', r.type_message,
          'est_systeme', r.est_systeme,
          'modifie_a', r.modifie_a
        )
        from public.messages_amis r
        where r.id = m.reply_to_message_id
          and not (auth.uid() = any (coalesce(r.supprime_pour, '{}'::uuid[])))
      )
    end as reply_to
  from public.messages_amis m
  where m.cree_a >= now() - interval '7 days'
    and m.destinataire in (auth.uid(), p_ami_id)
    and m.expediteur in (auth.uid(), p_ami_id)
    and not (auth.uid() = any (coalesce(m.supprime_pour, '{}'::uuid[])))
    and not exists (
      select 1 from public.blocages b
       where (b.bloqueur = auth.uid() and b.bloque = p_ami_id)
          or (b.bloqueur = p_ami_id and b.bloque = auth.uid())
    )
  order by m.cree_a asc
  limit 500
) t;
$kf$;
grant execute on function public.mes_messages_ami(uuid) to anon, authenticated;

drop function if exists public.apercus_messages_amis();
create or replace function public.apercus_messages_amis()
returns setof jsonb
language sql
security definer
set search_path = public
as $kf$
select to_jsonb(t) from (
  select distinct on (s.autre)
    s.autre as ami_id,
    s.contenu,
    s.type_message,
    (s.expediteur = auth.uid()) as moi,
    s.cree_a
  from (
    select
      m.contenu,
      m.type_message,
      m.expediteur,
      m.cree_a,
      case
        when m.expediteur = auth.uid() then m.destinataire
        else m.expediteur
      end as autre
    from public.messages_amis m
    where m.cree_a >= now() - interval '7 days'
      and (m.expediteur = auth.uid() or m.destinataire = auth.uid())
      and not (auth.uid() = any (coalesce(m.supprime_pour, '{}'::uuid[])))
      and not exists (
        select 1 from public.blocages b
         where (b.bloqueur = auth.uid()
                and b.bloque = case when m.expediteur = auth.uid()
                                    then m.destinataire else m.expediteur end)
            or (b.bloque = auth.uid()
                and b.bloqueur = case when m.expediteur = auth.uid()
                                      then m.destinataire else m.expediteur end)
      )
  ) s
  order by s.autre, s.cree_a desc
) t;
$kf$;

grant execute on function public.apercus_messages_amis() to anon, authenticated;

drop function if exists public.nb_messages_non_lus_amis();
create or replace function public.nb_messages_non_lus_amis()
returns setof jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object('ami_id', m.expediteur, 'nb', count(*))
  from public.messages_amis m
  where m.destinataire = auth.uid()
    and m.lu = false
    and m.cree_a >= now() - interval '7 days'
    and not exists (
      select 1 from public.blocages b
       where (b.bloqueur = auth.uid() and b.bloque = m.expediteur)
          or (b.bloqueur = m.expediteur and b.bloque = auth.uid())
    )
  group by m.expediteur;
$$;

grant execute on function public.nb_messages_non_lus_amis()
  to anon, authenticated;

-- 7) Informations partagées et tags -----------------------------------------
create or replace function public.envoyer_info_ami(
  p_ami_id uuid,
  p_contenu text,
  p_source_url text default null,
  p_information_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ami boolean;
  v_contenu text;
  v_url text;
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_ami_id is null then return 'destinataire_invalide'; end if;
  if p_contenu is null or length(trim(p_contenu)) = 0 then
    return 'contenu_vide';
  end if;
  v_contenu := trim(p_contenu);

  v_url := null;
  if p_source_url is not null and length(trim(p_source_url)) > 0 then
    v_url := trim(p_source_url);
  end if;

  if exists (
    select 1 from public.blocages b
     where (b.bloqueur = v_uid and b.bloque = p_ami_id)
        or (b.bloqueur = p_ami_id and b.bloque = v_uid)
  ) then
    return 'pas_ami';
  end if;

  select true into v_ami
  from public.amities a
  where a.statut = 'accepte'
    and ((a.demandeur = v_uid and a.destinataire = p_ami_id)
      or (a.demandeur = p_ami_id and a.destinataire = v_uid))
  limit 1;

  if v_ami is not true then return 'pas_ami'; end if;

  insert into public.partages_info
    (expediteur, destinataire, information_id, contenu, source_url)
  values
    (v_uid, p_ami_id, p_information_id, v_contenu, v_url);

  return 'envoye';
end;
$$;

grant execute on function public.envoyer_info_ami(uuid, text, text, uuid)
  to anon, authenticated;

drop function if exists public.mes_infos_recues();
create or replace function public.mes_infos_recues()
returns setof jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', pa.id,
    'expediteur', pa.expediteur,
    'prenom', p.prenom,
    'nom', p.nom,
    'avatar', p.avatar,
    'contenu', pa.contenu,
    'source_url', pa.source_url,
    'cree_a', pa.cree_a,
    'lu', pa.lu
  )
  from public.partages_info pa
  join public.profiles p on p.id = pa.expediteur
  where pa.destinataire = auth.uid()
    and not exists (
      select 1 from public.blocages b
       where (b.bloqueur = auth.uid() and b.bloque = pa.expediteur)
          or (b.bloqueur = pa.expediteur and b.bloque = auth.uid())
    )
  order by pa.cree_a desc
  limit 200;
$$;

grant execute on function public.mes_infos_recues() to anon, authenticated;

create or replace function public.taguer_information(
  p_ami_id uuid,
  p_info_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ami boolean;
  v_snippet text;
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_ami_id is null or p_info_id is null then return 'invalide'; end if;

  if exists (
    select 1 from public.blocages b
     where (b.bloqueur = v_uid and b.bloque = p_ami_id)
        or (b.bloqueur = p_ami_id and b.bloque = v_uid)
  ) then
    return 'pas_ami';
  end if;

  select true into v_ami
  from public.amities a
  where a.statut = 'accepte'
    and ((a.demandeur = v_uid and a.destinataire = p_ami_id)
      or (a.demandeur = p_ami_id and a.destinataire = v_uid))
  limit 1;
  if v_ami is not true then return 'pas_ami'; end if;

  select left(i.contenu, 160) into v_snippet
  from public.informations i
  where i.id = p_info_id;
  if v_snippet is null then return 'info_introuvable'; end if;

  delete from public.messages_amis where cree_a < now() - interval '7 days';
  insert into public.messages_amis
    (expediteur, destinataire, contenu, est_systeme, type_systeme, info_id)
  values
    (v_uid, p_ami_id, v_snippet, true, 'tag_info', p_info_id);
  return 'envoye';
end;
$$;
grant execute on function public.taguer_information(uuid, uuid)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- =====================================================================
-- Fichier : 20261102010000_partage_position_consentement.sql
-- =====================================================================
-- Point 8 — Partage de position : consentement explicite, durée limitée et
-- arrêt réel côté serveur.
--
-- Avant ce correctif :
--   * l'app activait le partage automatiquement au démarrage ;
--   * `publier_ma_position` créait une ligne active même sans consentement ;
--   * `definir_partage_position(false)` laissait les dernières coordonnées ;
--   * `mes_amis()` renvoyait une position vieille de plusieurs jours.
--
-- Maintenant :
--   * aucune position n'est publiée sans ligne active non expirée ;
--   * l'utilisateur choisit une durée (ou « jusqu'à désactivation ») ;
--   * la désactivation efface immédiatement latitude/longitude/cap ;
--   * une position n'est visible que si elle a moins de 60 minutes.

alter table if exists public.positions_amis
  add column if not exists expire_a timestamptz;

comment on column public.positions_amis.expire_a is
  'Fin du consentement de partage. NULL = partage sans date de fin, mais les coordonnées restent soumises au TTL de 60 min dans mes_amis().';

-- 1) Publier ma position : uniquement sur une autorisation déjà active -------
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

  -- Une autorisation expirée est révoquée avant toute publication.
  update public.positions_amis
     set partage_actif = false,
         latitude = null,
         longitude = null,
         cap = null,
         maj_a = null,
         expire_a = null
   where user_id = v_uid
     and expire_a is not null
     and expire_a <= now();

  -- Aucun INSERT : sans consentement préalable, on ne crée jamais de position.
  update public.positions_amis
     set latitude = p_latitude,
         longitude = p_longitude,
         cap = p_cap,
         maj_a = now()
   where user_id = v_uid
     and partage_actif = true
     and (expire_a is null or expire_a > now());

  return found;
end;
$$;

grant execute on function public.publier_ma_position(double precision, double precision, double precision)
  to anon, authenticated;

-- 2) Activer / désactiver, avec une durée facultative ------------------------
drop function if exists public.definir_partage_position(boolean);
drop function if exists public.definir_partage_position(boolean, integer);
create or replace function public.definir_partage_position(
  p_actif boolean,
  p_duree_minutes integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_actif boolean := coalesce(p_actif, false);
  v_duree integer := p_duree_minutes;
begin
  if v_uid is null then
    return false;
  end if;

  if v_actif and v_duree is not null and v_duree <= 0 then
    v_duree := null;
  end if;

  insert into public.positions_amis (
    user_id, latitude, longitude, cap, partage_actif, maj_a, expire_a
  )
  values (
    v_uid,
    null,
    null,
    null,
    v_actif,
    case when v_actif then now() else null end,
    case
      when v_actif and v_duree is not null
        then now() + make_interval(mins => v_duree)
      else null
    end
  )
  on conflict (user_id) do update set
    partage_actif = v_actif,
    maj_a = case when v_actif then now() else null end,
    expire_a = case
      when v_actif and v_duree is not null
        then now() + make_interval(mins => v_duree)
      else null
    end,
    -- Désactivation = effacement immédiat des coordonnées.
    latitude = case when v_actif then positions_amis.latitude else null end,
    longitude = case when v_actif then positions_amis.longitude else null end,
    cap = case when v_actif then positions_amis.cap else null end;

  return true;
end;
$$;

grant execute on function public.definir_partage_position(boolean, integer)
  to anon, authenticated;

-- 3) Mon partage est-il réellement actif ? -----------------------------------
drop function if exists public.mon_partage_position();
create or replace function public.mon_partage_position()
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce((
    select pos.partage_actif
       and (pos.expire_a is null or pos.expire_a > now())
    from public.positions_amis pos
    where pos.user_id = auth.uid()
  ), false);
$$;

grant execute on function public.mon_partage_position() to anon, authenticated;

-- 4) Détail pour l'écran de consentement -------------------------------------
create or replace function public.mon_partage_position_details()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'actif', coalesce(pos.partage_actif, false)
      and (pos.expire_a is null or pos.expire_a > now()),
    'expire_a', pos.expire_a
  )
  from public.positions_amis pos
  where pos.user_id = auth.uid()
  union all
  select jsonb_build_object('actif', false, 'expire_a', null)
  where not exists (
    select 1 from public.positions_amis pos where pos.user_id = auth.uid()
  )
  limit 1;
$$;

grant execute on function public.mon_partage_position_details()
  to anon, authenticated;

-- 5) Mes amis : TTL de 60 minutes et exclusion des comptes bloqués -----------
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
  partage_actif boolean,
  partage_expire_a timestamptz
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
    case when pos.partage_actif
              and pos.maj_a > now() - interval '60 minutes'
              and (pos.expire_a is null or pos.expire_a > now())
         then pos.latitude end as latitude,
    case when pos.partage_actif
              and pos.maj_a > now() - interval '60 minutes'
              and (pos.expire_a is null or pos.expire_a > now())
         then pos.longitude end as longitude,
    case when pos.partage_actif
              and pos.maj_a > now() - interval '60 minutes'
              and (pos.expire_a is null or pos.expire_a > now())
         then pos.cap end as cap,
    pos.maj_a,
    coalesce(
      pos.partage_actif
        and pos.maj_a > now() - interval '60 minutes'
        and (pos.expire_a is null or pos.expire_a > now()),
      false
    ) as partage_actif,
    pos.expire_a as partage_expire_a
  from public.amities a
  join public.profiles p
    on p.id = case when a.demandeur = auth.uid()
                   then a.destinataire else a.demandeur end
  left join public.positions_amis pos on pos.user_id = p.id
  where a.statut = 'accepte'
    and (a.demandeur = auth.uid() or a.destinataire = auth.uid())
    and not exists (
      select 1 from public.blocages b
       where (b.bloqueur = auth.uid() and b.bloque = p.id)
          or (b.bloqueur = p.id and b.bloque = auth.uid())
    )
  order by coalesce(p.prenom, ''), coalesce(p.nom, '');
$$;

grant execute on function public.mes_amis() to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- =====================================================================
-- Fichier : 20261102020000_rate_limit_adoption.sql
-- =====================================================================
-- Point 2 — Limitation des tentatives de récupération de compte.
--
-- `adopter_profil` vérifie un code de 8 caractères + le nom exact. Sans limite,
-- un attaquant pouvait essayer des codes en boucle. On ajoute :
--   * 5 échecs maximum par identité et par fenêtre de 10 minutes ;
--   * 15 échecs maximum par code et par fenêtre de 15 minutes ;
--   * un verrou transactionnel par code pour éviter les essais concurrents ;
--   * une remise à zéro des échecs de l'identité après une connexion réussie.
--
-- La table ne référence PAS profiles : les identités anonymes n'ont pas
-- toujours de profil et les tentatives doivent survivre à leur suppression.

create table if not exists public.tentatives_adoption (
  id bigserial primary key,
  uid uuid not null,
  code_tente text not null,
  reussi boolean not null default false,
  cree_a timestamptz not null default now()
);

create index if not exists tentatives_adoption_uid_idx
  on public.tentatives_adoption (uid, cree_a desc);
create index if not exists tentatives_adoption_code_idx
  on public.tentatives_adoption (code_tente, cree_a desc);

alter table public.tentatives_adoption enable row level security;

drop function if exists public.adopter_profil(text, text);
create or replace function public.adopter_profil(code_saisi text, nom_saisi text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(regexp_replace(
    coalesce(code_saisi, ''), '[^a-zA-Z0-9]', '', 'g'
  ));
  v_echecs_uid integer;
  v_echecs_code integer;
  v_retry integer;
  v_profil public.profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'Identité anonyme absente.';
  end if;

  -- Purge opportuniste : on ne conserve qu'une journée de journaux.
  delete from public.tentatives_adoption
   where cree_a < now() - interval '1 day';

  -- Un seul essai à la fois pour un code donné.
  perform pg_advisory_xact_lock(hashtext('adopter_profil:' || v_code));

  select count(*) into v_echecs_uid
  from public.tentatives_adoption
  where uid = v_uid
    and reussi = false
    and cree_a > now() - interval '10 minutes';

  select count(*) into v_echecs_code
  from public.tentatives_adoption
  where code_tente = v_code
    and reussi = false
    and cree_a > now() - interval '15 minutes';

  if v_echecs_uid >= 5 then
    return jsonb_build_object(
      'erreur', 'trop_de_tentatives',
      'retry_after_secondes', 600
    );
  end if;

  if v_echecs_code >= 15 then
    v_retry := 900;
    return jsonb_build_object(
      'erreur', 'trop_de_tentatives',
      'retry_after_secondes', v_retry
    );
  end if;

  -- Un code vide ou trop court est enregistré comme échec, sans requête.
  if length(v_code) < 6 then
    insert into public.tentatives_adoption (uid, code_tente, reussi)
    values (v_uid, v_code, false);
    return null;
  end if;

  select *
    into v_profil
    from public.profiles
   where code = v_code
     and lower(trim(nom)) = lower(trim(nom_saisi))
   limit 1;

  if v_profil is null then
    insert into public.tentatives_adoption (uid, code_tente, reussi)
    values (v_uid, v_code, false);
    return null;
  end if;

  if v_profil.id = v_uid then
    delete from public.tentatives_adoption
     where uid = v_uid and reussi = false;
    insert into public.tentatives_adoption (uid, code_tente, reussi)
    values (v_uid, v_code, true);
    return to_jsonb(v_profil);
  end if;

  -- L'identité anonyme jetable est supprimée. Ses partages_info et
  -- messages_amis suivent automatiquement (ON DELETE CASCADE).
  delete from public.profiles where id = v_uid;

  if to_regclass('public.amities') is not null then
    delete from public.amities
     where demandeur = v_uid or destinataire = v_uid;

    update public.amities
       set demandeur = case when demandeur = v_profil.id then v_uid else demandeur end,
           destinataire = case when destinataire = v_profil.id then v_uid else destinataire end
     where demandeur = v_profil.id or destinataire = v_profil.id;
  end if;

  if to_regclass('public.positions_amis') is not null then
    delete from public.positions_amis where user_id = v_uid;
    update public.positions_amis set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.reactions') is not null then
    delete from public.reactions r
     where r.user_id = v_profil.id
       and exists (
         select 1 from public.reactions r2
          where r2.information_id = r.information_id and r2.user_id = v_uid
       );
    update public.reactions set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.reactions_emoji') is not null then
    delete from public.reactions_emoji e
     where e.user_id = v_profil.id
       and exists (
         select 1 from public.reactions_emoji e2
          where e2.information_id = e.information_id and e2.user_id = v_uid
       );
    update public.reactions_emoji set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.signalements') is not null then
    update public.signalements set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.blocages') is not null then
    delete from public.blocages
     where bloqueur = v_uid or bloque = v_uid;
    update public.blocages
       set bloqueur = case when bloqueur = v_profil.id then v_uid else bloqueur end,
           bloque = case when bloque = v_profil.id then v_uid else bloque end
     where bloqueur = v_profil.id or bloque = v_profil.id;
  end if;

  update public.profiles set id = v_uid where id = v_profil.id;

  delete from public.tentatives_adoption
   where uid = v_uid and reussi = false;
  insert into public.tentatives_adoption (uid, code_tente, reussi)
  values (v_uid, v_code, true);

  select * into v_profil from public.profiles where id = v_uid;
  return to_jsonb(v_profil);
end;
$$;

grant execute on function public.adopter_profil(text, text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- =====================================================================
-- Fichier : 20261102030000_notifications_push.sql
-- =====================================================================
-- Point 6 — Infrastructure des notifications push.
--
-- Les préférences locales existaient déjà, mais rien n'était stocké côté
-- serveur et aucun jeton d'appareil n'était associé au compte. Ces tables
-- permettent à une Edge Function d'envoyer un push uniquement aux appareils
-- des personnes concernées, en respectant leurs préférences.
--
-- Le fournisseur (Firebase/APNs) reste configuré côté Supabase via des
-- secrets : aucune clé privée n'est stockée dans l'application.

create table if not exists public.appareils_push (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  token text not null unique,
  plateforme text not null default 'android'
    check (plateforme in ('android', 'ios', 'web')),
  cree_a timestamptz not null default now(),
  maj_a timestamptz not null default now()
);

create index if not exists appareils_push_user_idx
  on public.appareils_push (user_id);

alter table public.appareils_push enable row level security;

create table if not exists public.preferences_notifications (
  user_id uuid primary key references public.profiles(id)
    on delete cascade on update cascade,
  push_actif boolean not null default true,
  embouteillages boolean not null default true,
  routes_bloquees boolean not null default true,
  messages boolean not null default true,
  demandes_amis boolean not null default true,
  infos boolean not null default true,
  maj_a timestamptz not null default now()
);

alter table public.preferences_notifications enable row level security;

-- 1) Enregistrer / rafraîchir le jeton de cet appareil -----------------------
create or replace function public.enregistrer_token_push(
  p_token text,
  p_plateforme text default 'android'
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text := trim(coalesce(p_token, ''));
  v_plateforme text := lower(trim(coalesce(p_plateforme, 'android')));
begin
  if v_uid is null then return false; end if;
  if length(v_token) < 20 or length(v_token) > 4096 then return false; end if;
  if v_plateforme not in ('android', 'ios', 'web') then
    v_plateforme := 'android';
  end if;

  insert into public.appareils_push (user_id, token, plateforme)
  values (v_uid, v_token, v_plateforme)
  on conflict (token) do update set
    user_id = excluded.user_id,
    plateforme = excluded.plateforme,
    maj_a = now();

  return true;
end;
$$;

grant execute on function public.enregistrer_token_push(text, text)
  to anon, authenticated;

-- 2) Retirer le jeton (déconnexion, permission révoquée) --------------------
create or replace function public.supprimer_token_push(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return false; end if;
  delete from public.appareils_push
   where user_id = v_uid and token = trim(coalesce(p_token, ''));
  return found;
end;
$$;

grant execute on function public.supprimer_token_push(text)
  to anon, authenticated;

create or replace function public.supprimer_mes_tokens_push()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_nb integer;
begin
  if v_uid is null then return 0; end if;
  delete from public.appareils_push where user_id = v_uid;
  get diagnostics v_nb = row_count;
  return v_nb;
end;
$$;

grant execute on function public.supprimer_mes_tokens_push()
  to anon, authenticated;

-- 3) Préférences -------------------------------------------------------------
create or replace function public.mes_preferences_notifications()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'push_actif', p.push_actif,
        'embouteillages', p.embouteillages,
        'routes_bloquees', p.routes_bloquees,
        'messages', p.messages,
        'demandes_amis', p.demandes_amis,
        'infos', p.infos
      )
      from public.preferences_notifications p
      where p.user_id = auth.uid()
    ),
    jsonb_build_object(
      'push_actif', true,
      'embouteillages', true,
      'routes_bloquees', true,
      'messages', true,
      'demandes_amis', true,
      'infos', true
    )
  );
$$;

grant execute on function public.mes_preferences_notifications()
  to anon, authenticated;

create or replace function public.definir_preferences_notifications(
  p_preferences jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v jsonb := coalesce(p_preferences, '{}'::jsonb);
begin
  if v_uid is null then
    return jsonb_build_object('erreur', 'non_connecte');
  end if;

  insert into public.preferences_notifications (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  update public.preferences_notifications
     set push_actif = case when v ? 'push_actif'
           then coalesce((v->>'push_actif')::boolean, push_actif)
           else push_actif end,
         embouteillages = case when v ? 'embouteillages'
           then coalesce((v->>'embouteillages')::boolean, embouteillages)
           else embouteillages end,
         routes_bloquees = case when v ? 'routes_bloquees'
           then coalesce((v->>'routes_bloquees')::boolean, routes_bloquees)
           else routes_bloquees end,
         messages = case when v ? 'messages'
           then coalesce((v->>'messages')::boolean, messages)
           else messages end,
         demandes_amis = case when v ? 'demandes_amis'
           then coalesce((v->>'demandes_amis')::boolean, demandes_amis)
           else demandes_amis end,
         infos = case when v ? 'infos'
           then coalesce((v->>'infos')::boolean, infos)
           else infos end,
         maj_a = now()
   where user_id = v_uid;

  return public.mes_preferences_notifications();
end;
$$;

grant execute on function public.definir_preferences_notifications(jsonb)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- =====================================================================
-- Fichier : 20261102040000_purge_compte.sql
-- =====================================================================
-- Point 1 — Purge des données applicatives avant suppression du compte Auth.
--
-- La suppression d'un utilisateur `auth.users` ne supprime pas automatiquement
-- `profiles` (cette table n'a pas de FK vers auth.users dans le schéma actuel).
-- Cette fonction est appelée par l'Edge Function `supprimer-compte`, avec la
-- clé service_role uniquement, après le nettoyage des fichiers Storage.
--
-- Elle est volontairement NON exécutable par anon/authenticated : un compte ne
-- doit pas pouvoir purger les données d'un autre en changeant l'argument.

create or replace function public.purger_compte(p_uid uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_uid is null then
    return false;
  end if;

  delete from public.tentatives_adoption where uid = p_uid;

  delete from public.signalements_utilisateurs
   where signaleur = p_uid or cible = p_uid;

  delete from public.blocages
   where bloqueur = p_uid or bloque = p_uid;

  delete from public.amities
   where demandeur = p_uid or destinataire = p_uid;

  delete from public.positions_amis where user_id = p_uid;

  delete from public.reactions where user_id = p_uid;
  delete from public.reactions_emoji where user_id = p_uid;

  -- Signalements routiers : contribution personnelle, supprimée avec le compte.
  delete from public.signalements where user_id = p_uid;

  delete from public.appareils_push where user_id = p_uid;
  delete from public.preferences_notifications where user_id = p_uid;

  -- Le profil supprime en cascade messages_amis et partages_info.
  delete from public.profiles where id = p_uid;

  return true;
end;
$$;

revoke all on function public.purger_compte(uuid) from public;
revoke all on function public.purger_compte(uuid) from anon, authenticated;
grant execute on function public.purger_compte(uuid) to service_role;

select pg_notify('pgrst', 'reload schema');

commit;

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

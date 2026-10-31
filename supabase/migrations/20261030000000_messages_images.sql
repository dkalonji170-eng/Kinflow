-- Photos dans la discussion privée.
--
-- Jusqu'ici un message ne pouvait être que du texte ou un vocal. On ajoute la
-- PHOTO : une image prise avec l'appareil photo ou choisie dans la galerie,
-- envoyée comme un message. Comme les vocaux, l'image vit dans un bucket
-- privé (`messages_images`) et n'est lisible que par les deux personnes de la
-- conversation, via une URL signée.
--
-- Rétrocompatible : `image_chemin` est facultatif, les messages existants ne
-- changent pas. Le script est idempotent (on peut le relancer sans risque).

-- 1) Colonne de la photo ------------------------------------------------------
alter table if exists public.messages_amis
  add column if not exists image_chemin text;

comment on column public.messages_amis.image_chemin is
  'Chemin de la photo dans le bucket privé messages_images (NULL = pas de photo).';

-- 2) Bucket privé -------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('messages_images', 'messages_images', false)
on conflict (id) do update set public = false;

-- 3) Une photo n'est visible que par les deux personnes de la conversation ----
create or replace function public.puis_voir_image(p_chemin text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
      from public.messages_amis m
     where m.image_chemin = p_chemin
       and (m.expediteur = auth.uid() or m.destinataire = auth.uid())
  );
$$;

grant execute on function public.puis_voir_image(text) to authenticated;

-- 4) Politiques Storage (mêmes règles que les vocaux) -------------------------
drop policy if exists "messages_images_insert" on storage.objects;
create policy "messages_images_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'messages_images'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

drop policy if exists "messages_images_select" on storage.objects;
create policy "messages_images_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'messages_images'
    and (
      auth.uid()::text = (storage.foldername(name))[1]
      or auth.uid()::text = (storage.foldername(name))[2]
      or public.puis_voir_image(name)
    )
  );

drop policy if exists "messages_images_delete" on storage.objects;
create policy "messages_images_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'messages_images'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- 5) envoyer_message_ami : nouveau paramètre facultatif p_image_chemin ---------
-- `create or replace` ne remplace pas une fonction dont la liste d'arguments
-- change : on supprime explicitement les anciennes signatures.
drop function if exists public.envoyer_message_ami(uuid, text, text, integer);
drop function if exists public.envoyer_message_ami(uuid, text, text, integer, jsonb);

create or replace function public.envoyer_message_ami(
  p_ami_id uuid,
  p_contenu text,
  p_audio_chemin text default null,
  p_audio_duree_ms integer default null,
  p_audio_formes jsonb default null,
  p_image_chemin text default null
)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ami boolean;
  v_type text := 'texte';
  v_image text := nullif(trim(coalesce(p_image_chemin, '')), '');
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
  select true into v_ami from public.amities a
   where a.statut='accepte'
     and ((a.demandeur=v_uid and a.destinataire=p_ami_id)
       or (a.demandeur=p_ami_id and a.destinataire=v_uid))
   limit 1;
  if v_ami is not true then return 'pas_ami'; end if;
  delete from public.messages_amis where cree_a < now() - interval '7 days';
  insert into public.messages_amis
    (expediteur, destinataire, contenu, type_message, audio_chemin,
     audio_duree_ms, audio_formes, image_chemin)
  values (v_uid, p_ami_id, coalesce(trim(p_contenu), ''), v_type,
          case when v_type = 'vocal'
               then nullif(trim(coalesce(p_audio_chemin,'')), '') end,
          case when v_type = 'vocal' then p_audio_duree_ms end,
          case
            when v_type = 'vocal' and jsonb_typeof(p_audio_formes) = 'array'
              then p_audio_formes
          end,
          case when v_type = 'image' then v_image end);
  return 'envoye';
end;
$$;
grant execute on function public.envoyer_message_ami(uuid, text, text, integer, jsonb, text)
  to anon, authenticated;

-- 6) mes_messages_ami : on expose la photo au destinataire --------------------
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
    m.image_chemin, m.modifie_a
  from public.messages_amis m
  where m.cree_a >= now() - interval '7 days'
    and m.destinataire in (auth.uid(), p_ami_id)
    and m.expediteur in (auth.uid(), p_ami_id)
    and not (auth.uid() = any (coalesce(m.supprime_pour, '{}'::uuid[])))
  order by m.cree_a asc
  limit 500
) t;
$kf$;
grant execute on function public.mes_messages_ami(uuid) to anon, authenticated;

-- 7) Aperçu dans la liste Amis(es) : on expose le type du dernier message -----
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
  ) s
  order by s.autre, s.cree_a desc
) t;
$kf$;

grant execute on function public.apercus_messages_amis() to anon, authenticated;

-- 8) modifier_message : une photo n'a pas de texte modifiable -----------------
create or replace function public.modifier_message(
  p_message_id uuid,
  p_contenu text
)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_msg public.messages_amis%rowtype;
  v_texte text := coalesce(trim(p_contenu), '');
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_message_id is null then return 'message_invalide'; end if;
  if length(v_texte) = 0 then return 'contenu_vide'; end if;
  if length(v_texte) > 4000 then return 'contenu_trop_long'; end if;

  select * into v_msg from public.messages_amis where id = p_message_id;
  if not found then return 'message_introuvable'; end if;
  if v_msg.expediteur is distinct from v_uid then return 'pas_autorise'; end if;
  if v_msg.est_systeme is true then return 'message_systeme'; end if;
  if v_msg.type_message = 'vocal' then return 'vocal_non_modifiable'; end if;
  if v_msg.type_message = 'image' then return 'media_non_modifiable'; end if;

  update public.messages_amis
     set contenu = v_texte,
         modifie_a = now()
   where id = p_message_id;
  return 'modifie';
end;
$$;
grant execute on function public.modifier_message(uuid, text)
  to anon, authenticated;

-- 9) supprimer_message : on retire aussi la photo du bucket -------------------
create or replace function public.supprimer_message(p_message_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_msg public.messages_amis%rowtype;
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_message_id is null then return 'message_invalide'; end if;

  select * into v_msg from public.messages_amis where id = p_message_id;
  if not found then return 'message_introuvable'; end if;

  -- Expéditeur : suppression définitive pour tout le monde.
  if v_msg.expediteur = v_uid then
    if coalesce(v_msg.audio_chemin, '') <> '' then
      begin
        delete from storage.objects
         where bucket_id = 'messages_vocaux'
           and name = v_msg.audio_chemin;
      exception when others then
        null;
      end;
    end if;
    if coalesce(v_msg.image_chemin, '') <> '' then
      begin
        delete from storage.objects
         where bucket_id = 'messages_images'
           and name = v_msg.image_chemin;
      exception when others then
        null;
      end;
    end if;
    delete from public.messages_amis where id = p_message_id;
    return 'supprime';
  end if;

  -- Destinataire : masquage côté uniquement, le message reste chez l'autre.
  if v_msg.destinataire = v_uid then
    update public.messages_amis
       set supprime_pour = array_append(
             coalesce(supprime_pour, '{}'::uuid[]), v_uid)
     where id = p_message_id
       and not (v_uid = any (coalesce(supprime_pour, '{}'::uuid[])));
    return 'supprime';
  end if;

  return 'pas_autorise';
end;
$$;
grant execute on function public.supprimer_message(uuid)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

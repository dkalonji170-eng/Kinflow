-- Réponse à un message précis, façon WhatsApp.
--
-- Jusqu'ici une réponse était un message comme un autre : impossible de savoir
-- à quoi elle répondait. On ajoute une VRAIE RÉFÉRENCE vers le message cité :
--   * `reply_to_message_id` stocke l'identifiant du message d'origine (jamais
--     une copie de son texte) ;
--   * `mes_messages_ami` renvoie, en plus de l'identifiant, un aperçu
--     `reply_to` (expéditeur, contenu, type) relu À CHAQUE APPEL depuis la
--     table : si le message d'origine est modifié, l'aperçu suit ; s'il est
--     supprimé, la référence est remise à NULL (on delete set null) et la
--     réponse reste lisible, simplement sans citation.
--
-- Fonctionne pour TOUS les types de messages (texte, vocal, photo, système) :
-- l'aperçu n'est qu'un résumé, la référence reste l'identifiant.
--
-- Rétrocompatible : la colonne est facultative et le paramètre d'envoi a une
-- valeur par défaut. Le script est idempotent.

-- 1) Colonne de référence -----------------------------------------------------
alter table if exists public.messages_amis
  add column if not exists reply_to_message_id uuid;

comment on column public.messages_amis.reply_to_message_id is
  'Message auquel celui-ci répond (NULL = message normal). Référence réelle, pas une copie du texte.';

-- Contrainte de clé étrangère : on ne référence qu'un message existant, et la
-- suppression du message d'origine DÉTACHE les réponses (elle ne les supprime
-- jamais). Ajoutée une seule fois.
do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'messages_amis_reply_to_fkey'
       and conrelid = 'public.messages_amis'::regclass
  ) then
    alter table public.messages_amis
      add constraint messages_amis_reply_to_fkey
      foreign key (reply_to_message_id)
      references public.messages_amis(id)
      on delete set null;
  end if;
end
$$;

create index if not exists messages_amis_reply_to_idx
  on public.messages_amis (reply_to_message_id);

-- 2) envoyer_message_ami : nouveau paramètre facultatif p_reply_to_message_id --
-- `create or replace` ne remplace pas une fonction dont la liste d'arguments
-- change : on supprime explicitement les anciennes signatures.
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
  select true into v_ami from public.amities a
   where a.statut='accepte'
     and ((a.demandeur=v_uid and a.destinataire=p_ami_id)
       or (a.demandeur=p_ami_id and a.destinataire=v_uid))
   limit 1;
  if v_ami is not true then return 'pas_ami'; end if;

  -- Purge opportuniste AVANT la validation de la citation : on ne garde jamais
  -- plus de 7 jours de messages, et on ne veut pas créer une réponse pointant
  -- vers un message effacé dans la même transaction (violation de clé
  -- étrangère).
  delete from public.messages_amis where cree_a < now() - interval '7 days';

  -- La citation doit désigner un message de CETTE conversation : on ne peut
  -- pas citer le message d'une autre discussion.
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

-- 3) mes_messages_ami : la référence + l'aperçu du message cité --------------
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
    -- Aperçu relu à la source (donc toujours à jour). NULL si le message cité
    -- a été supprimé : la réponse reste alors affichée sans citation.
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
          -- Message d'origine masqué de mon côté : on n'en révèle pas le texte.
          and not (auth.uid() = any (coalesce(r.supprime_pour, '{}'::uuid[])))
      )
    end as reply_to
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

select pg_notify('pgrst', 'reload schema');

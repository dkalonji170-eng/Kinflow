-- Édition et suppression d'un message depuis l'appui long sur une bulle.
--
-- Jusqu'ici un message envoyé était définitif : impossible de corriger une
-- faute ni de retirer un message par mégarde. On ajoute deux RPC :
--
--   * modifier_message  : l'expéditeur corrige le texte de SON message texte
--                         (un vocal n'a pas de texte modifiable). La date de
--                         modification est conservée pour afficher « modifié ».
--   * supprimer_message : l'expéditeur supprime définitivement le message pour
--                         les DEUX côtés (l'audio est retiré du bucket) ;
--                         le destinataire peut le masquer de SON côté seul
--                         (colonne supprime_pour), comme dans les messageries.
--
-- Rétrocompatible : les colonnes sont facultatives et `mes_messages_ami`
-- filtre les messages masqués côté serveur.

alter table if exists public.messages_amis
  add column if not exists modifie_a timestamptz,
  add column if not exists supprime_pour uuid[];

-- Rattrapage : si certaines migrations antérieures n'ont pas été appliquées,
-- `mes_messages_ami` ci-dessous échouerait (colonne inexistante). On s'assure
-- que toutes les colonnes qu'elle lit existent. Aucun effet si elles existent.
alter table if exists public.messages_amis
  add column if not exists recu_a timestamptz,
  add column if not exists est_systeme boolean not null default false,
  add column if not exists type_systeme text,
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists info_id uuid,
  add column if not exists type_message text not null default 'texte',
  add column if not exists audio_chemin text,
  add column if not exists audio_duree_ms integer,
  add column if not exists audio_formes jsonb;

comment on column public.messages_amis.modifie_a is
  'Date de dernière édition du contenu par l''expéditeur (NULL = jamais modifié).';
comment on column public.messages_amis.supprime_pour is
  'Destinataires qui ont supprimé le message de leur côté (masquage local, pas de suppression physique).';

-- modifier_message -----------------------------------------------------------
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

  update public.messages_amis
     set contenu = v_texte,
         modifie_a = now()
   where id = p_message_id;
  return 'modifie';
end;
$$;
grant execute on function public.modifier_message(uuid, text)
  to anon, authenticated;

-- supprimer_message ----------------------------------------------------------
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
      -- L'objet Storage peut manquer (fichier jamais téléversé, droits) :
      -- la suppression du message doit réussir quand même.
      begin
        delete from storage.objects
         where bucket_id = 'messages_vocaux'
           and name = v_msg.audio_chemin;
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

-- mes_messages_ami : expose modifie_a et masque les messages supprimés --------
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
    m.modifie_a
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

-- Politique Storage : l'expéditeur d'un vocal peut retirer son fichier quand
-- il supprime son message (le SQL de `supprimer_message` tente aussi la
-- suppression directe, mais les droits Storage ne sont pas garantis en SQL).
drop policy if exists "messages_vocaux_delete" on storage.objects;
create policy "messages_vocaux_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'messages_vocaux'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

select pg_notify('pgrst', 'reload schema');

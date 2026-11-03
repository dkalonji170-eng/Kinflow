-- KinFlow — Correctif : le téléversement des photos échoue.
--
-- Cause : le bucket privé `messages_images` n'existe pas sur le projet
-- Supabase (l'API Storage répond « Bucket not found » / NoSuchBucket).
-- Les autres migrations ont bien été appliquées, mais celle des photos
-- (`20261030000000_messages_images.sql`) ne l'a pas été (ou seulement en
-- partie). La fonction `public.puis_voir_image` manque aussi.
--
-- À exécuter dans Supabase > SQL Editor, en une seule fois.
-- Idempotent : on peut le relancer sans risque.
--
-- ⚠️ NE PAS relancer `20261030000000_messages_images.sql` en entier : il
-- redéfinit `envoyer_message_ami` SANS `p_reply_to_message_id` et casserait
-- les réponses aux messages. Ce script ne touche pas à cette fonction.

begin;

-- 1) Bucket privé des photos ------------------------------------------------
insert into storage.buckets (id, name, public)
values ('messages_images', 'messages_images', false)
on conflict (id) do update set public = false;

-- 2) Une photo n'est visible que par les deux personnes de la conversation --
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

-- 3) Politiques Storage (mêmes règles que les vocaux) -----------------------
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

-- 4) Recharge du cache de schéma PostgREST ----------------------------------
select pg_notify('pgrst', 'reload schema');

commit;

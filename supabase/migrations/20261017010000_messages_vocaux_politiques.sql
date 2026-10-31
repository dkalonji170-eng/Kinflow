-- Messages vocaux : (re)crée le bucket privé et ses politiques d'accès.
--
-- Symptôme corrigé : l'expéditeur pouvait relire son vocal (lecture du fichier
-- local) mais le DESTINATAIRE recevait « Message vocal indisponible ». En
-- cause : la politique de LECTURE du bucket `messages_vocaux` ne couvrait pas
-- le destinataire, donc la création de l'URL signée échouait de son côté.
--
-- Ce script est idempotent : on peut le relancer sans risque.

-- 1) Bucket privé ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('messages_vocaux', 'messages_vocaux', false)
on conflict (id) do update set public = false;

-- 2) Un vocal n'est visible que par les deux personnes de la conversation -----
--    (l'expéditeur est le dossier 1, le destinataire le dossier 2). La fonction
--    ci-dessous vérifie en plus la table `messages_amis`, qui est verrouillée
--    par RLS : sans ce SECURITY DEFINER, la lecture directe serait refusée.
create or replace function public.puis_voir_vocal(p_chemin text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
      from public.messages_amis m
     where m.audio_chemin = p_chemin
       and (m.expediteur = auth.uid() or m.destinataire = auth.uid())
  );
$$;

grant execute on function public.puis_voir_vocal(text) to authenticated;

-- 3) Politiques Storage ------------------------------------------------------
drop policy if exists "messages_vocaux_insert" on storage.objects;
create policy "messages_vocaux_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'messages_vocaux'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

drop policy if exists "messages_vocaux_select" on storage.objects;
create policy "messages_vocaux_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'messages_vocaux'
    and (
      auth.uid()::text = (storage.foldername(name))[1]
      or auth.uid()::text = (storage.foldername(name))[2]
      or public.puis_voir_vocal(name)
    )
  );

select pg_notify('pgrst', 'reload schema');

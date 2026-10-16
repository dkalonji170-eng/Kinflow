-- Messages vocaux : colonnes, bucket privé et fonctions adaptées au partage d'audio.
alter table if exists public.messages_amis
  add column if not exists type_message text not null default 'texte',
  add column if not exists audio_chemin text,
  add column if not exists audio_duree_ms integer;

-- Bucket privé pour les messages vocaux.
insert into storage.buckets (id, name, public)
values ('messages_vocaux', 'messages_vocaux', false)
on conflict (id) do nothing;

-- Politiques Storage
drop policy if exists "messages_vocaux_insert" on storage.objects;
create policy "messages_vocaux_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'messages_vocaux'
    and auth.uid()::text = ((storage.foldername(name))[1])
  );

drop policy if exists "messages_vocaux_select" on storage.objects;
create policy "messages_vocaux_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'messages_vocaux'
    and auth.uid()::text in ((storage.foldername(name))[1], (storage.foldername(name))[2])
  );

-- Envoyer message texte ou vocal
drop function if exists public.envoyer_message_ami(uuid, text, text, integer);
drop function if exists public.envoyer_message_ami(uuid, text);
create or replace function public.envoyer_message_ami(
  p_ami_id uuid,
  p_contenu text,
  p_audio_chemin text default null,
  p_audio_duree_ms integer default null
)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ami boolean;
  v_type text := 'texte';
begin
  if v_uid is null then return 'non_connecte'; end if;
  if p_ami_id is null then return 'destinataire_invalide'; end if;
  if p_audio_chemin is not null and length(trim(p_audio_chemin)) > 0 then
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
  insert into public.messages_amis (expediteur, destinataire, contenu, type_message, audio_chemin, audio_duree_ms)
  values (v_uid, p_ami_id, coalesce(trim(p_contenu), ''), v_type,
          nullif(trim(coalesce(p_audio_chemin,'')), ''), p_audio_duree_ms);
  return 'envoye';
end;
$$;
grant execute on function public.envoyer_message_ami(uuid, text, text, integer) to anon, authenticated;

-- mes_messages_ami avec champs vocaux
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
    m.type_message, m.audio_chemin, m.audio_duree_ms
  from public.messages_amis m
  where m.cree_a >= now() - interval '7 days'
    and m.destinataire in (auth.uid(), p_ami_id)
    and m.expediteur in (auth.uid(), p_ami_id)
  order by m.cree_a asc
  limit 500
) t;
$kf$;
grant execute on function public.mes_messages_ami(uuid) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

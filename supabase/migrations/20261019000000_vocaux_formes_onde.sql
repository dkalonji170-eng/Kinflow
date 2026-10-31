-- Messages vocaux : forme d'onde (amplitude de la voix) enregistrée à l'envoi.
--
-- La bulle affichait une simple ligne plate, impossible à parcourir. On stocke
-- désormais une quarantaine de niveaux (0..100) relevés pendant
-- l'enregistrement : le destinataire redessine la même forme d'onde, avec les
-- barres déjà écoutées mises en évidence.
--
-- Rétrocompatible : `audio_formes` est facultatif. Les vocaux déjà envoyés
-- (valeur NULL) s'affichent avec une forme d'onde générée côté application.

alter table if exists public.messages_amis
  add column if not exists audio_formes jsonb;

comment on column public.messages_amis.audio_formes is
  'Forme d''onde du vocal : tableau JSON de niveaux 0..100, un par barre.';

-- envoyer_message_ami : nouveau paramètre facultatif p_audio_formes ------------
-- `create or replace` ne remplace PAS une fonction dont la liste d'arguments
-- change : il faut supprimer explicitement l'ancienne signature.
drop function if exists public.envoyer_message_ami(uuid, text, text, integer);

create or replace function public.envoyer_message_ami(
  p_ami_id uuid,
  p_contenu text,
  p_audio_chemin text default null,
  p_audio_duree_ms integer default null,
  p_audio_formes jsonb default null
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
  insert into public.messages_amis
    (expediteur, destinataire, contenu, type_message, audio_chemin, audio_duree_ms, audio_formes)
  values (v_uid, p_ami_id, coalesce(trim(p_contenu), ''), v_type,
          nullif(trim(coalesce(p_audio_chemin,'')), ''), p_audio_duree_ms,
          case
            when v_type = 'vocal' and jsonb_typeof(p_audio_formes) = 'array'
              then p_audio_formes
            else null
          end);
  return 'envoye';
end;
$$;
grant execute on function public.envoyer_message_ami(uuid, text, text, integer, jsonb)
  to anon, authenticated;

-- mes_messages_ami : on expose la forme d'onde au destinataire ----------------
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
    m.type_message, m.audio_chemin, m.audio_duree_ms, m.audio_formes
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

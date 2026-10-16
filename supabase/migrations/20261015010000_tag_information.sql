-- Taguage d'une information : au lieu d'envoyer le texte brut de l'info,
-- on crée un message système « tag » qui référence l'information d'origine.
-- - Celui qui tague voit « Vous avez tagué … »
-- - Celui qui est tagué voit « Vous avez été tagué … »
-- - Toucher le message ouvre l'information dans le fil.
--
-- On stocke donc l'identifiant de l'information sur la ligne de message.

alter table public.messages_amis
  add column if not exists info_id uuid references public.informations(id) on delete set null;

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
  if v_uid is null then
    return 'non_connecte';
  end if;
  if p_ami_id is null or p_info_id is null then
    return 'invalide';
  end if;
  select true into v_ami
  from public.amities a
  where a.statut = 'accepte'
    and ((a.demandeur = v_uid and a.destinataire = p_ami_id)
      or (a.demandeur = p_ami_id and a.destinataire = v_uid))
  limit 1;
  if v_ami is not true then
    return 'pas_ami';
  end if;
  select left(i.contenu, 160) into v_snippet
  from public.informations i
  where i.id = p_info_id;
  if v_snippet is null then
    return 'info_introuvable';
  end if;
  delete from public.messages_amis where cree_a < now() - interval '7 days';
  insert into public.messages_amis
    (expediteur, destinataire, contenu, est_systeme, type_systeme, info_id)
  values
    (v_uid, p_ami_id, v_snippet, true, 'tag_info', p_info_id);
  return 'envoye';
end;
$$;
grant execute on function public.taguer_information(uuid, uuid) to anon, authenticated;

-- La discussion renvoie aussi info_id (en plus des coordonnées).
drop function if exists public.mes_messages_ami(uuid);
create or replace function public.mes_messages_ami(p_ami_id uuid)
returns setof jsonb
language sql
security definer
set search_path = public
as $kf$
select to_jsonb(t) from (
  select
    m.id,
    m.expediteur,
    m.contenu,
    m.cree_a,
    (m.expediteur = auth.uid()) as moi,
    (m.recu_a is not null) as recu,
    m.lu,
    m.est_systeme,
    m.type_systeme,
    m.latitude,
    m.longitude,
    m.info_id
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

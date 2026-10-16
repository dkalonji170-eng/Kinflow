-- Messagerie privée entre amis : messages qui n'ont qu'une durée de VIE de
-- 7 jours. Comme les autres tables, elle est verrouillée par RLS (aucune
-- politique) et tout passe par des fonctions SECURITY DEFINER.
--
-- Les messages de plus de 7 jours ne sont JAMAIS renvoyés ; ils sont aussi
-- purgés à l'envoi pour ne pas gonfler la table.

create table if not exists public.messages_amis (
  id uuid primary key default gen_random_uuid(),
  expediteur uuid not null references public.profiles(id) on delete cascade,
  destinataire uuid not null references public.profiles(id) on delete cascade,
  contenu text not null,
  cree_a timestamptz not null default now(),
  lu boolean not null default false
);

create index if not exists messages_amis_destinataire_idx
  on public.messages_amis (destinataire, cree_a desc);

create index if not exists messages_amis_conversation_idx
  on public.messages_amis (expediteur, destinataire, cree_a);

alter table public.messages_amis enable row level security;

-- 1) Envoyer un message à un ami (amis confirmés uniquement) -----------------
drop function if exists public.envoyer_message_ami(uuid, text);
create or replace function public.envoyer_message_ami(
  p_ami_id uuid,
  p_contenu text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_ami boolean;
begin
  if v_uid is null then
    return 'non_connecte';
  end if;
  if p_ami_id is null then
    return 'destinataire_invalide';
  end if;
  if p_contenu is null or length(trim(p_contenu)) = 0 then
    return 'contenu_vide';
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

  -- Purge opportuniste : on ne garde jamais plus de 7 jours de messages.
  delete from public.messages_amis where cree_a < now() - interval '7 days';

  insert into public.messages_amis (expediteur, destinataire, contenu)
  values (v_uid, p_ami_id, trim(p_contenu));

  return 'envoye';
end;
$$;

grant execute on function public.envoyer_message_ami(uuid, text)
  to anon, authenticated;

-- 2) La discussion avec un ami (7 derniers jours, du plus ancien au plus récent)
drop function if exists public.mes_messages_ami(uuid);
create or replace function public.mes_messages_ami(p_ami_id uuid)
returns setof jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', m.id,
    'expediteur', m.expediteur,
    'contenu', m.contenu,
    'cree_a', m.cree_a,
    'moi', (m.expediteur = auth.uid())
  )
  from public.messages_amis m
  where m.cree_a >= now() - interval '7 days'
    and ((m.expediteur = auth.uid() and m.destinataire = p_ami_id)
      or (m.expediteur = p_ami_id and m.destinataire = auth.uid()))
  order by m.cree_a asc
  limit 500;
$$;

grant execute on function public.mes_messages_ami(uuid) to anon, authenticated;

-- 3) Marquer comme lus les messages reçus d'un ami ---------------------------
drop function if exists public.marquer_messages_lus(uuid);
create or replace function public.marquer_messages_lus(p_ami_id uuid)
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
  update public.messages_amis
     set lu = true
   where destinataire = v_uid and expediteur = p_ami_id and lu = false;
  return true;
end;
$$;

grant execute on function public.marquer_messages_lus(uuid)
  to anon, authenticated;

-- 4) Nombre de messages non lus, par ami ------------------------------------
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
  group by m.expediteur;
$$;

grant execute on function public.nb_messages_non_lus_amis()
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

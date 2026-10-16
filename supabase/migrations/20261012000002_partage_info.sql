-- Partage d'une information KinFlow à un ami(e) : boîte de réception interne.
-- Comme les autres tables, elle est verrouillée par RLS (aucune politique) :
-- tout passe par des fonctions SECURITY DEFINER, l'identité vient de
-- auth.uid(). On stocke un INSTANTANÉ du contenu (texte + lien) : l'info
-- reçue reste lisible même si l'information d'origine est supprimée.

create table if not exists public.partages_info (
  id uuid primary key default gen_random_uuid(),
  expediteur uuid not null references public.profiles(id) on delete cascade,
  destinataire uuid not null references public.profiles(id) on delete cascade,
  information_id uuid,
  contenu text not null,
  source_url text,
  cree_a timestamptz not null default now(),
  lu boolean not null default false
);

create index if not exists partages_info_destinataire_idx
  on public.partages_info (destinataire, cree_a desc);

alter table public.partages_info enable row level security;

-- 1) Envoyer une information à un ami (réservé aux amis confirmés) -----------
drop function if exists public.envoyer_info_ami(uuid, text, text, uuid);
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
  if v_uid is null then
    return 'non_connecte';
  end if;
  if p_ami_id is null then
    return 'destinataire_invalide';
  end if;
  if p_contenu is null or length(trim(p_contenu)) = 0 then
    return 'contenu_vide';
  end if;
  v_contenu := trim(p_contenu);

  v_url := null;
  if p_source_url is not null and length(trim(p_source_url)) > 0 then
    v_url := trim(p_source_url);
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

  insert into public.partages_info
    (expediteur, destinataire, information_id, contenu, source_url)
  values
    (v_uid, p_ami_id, p_information_id, v_contenu, v_url);

  return 'envoye';
end;
$$;

grant execute on function public.envoyer_info_ami(uuid, text, text, uuid)
  to anon, authenticated;

-- 2) Mes informations reçues (les plus récentes d'abord) ---------------------
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
  order by pa.cree_a desc
  limit 200;
$$;

grant execute on function public.mes_infos_recues() to anon, authenticated;

-- 3) Marquer mes informations reçues comme lues ------------------------------
drop function if exists public.marquer_infos_recues_vues();
create or replace function public.marquer_infos_recues_vues()
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
  update public.partages_info
     set lu = true
   where destinataire = v_uid and lu = false;
  return true;
end;
$$;

grant execute on function public.marquer_infos_recues_vues()
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

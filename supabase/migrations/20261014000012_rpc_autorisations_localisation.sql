-- RPC pour gérer autorisations + localisations avec messages système

-- Définir/retirer autorisation : moi autorise cet ami à ME localiser simplement ?
create or replace function public.definir_autorisation_loc_simple(
  p_ami_id uuid,
  p_autoriser boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_a public.amities%rowtype;
begin
  if v_uid is null or p_ami_id is null then
    return false;
  end if;
  select * into v_a
  from public.amities
  where statut = 'accepte'
    and ((demandeur = v_uid and destinataire = p_ami_id)
      or (demandeur = p_ami_id and destinataire = v_uid))
  limit 1;
  if v_a.id is null then
    return false;
  end if;
  if v_a.demandeur = v_uid then
    -- je suis demandeur : j'autorise destinataire (p_ami_id) à me localiser
    update public.amities
       set a1_autorise_a2_loc_simple = coalesce(p_autoriser, false),
           a2_autorise_a1_loc_simple = a2_autorise_a1_loc_simple  -- inchangé
     where id = v_a.id;
  else
    -- je suis destinataire
    update public.amities
       set a2_autorise_a1_loc_simple = coalesce(p_autoriser, false)
     where id = v_a.id;
  end if;
  return true;
end;
$$;
grant execute on function public.definir_autorisation_loc_simple(uuid, boolean) to anon, authenticated;

-- Renouveler urgence : moi autorise cet ami à ME localiser en urgence 1 fois
create or replace function public.renouveler_urgence(
  p_ami_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_a public.amities%rowtype;
begin
  if v_uid is null or p_ami_id is null then
    return false;
  end if;
  select * into v_a
  from public.amities
  where statut = 'accepte'
    and ((demandeur = v_uid and destinataire = p_ami_id)
      or (demandeur = p_ami_id and destinataire = v_uid))
  limit 1;
  if v_a.id is null then
    return false;
  end if;
  if v_a.demandeur = v_uid then
    -- je suis demandeur : je renouvelle pour que destinataire (p_ami_id) puisse me localiser en urgence
    update public.amities
       set a2_urgence_sur_a1 = true
     where id = v_a.id;
  else
    -- je suis destinataire
    update public.amities
       set a1_urgence_sur_a2 = true
     where id = v_a.id;
  end if;
  return true;
end;
$$;
grant execute on function public.renouveler_urgence(uuid) to anon, authenticated;

-- État des autorisations entre moi et p_ami_id
create or replace function public.etat_autorisations_localisation(
  p_ami_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_a public.amities%rowtype;
  res jsonb := jsonb_build_object('ok', false);
begin
  if v_uid is null or p_ami_id is null then
    return res;
  end if;
  select * into v_a
  from public.amities
  where statut = 'accepte'
    and ((demandeur = v_uid and destinataire = p_ami_id)
      or (demandeur = p_ami_id and destinataire = v_uid))
  limit 1;
  if v_a.id is null then
    return res;
  end if;
  if v_a.demandeur = v_uid then
    -- moi demandeur, ami destinataire
    res := jsonb_build_object(
      'ok', true,
      'moi_demandeur', true,
      'ami_autorise_moi_loc_simple', v_a.a2_autorise_a1_loc_simple,  -- ami autorise moi ?
      'moi_autorise_ami_loc_simple', v_a.a1_autorise_a2_loc_simple,  -- moi autorise ami ?
      'urgence_dispo_pour_moi_localiser_ami', v_a.a1_urgence_sur_a2,
      'urgence_dispo_pour_ami_localiser_moi', v_a.a2_urgence_sur_a1
    );
  else
    -- moi destinataire, ami demandeur
    res := jsonb_build_object(
      'ok', true,
      'moi_demandeur', false,
      'ami_autorise_moi_loc_simple', v_a.a1_autorise_a2_loc_simple,
      'moi_autorise_ami_loc_simple', v_a.a2_autorise_a1_loc_simple,
      'urgence_dispo_pour_moi_localiser_ami', v_a.a2_urgence_sur_a1,
      'urgence_dispo_pour_ami_localiser_moi', v_a.a1_urgence_sur_a2
    );
  end if;
  return res;
end;
$$;
grant execute on function public.etat_autorisations_localisation(uuid) to anon, authenticated;

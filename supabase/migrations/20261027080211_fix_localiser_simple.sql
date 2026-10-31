-- Corrige localiser_simple : autoriser la dernière position connue même si le partage est inactif
-- (comportement identique à localiser_urgence). L'autorisation entre amis reste requise.
create or replace function public.localiser_simple(
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
  v_pos public.positions_amis%rowtype;
  v_ami_nom text;
  v_heure text := to_char(now() at time zone 'Europe/Paris', 'HH24:MI');
  v_contenu text;
begin
  if v_uid is null or p_ami_id is null then
    return jsonb_build_object('ok', false, 'erreur', 'non_connecte');
  end if;
  select * into v_a
  from public.amities
  where statut = 'accepte'
    and ((demandeur = v_uid and destinataire = p_ami_id)
      or (demandeur = p_ami_id and destinataire = v_uid))
  limit 1;
  if v_a.id is null then
    return jsonb_build_object('ok', false, 'erreur', 'pas_ami');
  end if;
  -- vérifier autorisation : l'ami doit m'autoriser à le localiser simplement ?
  if v_a.demandeur = v_uid then
    if not coalesce(v_a.a2_autorise_a1_loc_simple, false) then
      return jsonb_build_object('ok', false, 'erreur', 'non_autorise');
    end if;
  else
    if not coalesce(v_a.a1_autorise_a2_loc_simple, false) then
      return jsonb_build_object('ok', false, 'erreur', 'non_autorise');
    end if;
  end if;
  -- récupérer position de l'ami ciblé (dernière position connue)
  select * into v_pos
  from public.positions_amis
  where user_id = p_ami_id and partage_actif = true
  limit 1;
  if v_pos.id is null then
    select * into v_pos
    from public.positions_amis
    where user_id = p_ami_id
    limit 1;
  end if;
  if v_pos.latitude is null or v_pos.longitude is null then
    return jsonb_build_object('ok', false, 'erreur', 'pas_de_position');
  end if;
  -- nom expediteur (moi)
  select coalesce(p.prenom, 'Quelqu''un') into v_ami_nom
  from public.profiles p where p.id = v_uid limit 1;
  v_contenu := v_ami_nom || ' t''a localisé à ' || v_heure || '. Position prise à partir de la dernière position connue.';
  delete from public.messages_amis where cree_a < now() - interval '7 days';
  insert into public.messages_amis
    (expediteur, destinataire, contenu, est_systeme, type_systeme, latitude, longitude)
  values
    (v_uid, p_ami_id, v_contenu, true, 'loc_simple', v_pos.latitude, v_pos.longitude);
  return jsonb_build_object(
    'ok', true,
    'latitude', v_pos.latitude,
    'longitude', v_pos.longitude,
    'cap', v_pos.cap,
    'maj_a', v_pos.maj_a,
    'message', v_contenu
  );
end;
$$;
grant execute on function public.localiser_simple(uuid) to anon, authenticated;

-- Système de rangs selon le nombre de signalements routiers
-- Calcule le niveau, le nom du rang, la progression vers le prochain niveau

-- Compte le nombre total de signalements d'un utilisateur
create or replace function public.compter_signalements_utilisateur(p_user_id uuid default auth.uid())
returns bigint
language sql
security definer
set search_path = public
as $$
  select count(*)
  from public.signalements
  where user_id = coalesce(p_user_id, auth.uid());
$$;

grant execute on function public.compter_signalements_utilisateur(uuid) to anon, authenticated;

-- Récupère le rang complet de l'utilisateur connecté
create or replace function public.mon_rang_signalements()
returns table (
  nb_signalements bigint,
  niveau integer,
  rang_nom text,
  rang_couleur text,
  rang_icone text,
  prochain_seuil bigint,
  reste_pour_prochain bigint,
  progression numeric,
  est_max boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_nb bigint;
begin
  if v_user_id is null then
    return query select 0::bigint, 1, 'Débutant', '#9E9E9E', 'shield', 1::bigint, 1::bigint, 0::numeric, false;
    return;
  end if;

  select coalesce(count(*), 0) into v_nb
  from public.signalements
  where user_id = v_user_id;

  -- Débutant (0)
  if v_nb < 1 then
    return query select v_nb, 1, 'Débutant', '#9E9E9E', 'shield', 1::bigint, 1::bigint, 0::numeric, false;
  -- Apprenti (1-4)
  elsif v_nb < 5 then
    return query select v_nb, 2, 'Apprenti', '#8D6E63', 'shield_outlined', 5::bigint, (5 - v_nb)::bigint, round((v_nb::numeric / 5::numeric) * 100, 0), false;
  -- Contributeur (5-9)
  elsif v_nb < 10 then
    return query select v_nb, 3, 'Contributeur', '#4CAF50', 'verified_user', 10::bigint, (10 - v_nb)::bigint, round((v_nb::numeric / 10::numeric) * 100, 0), false;
  -- Vigilant (10-24)
  elsif v_nb < 25 then
    return query select v_nb, 4, 'Vigilant', '#2196F3', 'visibility', 25::bigint, (25 - v_nb)::bigint, round((v_nb::numeric / 25::numeric) * 100, 0), false;
  -- Sentinelle (25-49)
  elsif v_nb < 50 then
    return query select v_nb, 5, 'Sentinelle', '#00BCD4', 'radar', 50::bigint, (50 - v_nb)::bigint, round((v_nb::numeric / 50::numeric) * 100, 0), false;
  -- Gardien (50-99)
  elsif v_nb < 100 then
    return query select v_nb, 6, 'Gardien', '#FF9800', 'security', 100::bigint, (100 - v_nb)::bigint, round((v_nb::numeric / 100::numeric) * 100, 0), false;
  -- Expert (100-249)
  elsif v_nb < 250 then
    return query select v_nb, 7, 'Expert', '#9C27B0', 'military_tech', 250::bigint, (250 - v_nb)::bigint, round((v_nb::numeric / 250::numeric) * 100, 0), false;
  -- Légende (>=250)
  else
    return query select v_nb, 8, 'Légende', '#FFD700', 'emoji_events', 0::bigint, 0::bigint, 100::numeric, true;
  end if;
end;
$$;

grant execute on function public.mon_rang_signalements() to anon, authenticated;

-- Récupère le rang d'un autre utilisateur
create or replace function public.rang_signalements_utilisateur(p_user_id uuid)
returns table (
  nb_signalements bigint,
  niveau integer,
  rang_nom text,
  rang_couleur text,
  rang_icone text,
  prochain_seuil bigint,
  reste_pour_prochain bigint,
  progression numeric,
  est_max boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nb bigint;
begin
  if p_user_id is null then
    return query select 0::bigint, 1, 'Débutant', '#9E9E9E', 'shield', 1::bigint, 1::bigint, 0::numeric, false;
    return;
  end if;

  select coalesce(count(*), 0) into v_nb
  from public.signalements
  where user_id = p_user_id;

  if v_nb < 1 then
    return query select v_nb, 1, 'Débutant', '#9E9E9E', 'shield', 1::bigint, 1::bigint, 0::numeric, false;
  elsif v_nb < 5 then
    return query select v_nb, 2, 'Apprenti', '#8D6E63', 'shield_outlined', 5::bigint, (5 - v_nb)::bigint, round((v_nb::numeric / 5::numeric) * 100, 0), false;
  elsif v_nb < 10 then
    return query select v_nb, 3, 'Contributeur', '#4CAF50', 'verified_user', 10::bigint, (10 - v_nb)::bigint, round((v_nb::numeric / 10::numeric) * 100, 0), false;
  elsif v_nb < 25 then
    return query select v_nb, 4, 'Vigilant', '#2196F3', 'visibility', 25::bigint, (25 - v_nb)::bigint, round((v_nb::numeric / 25::numeric) * 100, 0), false;
  elsif v_nb < 50 then
    return query select v_nb, 5, 'Sentinelle', '#00BCD4', 'radar', 50::bigint, (50 - v_nb)::bigint, round((v_nb::numeric / 50::numeric) * 100, 0), false;
  elsif v_nb < 100 then
    return query select v_nb, 6, 'Gardien', '#FF9800', 'security', 100::bigint, (100 - v_nb)::bigint, round((v_nb::numeric / 100::numeric) * 100, 0), false;
  elsif v_nb < 250 then
    return query select v_nb, 7, 'Expert', '#9C27B0', 'military_tech', 250::bigint, (250 - v_nb)::bigint, round((v_nb::numeric / 250::numeric) * 100, 0), false;
  else
    return query select v_nb, 8, 'Légende', '#FFD700', 'emoji_events', 0::bigint, 0::bigint, 100::numeric, true;
  end if;
end;
$$;

grant execute on function public.rang_signalements_utilisateur(uuid) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

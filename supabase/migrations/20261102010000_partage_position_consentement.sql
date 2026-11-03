-- Point 8 — Partage de position : consentement explicite, durée limitée et
-- arrêt réel côté serveur.
--
-- Avant ce correctif :
--   * l'app activait le partage automatiquement au démarrage ;
--   * `publier_ma_position` créait une ligne active même sans consentement ;
--   * `definir_partage_position(false)` laissait les dernières coordonnées ;
--   * `mes_amis()` renvoyait une position vieille de plusieurs jours.
--
-- Maintenant :
--   * aucune position n'est publiée sans ligne active non expirée ;
--   * l'utilisateur choisit une durée (ou « jusqu'à désactivation ») ;
--   * la désactivation efface immédiatement latitude/longitude/cap ;
--   * une position n'est visible que si elle a moins de 60 minutes.

alter table if exists public.positions_amis
  add column if not exists expire_a timestamptz;

comment on column public.positions_amis.expire_a is
  'Fin du consentement de partage. NULL = partage sans date de fin, mais les coordonnées restent soumises au TTL de 60 min dans mes_amis().';

-- 1) Publier ma position : uniquement sur une autorisation déjà active -------
drop function if exists public.publier_ma_position(double precision, double precision, double precision);
create or replace function public.publier_ma_position(
  p_latitude double precision,
  p_longitude double precision,
  p_cap double precision default null
)
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

  -- Une autorisation expirée est révoquée avant toute publication.
  update public.positions_amis
     set partage_actif = false,
         latitude = null,
         longitude = null,
         cap = null,
         maj_a = null,
         expire_a = null
   where user_id = v_uid
     and expire_a is not null
     and expire_a <= now();

  -- Aucun INSERT : sans consentement préalable, on ne crée jamais de position.
  update public.positions_amis
     set latitude = p_latitude,
         longitude = p_longitude,
         cap = p_cap,
         maj_a = now()
   where user_id = v_uid
     and partage_actif = true
     and (expire_a is null or expire_a > now());

  return found;
end;
$$;

grant execute on function public.publier_ma_position(double precision, double precision, double precision)
  to anon, authenticated;

-- 2) Activer / désactiver, avec une durée facultative ------------------------
drop function if exists public.definir_partage_position(boolean);
drop function if exists public.definir_partage_position(boolean, integer);
create or replace function public.definir_partage_position(
  p_actif boolean,
  p_duree_minutes integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_actif boolean := coalesce(p_actif, false);
  v_duree integer := p_duree_minutes;
begin
  if v_uid is null then
    return false;
  end if;

  if v_actif and v_duree is not null and v_duree <= 0 then
    v_duree := null;
  end if;

  insert into public.positions_amis (
    user_id, latitude, longitude, cap, partage_actif, maj_a, expire_a
  )
  values (
    v_uid,
    null,
    null,
    null,
    v_actif,
    case when v_actif then now() else null end,
    case
      when v_actif and v_duree is not null
        then now() + make_interval(mins => v_duree)
      else null
    end
  )
  on conflict (user_id) do update set
    partage_actif = v_actif,
    maj_a = case when v_actif then now() else null end,
    expire_a = case
      when v_actif and v_duree is not null
        then now() + make_interval(mins => v_duree)
      else null
    end,
    -- Désactivation = effacement immédiat des coordonnées.
    latitude = case when v_actif then positions_amis.latitude else null end,
    longitude = case when v_actif then positions_amis.longitude else null end,
    cap = case when v_actif then positions_amis.cap else null end;

  return true;
end;
$$;

grant execute on function public.definir_partage_position(boolean, integer)
  to anon, authenticated;

-- 3) Mon partage est-il réellement actif ? -----------------------------------
drop function if exists public.mon_partage_position();
create or replace function public.mon_partage_position()
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce((
    select pos.partage_actif
       and (pos.expire_a is null or pos.expire_a > now())
    from public.positions_amis pos
    where pos.user_id = auth.uid()
  ), false);
$$;

grant execute on function public.mon_partage_position() to anon, authenticated;

-- 4) Détail pour l'écran de consentement -------------------------------------
create or replace function public.mon_partage_position_details()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'actif', coalesce(pos.partage_actif, false)
      and (pos.expire_a is null or pos.expire_a > now()),
    'expire_a', pos.expire_a
  )
  from public.positions_amis pos
  where pos.user_id = auth.uid()
  union all
  select jsonb_build_object('actif', false, 'expire_a', null)
  where not exists (
    select 1 from public.positions_amis pos where pos.user_id = auth.uid()
  )
  limit 1;
$$;

grant execute on function public.mon_partage_position_details()
  to anon, authenticated;

-- 5) Mes amis : TTL de 60 minutes et exclusion des comptes bloqués -----------
drop function if exists public.mes_amis();
create or replace function public.mes_amis()
returns table (
  ami_id uuid,
  prenom text,
  nom text,
  avatar text,
  latitude double precision,
  longitude double precision,
  cap double precision,
  maj_a timestamptz,
  partage_actif boolean,
  partage_expire_a timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    p.id as ami_id,
    p.prenom,
    p.nom,
    p.avatar,
    case when pos.partage_actif
              and pos.maj_a > now() - interval '60 minutes'
              and (pos.expire_a is null or pos.expire_a > now())
         then pos.latitude end as latitude,
    case when pos.partage_actif
              and pos.maj_a > now() - interval '60 minutes'
              and (pos.expire_a is null or pos.expire_a > now())
         then pos.longitude end as longitude,
    case when pos.partage_actif
              and pos.maj_a > now() - interval '60 minutes'
              and (pos.expire_a is null or pos.expire_a > now())
         then pos.cap end as cap,
    pos.maj_a,
    coalesce(
      pos.partage_actif
        and pos.maj_a > now() - interval '60 minutes'
        and (pos.expire_a is null or pos.expire_a > now()),
      false
    ) as partage_actif,
    pos.expire_a as partage_expire_a
  from public.amities a
  join public.profiles p
    on p.id = case when a.demandeur = auth.uid()
                   then a.destinataire else a.demandeur end
  left join public.positions_amis pos on pos.user_id = p.id
  where a.statut = 'accepte'
    and (a.demandeur = auth.uid() or a.destinataire = auth.uid())
    and not exists (
      select 1 from public.blocages b
       where (b.bloqueur = auth.uid() and b.bloque = p.id)
          or (b.bloqueur = p.id and b.bloque = auth.uid())
    )
  order by coalesce(p.prenom, ''), coalesce(p.nom, '');
$$;

grant execute on function public.mes_amis() to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

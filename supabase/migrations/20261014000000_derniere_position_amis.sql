-- Dernière position connue d'un(e) ami(e), même hors ligne.
--
-- Avant : `mes_amis()` ne renvoyait latitude/longitude/cap que si le partage
-- était actif ET la position vieille de moins de 15 minutes. Passé ce délai
-- (téléphone éteint, appli fermée, simple pause), l'ami(e) disparaissait de la
-- carte.
--
-- Maintenant : dès que le partage est actif, on renvoie la DERNIÈRE position
-- enregistrée, quelle que soit son ancienneté. L'appli affiche l'âge de cette
-- position (« il y a 15 minutes », « il y a 2 jours », « il y a 1 an »).
-- Si le partage est explicitement désactivé (partage_actif = false), on ne
-- renvoie toujours rien : couper le partage cache la position.
--
-- Applique ce fichier dans le SQL Editor Supabase (ou via `supabase db push`).

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
  partage_actif boolean
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
    case when pos.partage_actif then pos.latitude end as latitude,
    case when pos.partage_actif then pos.longitude end as longitude,
    case when pos.partage_actif then pos.cap end as cap,
    pos.maj_a,
    coalesce(pos.partage_actif, false) as partage_actif
  from public.amities a
  join public.profiles p
    on p.id = case when a.demandeur = auth.uid()
                   then a.destinataire else a.demandeur end
  left join public.positions_amis pos on pos.user_id = p.id
  where a.statut = 'accepte'
    and (a.demandeur = auth.uid() or a.destinataire = auth.uid())
  order by coalesce(p.prenom, ''), coalesce(p.nom, '');
$$;

grant execute on function public.mes_amis() to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

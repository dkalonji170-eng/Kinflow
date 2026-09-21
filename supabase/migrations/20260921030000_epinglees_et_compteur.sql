-- Améliorations du Fil Social : infos épinglées + compteur pour le badge
-- de l'accueil.
--
-- 1) Une info peut être épinglée par l'équipe KinFlow (Table Editor) : elle
--    reste en haut du fil, même si elle a plus de 48 h, et le robot ne la
--    supprime pas.
alter table public.informations
  add column if not exists epinglee boolean not null default false;

-- 2) Compteur « combien d'infos depuis telle date ? » : sert au petit badge
--    rouge sur le bouton Social de l'accueil.
drop function if exists public.compter_infos_recentes(timestamptz);
create or replace function public.compter_infos_recentes(p_depuis timestamptz)
returns bigint
language sql
security definer
set search_path = public
as $$
  select count(*)::bigint
  from public.informations
  where p_depuis is null or cree_a > p_depuis;
$$;

grant execute on function public.compter_infos_recentes(timestamptz)
  to anon, authenticated;

-- 3) Nouvelle version du fil : les épinglées d'abord (et toujours visibles),
--    puis les plus récentes.
drop function if exists public.fil_informations();
create or replace function public.fil_informations()
returns table (
  id uuid,
  contenu text,
  latitude double precision,
  longitude double precision,
  nb_verts bigint,
  nb_rouges bigint,
  ma_reaction text,
  emojis jsonb,
  mes_emojis text[],
  epinglee boolean,
  cree_a timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    i.id,
    i.contenu,
    i.latitude,
    i.longitude,
    count(r.information_id) filter (where r.sens = 'VERT')::bigint as nb_verts,
    count(r.information_id) filter (where r.sens = 'ROUGE')::bigint as nb_rouges,
    (select r2.sens from public.reactions r2
      where r2.information_id = i.id and r2.user_id = auth.uid()) as ma_reaction,
    coalesce((
      select jsonb_agg(jsonb_build_object('e', e.emoji, 'c', e.nb))
      from (
        select e.emoji, count(*)::int as nb
        from public.reactions_emoji e
        where e.information_id = i.id
        group by e.emoji
      ) e
    ), '[]'::jsonb) as emojis,
    coalesce((
      select array_agg(e.emoji)
      from public.reactions_emoji e
      where e.information_id = i.id and e.user_id = auth.uid()
    ), '{}'::text[]) as mes_emojis,
    i.epinglee,
    i.cree_a
  from public.informations i
  left join public.reactions r on r.information_id = i.id
  where i.cree_a >= now() - interval '48 hours' or i.epinglee
  group by i.id, i.contenu, i.latitude, i.longitude, i.epinglee, i.cree_a
  order by i.epinglee desc, i.cree_a desc;
$$;

grant execute on function public.fil_informations() to anon, authenticated;

-- 4) Recyclage : le robot supprime les infos de plus de 3 jours, sauf les
--    épinglées (qui restent tant que l'équipe ne les décroche pas).
drop function if exists public.nettoyer_anciennes_infos(text);
create or replace function public.nettoyer_anciennes_infos(p_cle text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendu text;
  v_nb      integer;
begin
  select valeur into v_attendu
  from public.parametres_secrets
  where cle = 'cle_import_rss';
  if v_attendu is null or p_cle <> v_attendu then
    return 0;
  end if;

  delete from public.informations
  where cree_a < now() - interval '3 days'
    and not epinglee;

  get diagnostics v_nb = row_count;
  return v_nb;
end;
$$;

grant execute on function public.nettoyer_anciennes_infos(text)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');
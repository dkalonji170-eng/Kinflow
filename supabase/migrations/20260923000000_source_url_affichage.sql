-- Fil Social : chaque information affiche un lien cliquable « Plus
-- d'informations » vers l'article d'origine.
--
-- Le robot RSS stocke déjà l'URL source de chaque info (source_url, migration
-- 20260921010000) mais le fil ne la renvoyait pas : elle ne servait qu'au
-- dédoublonnage. On l'expose désormais dans fil_informations() pour que
-- l'app puisse ouvrir l'article. Les infos publiées manuellement sans URL
-- ont source_url NULL : l'app n'affiche alors aucun lien.

drop function if exists public.fil_informations();
create or replace function public.fil_informations()
returns table (
  id uuid,
  contenu text,
  source_url text,
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
    i.source_url,
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
  group by i.id, i.contenu, i.source_url, i.latitude, i.longitude,
           i.epinglee, i.cree_a
  order by i.epinglee desc, i.cree_a desc;
$$;

grant execute on function public.fil_informations() to anon, authenticated;

select pg_notify('pgrst', 'reload schema');
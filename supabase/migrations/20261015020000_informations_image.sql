-- Fil Social : chaque information peut afficher l'image de l'article
-- d'origine, au-dessus du texte (comme un aperçu de lien).
--
-- L'image est récupérée par le robot RSS (media:content / enclosure du flux,
-- sinon la balise og:image de la page) et stockée ici. Les infos publiées
-- manuellement sans image, ou les anciennes, restent en texte seul.

alter table public.informations
  add column if not exists image_url text;

-- Le fil renvoie désormais l'image.
drop function if exists public.fil_informations();
create or replace function public.fil_informations()
returns table (
  id uuid,
  contenu text,
  source_url text,
  image_url text,
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
    i.image_url,
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
  group by i.id, i.contenu, i.source_url, i.image_url, i.latitude, i.longitude,
           i.epinglee, i.cree_a
  order by i.epinglee desc, i.cree_a desc;
$$;

grant execute on function public.fil_informations() to anon, authenticated;

-- Le robot transmet maintenant l'image de l'article (p_image, optionnel).
drop function if exists public.publier_infos_rss(text, text, text);
create or replace function public.publier_infos_rss(
  p_contenu text,
  p_url text,
  p_cle text,
  p_image text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attendu text;
  v_propre  text := trim(p_contenu);
  v_image   text := nullif(trim(coalesce(p_image, '')), '');
begin
  if p_cle is null or p_contenu is null then
    return false;
  end if;

  -- Une info automatique a toujours une URL d'origine : indispensable au
  -- dédoublonnage (une info sans URL pourrait se dupliquer).
  if p_url is null or trim(p_url) = '' then
    return false;
  end if;

  select valeur into v_attendu
  from public.parametres_secrets
  where cle = 'cle_import_rss';
  if v_attendu is null or p_cle <> v_attendu then
    return false;
  end if;

  if char_length(v_propre) < 20 or char_length(v_propre) > 500 then
    return false;
  end if;

  -- On n'accepte qu'une URL d'image http(s) de taille raisonnable.
  if v_image is not null
     and (char_length(v_image) > 800 or v_image !~* '^https?://') then
    v_image := null;
  end if;

  insert into public.informations (contenu, source_url, image_url)
  values (v_propre, trim(p_url), v_image)
  on conflict (source_url) do nothing;

  return found;
end;
$$;

grant execute on function public.publier_infos_rss(text, text, text, text)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

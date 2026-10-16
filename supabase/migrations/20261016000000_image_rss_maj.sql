-- Fil Social : les articles déjà publiés doivent GAGNER leur image.
--
-- Avant : `on conflict (source_url) do nothing` → une info insérée sans
-- image la gardait vide pour toujours (impossible de la compléter au passage
-- suivant du robot). C'est la raison pour laquelle le fil affichait des
-- actus sans visuel même après l'ajout de `image_url`.
--
-- Maintenant : au conflit, on complète l'image manquante (on n'écrase jamais
-- une image déjà présente).

drop function if exists public.publier_infos_rss(text, text, text, text);
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
  on conflict (source_url) do update
    set image_url = excluded.image_url
    where public.informations.image_url is null
      and excluded.image_url is not null;

  return found;
end;
$$;

grant execute on function public.publier_infos_rss(text, text, text, text)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

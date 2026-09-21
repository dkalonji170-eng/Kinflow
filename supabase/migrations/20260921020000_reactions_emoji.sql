-- Réactions émoji sur les informations du Fil Social, en complément des
-- pouces VERT/ROUGE. Les émojis les plus populaires de chaque post sont
-- affichés en premier (top 4), et le visiteur peut en choisir d'autres.
--
-- À appliquer après les migrations des informations et de l'import RSS.

-- 1) Table des réactions émoji : une personne pose chaque émoji au plus une
--    fois par information.
create table if not exists public.reactions_emoji (
  information_id uuid not null references public.informations(id) on delete cascade,
  user_id uuid not null,
  emoji text not null check (char_length(emoji) between 1 and 16),
  cree_a timestamptz not null default now(),
  primary key (information_id, user_id, emoji)
);

-- Verrouillée : personne ne lit/écrit directement via l'API, tout passe par
-- les fonctions SECURITY DEFINER.
alter table public.reactions_emoji enable row level security;

-- 2) Nouvelle version du fil : il renvoie aussi les émojis comptés par post
--    (tous, triés par la suite côté app) et les émojis du visiteur.
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
    i.cree_a
  from public.informations i
  left join public.reactions r on r.information_id = i.id
  where i.cree_a >= now() - interval '48 hours'
  group by i.id, i.contenu, i.latitude, i.longitude, i.cree_a
  order by i.cree_a desc;
$$;

grant execute on function public.fil_informations() to anon, authenticated;

-- 3) Poser/retirer un émoji : bascule (le même émoji retapé est retiré).
drop function if exists public.reagir_emoji(uuid, text);
create or replace function public.reagir_emoji(p_id uuid, p_emoji text)
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
  if p_emoji is null or char_length(p_emoji) > 16 then
    return false;
  end if;
  if not exists (select 1 from public.informations where id = p_id) then
    return false;
  end if;

  if exists (
    select 1 from public.reactions_emoji
    where information_id = p_id and user_id = v_uid and emoji = p_emoji
  ) then
    delete from public.reactions_emoji
    where information_id = p_id and user_id = v_uid and emoji = p_emoji;
    return true;
  end if;

  insert into public.reactions_emoji (information_id, user_id, emoji)
  values (p_id, v_uid, p_emoji)
  on conflict (information_id, user_id, emoji) do nothing;

  return true;
end;
$$;

grant execute on function public.reagir_emoji(uuid, text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');
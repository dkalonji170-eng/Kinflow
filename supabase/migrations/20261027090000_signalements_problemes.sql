-- Signalements de problèmes (mur collaboratif)
create table if not exists public.signalements_problemes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  type text not null,
  description text not null,
  cree_a timestamptz not null default now()
);

alter table public.signalements_problemes enable row level security;

drop policy if exists "signalements_problemes_select_all" on public.signalements_problemes;
create policy "signalements_problemes_select_all"
  on public.signalements_problemes for select
  to anon, authenticated
  using (true);

drop policy if exists "signalements_problemes_insert_own" on public.signalements_problemes;
create policy "signalements_problemes_insert_own"
  on public.signalements_problemes for insert
  to anon, authenticated
  with check (auth.uid() = user_id);

-- Likes
create table if not exists public.signalements_problemes_likes (
  id uuid primary key default gen_random_uuid(),
  probleme_id uuid not null references public.signalements_problemes(id) on delete cascade,
  user_id uuid not null,
  cree_a timestamptz not null default now(),
  unique(probleme_id, user_id)
);

alter table public.signalements_problemes_likes enable row level security;

drop policy if exists "signalements_problemes_likes_select_all" on public.signalements_problemes_likes;
create policy "signalements_problemes_likes_select_all"
  on public.signalements_problemes_likes for select
  to anon, authenticated
  using (true);

drop policy if exists "signalements_problemes_likes_insert_own" on public.signalements_problemes_likes;
create policy "signalements_problemes_likes_insert_own"
  on public.signalements_problemes_likes for insert
  to anon, authenticated
  with check (auth.uid() = user_id);

drop policy if exists "signalements_problemes_likes_delete_own" on public.signalements_problemes_likes;
create policy "signalements_problemes_likes_delete_own"
  on public.signalements_problemes_likes for delete
  to anon, authenticated
  using (auth.uid() = user_id);

-- Déposer un signalement
drop function if exists public.signaler_probleme(text, text);
create or replace function public.signaler_probleme(
  p_type text,
  p_description text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    return null;
  end if;
  if coalesce(trim(p_type),'') = '' or coalesce(trim(p_description),'') = '' then
    return null;
  end if;
  insert into public.signalements_problemes (user_id, type, description)
  values (auth.uid(), trim(p_type), trim(p_description))
  returning id into v_id;
  return v_id;
end;
$$;
grant execute on function public.signaler_probleme(text, text) to anon, authenticated;

-- Liker / déliker
drop function if exists public.toggle_like_probleme(uuid);
create or replace function public.toggle_like_probleme(p_probleme_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_existe boolean;
  v_nb integer;
begin
  if v_uid is null or p_probleme_id is null then
    return jsonb_build_object('ok', false);
  end if;
  select exists(select 1 from public.signalements_problemes_likes where probleme_id = p_probleme_id and user_id = v_uid) into v_existe;
  if v_existe then
    delete from public.signalements_problemes_likes where probleme_id = p_probleme_id and user_id = v_uid;
  else
    insert into public.signalements_problemes_likes (probleme_id, user_id) values (p_probleme_id, v_uid);
  end if;
  select count(*) into v_nb from public.signalements_problemes_likes where probleme_id = p_probleme_id;
  return jsonb_build_object('ok', true, 'aime', not v_existe, 'nb', v_nb);
end;
$$;
grant execute on function public.toggle_like_probleme(uuid) to anon, authenticated;

-- Liste des signalements avec nb likes + j'ai liké
drop function if exists public.liste_signalements_problemes();
create or replace function public.liste_signalements_problemes()
returns table (
  id uuid,
  type text,
  description text,
  cree_a timestamptz,
  nb_likes bigint,
  j_ai_like boolean
)
language sql
security definer
set search_path = public
as $$
  select 
    sp.id,
    sp.type,
    sp.description,
    sp.cree_a,
    coalesce(l.nb, 0) as nb_likes,
    coalesce(mj.aime, false) as j_ai_like
  from public.signalements_problemes sp
  left join (
    select probleme_id, count(*) as nb
    from public.signalements_problemes_likes
    group by probleme_id
  ) l on l.probleme_id = sp.id
  left join (
    select probleme_id, true as aime
    from public.signalements_problemes_likes
    where user_id = auth.uid()
  ) mj on mj.probleme_id = sp.id
  order by coalesce(l.nb, 0) desc, sp.cree_a desc
$$;
grant execute on function public.liste_signalements_problemes() to anon, authenticated;

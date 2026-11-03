-- Espaces informateurs — PHASE A
--
-- Chaque compte devient un « espace informateur » privé :
--   * un lien secret (jeton_espace) ouvre l'espace en lecture ;
--   * l'auteur publie des reportages (texte + photos) ;
--   * personne d'autre ne voit l'espace sans le lien.
--
-- Aucun fil public, aucun annuaire, aucune validation avant publication :
-- la visibilité repose sur le lien, et l'auteur peut le révoquer.
--
-- Cette migration ne contient QUE la phase A (espace + publication).
-- Les abonnements/likes/commentaires arrivent en phase B, mais la table
-- `abonnements` est créée ici car la règle de lecture des publications en
-- dépend déjà.

-- 1) Le jeton d'espace -------------------------------------------------------
alter table public.profiles add column if not exists jeton_espace text;
alter table public.profiles add column if not exists bio text;

create unique index if not exists profiles_jeton_espace_unique
  on public.profiles (jeton_espace)
  where jeton_espace is not null;

create or replace function public.attribuer_jeton_espace()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_jeton text;
  v_essais int := 0;
begin
  if new.jeton_espace is not null then
    return new;
  end if;
  loop
    v_essais := v_essais + 1;
    -- 16 caractères hexadécimaux = 64 bits : non devinable par balayage.
    v_jeton := substr(md5(concat(random(), clock_timestamp(), new.id)), 1, 16);
    exit when not exists (
      select 1 from public.profiles where jeton_espace = v_jeton
    );
    if v_essais >= 50 then
      raise exception 'Impossible de generer un jeton espace unique.';
    end if;
  end loop;
  new.jeton_espace := v_jeton;
  return new;
end $$;

drop trigger if exists profiles_jeton_espace on public.profiles;
create trigger profiles_jeton_espace
  before insert on public.profiles
  for each row execute function public.attribuer_jeton_espace();

-- Attribue un jeton aux profils existants.
do $$
declare
  r record;
  v_jeton text;
  v_essais int;
begin
  for r in select id from public.profiles where jeton_espace is null loop
    v_essais := 0;
    loop
      v_essais := v_essais + 1;
      v_jeton := substr(md5(concat(random(), clock_timestamp(), r.id)), 1, 16);
      exit when not exists (
        select 1 from public.profiles where jeton_espace = v_jeton
      );
      if v_essais >= 50 then
        raise exception 'Impossible de generer un jeton espace unique.';
      end if;
    end loop;
    update public.profiles set jeton_espace = v_jeton where id = r.id;
  end loop;
end $$;

-- 2) Abonnements (créés ici : la lecture des publications en dépend) --------
create table if not exists public.abonnements (
  abonne uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  informateur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  cree_a timestamptz not null default now(),
  primary key (abonne, informateur),
  check (abonne <> informateur)
);

alter table public.abonnements enable row level security;

drop policy if exists "abonnements_select_own" on public.abonnements;
create policy "abonnements_select_own"
  on public.abonnements for select
  to authenticated
  using (abonne = auth.uid() or informateur = auth.uid());

-- 3) Publications ------------------------------------------------------------
create table if not exists public.publications (
  id uuid primary key default gen_random_uuid(),
  auteur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  titre text not null check (char_length(titre) between 3 and 120),
  contenu text not null check (char_length(contenu) between 1 and 2000),
  photos jsonb not null default '[]'::jsonb,
  type_info text not null default 'info'
    check (type_info in ('trafic','eau','courant','internet','securite','info')),
  lieu text,
  statut text not null default 'publie'
    check (statut in ('publie','masque')),
  cree_a timestamptz not null default now(),
  check (jsonb_typeof(photos) = 'array'),
  check (jsonb_array_length(photos) <= 4)
);

create index if not exists publications_auteur_idx
  on public.publications (auteur, cree_a desc);

alter table public.publications enable row level security;

-- Règle de lecture : l'auteur, ou quelqu'un qui le suit.
drop policy if exists "publications_select" on public.publications;
create policy "publications_select"
  on public.publications for select
  to authenticated
  using (
    statut = 'publie'
    and (
      auteur = auth.uid()
      or exists (
        select 1 from public.abonnements a
         where a.abonne = auth.uid()
           and a.informateur = publications.auteur
      )
    )
  );

drop policy if exists "publications_insert_own" on public.publications;
create policy "publications_insert_own"
  on public.publications for insert
  to authenticated
  with check (auteur = auth.uid());

drop policy if exists "publications_delete_own" on public.publications;
create policy "publications_delete_own"
  on public.publications for delete
  to authenticated
  using (auteur = auth.uid());

drop policy if exists "publications_update_own" on public.publications;
create policy "publications_update_own"
  on public.publications for update
  to authenticated
  using (auteur = auth.uid())
  with check (auteur = auth.uid());

-- 4) Bucket privé des photos de reportage ------------------------------------
-- Chemin : <auteur>/<publication>/<n>.jpg
insert into storage.buckets (id, name, public)
values ('publications_photos', 'publications_photos', false)
on conflict (id) do update set public = false;

drop policy if exists "publications_photos_insert" on storage.objects;
create policy "publications_photos_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'publications_photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

drop policy if exists "publications_photos_select" on storage.objects;
create policy "publications_photos_select"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'publications_photos'
    and (
      auth.uid()::text = (storage.foldername(name))[1]
      or exists (
        select 1 from public.abonnements a
         where a.abonne = auth.uid()
           and a.informateur::text = (storage.foldername(name))[1]
      )
    )
  );

drop policy if exists "publications_photos_delete" on storage.objects;
create policy "publications_photos_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'publications_photos'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- 5) Mon espace --------------------------------------------------------------
drop function if exists public.mon_espace();
create or replace function public.mon_espace()
returns table (
  jeton text,
  bio text,
  nb_publications bigint,
  nb_abonnes bigint,
  prenom text,
  nom text,
  avatar text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  return query
    select p.jeton_espace,
           p.bio,
           (select count(*) from public.publications pb
             where pb.auteur = v_uid and pb.statut = 'publie'),
           (select count(*) from public.abonnements a
             where a.informateur = v_uid),
           p.prenom,
           p.nom,
           p.avatar
      from public.profiles p
     where p.id = v_uid;
end $$;

grant execute on function public.mon_espace() to authenticated;

-- 6) Modifier ma bio ---------------------------------------------------------
drop function if exists public.modifier_bio_espace(text);
create or replace function public.modifier_bio_espace(p_bio text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  update public.profiles
     set bio = nullif(trim(coalesce(p_bio, '')), '')
   where id = v_uid;
  return true;
end $$;

grant execute on function public.modifier_bio_espace(text) to authenticated;

-- 7) Publier un reportage ----------------------------------------------------
drop function if exists public.publier_publication(text, text, jsonb, text, text);
create or replace function public.publier_publication(
  p_titre text,
  p_contenu text,
  p_photos jsonb default '[]'::jsonb,
  p_type text default 'info',
  p_lieu text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_titre text := trim(coalesce(p_titre, ''));
  v_contenu text := trim(coalesce(p_contenu, ''));
  v_photos jsonb := coalesce(p_photos, '[]'::jsonb);
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  if char_length(v_titre) < 3 then
    raise exception 'titre_trop_court';
  end if;
  if char_length(v_contenu) < 1 then
    raise exception 'contenu_vide';
  end if;
  if jsonb_typeof(v_photos) <> 'array' then
    raise exception 'photos_invalides';
  end if;
  if jsonb_array_length(v_photos) > 4 then
    raise exception 'trop_de_photos';
  end if;
  if coalesce(p_type, 'info') not in
       ('trafic','eau','courant','internet','securite','info') then
    raise exception 'type_invalide';
  end if;

  -- Garde-fou : 20 reportages par jour maximum.
  if (select count(*) from public.publications
       where auteur = v_uid and cree_a > now() - interval '1 day') >= 20 then
    raise exception 'trop_de_publications';
  end if;

  insert into public.publications
    (auteur, titre, contenu, photos, type_info, lieu)
  values
    (v_uid, v_titre, v_contenu, v_photos, coalesce(p_type, 'info'),
     nullif(trim(coalesce(p_lieu, '')), ''))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.publier_publication(text, text, jsonb, text, text)
  to authenticated;

-- 8) Mes publications --------------------------------------------------------
drop function if exists public.mes_publications(integer);
create or replace function public.mes_publications(p_limite integer default 50)
returns table (
  id uuid,
  titre text,
  contenu text,
  photos jsonb,
  type_info text,
  lieu text,
  statut text,
  cree_a timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.titre, p.contenu, p.photos, p.type_info, p.lieu,
         p.statut, p.cree_a
    from public.publications p
   where p.auteur = auth.uid()
   order by p.cree_a desc
   limit greatest(1, least(coalesce(p_limite, 50), 200));
$$;

grant execute on function public.mes_publications(integer) to authenticated;

-- 9) Lire un espace par son lien ---------------------------------------------
drop function if exists public.espace_par_jeton(text);
create or replace function public.espace_par_jeton(p_jeton text)
returns table (
  informateur uuid,
  pseudo text,
  avatar text,
  bio text
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, trim(concat_ws(' ', p.prenom, p.nom)), p.avatar, p.bio
    from public.profiles p
   where p.jeton_espace = nullif(trim(p_jeton), '');
$$;

grant execute on function public.espace_par_jeton(text) to authenticated;

drop function if exists public.publications_espace(text, integer);
create or replace function public.publications_espace(
  p_jeton text,
  p_limite integer default 50
)
returns table (
  id uuid,
  titre text,
  contenu text,
  photos jsonb,
  type_info text,
  lieu text,
  cree_a timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.titre, p.contenu, p.photos, p.type_info, p.lieu, p.cree_a
    from public.publications p
    join public.profiles pr on pr.id = p.auteur
   where pr.jeton_espace = nullif(trim(p_jeton), '')
     and p.statut = 'publie'
   order by p.cree_a desc
   limit greatest(1, least(coalesce(p_limite, 50), 200));
$$;

grant execute on function public.publications_espace(text, integer)
  to authenticated;

-- 9 bis) Suivre l'espace ouvert par lien --------------------------------------
-- Ouvrir un espace vaut abonnement : c'est ce qui autorise ensuite la lecture
-- des photos privées du bucket (politique Storage) et qui alimentera la liste
-- « Mes abonnements ». Réouvrir le même lien ne change rien.
drop function if exists public.suivre_espace(text);
create or replace function public.suivre_espace(p_jeton text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_informateur uuid;
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  select p.id into v_informateur
    from public.profiles p
   where p.jeton_espace = nullif(trim(p_jeton), '');
  if v_informateur is null then
    raise exception 'espace_introuvable';
  end if;
  if v_informateur <> v_uid then
    insert into public.abonnements (abonne, informateur)
    values (v_uid, v_informateur)
    on conflict (abonne, informateur) do nothing;
  end if;
  return v_informateur;
end $$;

grant execute on function public.suivre_espace(text) to authenticated;

-- 10) Révoquer / régénérer mon lien -----------------------------------------
drop function if exists public.regenerer_jeton_espace();
create or replace function public.regenerer_jeton_espace()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_jeton text;
  v_essais int := 0;
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  loop
    v_essais := v_essais + 1;
    v_jeton := substr(md5(concat(random(), clock_timestamp(), v_uid)), 1, 16);
    exit when not exists (
      select 1 from public.profiles where jeton_espace = v_jeton
    );
    if v_essais >= 50 then
      raise exception 'Impossible de generer un jeton espace unique.';
    end if;
  end loop;
  update public.profiles set jeton_espace = v_jeton where id = v_uid;
  return v_jeton;
end $$;

grant execute on function public.regenerer_jeton_espace() to authenticated;

-- 11) Supprimer une publication ---------------------------------------------
drop function if exists public.supprimer_publication(uuid);
create or replace function public.supprimer_publication(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  delete from public.publications
   where id = p_id and auteur = v_uid;
  return found;
end $$;

grant execute on function public.supprimer_publication(uuid) to authenticated;

-- 12) Recharge du cache de schéma -------------------------------------------
select pg_notify('pgrst', 'reload schema');

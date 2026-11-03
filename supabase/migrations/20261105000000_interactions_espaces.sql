-- Espaces informateurs — PHASE B
--
-- 1) Le propriétaire peut ouvrir la publication à des membres désignés, ou à
--    tous les lecteurs de son espace.
-- 2) Likes sur les reportages.
-- 3) Commentaires ouverts à tous les lecteurs, réponses aux commentaires et
--    une réaction emoji par personne et par commentaire.
-- 4) Publications et commentaires anonymes : le nom et l'avatar sont masqués,
--    l'interface affiche « Anonyme ».
--
-- Tout passe par des RPC SECURITY DEFINER : `profiles` reste en RLS
-- « select_own », et les règles d'accès sont centralisées ici.

-- 0) Réglage : qui peut publier dans mon espace ? ----------------------------
alter table public.profiles
  add column if not exists ouverture_publication text not null
  default 'proprietaire';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'profiles_ouverture_publication_check'
  ) then
    alter table public.profiles
      add constraint profiles_ouverture_publication_check
      check (ouverture_publication in ('proprietaire', 'membres', 'tous'));
  end if;
end $$;

-- 1) Membres autorisés à publier --------------------------------------------
create table if not exists public.membres_espace (
  informateur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  membre uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  cree_a timestamptz not null default now(),
  primary key (informateur, membre),
  check (informateur <> membre)
);

alter table public.membres_espace enable row level security;

drop policy if exists "membres_espace_select_own" on public.membres_espace;
create policy "membres_espace_select_own"
  on public.membres_espace for select
  to authenticated
  using (informateur = auth.uid() or membre = auth.uid());

-- 2) Publications : espace propriétaire + anonymat --------------------------
alter table public.publications
  add column if not exists espace uuid references public.profiles(id)
  on delete cascade on update cascade;

update public.publications
   set espace = auteur
 where espace is null;

alter table public.publications alter column espace set not null;

alter table public.publications
  add column if not exists anonyme boolean not null default false;

create index if not exists publications_espace_idx
  on public.publications (espace, cree_a desc);

-- 3) Règles d'accès (centralisées) ------------------------------------------
create or replace function public.peut_voir_espace(p_informateur uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select auth.uid() is not null
     and (
       p_informateur = auth.uid()
       or exists (
         select 1 from public.abonnements a
          where a.abonne = auth.uid()
            and a.informateur = p_informateur
       )
       or exists (
         select 1 from public.membres_espace m
          where m.informateur = p_informateur
            and m.membre = auth.uid()
       )
     );
$$;

create or replace function public.peut_publier_dans_espace(p_informateur uuid)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_ouverture text;
begin
  if auth.uid() is null then
    return false;
  end if;
  if p_informateur = auth.uid() then
    return true;
  end if;
  select coalesce(ouverture_publication, 'proprietaire')
    into v_ouverture
    from public.profiles
   where id = p_informateur;
  if v_ouverture is null then
    return false;
  end if;
  if v_ouverture = 'tous' then
    return exists (
      select 1 from public.abonnements a
       where a.abonne = auth.uid()
         and a.informateur = p_informateur
    ) or exists (
      select 1 from public.membres_espace m
       where m.informateur = p_informateur
         and m.membre = auth.uid()
    );
  end if;
  if v_ouverture = 'membres' then
    return exists (
      select 1 from public.membres_espace m
       where m.informateur = p_informateur
         and m.membre = auth.uid()
    );
  end if;
  return false;
end $$;

create or replace function public.peut_gerer_espace(p_informateur uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select auth.uid() is not null and p_informateur = auth.uid();
$$;

create or replace function public.peut_voir_publication(p_publication uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
      from public.publications p
     where p.id = p_publication
       and p.statut = 'publie'
       and public.peut_voir_espace(p.espace)
  );
$$;

-- Conversion prudente d'un dossier Storage en uuid (jamais d'exception).
create or replace function public.texte_uuid(p_text text)
returns uuid
language plpgsql
immutable
as $$
begin
  return p_text::uuid;
exception when others then
  return null;
end $$;

-- 4) Likes ------------------------------------------------------------------
create table if not exists public.likes_publications (
  publication uuid not null references public.publications(id)
    on delete cascade on update cascade,
  auteur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  cree_a timestamptz not null default now(),
  primary key (publication, auteur)
);

create index if not exists likes_publications_publication_idx
  on public.likes_publications (publication);

alter table public.likes_publications enable row level security;

-- 5) Commentaires -----------------------------------------------------------
create table if not exists public.commentaires (
  id uuid primary key default gen_random_uuid(),
  publication uuid not null references public.publications(id)
    on delete cascade on update cascade,
  auteur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  parent uuid references public.commentaires(id) on delete cascade,
  contenu text not null check (char_length(contenu) between 1 and 1000),
  anonyme boolean not null default false,
  cree_a timestamptz not null default now()
);

create index if not exists commentaires_publication_idx
  on public.commentaires (publication, cree_a);

alter table public.commentaires enable row level security;

-- 6) Réactions emoji sur les commentaires ------------------------------------
create table if not exists public.reactions_commentaires (
  commentaire uuid not null references public.commentaires(id)
    on delete cascade on update cascade,
  auteur uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  emoji text not null check (char_length(emoji) between 1 and 8),
  cree_a timestamptz not null default now(),
  primary key (commentaire, auteur)
);

create index if not exists reactions_commentaires_commentaire_idx
  on public.reactions_commentaires (commentaire);

alter table public.reactions_commentaires enable row level security;

-- 7) Politique de lecture des publications ----------------------------------
drop policy if exists "publications_select" on public.publications;
create policy "publications_select"
  on public.publications for select
  to authenticated
  using (statut = 'publie' and public.peut_voir_espace(espace));

-- 8) Mon espace (avec le réglage de publication) ----------------------------
drop function if exists public.mon_espace();
create or replace function public.mon_espace()
returns table (
  id uuid,
  jeton text,
  bio text,
  nb_publications bigint,
  nb_abonnes bigint,
  prenom text,
  nom text,
  avatar text,
  ouverture_publication text
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
    select p.id,
           p.jeton_espace,
           p.bio,
           (select count(*) from public.publications pb
             where pb.espace = v_uid and pb.statut = 'publie'),
           (select count(*) from public.abonnements a
             where a.informateur = v_uid),
           p.prenom,
           p.nom,
           p.avatar,
           p.ouverture_publication
      from public.profiles p
     where p.id = v_uid;
end $$;

grant execute on function public.mon_espace() to authenticated;

-- 9) Lire un espace par son lien --------------------------------------------
drop function if exists public.espace_par_jeton(text);
create or replace function public.espace_par_jeton(p_jeton text)
returns table (
  informateur uuid,
  pseudo text,
  avatar text,
  bio text,
  ouverture text,
  mon_role text,
  je_peux_publier boolean,
  nb_publications bigint,
  nb_abonnes bigint
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id,
         trim(concat_ws(' ', p.prenom, p.nom)),
         p.avatar,
         p.bio,
         p.ouverture_publication,
         case
           when p.id = auth.uid() then 'proprietaire'
           when exists (
             select 1 from public.membres_espace m
              where m.informateur = p.id and m.membre = auth.uid()
           ) then 'membre'
           else 'lecteur'
         end,
         public.peut_publier_dans_espace(p.id),
         (select count(*) from public.publications pb
           where pb.espace = p.id and pb.statut = 'publie'),
         (select count(*) from public.abonnements a
           where a.informateur = p.id)
    from public.profiles p
   where p.jeton_espace = nullif(trim(p_jeton), '');
$$;

grant execute on function public.espace_par_jeton(text) to authenticated;

-- 10) Publications d'un espace ----------------------------------------------
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
  cree_a timestamptz,
  anonyme boolean,
  auteur_nom text,
  auteur_avatar text,
  nb_likes bigint,
  nb_commentaires bigint,
  jai_like boolean,
  je_peux_supprimer boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_espace uuid;
begin
  select p.id into v_espace
    from public.profiles p
   where p.jeton_espace = nullif(trim(p_jeton), '');
  if v_espace is null or not public.peut_voir_espace(v_espace) then
    return;
  end if;
  return query
    select p.id,
           p.titre,
           p.contenu,
           p.photos,
           p.type_info,
           p.lieu,
           p.cree_a,
           p.anonyme,
           case when p.anonyme then null
                else trim(concat_ws(' ', pr.prenom, pr.nom)) end,
           case when p.anonyme then null else pr.avatar end,
           (select count(*) from public.likes_publications l
             where l.publication = p.id),
           (select count(*) from public.commentaires c
             where c.publication = p.id),
           exists (
             select 1 from public.likes_publications l
              where l.publication = p.id and l.auteur = auth.uid()
           ),
           (p.auteur = auth.uid() or p.espace = auth.uid())
      from public.publications p
      join public.profiles pr on pr.id = p.auteur
     where p.espace = v_espace
       and p.statut = 'publie'
     order by p.cree_a desc
     limit greatest(1, least(coalesce(p_limite, 50), 200));
end $$;

grant execute on function public.publications_espace(text, integer)
  to authenticated;

-- 11) Mes publications (tout mon espace, y compris les co-publications) ------
drop function if exists public.mes_publications(integer);
create or replace function public.mes_publications(p_limite integer default 50)
returns table (
  id uuid,
  titre text,
  contenu text,
  photos jsonb,
  type_info text,
  lieu text,
  cree_a timestamptz,
  anonyme boolean,
  auteur_nom text,
  auteur_avatar text,
  nb_likes bigint,
  nb_commentaires bigint,
  jai_like boolean,
  je_peux_supprimer boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  return query
    select p.id,
           p.titre,
           p.contenu,
           p.photos,
           p.type_info,
           p.lieu,
           p.cree_a,
           p.anonyme,
           case when p.anonyme then null
                else trim(concat_ws(' ', pr.prenom, pr.nom)) end,
           case when p.anonyme then null else pr.avatar end,
           (select count(*) from public.likes_publications l
             where l.publication = p.id),
           (select count(*) from public.commentaires c
             where c.publication = p.id),
           exists (
             select 1 from public.likes_publications l
              where l.publication = p.id and l.auteur = v_uid
           ),
           (p.auteur = v_uid or p.espace = v_uid)
      from public.publications p
      join public.profiles pr on pr.id = p.auteur
     where p.espace = v_uid
     order by p.cree_a desc
     limit greatest(1, least(coalesce(p_limite, 50), 200));
end $$;

grant execute on function public.mes_publications(integer) to authenticated;

-- 12) Publier (propriétaire, membre désigné, ou tous selon le réglage) ------
drop function if exists public.publier_publication(text, text, jsonb, text, text);
drop function if exists public.publier_publication(
  text, text, text, jsonb, text, text, boolean
);
create or replace function public.publier_publication(
  p_jeton text,
  p_titre text,
  p_contenu text,
  p_photos jsonb default '[]'::jsonb,
  p_type text default 'info',
  p_lieu text default null,
  p_anonyme boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_espace uuid;
  v_id uuid;
  v_titre text := trim(coalesce(p_titre, ''));
  v_contenu text := trim(coalesce(p_contenu, ''));
  v_photos jsonb := coalesce(p_photos, '[]'::jsonb);
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  select p.id into v_espace
    from public.profiles p
   where p.jeton_espace = nullif(trim(p_jeton), '');
  if v_espace is null then
    raise exception 'espace_introuvable';
  end if;
  if not public.peut_publier_dans_espace(v_espace) then
    raise exception 'publication_non_autorisee';
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

  if (select count(*) from public.publications
       where auteur = v_uid and cree_a > now() - interval '1 day') >= 20 then
    raise exception 'trop_de_publications';
  end if;

  insert into public.publications
    (espace, auteur, titre, contenu, photos, type_info, lieu, anonyme)
  values
    (v_espace, v_uid, v_titre, v_contenu, v_photos,
     coalesce(p_type, 'info'),
     nullif(trim(coalesce(p_lieu, '')), ''),
     coalesce(p_anonyme, false))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.publier_publication(
  text, text, text, jsonb, text, text, boolean
) to authenticated;

-- 13) Supprimer une publication (auteur ou propriétaire de l'espace) --------
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
   where id = p_id and (auteur = v_uid or espace = v_uid);
  return found;
end $$;

grant execute on function public.supprimer_publication(uuid) to authenticated;

-- 14) Liker / retirer son like ----------------------------------------------
drop function if exists public.liker_publication(uuid);
create or replace function public.liker_publication(p_publication uuid)
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
  if not public.peut_voir_publication(p_publication) then
    raise exception 'acces_refuse';
  end if;
  if exists (
    select 1 from public.likes_publications
     where publication = p_publication and auteur = v_uid
  ) then
    delete from public.likes_publications
     where publication = p_publication and auteur = v_uid;
    return false;
  end if;
  insert into public.likes_publications (publication, auteur)
  values (p_publication, v_uid)
  on conflict do nothing;
  return true;
end $$;

grant execute on function public.liker_publication(uuid) to authenticated;

-- 15) Commentaires d'une publication ---------------------------------------
drop function if exists public.commentaires_publication(uuid);
create or replace function public.commentaires_publication(p_publication uuid)
returns table (
  id uuid,
  parent uuid,
  contenu text,
  anonyme boolean,
  cree_a timestamptz,
  auteur_nom text,
  auteur_avatar text,
  nb_reactions bigint,
  mon_emoji text,
  je_peux_supprimer boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_espace uuid;
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  if not public.peut_voir_publication(p_publication) then
    return;
  end if;
  select p.espace into v_espace
    from public.publications p where p.id = p_publication;
  return query
    select c.id,
           c.parent,
           c.contenu,
           c.anonyme,
           c.cree_a,
           case when c.anonyme then null
                else trim(concat_ws(' ', pr.prenom, pr.nom)) end,
           case when c.anonyme then null else pr.avatar end,
           (select count(*) from public.reactions_commentaires r
             where r.commentaire = c.id),
           (select r.emoji from public.reactions_commentaires r
             where r.commentaire = c.id and r.auteur = v_uid),
           (c.auteur = v_uid or v_espace = v_uid)
      from public.commentaires c
      join public.profiles pr on pr.id = c.auteur
     where c.publication = p_publication
     order by c.cree_a asc;
end $$;

grant execute on function public.commentaires_publication(uuid)
  to authenticated;

-- 16) Commenter / répondre ---------------------------------------------------
drop function if exists public.commenter_publication(uuid, text, uuid, boolean);
create or replace function public.commenter_publication(
  p_publication uuid,
  p_contenu text,
  p_parent uuid default null,
  p_anonyme boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_contenu text := trim(coalesce(p_contenu, ''));
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  if not public.peut_voir_publication(p_publication) then
    raise exception 'acces_refuse';
  end if;
  if char_length(v_contenu) < 1 then
    raise exception 'commentaire_vide';
  end if;
  if char_length(v_contenu) > 1000 then
    raise exception 'commentaire_trop_long';
  end if;
  if p_parent is not null and not exists (
    select 1 from public.commentaires
     where id = p_parent and publication = p_publication
  ) then
    raise exception 'parent_invalide';
  end if;
  if (select count(*) from public.commentaires
       where auteur = v_uid and cree_a > now() - interval '1 day') >= 200 then
    raise exception 'trop_de_commentaires';
  end if;

  insert into public.commentaires
    (publication, auteur, parent, contenu, anonyme)
  values
    (p_publication, v_uid, p_parent, v_contenu, coalesce(p_anonyme, false))
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.commenter_publication(uuid, text, uuid, boolean)
  to authenticated;

-- 17) Supprimer un commentaire (auteur ou propriétaire de l'espace) ---------
drop function if exists public.supprimer_commentaire(uuid);
create or replace function public.supprimer_commentaire(p_id uuid)
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
  delete from public.commentaires c
   using public.publications p
   where c.id = p_id
     and p.id = c.publication
     and (c.auteur = v_uid or p.espace = v_uid);
  return found;
end $$;

grant execute on function public.supprimer_commentaire(uuid) to authenticated;

-- 18) Réagir à un commentaire (un emoji par personne) -----------------------
drop function if exists public.reagir_commentaire(uuid, text);
create or replace function public.reagir_commentaire(
  p_commentaire uuid,
  p_emoji text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_emoji text := trim(coalesce(p_emoji, ''));
  v_publication uuid;
  v_actuel text;
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  select c.publication into v_publication
    from public.commentaires c where c.id = p_commentaire;
  if v_publication is null or not public.peut_voir_publication(v_publication) then
    raise exception 'acces_refuse';
  end if;
  if char_length(v_emoji) > 8 then
    raise exception 'emoji_invalide';
  end if;

  select emoji into v_actuel
    from public.reactions_commentaires
   where commentaire = p_commentaire and auteur = v_uid;

  if v_emoji = '' or v_actuel = v_emoji then
    delete from public.reactions_commentaires
     where commentaire = p_commentaire and auteur = v_uid;
    return null;
  end if;

  insert into public.reactions_commentaires (commentaire, auteur, emoji)
  values (p_commentaire, v_uid, v_emoji)
  on conflict (commentaire, auteur) do update set emoji = excluded.emoji;
  return v_emoji;
end $$;

grant execute on function public.reagir_commentaire(uuid, text)
  to authenticated;

-- 19) Réglage « qui peut publier » ------------------------------------------
drop function if exists public.modifier_ouverture_publication(text);
create or replace function public.modifier_ouverture_publication(p_mode text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_mode text := lower(trim(coalesce(p_mode, '')));
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  if v_mode not in ('proprietaire', 'membres', 'tous') then
    raise exception 'mode_invalide';
  end if;
  update public.profiles
     set ouverture_publication = v_mode
   where id = v_uid;
  return true;
end $$;

grant execute on function public.modifier_ouverture_publication(text)
  to authenticated;

-- 20) Équipe : membres autorisés -------------------------------------------
drop function if exists public.mes_membres_espace();
create or replace function public.mes_membres_espace()
returns table (
  membre uuid,
  nom text,
  avatar text,
  cree_a timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select m.membre,
         trim(concat_ws(' ', p.prenom, p.nom)),
         p.avatar,
         m.cree_a
    from public.membres_espace m
    join public.profiles p on p.id = m.membre
   where m.informateur = auth.uid()
   order by m.cree_a asc;
$$;

grant execute on function public.mes_membres_espace() to authenticated;

-- Retrouve un utilisateur par son code AMI, avec son identifiant.
drop function if exists public.trouver_utilisateur_par_code(text);
create or replace function public.trouver_utilisateur_par_code(p_code text)
returns table (id uuid, nom text, avatar text)
language sql
security definer
set search_path = public
stable
as $$
  select p.id,
         trim(concat_ws(' ', p.prenom, p.nom)),
         p.avatar
    from public.profiles p
   where p.code_ami = upper(trim(coalesce(p_code, '')))
   limit 1;
$$;

grant execute on function public.trouver_utilisateur_par_code(text)
  to authenticated;

drop function if exists public.ajouter_membre_espace(text);
create or replace function public.ajouter_membre_espace(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_membre uuid;
begin
  if v_uid is null then
    raise exception 'non_connecte';
  end if;
  select p.id into v_membre
    from public.profiles p
   where p.code_ami = upper(trim(coalesce(p_code, '')));
  if v_membre is null then
    raise exception 'introuvable';
  end if;
  if v_membre = v_uid then
    raise exception 'soi_meme';
  end if;
  insert into public.membres_espace (informateur, membre)
  values (v_uid, v_membre)
  on conflict do nothing;
  return v_membre;
end $$;

grant execute on function public.ajouter_membre_espace(text)
  to authenticated;

drop function if exists public.retirer_membre_espace(uuid);
create or replace function public.retirer_membre_espace(p_membre uuid)
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
  delete from public.membres_espace
   where informateur = v_uid and membre = p_membre;
  return found;
end $$;

grant execute on function public.retirer_membre_espace(uuid)
  to authenticated;

-- 21) Storage : chemins dans le dossier de l'ESPACE, pas du rédacteur -------
drop policy if exists "publications_photos_insert" on storage.objects;
create policy "publications_photos_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'publications_photos'
    and public.peut_publier_dans_espace(
      public.texte_uuid((storage.foldername(name))[1])
    )
  );

drop policy if exists "publications_photos_select" on storage.objects;
create policy "publications_photos_select"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'publications_photos'
    and public.peut_voir_espace(
      public.texte_uuid((storage.foldername(name))[1])
    )
  );

drop policy if exists "publications_photos_delete" on storage.objects;
create policy "publications_photos_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'publications_photos'
    and public.peut_gerer_espace(
      public.texte_uuid((storage.foldername(name))[1])
    )
  );

-- 22) Recharge du cache de schéma -------------------------------------------
select pg_notify('pgrst', 'reload schema');

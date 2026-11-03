create table if not exists public.pages (
  id uuid primary key default gen_random_uuid(),
  proprietaire uuid not null references public.profiles(id) on delete cascade,
  nom text not null,
  categorie text not null,
  description text not null default '',
  cree_a timestamptz not null default now(),
  unique (proprietaire)
);

create table if not exists public.page_publications (
  id uuid primary key default gen_random_uuid(),
  page_id uuid not null references public.pages(id) on delete cascade,
  auteur uuid not null references public.profiles(id) on delete cascade,
  contenu text not null,
  image_url text,
  cree_a timestamptz not null default now()
);

create table if not exists public.page_commentaires (
  id uuid primary key default gen_random_uuid(),
  publication_id uuid not null references public.page_publications(id) on delete cascade,
  auteur uuid not null references public.profiles(id) on delete cascade,
  parent_id uuid references public.page_commentaires(id) on delete cascade,
  contenu text not null,
  cree_a timestamptz not null default now()
);

create table if not exists public.page_abonnements (
  page_id uuid not null references public.pages(id) on delete cascade,
  utilisateur uuid not null references public.profiles(id) on delete cascade,
  cree_a timestamptz not null default now(),
  primary key (page_id, utilisateur)
);

create table if not exists public.page_notifications (
  id uuid primary key default gen_random_uuid(),
  destinataire uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('publication', 'reponse_commentaire')),
  publication_id uuid references public.page_publications(id) on delete cascade,
  commentaire_id uuid references public.page_commentaires(id) on delete cascade,
  lu boolean not null default false,
  cree_a timestamptz not null default now()
);

create or replace function public.notifier_publication_page()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.page_notifications (
    destinataire,
    type,
    publication_id
  )
  select
    a.utilisateur,
    'publication',
    new.id
  from public.page_abonnements a
  where a.page_id = new.page_id
    and a.utilisateur <> new.auteur;
  return new;
end;
$$;

drop trigger if exists page_publication_notification on public.page_publications;
create trigger page_publication_notification
after insert on public.page_publications
for each row execute function public.notifier_publication_page();

create or replace function public.notifier_reponse_commentaire()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_parent_auteur uuid;
begin
  if new.parent_id is null then
    return new;
  end if;
  select auteur into v_parent_auteur
  from public.page_commentaires
  where id = new.parent_id;
  if v_parent_auteur is null or v_parent_auteur = new.auteur then
    return new;
  end if;
  insert into public.page_notifications (
    destinataire,
    type,
    publication_id,
    commentaire_id
  )
  values (
    v_parent_auteur,
    'reponse_commentaire',
    new.publication_id,
    new.id
  );
  return new;
end;
$$;

drop trigger if exists page_commentaire_reponse_notification on public.page_commentaires;
create trigger page_commentaire_reponse_notification
after insert on public.page_commentaires
for each row execute function public.notifier_reponse_commentaire();

create or replace function public.compter_notifications_pages()
returns table (
  publications bigint,
  reponses_commentaires bigint
)
language sql
security definer
set search_path = public
as $$
  select
    count(*) filter (where n.type = 'publication') as publications,
    count(*) filter (where n.type = 'reponse_commentaire') as reponses_commentaires
  from public.page_notifications n
  where n.destinataire = auth.uid()
    and not n.lu;
$$;

grant execute on function public.compter_notifications_pages() to authenticated;

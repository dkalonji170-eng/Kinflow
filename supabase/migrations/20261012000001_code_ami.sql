-- Code AMI : identifiant PUBLIC, distinct du code de compte.
--
-- Le code de compte (colonne `code`) sert à se reconnecter : quiconque le
-- connaît (avec le nom) peut adopter le profil via `adopter_profil`. Il doit
-- donc rester secret et ne JAMAIS servir à ajouter des amis.
--
-- On ajoute donc `code_ami` : un identifiant public, généré automatiquement,
-- que l'on peut afficher en QR code et partager sans risque. Les fonctions
-- d'amitié (chercher_profil, envoyer_demande_ami) travaillent uniquement sur
-- `code_ami`.

-- 1) Colonne + index unique + attribution automatique ------------------------
alter table public.profiles add column if not exists code_ami text;

create unique index if not exists profiles_code_ami_unique
  on public.profiles (code_ami)
  where code_ami is not null;

create or replace function public.attribuer_code_ami()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_essais int := 0;
begin
  if new.code_ami is not null then
    return new;
  end if;
  loop
    v_essais := v_essais + 1;
    v_code := upper(substr(md5(concat(random(), clock_timestamp())), 1, 8));
    exit when not exists (select 1 from public.profiles where code_ami = v_code);
    if v_essais >= 50 then
      raise exception 'Impossible de generer un code ami unique.';
    end if;
  end loop;
  new.code_ami := v_code;
  return new;
end $$;

drop trigger if exists profiles_code_ami on public.profiles;
create trigger profiles_code_ami
  before insert on public.profiles
  for each row execute function public.attribuer_code_ami();

-- 2) Attribue un code ami aux profils qui n'en ont pas encore ----------------
do $$
declare
  r record;
  v_code text;
  v_essais int;
begin
  for r in select id from public.profiles where code_ami is null loop
    v_essais := 0;
    loop
      v_essais := v_essais + 1;
      v_code := upper(substr(md5(concat(random(), clock_timestamp())), 1, 8));
      exit when not exists (select 1 from public.profiles where code_ami = v_code);
      if v_essais >= 50 then
        raise exception 'Impossible de generer un code ami unique.';
      end if;
    end loop;
    update public.profiles set code_ami = v_code where id = r.id;
  end loop;
end $$;

-- 3) Mon code ami (le mien seulement) ---------------------------------------
drop function if exists public.mon_code_ami();
create or replace function public.mon_code_ami()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
begin
  if v_uid is null then
    return null;
  end if;
  select code_ami into v_code from public.profiles where id = v_uid;
  if v_code is null then
    update public.profiles
       set code_ami = upper(substr(md5(concat(random(), clock_timestamp())), 1, 8))
     where id = v_uid
    returning code_ami into v_code;
  end if;
  return v_code;
end $$;

grant execute on function public.mon_code_ami() to anon, authenticated;

-- 4) Recherche d'un profil par son code AMI ----------------------------------
drop function if exists public.chercher_profil(text);
create or replace function public.chercher_profil(p_code text)
returns table (prenom text, nom text, avatar text)
language sql
security definer
set search_path = public
as $$
  select p.prenom, p.nom, p.avatar
  from public.profiles p
  where p.code_ami = upper(p_code)
  limit 1;
$$;

grant execute on function public.chercher_profil(text) to anon, authenticated;

-- 5) Envoyer une demande d'ami par code AMI ----------------------------------
drop function if exists public.envoyer_demande_ami(text);
create or replace function public.envoyer_demande_ami(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(p_code);
  v_cible public.profiles%rowtype;
  v_existe public.amities%rowtype;
begin
  if v_uid is null then
    return 'non_connecte';
  end if;
  if v_code is null or length(v_code) = 0 then
    return 'code_invalide';
  end if;

  select * into v_cible from public.profiles where code_ami = v_code limit 1;
  if v_cible is null then
    return 'introuvable';
  end if;
  if v_cible.id = v_uid then
    return 'soi_meme';
  end if;

  select * into v_existe
  from public.amities
  where (demandeur = v_uid and destinataire = v_cible.id)
     or (demandeur = v_cible.id and destinataire = v_uid)
  limit 1;

  if v_existe is not null then
    if v_existe.statut = 'accepte' then
      return 'deja_ami';
    end if;
    if v_existe.demandeur = v_uid then
      return 'deja_envoye';
    end if;
    update public.amities
       set statut = 'accepte', repondu_a = now()
     where id = v_existe.id;
    return 'accepte';
  end if;

  insert into public.amities (demandeur, destinataire)
  values (v_uid, v_cible.id);

  return 'envoye';
end $$;

grant execute on function public.envoyer_demande_ami(text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

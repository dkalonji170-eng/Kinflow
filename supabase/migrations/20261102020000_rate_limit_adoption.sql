-- Point 2 — Limitation des tentatives de récupération de compte.
--
-- `adopter_profil` vérifie un code de 8 caractères + le nom exact. Sans limite,
-- un attaquant pouvait essayer des codes en boucle. On ajoute :
--   * 5 échecs maximum par identité et par fenêtre de 10 minutes ;
--   * 15 échecs maximum par code et par fenêtre de 15 minutes ;
--   * un verrou transactionnel par code pour éviter les essais concurrents ;
--   * une remise à zéro des échecs de l'identité après une connexion réussie.
--
-- La table ne référence PAS profiles : les identités anonymes n'ont pas
-- toujours de profil et les tentatives doivent survivre à leur suppression.

create table if not exists public.tentatives_adoption (
  id bigserial primary key,
  uid uuid not null,
  code_tente text not null,
  reussi boolean not null default false,
  cree_a timestamptz not null default now()
);

create index if not exists tentatives_adoption_uid_idx
  on public.tentatives_adoption (uid, cree_a desc);
create index if not exists tentatives_adoption_code_idx
  on public.tentatives_adoption (code_tente, cree_a desc);

alter table public.tentatives_adoption enable row level security;

drop function if exists public.adopter_profil(text, text);
create or replace function public.adopter_profil(code_saisi text, nom_saisi text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(regexp_replace(
    coalesce(code_saisi, ''), '[^a-zA-Z0-9]', '', 'g'
  ));
  v_echecs_uid integer;
  v_echecs_code integer;
  v_retry integer;
  v_profil public.profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'Identité anonyme absente.';
  end if;

  -- Purge opportuniste : on ne conserve qu'une journée de journaux.
  delete from public.tentatives_adoption
   where cree_a < now() - interval '1 day';

  -- Un seul essai à la fois pour un code donné.
  perform pg_advisory_xact_lock(hashtext('adopter_profil:' || v_code));

  select count(*) into v_echecs_uid
  from public.tentatives_adoption
  where uid = v_uid
    and reussi = false
    and cree_a > now() - interval '10 minutes';

  select count(*) into v_echecs_code
  from public.tentatives_adoption
  where code_tente = v_code
    and reussi = false
    and cree_a > now() - interval '15 minutes';

  if v_echecs_uid >= 5 then
    return jsonb_build_object(
      'erreur', 'trop_de_tentatives',
      'retry_after_secondes', 600
    );
  end if;

  if v_echecs_code >= 15 then
    v_retry := 900;
    return jsonb_build_object(
      'erreur', 'trop_de_tentatives',
      'retry_after_secondes', v_retry
    );
  end if;

  -- Un code vide ou trop court est enregistré comme échec, sans requête.
  if length(v_code) < 6 then
    insert into public.tentatives_adoption (uid, code_tente, reussi)
    values (v_uid, v_code, false);
    return null;
  end if;

  select *
    into v_profil
    from public.profiles
   where code = v_code
     and lower(trim(nom)) = lower(trim(nom_saisi))
   limit 1;

  if v_profil is null then
    insert into public.tentatives_adoption (uid, code_tente, reussi)
    values (v_uid, v_code, false);
    return null;
  end if;

  if v_profil.id = v_uid then
    delete from public.tentatives_adoption
     where uid = v_uid and reussi = false;
    insert into public.tentatives_adoption (uid, code_tente, reussi)
    values (v_uid, v_code, true);
    return to_jsonb(v_profil);
  end if;

  -- L'identité anonyme jetable est supprimée. Ses partages_info et
  -- messages_amis suivent automatiquement (ON DELETE CASCADE).
  delete from public.profiles where id = v_uid;

  if to_regclass('public.amities') is not null then
    delete from public.amities
     where demandeur = v_uid or destinataire = v_uid;

    update public.amities
       set demandeur = case when demandeur = v_profil.id then v_uid else demandeur end,
           destinataire = case when destinataire = v_profil.id then v_uid else destinataire end
     where demandeur = v_profil.id or destinataire = v_profil.id;
  end if;

  if to_regclass('public.positions_amis') is not null then
    delete from public.positions_amis where user_id = v_uid;
    update public.positions_amis set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.reactions') is not null then
    delete from public.reactions r
     where r.user_id = v_profil.id
       and exists (
         select 1 from public.reactions r2
          where r2.information_id = r.information_id and r2.user_id = v_uid
       );
    update public.reactions set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.reactions_emoji') is not null then
    delete from public.reactions_emoji e
     where e.user_id = v_profil.id
       and exists (
         select 1 from public.reactions_emoji e2
          where e2.information_id = e.information_id and e2.user_id = v_uid
       );
    update public.reactions_emoji set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.signalements') is not null then
    update public.signalements set user_id = v_uid where user_id = v_profil.id;
  end if;

  if to_regclass('public.blocages') is not null then
    delete from public.blocages
     where bloqueur = v_uid or bloque = v_uid;
    update public.blocages
       set bloqueur = case when bloqueur = v_profil.id then v_uid else bloqueur end,
           bloque = case when bloque = v_profil.id then v_uid else bloque end
     where bloqueur = v_profil.id or bloque = v_profil.id;
  end if;

  update public.profiles set id = v_uid where id = v_profil.id;

  delete from public.tentatives_adoption
   where uid = v_uid and reussi = false;
  insert into public.tentatives_adoption (uid, code_tente, reussi)
  values (v_uid, v_code, true);

  select * into v_profil from public.profiles where id = v_uid;
  return to_jsonb(v_profil);
end;
$$;

grant execute on function public.adopter_profil(text, text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

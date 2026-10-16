-- Récupération de compte : correctif de l'erreur 23503.
--
-- « Adopter un profil » (connexion par nom + code) transfère le profil existant
-- sous l'identité anonyme courante de l'appareil :
--
--     update public.profiles set id = auth.uid() where id = <ancien id>;
--
-- Or `partages_info` et `messages_amis` référencent `profiles(id)` avec
-- `on delete cascade` mais SANS `on update cascade`. Dès que le profil possède
-- la moindre info partagée ou le moindre message, Postgres refuse la mise à
-- jour de la clé primaire et la connexion échoue avec :
--
--   update or delete on table "profiles" violates foreign key constraint
--   "partages_info_expediteur_fkey" on table "partagesinfo" (SQLSTATE 23503)
--
-- Correctif : les clés étrangères suivent maintenant le changement d'id du
-- profil (en plus de la suppression en cascade déjà en place).

do $mig$
begin
  if to_regclass('public.partages_info') is not null then
    alter table public.partages_info
      drop constraint if exists partages_info_expediteur_fkey;
    alter table public.partages_info
      add constraint partages_info_expediteur_fkey
      foreign key (expediteur) references public.profiles(id)
      on delete cascade on update cascade;

    alter table public.partages_info
      drop constraint if exists partages_info_destinataire_fkey;
    alter table public.partages_info
      add constraint partages_info_destinataire_fkey
      foreign key (destinataire) references public.profiles(id)
      on delete cascade on update cascade;
  end if;

  if to_regclass('public.messages_amis') is not null then
    alter table public.messages_amis
      drop constraint if exists messages_amis_expediteur_fkey;
    alter table public.messages_amis
      add constraint messages_amis_expediteur_fkey
      foreign key (expediteur) references public.profiles(id)
      on delete cascade on update cascade;

    alter table public.messages_amis
      drop constraint if exists messages_amis_destinataire_fkey;
    alter table public.messages_amis
      add constraint messages_amis_destinataire_fkey
      foreign key (destinataire) references public.profiles(id)
      on delete cascade on update cascade;
  end if;
end
$mig$;

-- On profite du passage pour rendre la récupération de compte vraiment
-- complète : plusieurs tables stockent l'identité de l'utilisateur
-- (`user_id`, `demandeur`, `destinataire`) SANS clé étrangère vers profiles.
-- Sans report explicite, ces données seraient perdues au moment de l'adoption :
--   amities (demandeur/destinataire), positions_amis (user_id),
--   reactions (user_id), reactions_emoji (user_id), signalements (user_id).
-- On les transfère donc à la main vers la nouvelle identité.
drop function if exists public.adopter_profil(text, text);
create or replace function public.adopter_profil(code_saisi text, nom_saisi text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(code_saisi, ''), '[^a-zA-Z0-9]', '', 'g'));
  v_profil public.profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'Identité anonyme absente.';
  end if;

  select *
    into v_profil
    from public.profiles
   where code = v_code
     and lower(trim(nom)) = lower(trim(nom_saisi))
   limit 1;

  if v_profil is null then
    return null;
  end if;

  if v_profil.id = v_uid then
    return to_jsonb(v_profil);
  end if;

  -- L'identité anonyme jetable est supprimée. Ses partages_info et
  -- messages_amis suivent automatiquement (ON DELETE CASCADE).
  delete from public.profiles where id = v_uid;

  -- amities / positions_amis n'ont pas de clé étrangère : on les reporte à la
  -- main sur la nouvelle identité (après avoir retiré les éventuelles lignes
  -- de l'identité jetable, pour éviter tout doublon).
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

  -- reactions : une seule réaction (VERT/ROUGE) par info et par personne.
  -- Si les deux identités ont réagi à la même info, on garde celle de
  -- l'identité courante (la plus récente) avant de transférer le reste.
  if to_regclass('public.reactions') is not null then
    delete from public.reactions r
     where r.user_id = v_profil.id
       and exists (
         select 1 from public.reactions r2
          where r2.information_id = r.information_id and r2.user_id = v_uid
       );
    update public.reactions set user_id = v_uid where user_id = v_profil.id;
  end if;

  -- reactions_emoji : un seul émoji par info et par personne (même logique).
  if to_regclass('public.reactions_emoji') is not null then
    delete from public.reactions_emoji e
     where e.user_id = v_profil.id
       and exists (
         select 1 from public.reactions_emoji e2
          where e2.information_id = e.information_id and e2.user_id = v_uid
       );
    update public.reactions_emoji set user_id = v_uid where user_id = v_profil.id;
  end if;

  -- signalements : pas de contrainte d'unicité, on reporte simplement.
  if to_regclass('public.signalements') is not null then
    update public.signalements set user_id = v_uid where user_id = v_profil.id;
  end if;

  -- Le profil bascule ; partages_info et messages_amis suivent via
  -- ON UPDATE CASCADE posé plus haut.
  update public.profiles set id = v_uid where id = v_profil.id;

  select *
    into v_profil
    from public.profiles
   where id = v_uid;

  return to_jsonb(v_profil);
end;
$$;

grant execute on function public.adopter_profil(text, text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

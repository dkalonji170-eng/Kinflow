-- Correctif : récupération de compte impossible (SQLSTATE 23503).
--
-- `adopter_profil` déplace le profil existant sous l'identité anonyme de
-- l'appareil :
--
--     update public.profiles set id = auth.uid() where id = <ancien id>;
--
-- Toute clé étrangère qui référence `profiles(id)` doit donc suivre le
-- changement d'id (`on update cascade`) et la suppression (`on delete
-- cascade`). Les tables récentes (commentaires, publications, abonnements,
-- likes, réactions…) peuvent avoir été créées par une première version du
-- schéma sans ces options. Résultat :
--
--   update or delete on table "profiles" violates foreign key constraint
--   "commentaires_auteur_fkey" on table "commentaires" (23503)
--
-- On répare ici TOUTES les clés étrangères qui pointent vers profiles, quel
-- que soit leur nom, pour que la connexion par code + nom fonctionne même
-- quand le profil a déjà publié ou commenté.

do $mig$
declare
  r record;
begin
  for r in
    select c.conname,
           c.conrelid::regclass as table_concernee,
           a.attname as colonne
      from pg_constraint c
      join pg_attribute a
        on a.attrelid = c.conrelid
       and a.attnum = c.conkey[1]
     where c.contype = 'f'
       and c.confrelid = 'public.profiles'::regclass
       and c.conkey is not null
       and array_length(c.conkey, 1) = 1
       and (c.confupdtype <> 'c' or c.confdeltype <> 'c')
  loop
    execute format(
      'alter table %s drop constraint %I',
      r.table_concernee, r.conname
    );
    execute format(
      'alter table %s add constraint %I foreign key (%I) ' ||
      'references public.profiles(id) on delete cascade on update cascade',
      r.table_concernee, r.conname, r.colonne
    );
    raise notice 'FK réparée : %.% -> profiles(id)',
      r.table_concernee, r.colonne;
  end loop;
end
$mig$;

select pg_notify('pgrst', 'reload schema');

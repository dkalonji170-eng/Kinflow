-- Correctif : le tag d'une information ne fonctionnait jamais.
--
-- La colonne messages_amis.type_systeme porte une contrainte CHECK qui
-- n'autorisait que 'humain', 'loc_simple' et 'loc_urgence' (migration
-- 20261014000011). Or public.taguer_information() insère 'tag_info'.
-- L'INSERT violait donc la contrainte, la fonction levait une exception et
-- l'application affichait à tort « Tag impossible. Vérifie ta connexion. ».
--
-- On recrée la contrainte en incluant 'tag_info'.

do $$
declare
  c record;
begin
  -- Supprime toute contrainte CHECK existante qui mentionne type_systeme
  -- (peu importe son nom auto-généré).
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.messages_amis'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%type_systeme%'
  loop
    execute format('alter table public.messages_amis drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.messages_amis
  add constraint messages_amis_type_systeme_check
  check (
    type_systeme in ('humain', 'loc_simple', 'loc_urgence', 'tag_info')
    or type_systeme is null
  );

select pg_notify('pgrst', 'reload schema');

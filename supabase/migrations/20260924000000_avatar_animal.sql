-- Avatar « animal » façon Xender : identifiant stable d'un des 10 avatars
-- proposés à l'inscription (lion, tigre, panda, renard, koala, grenouille,
-- lapin, chien, loup, hibou). NULL tant qu'aucun avatar n'est choisi.
-- Aucun fichier image n'est stocké : l'app dessine l'animal et sa couleur.
alter table public.profiles add column if not exists avatar text;

select pg_notify('pgrst', 'reload schema');
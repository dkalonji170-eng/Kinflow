-- Suppression complète des grades (rangs) et de la série d'activité.
--
-- L'application n'affiche plus de grade ni de série : on retire les
-- fonctions RPC et la table qui les alimentaient. Script idempotent.

drop function if exists public.mon_rang_signalements();
drop function if exists public.rang_signalements_utilisateur(uuid);
drop function if exists public.compter_signalements_utilisateur(uuid);
drop function if exists public.rang_depuis_jours(integer);

-- Jours d'activité : ne servaient qu'au calcul du grade.
drop table if exists public.activite_utilisateur;

select pg_notify('pgrst', 'reload schema');

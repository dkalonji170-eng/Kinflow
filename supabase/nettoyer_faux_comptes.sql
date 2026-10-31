-- ===========================================================================
-- KinFlow — Nettoyage des comptes de test (« faux amis »)
-- ===========================================================================
--
-- À exécuter dans le tableau de bord Supabase, Éditeur SQL :
--   https://supabase.com/dashboard/project/qosznioaonumbdjhiwuj/sql/new
--
-- L'éditeur SQL s'exécute avec les droits administrateur : la RLS ne
-- s'applique pas, on voit donc tous les profils. C'est normal.
--
-- ⚠ AVANT DE SUPPRIMER : identifie bien ton VRAI compte (étape 1) et ne
--   supprime jamais son « code_compte ». Une suppression est définitive.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- ÉTAPE 1 — Repérer les faux comptes
-- ---------------------------------------------------------------------------
-- Exécute cette requête. Elle liste tous les profils avec leur code de compte
-- (privé), leur code ami (public) et le nombre de liens d'amitié. Repère les
-- lignes de test, puis note leurs « code_compte » pour l'étape 3.

select
  p.id,
  p.nom,
  p.prenom,
  p.code                                               as code_compte,
  p.code_ami                                           as code_ami,
  p.telephone,
  p.email,
  (select count(*) from public.amities a
     where a.demandeur = p.id or a.destinataire = p.id) as nb_liens_amis
from public.profiles p
order by p.nom nulls last, p.prenom nulls last;


-- ---------------------------------------------------------------------------
-- ÉTAPE 2 — (Une seule fois) Créer la fonction de suppression propre
-- ---------------------------------------------------------------------------
-- Cette fonction efface un profil ET toutes ses données rattachées.
-- Les tables partages_info et messages_amis suivent en cascade (clé
-- étrangère), mais amities / positions_amis / reactions / reactions_emoji /
-- signalements n'ont pas de clé étrangère : on les nettoie explicitement.

create or replace function public.supprimer_profils(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nb integer;
begin
  delete from public.amities
   where demandeur = any(p_ids) or destinataire = any(p_ids);

  delete from public.positions_amis  where user_id = any(p_ids);
  delete from public.reactions       where user_id = any(p_ids);
  delete from public.reactions_emoji where user_id = any(p_ids);
  delete from public.signalements    where user_id = any(p_ids);

  -- partages_info et messages_amis sont supprimés automatiquement
  -- (ON DELETE CASCADE vers profiles.id).
  delete from public.profiles where id = any(p_ids);
  get diagnostics v_nb = row_count;
  return v_nb;
end $$;

-- Aucun droit accordé à anon/authenticated : cette fonction est réservée
-- à l'éditeur SQL (rôle administrateur). L'app ne peut donc pas l'appeler.


-- ---------------------------------------------------------------------------
-- ÉTAPE 3 — Supprimer les faux comptes par leur code
-- ---------------------------------------------------------------------------
-- Remplace les codes ci-dessous par ceux des faux comptes relevés à l'étape 1
-- (colonne code_compte, 8 caractères, sans tiret).
--
-- Pour vérifier AVANT de supprimer, lance d'abord uniquement le SELECT.

-- 3a) Vérifier les cibles (doit lister exactement tes faux comptes) :
select id, nom, prenom, code as code_compte
from public.profiles
where code in ('AAAAAAAA', 'BBBBBBBB')   -- <-- à remplacer
order by nom;

-- 3b) Supprimer (décommente en retirant les deux tirets « -- » devant select) :
-- select public.supprimer_profils(array(
--   select id from public.profiles
--   where code in ('AAAAAAAA', 'BBBBBBBB')   -- <-- mêmes codes qu'en 3a
-- )) as profils_supprimes;


-- ---------------------------------------------------------------------------
-- CAS CONCRET — Supprimer « Kabasele » et « Grace »
-- ---------------------------------------------------------------------------
-- ⚠ Lance d'abord le contrôle (A), vérifie que ce sont bien les 2 lignes de
--   test et pas ton vrai compte, PUIS supprime (B).

-- (A) Contrôle — doit lister Kabasele et Grace (et seulement eux) :
select id, nom, prenom, code as code_compte, code_ami, telephone, email
from public.profiles
where lower(coalesce(nom, ''))    in ('kabasele', 'grace')
   or lower(coalesce(prenom, '')) in ('kabasele', 'grace')
order by nom, prenom;

-- (B) Suppression (décommente en retirant les deux tirets « -- ») :
-- select public.supprimer_profils(array(
--   select id from public.profiles
--   where lower(coalesce(nom, ''))    in ('kabasele', 'grace')
--      or lower(coalesce(prenom, '')) in ('kabasele', 'grace')
-- )) as profils_supprimes;


-- Si Kabasele ou Grace a un autre nom de famille, remplace plutôt le bloc
-- « where » par leurs codes de compte (relevés à l'étape 1) :
--   where code in ('XXXXXXXX', 'YYYYYYYY')


-- ---------------------------------------------------------------------------
-- Variante : supprimer par nom (si tu ne connais pas les codes)
-- ---------------------------------------------------------------------------
-- ⚠ À n'utiliser que si les noms sont uniques. Vérifie d'abord avec un SELECT.

-- select id, nom, prenom, code as code_compte
-- from public.profiles
-- where lower(nom) in ('test', 'testeur', 'faux')   -- <-- à remplacer
-- order by nom;


-- ---------------------------------------------------------------------------
-- Optionnel — Nettoyer les identités de connexion orphelines
-- ---------------------------------------------------------------------------
-- Supprimer un profil ne supprime pas l'utilisateur dans « Authentication ».
-- Ces comptes anonymes inutilisés sont sans danger, mais si tu veux les
-- retirer aussi :
--   Tableau de bord → Authentication → Users → filtre « Anonymous »
--   → sélectionne les utilisateurs de test → Delete user.
-- Ne touche PAS à l'utilisateur lié à ton vrai compte.

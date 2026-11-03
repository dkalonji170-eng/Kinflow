-- Point 1 — Purge des données applicatives avant suppression du compte Auth.
--
-- La suppression d'un utilisateur `auth.users` ne supprime pas automatiquement
-- `profiles` (cette table n'a pas de FK vers auth.users dans le schéma actuel).
-- Cette fonction est appelée par l'Edge Function `supprimer-compte`, avec la
-- clé service_role uniquement, après le nettoyage des fichiers Storage.
--
-- Elle est volontairement NON exécutable par anon/authenticated : un compte ne
-- doit pas pouvoir purger les données d'un autre en changeant l'argument.

create or replace function public.purger_compte(p_uid uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_uid is null then
    return false;
  end if;

  delete from public.tentatives_adoption where uid = p_uid;

  delete from public.signalements_utilisateurs
   where signaleur = p_uid or cible = p_uid;

  delete from public.blocages
   where bloqueur = p_uid or bloque = p_uid;

  delete from public.amities
   where demandeur = p_uid or destinataire = p_uid;

  delete from public.positions_amis where user_id = p_uid;

  delete from public.reactions where user_id = p_uid;
  delete from public.reactions_emoji where user_id = p_uid;

  -- Signalements routiers : contribution personnelle, supprimée avec le compte.
  delete from public.signalements where user_id = p_uid;

  delete from public.appareils_push where user_id = p_uid;
  delete from public.preferences_notifications where user_id = p_uid;

  -- Le profil supprime en cascade messages_amis et partages_info.
  delete from public.profiles where id = p_uid;

  return true;
end;
$$;

revoke all on function public.purger_compte(uuid) from public;
revoke all on function public.purger_compte(uuid) from anon, authenticated;
grant execute on function public.purger_compte(uuid) to service_role;

select pg_notify('pgrst', 'reload schema');

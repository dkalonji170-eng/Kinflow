-- Localisation simple : désormais AUTORISÉE PAR DÉFAUT entre amis(es).
--
-- Avant : les colonnes valaient `false` par défaut et il fallait une
-- autorisation explicite (questionnaire) pour que la localisation simple
-- fonctionne — ce qui faisait qu'elle ne marchait quasiment jamais.
--
-- Maintenant : dès qu'une amitié est acceptée, chacun autorise l'autre à le/la
-- localiser simplement. Chacun peut retirer son accord à tout moment via
-- l'interrupteur « Autoriser … à me localiser » (fonction
-- `definir_autorisation_loc_simple`), qui reste inchangée.

alter table public.amities
  alter column a1_autorise_a2_loc_simple set default true,
  alter column a2_autorise_a1_loc_simple set default true;

-- Amitiés existantes : on les ouvre aussi (le temps que l'utilisateur retire
-- explicitement son accord s'il le souhaite). Les amitiés refusées/en attente
-- ne sont pas touchées.
update public.amities
   set a1_autorise_a2_loc_simple = true,
       a2_autorise_a1_loc_simple = true
 where statut = 'accepte'
   and (a1_autorise_a2_loc_simple is distinct from true
     or a2_autorise_a1_loc_simple is distinct from true);

select pg_notify('pgrst', 'reload schema');

-- Autorisations réciproques de localisation entre amis (acceptés)
-- - loc_simple_autorise : A autorise B à le localiser à tout moment (simple)
-- - urgence_disponible : A a donné une urgence dispo pour que B le localise 1 fois
-- (stocké par sens pour la paire)

alter table public.amities
  add column if not exists a1_autorise_a2_loc_simple boolean not null default false,
  add column if not exists a2_autorise_a1_loc_simple boolean not null default false,
  add column if not exists a1_urgence_sur_a2 boolean not null default true,
  add column if not exists a2_urgence_sur_a1 boolean not null default true;

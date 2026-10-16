-- Messages système pour traçabilité des localisations (simple / urgence)
-- type_systeme: 'humain' | 'loc_simple' | 'loc_urgence' | null

alter table public.messages_amis
  add column if not exists type_systeme text
    check (type_systeme in ('humain', 'loc_simple', 'loc_urgence') or type_systeme is null),
  add column if not exists est_systeme boolean not null default false;

-- Index utile (facultatif)
create index if not exists messages_amis_systeme_idx
  on public.messages_amis (est_systeme, cree_a desc);

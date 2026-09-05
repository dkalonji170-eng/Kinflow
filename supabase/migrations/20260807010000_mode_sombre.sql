alter table public.profiles
  add column if not exists mode_sombre boolean not null default false;

select pg_notify('pgrst', 'reload schema');

create or replace function public.adopter_profil(code_saisi text, nom_saisi text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(regexp_replace(coalesce(code_saisi, ''), '[^a-zA-Z0-9]', '', 'g'));
  v_profil public.profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'Identité anonyme absente.';
  end if;

  select *
    into v_profil
    from public.profiles
   where code = v_code
     and lower(trim(nom)) = lower(trim(nom_saisi))
   limit 1;

  if v_profil is null then
    return null;
  end if;

  if v_profil.id = v_uid then
    return to_jsonb(v_profil);
  end if;

  delete from public.profiles where id = v_uid;

  update public.profiles
     set id = v_uid
   where id = v_profil.id;

  select *
    into v_profil
    from public.profiles
   where id = v_uid;

  return to_jsonb(v_profil);
end;
$$;

grant execute on function public.adopter_profil(text, text) to anon;

create unique index if not exists profiles_code_key on public.profiles(code);

select pg_notify('pgrst', 'reload schema');

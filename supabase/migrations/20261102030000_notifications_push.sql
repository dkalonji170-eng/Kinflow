-- Point 6 — Infrastructure des notifications push.
--
-- Les préférences locales existaient déjà, mais rien n'était stocké côté
-- serveur et aucun jeton d'appareil n'était associé au compte. Ces tables
-- permettent à une Edge Function d'envoyer un push uniquement aux appareils
-- des personnes concernées, en respectant leurs préférences.
--
-- Le fournisseur (Firebase/APNs) reste configuré côté Supabase via des
-- secrets : aucune clé privée n'est stockée dans l'application.

create table if not exists public.appareils_push (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  token text not null unique,
  plateforme text not null default 'android'
    check (plateforme in ('android', 'ios', 'web')),
  cree_a timestamptz not null default now(),
  maj_a timestamptz not null default now()
);

create index if not exists appareils_push_user_idx
  on public.appareils_push (user_id);

alter table public.appareils_push enable row level security;

create table if not exists public.preferences_notifications (
  user_id uuid primary key references public.profiles(id)
    on delete cascade on update cascade,
  push_actif boolean not null default true,
  embouteillages boolean not null default true,
  routes_bloquees boolean not null default true,
  messages boolean not null default true,
  demandes_amis boolean not null default true,
  infos boolean not null default true,
  maj_a timestamptz not null default now()
);

alter table public.preferences_notifications enable row level security;

-- 1) Enregistrer / rafraîchir le jeton de cet appareil -----------------------
create or replace function public.enregistrer_token_push(
  p_token text,
  p_plateforme text default 'android'
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text := trim(coalesce(p_token, ''));
  v_plateforme text := lower(trim(coalesce(p_plateforme, 'android')));
begin
  if v_uid is null then return false; end if;
  if length(v_token) < 20 or length(v_token) > 4096 then return false; end if;
  if v_plateforme not in ('android', 'ios', 'web') then
    v_plateforme := 'android';
  end if;

  insert into public.appareils_push (user_id, token, plateforme)
  values (v_uid, v_token, v_plateforme)
  on conflict (token) do update set
    user_id = excluded.user_id,
    plateforme = excluded.plateforme,
    maj_a = now();

  return true;
end;
$$;

grant execute on function public.enregistrer_token_push(text, text)
  to anon, authenticated;

-- 2) Retirer le jeton (déconnexion, permission révoquée) --------------------
create or replace function public.supprimer_token_push(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return false; end if;
  delete from public.appareils_push
   where user_id = v_uid and token = trim(coalesce(p_token, ''));
  return found;
end;
$$;

grant execute on function public.supprimer_token_push(text)
  to anon, authenticated;

create or replace function public.supprimer_mes_tokens_push()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_nb integer;
begin
  if v_uid is null then return 0; end if;
  delete from public.appareils_push where user_id = v_uid;
  get diagnostics v_nb = row_count;
  return v_nb;
end;
$$;

grant execute on function public.supprimer_mes_tokens_push()
  to anon, authenticated;

-- 3) Préférences -------------------------------------------------------------
create or replace function public.mes_preferences_notifications()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'push_actif', p.push_actif,
        'embouteillages', p.embouteillages,
        'routes_bloquees', p.routes_bloquees,
        'messages', p.messages,
        'demandes_amis', p.demandes_amis,
        'infos', p.infos
      )
      from public.preferences_notifications p
      where p.user_id = auth.uid()
    ),
    jsonb_build_object(
      'push_actif', true,
      'embouteillages', true,
      'routes_bloquees', true,
      'messages', true,
      'demandes_amis', true,
      'infos', true
    )
  );
$$;

grant execute on function public.mes_preferences_notifications()
  to anon, authenticated;

create or replace function public.definir_preferences_notifications(
  p_preferences jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v jsonb := coalesce(p_preferences, '{}'::jsonb);
begin
  if v_uid is null then
    return jsonb_build_object('erreur', 'non_connecte');
  end if;

  insert into public.preferences_notifications (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  update public.preferences_notifications
     set push_actif = case when v ? 'push_actif'
           then coalesce((v->>'push_actif')::boolean, push_actif)
           else push_actif end,
         embouteillages = case when v ? 'embouteillages'
           then coalesce((v->>'embouteillages')::boolean, embouteillages)
           else embouteillages end,
         routes_bloquees = case when v ? 'routes_bloquees'
           then coalesce((v->>'routes_bloquees')::boolean, routes_bloquees)
           else routes_bloquees end,
         messages = case when v ? 'messages'
           then coalesce((v->>'messages')::boolean, messages)
           else messages end,
         demandes_amis = case when v ? 'demandes_amis'
           then coalesce((v->>'demandes_amis')::boolean, demandes_amis)
           else demandes_amis end,
         infos = case when v ? 'infos'
           then coalesce((v->>'infos')::boolean, infos)
           else infos end,
         maj_a = now()
   where user_id = v_uid;

  return public.mes_preferences_notifications();
end;
$$;

grant execute on function public.definir_preferences_notifications(jsonb)
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- Fil Social : UN SEUL émoji par personne et par information.
-- L'utilisateur peut poser l'émoji de son choix, mais un seul à la fois :
-- retaper le même le retire, poser un autre émoji remplace le précédent.
-- (La table autorisait jusqu'ici plusieurs émojis d'une même personne.)

-- 1) Nettoyage : s'il reste plusieurs émojis d'une même personne sur une
--    même info, on ne garde que le plus récent.
with ranges as (
  select ctid,
         row_number() over (
           partition by information_id, user_id
           order by cree_a desc, ctid desc
         ) as rang
  from public.reactions_emoji
)
delete from public.reactions_emoji re
using ranges r
where r.ctid = re.ctid
  and r.rang > 1;

-- 2) Contrainte d'unicité : au plus une ligne par (info, personne).
alter table public.reactions_emoji
  add constraint reactions_emoji_une_par_personne
  unique (information_id, user_id);

-- 3) Nouvelle bascule émoji : pose, remplace ou retire.
drop function if exists public.reagir_emoji(uuid, text);
create or replace function public.reagir_emoji(p_id uuid, p_emoji text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_ancien text;
begin
  if v_uid is null then
    return false;
  end if;
  if p_emoji is null or char_length(p_emoji) not between 1 and 16 then
    return false;
  end if;
  if not exists (select 1 from public.informations where id = p_id) then
    return false;
  end if;

  select emoji into v_ancien
  from public.reactions_emoji
  where information_id = p_id and user_id = v_uid;

  if v_ancien is null then
    -- Aucun émoji posé : on pose celui choisi.
    insert into public.reactions_emoji (information_id, user_id, emoji)
    values (p_id, v_uid, p_emoji)
    on conflict (information_id, user_id)
    do update set emoji = excluded.emoji;
    return true;
  end if;

  if v_ancien = p_emoji then
    -- Le même émoji retapé : on retire sa réaction.
    delete from public.reactions_emoji
    where information_id = p_id and user_id = v_uid;
    return true;
  end if;

  -- Un autre émoji : il remplace le précédent (un seul à la fois).
  update public.reactions_emoji
  set emoji = p_emoji, cree_a = now()
  where information_id = p_id and user_id = v_uid;

  return true;
end;
$$;

grant execute on function public.reagir_emoji(uuid, text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');
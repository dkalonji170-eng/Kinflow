-- Statut des messages : en cours d'envoi (côté app), envoyé (présent sur le
-- serveur), reçu (arrivé sur le téléphone du destinataire), lu.
--
-- On ajoute une colonne recu_a, estampillée quand l'application du
-- destinataire récupère ses messages non lus. La lecture (lu) reste distincte.

alter table public.messages_amis
  add column if not exists recu_a timestamptz;

drop function if exists public.mes_messages_ami(uuid);
create or replace function public.mes_messages_ami(p_ami_id uuid)
returns setof jsonb
language sql
security definer
set search_path = public
as $kf$
select to_jsonb(t) from (
  select
    m.id,
    m.expediteur,
    m.contenu,
    m.cree_a,
    (m.expediteur = auth.uid()) as moi,
    (m.recu_a is not null) as recu,
    m.lu
  from public.messages_amis m
  where m.cree_a >= now() - interval '7 days'
    and m.destinataire in (auth.uid(), p_ami_id)
    and m.expediteur in (auth.uid(), p_ami_id)
  order by m.cree_a asc
  limit 500
) t;
$kf$;

grant execute on function public.mes_messages_ami(uuid) to anon, authenticated;

drop function if exists public.marquer_messages_lus(uuid);
create or replace function public.marquer_messages_lus(p_ami_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $kf$
begin
  if auth.uid() is null then
    return false;
  end if;
  update public.messages_amis
     set lu = true,
         recu_a = coalesce(recu_a, now())
   where destinataire = auth.uid()
     and expediteur = p_ami_id
     and lu = false;
  return true;
end;
$kf$;

grant execute on function public.marquer_messages_lus(uuid)
  to anon, authenticated;

drop function if exists public.marquer_messages_recus();
create or replace function public.marquer_messages_recus()
returns boolean
language plpgsql
security definer
set search_path = public
as $kf$
begin
  if auth.uid() is null then
    return false;
  end if;
  update public.messages_amis
     set recu_a = now()
   where destinataire = auth.uid()
     and recu_a is null;
  return true;
end;
$kf$;

grant execute on function public.marquer_messages_recus()
  to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

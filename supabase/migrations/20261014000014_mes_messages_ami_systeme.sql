-- La discussion doit aussi renvoyer l'indicateur de message système afin que
-- l'application stylise les localisations (orange = simple, rouge = urgence)
-- différemment des messages humains.
--
-- On remplace mes_messages_ami pour exposer est_systeme + type_systeme.

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
    m.lu,
    m.est_systeme,
    m.type_systeme
  from public.messages_amis m
  where m.cree_a >= now() - interval '7 days'
    and m.destinataire in (auth.uid(), p_ami_id)
    and m.expediteur in (auth.uid(), p_ami_id)
  order by m.cree_a asc
  limit 500
) t;
$kf$;

grant execute on function public.mes_messages_ami(uuid) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

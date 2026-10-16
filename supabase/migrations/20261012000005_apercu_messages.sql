-- Aperçu de discussion : le dernier message échangé avec chaque ami(e), sur
-- la fenêtre de 7 jours. Sert à afficher sous le nom, dans la liste Amis(es).

drop function if exists public.apercus_messages_amis();
create or replace function public.apercus_messages_amis()
returns setof jsonb
language sql
security definer
set search_path = public
as $kf$
select to_jsonb(t) from (
  select distinct on (s.autre)
    s.autre as ami_id,
    s.contenu,
    (s.expediteur = auth.uid()) as moi,
    s.cree_a
  from (
    select
      m.contenu,
      m.expediteur,
      m.cree_a,
      case
        when m.expediteur = auth.uid() then m.destinataire
        else m.expediteur
      end as autre
    from public.messages_amis m
    where m.cree_a >= now() - interval '7 days'
      and (m.expediteur = auth.uid() or m.destinataire = auth.uid())
  ) s
  order by s.autre, s.cree_a desc
) t;
$kf$;

grant execute on function public.apercus_messages_amis() to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

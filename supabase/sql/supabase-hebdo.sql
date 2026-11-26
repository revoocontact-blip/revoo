-- =====================================================================
-- ORLEOO — e-mail « Nouveautés de la semaine » (uniquement pour les membres qui l'acceptent)
-- Envoi chaque lundi matin. Peut être relancé sans risque.
-- =====================================================================
alter table public.profiles add column if not exists notify_digest boolean not null default false;

create or replace function public.send_weekly_digest()
returns int language plpgsql security definer set search_path = public as $$
declare u record; items text; n int := 0;
begin
  for u in select p.id from public.profiles p where p.notify_digest loop
    select string_agg('• ' || l.title || ' — ' || l.price || ' € : https://revoocontact-blip.github.io/revoo/#/article/' || l.id, chr(10) order by score desc, l.created_at desc)
    into items
    from (select l.*, (case when l.category in (select l2.category from public.favorites f join public.listings l2 on l2.id = f.listing_id where f.user_id = u.id) then 2 else 0 end
                    + case when l.category in (select s.category from public.saved_searches s where s.user_id = u.id and s.category is not null) then 1 else 0 end) score
          from public.listings l
          where l.status = 'active' and l.seller_id <> u.id and l.created_at > now() - interval '7 days'
          order by score desc, l.created_at desc limit 6) l;
    if items is not null then
      perform public.send_revoo_email(u.id, 'Les nouveautés de la semaine sur Orleoo',
        'Voici quelques nouvelles annonces de la semaine qui pourraient te plaire :' || chr(10) || chr(10) || items || chr(10) || chr(10)
        || 'Tu reçois cet e-mail car tu as activé « Nouveautés de la semaine » dans Mon compte. Tu peux le désactiver à tout moment.',
        'https://revoocontact-blip.github.io/revoo/#/catalogue');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.send_weekly_digest() from public, anon, authenticated;

-- Chaque lundi à 8 h 37 (heure de Paris = 7 h 37 UTC en hiver)
do $$ begin
  perform cron.unschedule('orleoo-hebdo');
exception when others then null; end $$;
select cron.schedule('orleoo-hebdo', '37 7 * * 1', 'select public.send_weekly_digest()');

select 'E-mail « Nouveautés de la semaine » programmé chaque lundi' as info;

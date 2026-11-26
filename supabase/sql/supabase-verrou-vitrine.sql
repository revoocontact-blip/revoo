-- =====================================================================
-- ORLEOO — verrou du mode vitrine
-- Tant que les achats ne sont pas ouverts (site_settings.achats_ouverts = false),
-- le SERVEUR refuse toute commande, tout paiement et tout échange accepté,
-- même si quelqu'un appelle la base directement sans passer par le site.
-- À lancer APRÈS supabase-offres-lots.sql. Peut être relancé sans risque.
-- À l'ouverture des achats :
--   update public.site_settings set achats_ouverts = true where id = 1;
-- =====================================================================
alter table public.site_settings add column if not exists achats_ouverts boolean not null default false;
create or replace function public.achats_ouverts()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select achats_ouverts from public.site_settings where id = 1), false);
$$;
grant execute on function public.achats_ouverts() to anon, authenticated;

create or replace function public.require_purchases_open()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.achats_ouverts() then return new; end if;
  -- traitement automatique par le serveur (pg_cron, webhook) : pas d'utilisateur connecté
  if tg_table_name = 'trades' and tg_op = 'UPDATE'
     and not (new.status = 'accepted' and old.status is distinct from 'accepted') then
    return new;
  end if;
  raise exception 'Les achats ne sont pas encore ouverts sur Orleoo : clique sur « Me prévenir » pour être averti(e) de l’ouverture.';
end $$;
revoke all on function public.require_purchases_open() from public, anon, authenticated;

drop trigger if exists orders_require_open on public.orders;
create trigger orders_require_open before insert on public.orders
  for each row execute function public.require_purchases_open();

drop trigger if exists checkouts_require_open on public.checkouts;
create trigger checkouts_require_open before insert on public.checkouts
  for each row execute function public.require_purchases_open();

drop trigger if exists trades_require_open on public.trades;
create trigger trades_require_open before insert or update of status on public.trades
  for each row execute function public.require_purchases_open();

select 'Verrou vitrine actif : achats ' || case when public.achats_ouverts() then 'OUVERTS' else 'fermés' end as info;

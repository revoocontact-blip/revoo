-- 44. Durcissement sécurité (audit nov. 2026)
-- Les tâches de fond ne sont plus appelables depuis le site : seul le planificateur les lance.
revoke execute on function public.settle_orders() from public, anon, authenticated;
revoke execute on function public.settle_trades() from public, anon, authenticated;
revoke execute on function public.settle_subscriptions() from public, anon, authenticated;
revoke execute on function public.expire_checkouts() from public, anon, authenticated;
revoke execute on function public.expire_offers() from public, anon, authenticated;
revoke execute on function public.is_banned(uuid) from public, anon, authenticated;
-- Réservé aux membres connectés
revoke execute on function public.mark_follow_hits_seen() from public, anon;
grant execute on function public.mark_follow_hits_seen() to authenticated;
-- Chemin de recherche figé
alter function public.min_price_drop() set search_path = public;
-- Le planificateur lance aussi les abonnements et les paiements expirés
select cron.unschedule('revoo-delais');
select cron.schedule('revoo-delais','*/15 * * * *',
  'select public.settle_orders(); select public.settle_trades(); select public.expire_offers(); select public.settle_subscriptions(); select public.expire_checkouts();');

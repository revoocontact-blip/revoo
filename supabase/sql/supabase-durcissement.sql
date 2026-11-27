-- =====================================================================
-- ORLEOO — durcissement avant lancement (d'après l'analyse de sécurité Supabase)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer en DERNIER. Peut être relancé sans risque.
-- =====================================================================

-- 1. Fonctions réservées aux membres connectés : plus appelables par les visiteurs anonymes
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('blocked_me','expire_offers','launch_email_count','mark_price_drops_seen') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- 2. Fonctions de déclencheurs (jamais appelées directement) : personne ne peut les appeler
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prorettype = 'trigger'::regtype loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

-- 3. Chemin de recherche fixé pour les fonctions qui n'en avaient pas
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('touch_updated_at','impact_kg_for','order_set_deadline','new_handoff_code','check_address','eur_txt','plan_limit','norm_txt')
             and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') loop
    execute format('alter function %s set search_path = public', f.sig);
  end loop;
end $$;

-- 4. Index pour que la base reste rapide quand elle grossira
create index if not exists favorites_listing_idx         on public.favorites (listing_id);
create index if not exists launch_waitlist_listing_idx   on public.launch_waitlist (listing_id);
create index if not exists orders_listing_idx            on public.orders (listing_id);
create index if not exists price_drops_listing_idx       on public.price_drops (listing_id);
create index if not exists alert_hits_listing_idx        on public.alert_hits (listing_id);
create index if not exists blocks_blocked_idx            on public.blocks (blocked_id);
create index if not exists reviews_buyer_idx             on public.reviews (buyer_id);
create index if not exists trades_offered_idx            on public.trades (offered_listing);
create index if not exists trades_wanted_idx             on public.trades (wanted_listing);
create index if not exists trades_checkout_idx           on public.trades (checkout_id);
create index if not exists wallet_moves_order_idx        on public.wallet_moves (order_id);
create index if not exists wallet_moves_trade_idx        on public.wallet_moves (trade_id);
create index if not exists reports_reporter_idx          on public.reports (reporter_id);
create index if not exists message_notifications_rcpt_idx on public.message_notifications (recipient_id);
create index if not exists mod_log_actor_idx             on public.mod_log (actor_id);
create index if not exists mod_log_target_user_idx       on public.mod_log (target_user);
create index if not exists trade_addresses_user_idx      on public.trade_addresses (user_id);
create index if not exists payout_requests_user_idx      on public.payout_requests (user_id);
create index if not exists checkouts_trade_idx           on public.checkouts (trade_id);
-- index en double
drop index if exists public.orders_buyer_idx;

select 'Durcissement appliqué' as info;

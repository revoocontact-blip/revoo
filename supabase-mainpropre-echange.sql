-- =====================================================================
-- REVOO — remise en main propre avec code + échanges sécurisés
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-revoopay.sql. (Peut être relancé sans risque.)
--
-- Tant que Mangopay n'est pas branché, tout est en mode démo : aucun argent
-- n'est encaissé ni remboursé pour de vrai.
-- =====================================================================

-- Vérification : les scripts précédents doivent avoir été lancés
do $$ begin
  if to_regclass('public.listings') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-revoo.sql, puis relance ce script.';
  end if;
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-signalements.sql, puis relance ce script.';
  end if;
  if to_regclass('public.conversations') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-messagerie.sql, puis relance ce script.';
  end if;
  if to_regclass('public.orders') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-revoopay.sql, puis relance ce script.';
  end if;
end $$;

-- =====================================================================
-- 1. REMISE EN MAIN PROPRE AVEC CODE À 6 CHIFFRES
--    L'acheteur paie → l'argent est bloqué → il reçoit un code secret.
--    Au rendez-vous, il vérifie l'article puis donne le code au vendeur.
--    Le vendeur tape le code → paiement validé → il remet l'article.
--    L'acheteur peut « Annuler l'achat » tant que le code n'est pas validé :
--    remboursement sous 48 h maximum.
--    Délai de rendez-vous : 7 jours, prolongeable une fois ou plusieurs fois
--    de 7 jours au total maximum. Sans code validé à temps : annulation
--    automatique et remboursement sous 48 h maximum.
-- =====================================================================
alter table public.orders add column if not exists cancelled_at timestamptz;
alter table public.orders add column if not exists refund_due_at timestamptz;
alter table public.orders add column if not exists cancelled_by text;
alter table public.orders add column if not exists handoff_deadline timestamptz;
alter table public.orders add column if not exists handoff_extended int not null default 0;
update public.orders set handoff_deadline = created_at + interval '7 days'
 where delivery = 'main_propre' and handoff_deadline is null;

create or replace function public.order_set_deadline()
returns trigger language plpgsql as $$
begin
  if new.delivery = 'main_propre' then
    new.handoff_deadline := now() + interval '7 days';
    new.handoff_extended := 0;
  else
    new.handoff_deadline := null;
  end if;
  return new;
end $$;
drop trigger if exists orders_set_deadline on public.orders;
create trigger orders_set_deadline before insert on public.orders
  for each row execute function public.order_set_deadline();

-- Les codes sont dans une table à part : SEUL l'acheteur peut les lire.
create table if not exists public.order_codes (
  order_id  uuid primary key references public.orders(id) on delete cascade,
  code      text not null check (code ~ '^[0-9]{6}$'),
  attempts  int not null default 0
);
alter table public.order_codes enable row level security;
drop policy if exists "code : visible par l'acheteur seul" on public.order_codes;
create policy "code : visible par l'acheteur seul" on public.order_codes
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and o.buyer_id = auth.uid()));

create or replace function public.new_handoff_code()
returns text language sql volatile as $$
  select lpad(((('x' || substr(md5(gen_random_uuid()::text), 1, 8))::bit(32)::bigint) % 1000000)::text, 6, '0');
$$;

create or replace function public.order_add_code()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.delivery = 'main_propre' then
    insert into public.order_codes (order_id, code) values (new.id, public.new_handoff_code())
    on conflict (order_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists orders_add_code on public.orders;
create trigger orders_add_code after insert on public.orders
  for each row execute function public.order_add_code();

-- Commandes en main propre déjà existantes : on leur donne un code
insert into public.order_codes (order_id, code)
select id, public.new_handoff_code() from public.orders
where delivery = 'main_propre' and status = 'paid'
on conflict (order_id) do nothing;

-- Le vendeur tape le code. Réponse : 'ok', 'wrong:<essais restants>' ou 'locked'.
create or replace function public.confirm_handoff(p_order uuid, p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare o record; c record;
begin
  select * into o from public.orders where id = p_order for update;
  if o is null or o.seller_id is distinct from auth.uid() or o.delivery <> 'main_propre' or o.status <> 'paid' then
    raise exception 'Action impossible sur cette commande';
  end if;
  select * into c from public.order_codes where order_id = p_order for update;
  if c is null then raise exception 'Code introuvable : contacte la modération'; end if;
  if o.handoff_deadline is not null and o.handoff_deadline <= now() then
    raise exception 'Le délai de rendez-vous est dépassé : la vente va être annulée et l’acheteur remboursé';
  end if;
  if c.attempts >= 5 then return 'locked'; end if;
  if c.code <> regexp_replace(coalesce(p_code, ''), '\D', '', 'g') then
    update public.order_codes set attempts = attempts + 1 where order_id = p_order;
    if c.attempts + 1 >= 5 then return 'locked'; end if;
    return 'wrong:' || (5 - c.attempts - 1);
  end if;
  update public.orders set status = 'received', shipped_at = now(), received_at = now(), updated_at = now() where id = p_order;
  return 'ok';
end $$;

-- L'envoi « Marquer comme envoyé » ne concerne plus que les colis
create or replace function public.mark_shipped(p_order uuid, p_tracking text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders set status = 'shipped', tracking = nullif(trim(p_tracking),''), shipped_at = now(), updated_at = now()
  where id = p_order and seller_id = auth.uid() and status = 'paid' and delivery = 'colis';
  if not found then raise exception 'Action impossible sur cette commande'; end if;
end $$;

-- Annulation : vendeur (avant envoi / remise), acheteur en main propre (avant validation du code),
-- ou modération. L'article est remis en vente, remboursement sous 48 h maximum.
create or replace function public.cancel_order(p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o record; who text;
begin
  select * into o from public.orders where id = p_order for update;
  if o is null then raise exception 'Commande introuvable'; end if;
  if o.seller_id = auth.uid() and o.status = 'paid' then who := 'vendeur';
  elsif o.buyer_id = auth.uid() and o.status = 'paid' and o.delivery = 'main_propre' then who := 'acheteur';
  elsif public.is_admin() and o.status in ('paid','shipped','problem') then who := 'moderation';
  else raise exception 'Action impossible sur cette commande';
  end if;
  update public.orders set status = 'cancelled', cancelled_at = now(), refund_due_at = now() + interval '48 hours',
    cancelled_by = who, updated_at = now() where id = p_order;
  update public.listings set status = 'active' where id = o.listing_id and status = 'sold';
end $$;

-- Prolonger le délai de rendez-vous (acheteur ou vendeur) : 7 jours de plus au total, maximum
create or replace function public.extend_handoff(p_order uuid, p_days int)
returns void language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from public.orders where id = p_order for update;
  if o is null or auth.uid() not in (o.buyer_id, o.seller_id) or o.delivery <> 'main_propre' or o.status <> 'paid' then
    raise exception 'Action impossible sur cette commande';
  end if;
  if p_days is null or p_days < 1 or p_days > 7 then raise exception 'Choisis entre 1 et 7 jours'; end if;
  if o.handoff_extended + p_days > 7 then
    raise exception 'Le délai ne peut être prolongé que de 7 jours au total (il reste % jour(s))', 7 - o.handoff_extended;
  end if;
  if o.handoff_deadline <= now() then raise exception 'Le délai est déjà dépassé'; end if;
  update public.orders set handoff_deadline = handoff_deadline + make_interval(days => p_days),
    handoff_extended = handoff_extended + p_days, updated_at = now() where id = p_order;
end $$;

-- Annulation automatique des remises en main propre dont le délai est dépassé
create or replace function public.settle_orders()
returns void language plpgsql security definer set search_path = public as $$
begin
  with c as (
    update public.orders set status = 'cancelled', cancelled_at = now(), refund_due_at = now() + interval '48 hours',
      cancelled_by = 'delai', updated_at = now()
    where delivery = 'main_propre' and status = 'paid' and handoff_deadline <= now()
    returning listing_id
  )
  update public.listings set status = 'active' where id in (select listing_id from c) and status = 'sold';
end $$;

revoke all on function public.extend_handoff(uuid,int) from public, anon;
grant execute on function public.extend_handoff(uuid,int) to authenticated;
revoke all on function public.settle_orders() from public, anon;
grant execute on function public.settle_orders() to authenticated;
revoke all on function public.confirm_handoff(uuid,text) from public, anon;
grant execute on function public.confirm_handoff(uuid,text) to authenticated;
revoke all on function public.new_handoff_code() from public, anon, authenticated;

-- =====================================================================
-- 2. ÉCHANGES
--    • Débloqué après 3 achats confirmés (pour les deux personnes).
--    • Celui qui propose peut ajouter de l'argent (complément), bloqué dès l'accord.
--    • Numéro de suivi obligatoire pour chaque colis.
--    • Les 48 h de vérification démarrent quand le DERNIER des deux colis est reçu
--      (un colis non confirmé 14 jours après son envoi compte comme reçu).
--      Sans réponse, l'échange est validé automatiquement.
--    • En cas de problème, tout reste bloqué et la modération tranche.
-- =====================================================================
create table if not exists public.trades (
  id                    uuid primary key default gen_random_uuid(),
  proposer_id           uuid not null references public.profiles(id) on delete cascade,
  receiver_id           uuid not null references public.profiles(id) on delete cascade,
  offered_listing       uuid references public.listings(id) on delete set null,
  wanted_listing        uuid references public.listings(id) on delete set null,
  offered_title         text not null,
  offered_photo         text,
  wanted_title          text not null,
  wanted_photo          text,
  topup                 numeric(10,2) not null default 0 check (topup >= 0 and topup <= 500),
  fee                   numeric(10,2) not null default 1 check (fee >= 0),
  message               text check (char_length(message) <= 500),
  status                text not null default 'proposed'
                        check (status in ('proposed','accepted','completed','problem','declined','cancelled')),
  proposer_tracking     text check (char_length(proposer_tracking) <= 60),
  receiver_tracking     text check (char_length(receiver_tracking) <= 60),
  proposer_shipped_at   timestamptz,
  receiver_shipped_at   timestamptz,
  proposer_received_at  timestamptz,   -- le proposeur a reçu le colis de l'autre
  receiver_received_at  timestamptz,
  review_deadline       timestamptz,   -- fin des 48 h (après le dernier colis reçu)
  proposer_ok           boolean not null default false,
  receiver_ok           boolean not null default false,
  problem               text check (char_length(problem) <= 1000),
  problem_by            uuid,
  refund_due_at         timestamptz,
  demo                  boolean not null default true,
  created_at            timestamptz not null default now(),
  accepted_at           timestamptz,
  completed_at          timestamptz,
  updated_at            timestamptz not null default now(),
  check (proposer_id <> receiver_id)
);
-- Négociation : le complément peut être payé par l'un ou l'autre, et chacun peut faire une contre-proposition
alter table public.trades add column if not exists topup_payer text not null default 'proposer';
alter table public.trades add column if not exists turn uuid;
alter table public.trades add column if not exists rounds int not null default 0;
do $$ begin
  alter table public.trades add constraint trades_topup_payer_check check (topup_payer in ('proposer','receiver'));
exception when duplicate_object then null; end $$;
update public.trades set turn = receiver_id where status = 'proposed' and turn is null;
create index if not exists trades_proposer_idx on public.trades (proposer_id, created_at desc);
create index if not exists trades_receiver_idx on public.trades (receiver_id, created_at desc);
alter table public.trades enable row level security;
drop policy if exists "échanges : voir les miens" on public.trades;
create policy "échanges : voir les miens" on public.trades
  for select to authenticated using (auth.uid() in (proposer_id, receiver_id) or public.is_admin());

-- Adresses d'envoi : visibles par l'autre personne seulement une fois l'échange accepté
create table if not exists public.trade_addresses (
  trade_id  uuid not null references public.trades(id) on delete cascade,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  name      text not null check (char_length(name) <= 80),
  address   text not null check (char_length(address) <= 200),
  zip       text not null check (char_length(zip) <= 10),
  city      text not null check (char_length(city) <= 80),
  primary key (trade_id, user_id)
);
alter table public.trade_addresses enable row level security;
drop policy if exists "adresses d'échange : visibles si accepté" on public.trade_addresses;
create policy "adresses d'échange : visibles si accepté" on public.trade_addresses
  for select to authenticated using (
    user_id = auth.uid() or public.is_admin() or exists (
      select 1 from public.trades t where t.id = trade_id and auth.uid() in (t.proposer_id, t.receiver_id)
        and t.status in ('accepted','completed','problem')));

create or replace function public.purchases_done(p_user uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.orders where buyer_id = p_user and status = 'received';
$$;

create or replace function public.check_address(p_name text, p_address text, p_zip text, p_city text)
returns void language plpgsql immutable as $$
begin
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_address),'') = '' or coalesce(trim(p_zip),'') = '' or coalesce(trim(p_city),'') = '' then
    raise exception 'Adresse d’envoi incomplète';
  end if;
end $$;

-- Proposer un échange (p_topup_from : 'proposer' = j'ajoute de l'argent, 'receiver' = je demande de l'argent)
drop function if exists public.propose_trade(uuid,uuid,numeric,text,text,text,text,text);
create or replace function public.propose_trade(
  p_offered uuid, p_wanted uuid, p_topup numeric, p_message text,
  p_name text, p_address text, p_zip text, p_city text, p_topup_from text default 'proposer')
returns uuid language plpgsql security definer set search_path = public as $$
declare a record; b record; new_id uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if public.purchases_done(auth.uid()) < 3 then raise exception 'L’échange se débloque après 3 achats confirmés'; end if;
  select * into a from public.listings where id = p_offered;
  select * into b from public.listings where id = p_wanted;
  if a is null or a.seller_id <> auth.uid() or a.status <> 'active' then raise exception 'Choisis un de tes articles en ligne'; end if;
  if b is null or b.status <> 'active' then raise exception 'Cet article n’est plus disponible'; end if;
  if b.seller_id = auth.uid() then raise exception 'Tu ne peux pas échanger avec toi-même'; end if;
  if coalesce(p_topup, 0) < 0 or coalesce(p_topup, 0) > 500 then raise exception 'Le complément doit être entre 0 et 500 €'; end if;
  if coalesce(p_topup_from, 'proposer') not in ('proposer','receiver') then raise exception 'Complément invalide'; end if;
  perform public.check_address(p_name, p_address, p_zip, p_city);
  if exists (select 1 from public.trades where offered_listing = p_offered and wanted_listing = p_wanted and status = 'proposed') then
    raise exception 'Tu as déjà proposé cet échange';
  end if;
  insert into public.trades (proposer_id, receiver_id, offered_listing, wanted_listing, offered_title, offered_photo,
                             wanted_title, wanted_photo, topup, topup_payer, turn, message)
  values (auth.uid(), b.seller_id, a.id, b.id, a.title, a.photos[1], b.title, b.photos[1],
          round(coalesce(p_topup, 0), 2), coalesce(p_topup_from, 'proposer'), b.seller_id,
          nullif(left(trim(coalesce(p_message,'')), 500), ''))
  returning id into new_id;
  insert into public.trade_addresses values (new_id, auth.uid(), trim(p_name), trim(p_address), trim(p_zip), trim(p_city));
  return new_id;
end $$;

-- Contre-proposition : celui qui doit répondre change le complément (montant et qui le paie).
-- C'est ensuite à l'autre de répondre. 10 allers-retours maximum.
create or replace function public.counter_trade(
  p_trade uuid, p_topup numeric, p_topup_from text,
  p_name text default null, p_address text default null, p_zip text default null, p_city text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t record;
begin
  select * into t from public.trades where id = p_trade for update;
  if t is null or t.status <> 'proposed' or t.turn is distinct from auth.uid() then raise exception 'Ce n’est pas à toi de répondre'; end if;
  if t.rounds >= 10 then raise exception 'Trop de contre-propositions : accepte ou refuse'; end if;
  if coalesce(p_topup, 0) < 0 or coalesce(p_topup, 0) > 500 then raise exception 'Le complément doit être entre 0 et 500 €'; end if;
  if p_topup_from not in ('proposer','receiver') then raise exception 'Complément invalide'; end if;
  if round(coalesce(p_topup,0),2) = t.topup and (p_topup_from = t.topup_payer or coalesce(p_topup,0) = 0) then
    raise exception 'Ta contre-proposition est identique : accepte-la directement';
  end if;
  if auth.uid() = t.receiver_id then
    if p_name is not null then
      perform public.check_address(p_name, p_address, p_zip, p_city);
      insert into public.trade_addresses values (p_trade, auth.uid(), trim(p_name), trim(p_address), trim(p_zip), trim(p_city))
      on conflict (trade_id, user_id) do update set name = excluded.name, address = excluded.address, zip = excluded.zip, city = excluded.city;
    elsif not exists (select 1 from public.trade_addresses where trade_id = p_trade and user_id = auth.uid()) then
      raise exception 'Adresse d’envoi incomplète';
    end if;
  end if;
  update public.trades set topup = round(coalesce(p_topup,0),2), topup_payer = p_topup_from,
    turn = case when auth.uid() = proposer_id then receiver_id else proposer_id end,
    rounds = rounds + 1, updated_at = now() where id = p_trade;
end $$;

-- Accepter (celui dont c'est le tour) ; refuser / retirer (l'un ou l'autre, tant que rien n'est accepté)
drop function if exists public.respond_trade(uuid,boolean,text,text,text,text);
create or replace function public.respond_trade(
  p_trade uuid, p_accept boolean,
  p_name text default null, p_address text default null, p_zip text default null, p_city text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t record; n int;
begin
  select * into t from public.trades where id = p_trade for update;
  if t is null or auth.uid() not in (t.proposer_id, t.receiver_id) or t.status <> 'proposed' then raise exception 'Action impossible sur cet échange'; end if;
  if not p_accept then
    update public.trades set status = case when auth.uid() = t.proposer_id then 'cancelled' else 'declined' end, updated_at = now() where id = p_trade;
    return;
  end if;
  if t.turn is distinct from auth.uid() then raise exception 'Attends la réponse de l’autre personne'; end if;
  if public.purchases_done(t.proposer_id) < 3 or public.purchases_done(t.receiver_id) < 3 then
    raise exception 'L’échange se débloque après 3 achats confirmés';
  end if;
  if auth.uid() = t.receiver_id then
    if p_name is not null then
      perform public.check_address(p_name, p_address, p_zip, p_city);
      insert into public.trade_addresses values (p_trade, auth.uid(), trim(p_name), trim(p_address), trim(p_zip), trim(p_city))
      on conflict (trade_id, user_id) do update set name = excluded.name, address = excluded.address, zip = excluded.zip, city = excluded.city;
    end if;
  end if;
  if not exists (select 1 from public.trade_addresses where trade_id = p_trade and user_id = t.receiver_id) then
    raise exception 'Adresse d’envoi incomplète';
  end if;
  update public.listings set status = 'sold'
   where id in (t.offered_listing, t.wanted_listing) and status = 'active';
  get diagnostics n = row_count;
  if n <> 2 then raise exception 'Un des deux articles n’est plus disponible'; end if;
  update public.trades set status = 'accepted', accepted_at = now(), turn = null, updated_at = now() where id = p_trade;
  -- les autres propositions sur ces articles tombent
  update public.trades set status = 'cancelled', updated_at = now()
   where id <> p_trade and status = 'proposed'
     and (offered_listing in (t.offered_listing, t.wanted_listing) or wanted_listing in (t.offered_listing, t.wanted_listing));
  insert into public.conversations (listing_id, buyer_id, seller_id)
  values (t.wanted_listing, t.proposer_id, t.receiver_id) on conflict (listing_id, buyer_id) do nothing;
end $$;

-- Annuler : le proposeur avant réponse, ou l'un des deux tant que personne n'a envoyé son colis
create or replace function public.cancel_trade(p_trade uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t record;
begin
  select * into t from public.trades where id = p_trade for update;
  if t is null then raise exception 'Échange introuvable'; end if;
  if t.status = 'proposed' and t.proposer_id = auth.uid() then
    update public.trades set status = 'cancelled', updated_at = now() where id = p_trade;
    return;
  end if;
  if not ((t.status = 'accepted' and auth.uid() in (t.proposer_id, t.receiver_id)
           and t.proposer_shipped_at is null and t.receiver_shipped_at is null)
          or (public.is_admin() and t.status in ('proposed','accepted','problem'))) then
    raise exception 'Action impossible : un colis est déjà parti. Signale un problème si besoin';
  end if;
  update public.trades set status = 'cancelled', refund_due_at = case when t.status = 'proposed' then null else now() + interval '48 hours' end,
    updated_at = now() where id = p_trade;
  if t.status <> 'proposed' then
    update public.listings set status = 'active' where id in (t.offered_listing, t.wanted_listing) and status = 'sold';
  end if;
end $$;

-- J'ai envoyé mon colis (numéro de suivi obligatoire)
create or replace function public.ship_trade(p_trade uuid, p_tracking text)
returns void language plpgsql security definer set search_path = public as $$
declare t record; trk text := trim(coalesce(p_tracking, ''));
begin
  if char_length(trk) < 6 then raise exception 'Indique le numéro de suivi du colis'; end if;
  select * into t from public.trades where id = p_trade for update;
  if t is null or t.status <> 'accepted' then raise exception 'Action impossible sur cet échange'; end if;
  if t.proposer_id = auth.uid() and t.proposer_shipped_at is null then
    update public.trades set proposer_tracking = left(trk, 60), proposer_shipped_at = now(), updated_at = now() where id = p_trade;
  elsif t.receiver_id = auth.uid() and t.receiver_shipped_at is null then
    update public.trades set receiver_tracking = left(trk, 60), receiver_shipped_at = now(), updated_at = now() where id = p_trade;
  else raise exception 'Action impossible sur cet échange';
  end if;
end $$;

-- J'ai reçu le colis de l'autre. Quand les DEUX colis sont reçus, les 48 h démarrent.
create or replace function public.receive_trade(p_trade uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t record;
begin
  select * into t from public.trades where id = p_trade for update;
  if t is null or t.status <> 'accepted' then raise exception 'Action impossible sur cet échange'; end if;
  if t.proposer_id = auth.uid() and t.receiver_shipped_at is not null and t.proposer_received_at is null then
    update public.trades set proposer_received_at = now(), updated_at = now() where id = p_trade;
  elsif t.receiver_id = auth.uid() and t.proposer_shipped_at is not null and t.receiver_received_at is null then
    update public.trades set receiver_received_at = now(), updated_at = now() where id = p_trade;
  else raise exception 'Action impossible : le colis n’a pas encore été envoyé';
  end if;
  update public.trades set review_deadline = now() + interval '48 hours'
   where id = p_trade and proposer_received_at is not null and receiver_received_at is not null and review_deadline is null;
end $$;

-- Tout est conforme de mon côté. Quand les deux ont validé, l'échange est terminé.
create or replace function public.validate_trade(p_trade uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t record;
begin
  select * into t from public.trades where id = p_trade for update;
  if t is null or t.status <> 'accepted' or t.review_deadline is null then raise exception 'Action impossible sur cet échange'; end if;
  if t.proposer_id = auth.uid() then update public.trades set proposer_ok = true, updated_at = now() where id = p_trade;
  elsif t.receiver_id = auth.uid() then update public.trades set receiver_ok = true, updated_at = now() where id = p_trade;
  else raise exception 'Action impossible sur cet échange';
  end if;
  update public.trades set status = 'completed', completed_at = now(), updated_at = now()
   where id = p_trade and proposer_ok and receiver_ok;
end $$;

-- Signaler un problème : tout reste bloqué, la modération tranche
create or replace function public.report_trade_problem(p_trade uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Décris le problème'; end if;
  update public.trades set status = 'problem', problem = left(trim(p_reason), 1000), problem_by = auth.uid(), updated_at = now()
   where id = p_trade and auth.uid() in (proposer_id, receiver_id) and status = 'accepted'
     and (review_deadline is null or review_deadline > now());
  if not found then raise exception 'Action impossible sur cet échange'; end if;
end $$;

-- Vérifications automatiques des échanges :
--  • un colis envoyé depuis 14 jours sans « reçu » ni problème signalé compte comme reçu
--    (délai réaliste : acheminement + attente possible en point relais) ;
--  • quand les deux colis sont reçus, les 48 h démarrent ;
--  • passé les 48 h sans problème signalé, l'échange est validé.
drop function if exists public.settle_trades();
create or replace function public.settle_trades()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.trades set proposer_received_at = receiver_shipped_at + interval '14 days', updated_at = now()
   where status = 'accepted' and proposer_received_at is null and receiver_shipped_at <= now() - interval '14 days';
  update public.trades set receiver_received_at = proposer_shipped_at + interval '14 days', updated_at = now()
   where status = 'accepted' and receiver_received_at is null and proposer_shipped_at <= now() - interval '14 days';
  update public.trades set review_deadline = now() + interval '48 hours', updated_at = now()
   where status = 'accepted' and review_deadline is null and proposer_received_at is not null and receiver_received_at is not null;
  update public.trades set status = 'completed', completed_at = now(), updated_at = now()
   where status = 'accepted' and review_deadline is not null and review_deadline <= now();
end $$;

-- Modération : trancher un litige
create or replace function public.admin_resolve_trade(p_trade uuid, p_outcome text)
returns void language plpgsql security definer set search_path = public as $$
declare t record;
begin
  if not public.is_admin() then raise exception 'Réservé à la modération'; end if;
  select * into t from public.trades where id = p_trade for update;
  if t is null or t.status not in ('accepted','problem') then raise exception 'Action impossible sur cet échange'; end if;
  if p_outcome = 'complete' then
    update public.trades set status = 'completed', completed_at = now(), updated_at = now() where id = p_trade;
  elsif p_outcome = 'cancel' then
    update public.trades set status = 'cancelled', refund_due_at = now() + interval '48 hours', updated_at = now() where id = p_trade;
    update public.listings set status = 'active' where id in (t.offered_listing, t.wanted_listing) and status = 'sold';
  else raise exception 'Décision inconnue';
  end if;
end $$;

revoke all on function public.propose_trade(uuid,uuid,numeric,text,text,text,text,text,text) from public, anon;
revoke all on function public.counter_trade(uuid,numeric,text,text,text,text,text) from public, anon;
revoke all on function public.respond_trade(uuid,boolean,text,text,text,text) from public, anon;
revoke all on function public.cancel_trade(uuid) from public, anon;
revoke all on function public.ship_trade(uuid,text) from public, anon;
revoke all on function public.receive_trade(uuid) from public, anon;
revoke all on function public.validate_trade(uuid) from public, anon;
revoke all on function public.report_trade_problem(uuid,text) from public, anon;
revoke all on function public.settle_trades() from public, anon;
revoke all on function public.admin_resolve_trade(uuid,text) from public, anon;
revoke all on function public.purchases_done(uuid) from public, anon;
grant execute on function public.propose_trade(uuid,uuid,numeric,text,text,text,text,text,text) to authenticated;
grant execute on function public.counter_trade(uuid,numeric,text,text,text,text,text) to authenticated;
grant execute on function public.respond_trade(uuid,boolean,text,text,text,text) to authenticated;
grant execute on function public.cancel_trade(uuid) to authenticated;
grant execute on function public.ship_trade(uuid,text) to authenticated;
grant execute on function public.receive_trade(uuid) to authenticated;
grant execute on function public.validate_trade(uuid) to authenticated;
grant execute on function public.report_trade_problem(uuid,text) to authenticated;
grant execute on function public.settle_trades() to authenticated;
grant execute on function public.admin_resolve_trade(uuid,text) to authenticated;

-- =====================================================================
-- 3. VÉRIFICATION AUTOMATIQUE DES DÉLAIS (toutes les 15 minutes)
--    Utilise l'extension pg_cron de Supabase. Si elle n'est pas disponible,
--    les délais sont quand même vérifiés à chaque visite du site.
-- =====================================================================
do $$ begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'revoo-delais';
  perform cron.schedule('revoo-delais', '*/15 * * * *', 'select public.settle_orders(); select public.settle_trades();');
exception when others then
  raise notice 'Vérification automatique non planifiée (%). Les délais sont vérifiés à chaque visite.', sqlerrm;
end $$;

-- Vérification : doit afficher deux tables (order_codes et trades)
select table_name from information_schema.tables where table_schema = 'public' and table_name in ('order_codes','trades');

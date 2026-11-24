-- =====================================================================
-- ORLEOO — paiement 100 % sur Orleoo (préparation Mangopay)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS tous les autres scripts. Peut être relancé sans risque.
--
-- Ce script :
--   1. bloque tout paiement ou échange de coordonnées en dehors d'Orleoo
--      (messages, annonces, propositions d'échange) ;
--   2. prépare les tables du paiement Mangopay (comptes, paiements, porte-monnaie,
--      virements) ;
--   3. ajoute le « mode de paiement » du site : 'demo' (aujourd'hui, aucun argent réel)
--      ou 'mangopay' (plus tard, quand le contrat et les clés seront prêts).
--
-- Tant que payment_mode = 'demo', RIEN ne change pour les commandes et échanges.
-- AUCUNE clé secrète n'est dans ce fichier : les clés Mangopay iront uniquement
-- dans les « Secrets » des Edge Functions Supabase.
-- =====================================================================

-- ---------- 1. INTERDIRE LE PAIEMENT EN DEHORS D'ORLEOO ----------
-- Renvoie la raison du blocage, ou null si le texte est correct.
create or replace function public.off_platform_reason(p_txt text)
returns text language plpgsql immutable set search_path = public as $$
declare t text; sq text;
begin
  if p_txt is null or p_txt = '' then return null; end if;
  t := lower(translate(p_txt, 'ÀÂÄÁÃÇÉÈÊËÎÏÍÔÖÓÙÛÜÚàâäáãçéèêëîïíôöóùûüú', 'AAAAACEEEEIIIOOOUUUUaaaaaceeeeiiiooouuuu'));
  sq := regexp_replace(t, '[^a-z]', '', 'g');
  if t ~ '[a-z0-9._%+-]+\s*(@|\(at\)|\[at\]|\yarobase\y)\s*[a-z0-9-]+\.[a-z]{2,}' then
    return 'une adresse e-mail';
  end if;
  if t ~ '(\+|00)\s*33[\s.-]*[1-9]([\s.-]*[0-9]{2}){4}' or t ~ '\y0[1-9]([\s.-]*[0-9]{2}){4}\y' then
    return 'un numéro de téléphone';
  end if;
  if t ~ '\yfr\s*[0-9]{2}(\s*[0-9a-z]{4}){5}' or t ~ '\y(iban|rib|bic)\y' then
    return 'des coordonnées bancaires';
  end if;
  if sq ~ '(paypal|westernunion|moneygram|mandatcash)'
     or t ~ '\y(lydia|wero|paylib|sumeria|revolut|virement|especes|liquide|cash)\y' then
    return 'un moyen de paiement extérieur à Orleoo';
  end if;
  if sq ~ 'whatsapp' or t ~ '\y(telegram|snapchat|snap|instagram|insta|messenger|signal)\y'
     or t ~ '\y(hors|en dehors)( du| de)? (site|orleoo|plateforme|appli|application)\y' then
    return 'une invitation à continuer en dehors d''Orleoo';
  end if;
  return null;
end $$;

create or replace function public.block_off_platform()
returns trigger language plpgsql security definer set search_path = public as $$
declare txt text; why text;
begin
  if public.is_admin() then return new; end if;
  if tg_table_name = 'messages' then
    txt := new.body;
  elsif tg_table_name = 'listings' then
    if tg_op = 'UPDATE' and new.title is not distinct from old.title
       and new.description is not distinct from old.description then return new; end if;
    txt := coalesce(new.title, '') || ' ' || coalesce(new.description, '');
  elsif tg_table_name = 'trades' then
    if tg_op = 'UPDATE' and new.message is not distinct from old.message then return new; end if;
    txt := new.message;
  end if;
  why := public.off_platform_reason(txt);
  if why is not null then
    raise exception 'Pour ta sécurité, tout se passe sur Orleoo : les paiements et les échanges de coordonnées en dehors du site sont interdits. Ton texte contient %. Retire-le puis réessaie.', why;
  end if;
  return new;
end $$;
revoke all on function public.block_off_platform() from public, anon, authenticated;

drop trigger if exists messages_off_platform on public.messages;
create trigger messages_off_platform before insert on public.messages
  for each row execute function public.block_off_platform();
drop trigger if exists listings_off_platform on public.listings;
create trigger listings_off_platform before insert or update on public.listings
  for each row execute function public.block_off_platform();
drop trigger if exists trades_off_platform on public.trades;
create trigger trades_off_platform before insert or update on public.trades
  for each row execute function public.block_off_platform();

-- ---------- 2. MODE DE PAIEMENT DU SITE ----------
alter table public.site_settings add column if not exists payment_mode text not null default 'demo';
do $$ begin
  alter table public.site_settings add constraint site_settings_payment_mode_check check (payment_mode in ('demo','mangopay'));
exception when duplicate_object then null; end $$;

create or replace function public.payment_mode()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select payment_mode from public.site_settings where id = 1), 'demo');
$$;
grant execute on function public.payment_mode() to anon, authenticated;

-- En mode Mangopay, plus aucune commande « démo » ne peut être créée :
-- une commande n'existe qu'après un paiement réussi (voir finalize_checkout).
create or replace function public.orders_require_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.payment_mode() = 'mangopay' and new.demo then
    raise exception 'Le paiement passe obligatoirement par Orleoo : recommence depuis ton panier.';
  end if;
  return new;
end $$;
drop trigger if exists orders_require_payment on public.orders;
create trigger orders_require_payment before insert on public.orders
  for each row execute function public.orders_require_payment();

-- ---------- 3. COMPTES DE PAIEMENT (un par membre, chez Mangopay) ----------
create table if not exists public.payment_accounts (
  user_id          uuid primary key references public.profiles(id) on delete cascade,
  provider         text not null default 'mangopay',
  provider_user_id text unique,
  wallet_id        text unique,
  kyc_status       text not null default 'aucun' check (kyc_status in ('aucun','en_cours','valide','refuse')),
  bank_account_id  text,
  iban_last4       text check (char_length(iban_last4) <= 4),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.payment_accounts enable row level security;
drop policy if exists "mon compte de paiement" on public.payment_accounts;
create policy "mon compte de paiement" on public.payment_accounts
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
-- Aucune écriture depuis le site : seule l'Edge Function (clé serveur) écrit ici.

-- ---------- 4. PAIEMENTS (panier ou complément d'échange) ----------
create table if not exists public.checkouts (
  id                uuid primary key default gen_random_uuid(),
  buyer_id          uuid not null references public.profiles(id) on delete cascade,
  kind              text not null default 'achat' check (kind in ('achat','echange')),
  items             jsonb not null default '[]'::jsonb,
  trade_id          uuid references public.trades(id) on delete set null,
  ship_name         text check (char_length(ship_name) <= 80),
  ship_address      text check (char_length(ship_address) <= 200),
  ship_zip          text check (char_length(ship_zip) <= 10),
  ship_city         text check (char_length(ship_city) <= 80),
  amount            numeric(10,2) not null check (amount >= 0),
  fee               numeric(10,2) not null default 0 check (fee >= 0),
  status            text not null default 'en_attente'
                    check (status in ('en_attente','paye','echoue','expire','rembourse')),
  provider          text not null default 'mangopay',
  provider_payin_id text unique,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null default now() + interval '30 minutes',
  paid_at           timestamptz
);
create index if not exists checkouts_buyer_idx on public.checkouts (buyer_id, created_at desc);
alter table public.checkouts enable row level security;
drop policy if exists "mes paiements" on public.checkouts;
create policy "mes paiements" on public.checkouts
  for select to authenticated using (buyer_id = auth.uid() or public.is_admin());

-- Le complément d'un échange doit être payé avant l'envoi des colis (mode Mangopay)
alter table public.trades add column if not exists topup_paid boolean not null default false;
alter table public.trades add column if not exists checkout_id uuid references public.checkouts(id) on delete set null;

-- ---------- 5. PORTE-MONNAIE ET VIREMENTS ----------
create table if not exists public.wallet_moves (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  order_id     uuid references public.orders(id) on delete set null,
  trade_id     uuid references public.trades(id) on delete set null,
  kind         text not null check (kind in ('vente','complement','remboursement','virement','frais')),
  amount       numeric(10,2) not null,
  status       text not null default 'bloque' check (status in ('bloque','disponible','verse','annule')),
  provider_ref text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists wallet_moves_user_idx on public.wallet_moves (user_id, created_at desc);
alter table public.wallet_moves enable row level security;
drop policy if exists "mes mouvements" on public.wallet_moves;
create policy "mes mouvements" on public.wallet_moves
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

create table if not exists public.payout_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  amount       numeric(10,2) not null check (amount > 0),
  status       text not null default 'demande' check (status in ('demande','envoye','echoue')),
  provider_ref text,
  created_at   timestamptz not null default now(),
  sent_at      timestamptz
);
alter table public.payout_requests enable row level security;
drop policy if exists "mes virements" on public.payout_requests;
create policy "mes virements" on public.payout_requests
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- ---------- 6. DÉMARRER UN PAIEMENT (mode Mangopay) ----------
-- Réserve les articles 30 minutes et calcule le montant. Le paiement par carte est
-- ensuite créé par l'Edge Function « orleoo-paiement » (clé serveur Mangopay).
create or replace function public.start_checkout(
  p_items jsonb, p_name text default null, p_address text default null, p_zip text default null, p_city text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; l record; dlv text; total numeric := 0; fees numeric := 0; clean jsonb := '[]'::jsonb; cid uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if public.payment_mode() <> 'mangopay' then raise exception 'Le paiement par carte n''est pas encore ouvert'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Panier vide'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Trop d’articles dans le panier'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    dlv := it->>'delivery';
    select * into l from public.listings where id = (it->>'listing')::uuid for update;
    if l is null or l.status <> 'active' then raise exception 'Un article de ton panier n’est plus disponible'; end if;
    if l.seller_id = auth.uid() then raise exception 'Tu ne peux pas acheter ton propre article'; end if;
    if dlv not in ('main_propre','colis') then raise exception 'Mode de livraison invalide'; end if;
    if dlv = 'colis' and (coalesce(trim(p_name),'') = '' or coalesce(trim(p_address),'') = ''
       or coalesce(trim(p_zip),'') = '' or coalesce(trim(p_city),'') = '') then
      raise exception 'Adresse de livraison incomplète';
    end if;
    total := total + l.price; fees := fees + 1.00;   -- mêmes frais que create_cart_orders
    clean := clean || jsonb_build_object('listing', l.id, 'delivery', dlv, 'price', l.price);
    update public.listings set status = 'sold' where id = l.id;   -- réservé pendant le paiement
  end loop;
  insert into public.checkouts (buyer_id, kind, items, ship_name, ship_address, ship_zip, ship_city, amount, fee)
  values (auth.uid(), 'achat', clean, nullif(trim(p_name),''), nullif(trim(p_address),''),
          nullif(trim(p_zip),''), nullif(trim(p_city),''), total, fees)
  returning id into cid;
  return cid;
end $$;
revoke all on function public.start_checkout(jsonb,text,text,text,text) from public, anon;
grant execute on function public.start_checkout(jsonb,text,text,text,text) to authenticated;

-- ---------- 7. APRÈS LE PAIEMENT (appelé UNIQUEMENT par l'Edge Function) ----------
create or replace function public.finalize_checkout(p_checkout uuid, p_payin text)
returns void language plpgsql security definer set search_path = public as $$
declare c record; it jsonb; l record; dlv text;
begin
  select * into c from public.checkouts where id = p_checkout for update;
  if c is null then raise exception 'Paiement introuvable'; end if;
  if c.status = 'paye' then return; end if;                       -- déjà traité (webhook reçu deux fois)
  if c.status <> 'en_attente' then raise exception 'Paiement déjà clos'; end if;
  update public.checkouts set status = 'paye', paid_at = now(), provider_payin_id = p_payin where id = c.id;
  if c.kind = 'echange' then
    update public.trades set topup_paid = true, updated_at = now() where id = c.trade_id;
    return;
  end if;
  for it in select * from jsonb_array_elements(c.items) loop
    dlv := it->>'delivery';
    select * into l from public.listings where id = (it->>'listing')::uuid;
    insert into public.orders (listing_id, buyer_id, seller_id, title, photo, price, fee, delivery,
                               ship_name, ship_address, ship_zip, ship_city, demo, payment_id)
    values (l.id, c.buyer_id, l.seller_id, l.title, l.photos[1], (it->>'price')::numeric, 1.00, dlv,
            case when dlv='colis' then c.ship_name end, case when dlv='colis' then c.ship_address end,
            case when dlv='colis' then c.ship_zip end, case when dlv='colis' then c.ship_city end,
            false, c.id);
    insert into public.wallet_moves (user_id, kind, amount, status, provider_ref)
    values (l.seller_id, 'vente', (it->>'price')::numeric, 'bloque', p_payin);
    insert into public.conversations (listing_id, buyer_id, seller_id)
    values (l.id, c.buyer_id, l.seller_id) on conflict (listing_id, buyer_id) do nothing;
  end loop;
end $$;

create or replace function public.fail_checkout(p_checkout uuid, p_status text default 'echoue')
returns void language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from public.checkouts where id = p_checkout for update;
  if c is null or c.status <> 'en_attente' then return; end if;
  update public.checkouts set status = case when p_status = 'expire' then 'expire' else 'echoue' end where id = c.id;
  if c.kind = 'achat' then
    update public.listings set status = 'active'
    where id in (select (x->>'listing')::uuid from jsonb_array_elements(c.items) x) and status = 'sold'
      and not exists (select 1 from public.orders o where o.listing_id = listings.id and o.status <> 'cancelled');
  end if;
end $$;

-- Libère les articles des paiements abandonnés (à lancer régulièrement, comme settle_orders)
create or replace function public.expire_checkouts()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from public.checkouts where status = 'en_attente' and expires_at <= now() loop
    perform public.fail_checkout(r.id, 'expire');
  end loop;
end $$;

revoke all on function public.finalize_checkout(uuid,text) from public, anon, authenticated;
revoke all on function public.fail_checkout(uuid,text) from public, anon, authenticated;
revoke all on function public.expire_checkouts() from public, anon;
grant execute on function public.expire_checkouts() to authenticated;

select 'Paiement sécurisé prêt : mode ' || public.payment_mode() as info;

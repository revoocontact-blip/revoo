-- =====================================================================
-- ORLEOO — « Faire une offre » + réductions sur les lots
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-frais.sql. Peut être relancé sans risque.
--
-- Offres :
--   • l'acheteur propose un prix (au moins 50 % du prix affiché) ;
--   • le vendeur accepte, refuse ou fait une contre-offre (une seule) ;
--   • une offre sans réponse expire au bout de 48 h ;
--   • une offre acceptée donne 48 h à l'acheteur pour payer à ce prix.
-- Lots :
--   • chaque vendeur choisit une réduction dès 2, 3 et 5 articles achetés chez lui ;
--   • la réduction s'applique aux articles sans offre acceptée.
-- Le prix payé est TOUJOURS recalculé ici, sur le serveur.
-- Mode vitrine (achats pas encore ouverts) : une offre acceptée garde son prix,
--   et les 48 h pour payer démarrent à l'ouverture des achats :
--   update public.site_settings set achats_ouverts = true where id = 1;
-- =====================================================================

-- ---------- 1. RÉDUCTIONS SUR LES LOTS (réglées par le vendeur) ----------
alter table public.profiles add column if not exists lot2 smallint not null default 0;
alter table public.profiles add column if not exists lot3 smallint not null default 0;
alter table public.profiles add column if not exists lot5 smallint not null default 0;
do $$ begin
  alter table public.profiles add constraint profiles_lots_check
    check (lot2 between 0 and 50 and lot3 between 0 and 50 and lot5 between 0 and 50);
exception when duplicate_object then null; end $$;

-- Réduction (en %) pour p_n articles achetés ensemble chez ce vendeur
create or replace function public.lot_percent(p_seller uuid, p_n int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select greatest(
           case when p_n >= 2 then lot2 else 0 end,
           case when p_n >= 3 then lot3 else 0 end,
           case when p_n >= 5 then lot5 else 0 end)
         from public.profiles where id = p_seller), 0);
$$;
grant execute on function public.lot_percent(uuid, int) to anon, authenticated;

-- ---------- 2. OFFRES ----------
alter table public.site_settings add column if not exists achats_ouverts boolean not null default false;
create or replace function public.achats_ouverts()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select achats_ouverts from public.site_settings where id = 1), false);
$$;
grant execute on function public.achats_ouverts() to anon, authenticated;

create table if not exists public.offers (
  id          uuid primary key default gen_random_uuid(),
  listing_id  uuid not null references public.listings(id) on delete cascade,
  buyer_id    uuid not null references public.profiles(id) on delete cascade,
  seller_id   uuid not null references public.profiles(id) on delete cascade,
  list_price  numeric(10,2) not null,                 -- prix affiché au moment de l'offre
  amount      numeric(10,2) not null check (amount > 0),
  status      text not null default 'en_attente'
              check (status in ('en_attente','contre','acceptee','refusee','annulee','expiree','utilisee')),
  countered   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '48 hours',   -- délai pour répondre
  valid_until timestamptz,                                               -- délai pour payer (offre acceptée)
  used_at     timestamptz,
  check (buyer_id <> seller_id)
);
create index if not exists offers_buyer_idx on public.offers (buyer_id, created_at desc);
create index if not exists offers_seller_idx on public.offers (seller_id, created_at desc);
create index if not exists offers_listing_idx on public.offers (listing_id, status);
alter table public.offers enable row level security;
drop policy if exists "offres : voir les miennes" on public.offers;
create policy "offres : voir les miennes" on public.offers for select to authenticated
  using (auth.uid() in (buyer_id, seller_id) or public.is_admin());
-- aucune écriture directe : tout passe par les fonctions ci-dessous
revoke insert, update, delete on public.offers from anon, authenticated;

create or replace function public.eur_txt(p numeric)
returns text language sql immutable as $$
  select replace(to_char(p, 'FM999990.00'), '.', ',') || ' €';
$$;

-- Les offres trop vieilles expirent
create or replace function public.expire_offers()
returns void language sql security definer set search_path = public as $$
  update public.offers set status = 'expiree', updated_at = now()
   where (status in ('en_attente','contre') and expires_at < now())
      or (status = 'acceptee' and valid_until is not null and valid_until < now());
$$;
grant execute on function public.expire_offers() to authenticated;

-- Message automatique dans la conversation acheteur / vendeur
create or replace function public.offer_message(o public.offers, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare conv uuid;
begin
  insert into public.conversations (listing_id, buyer_id, seller_id)
  values (o.listing_id, o.buyer_id, o.seller_id) on conflict (listing_id, buyer_id) do nothing;
  select id into conv from public.conversations where listing_id = o.listing_id and buyer_id = o.buyer_id;
  insert into public.messages (conversation_id, sender_id, body) values (conv, auth.uid(), p_text);
exception when others then
  raise warning 'message d''offre non envoyé : %', sqlerrm;
end $$;
revoke all on function public.offer_message(public.offers, text) from public, anon, authenticated;

-- L'acheteur fait une offre
create or replace function public.make_offer(p_listing uuid, p_amount numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); l record; amt numeric := round(coalesce(p_amount, 0), 2); o public.offers; vac boolean;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  perform public.expire_offers();
  select * into l from public.listings where id = p_listing;
  if l is null or l.status <> 'active' then raise exception 'Cet article n’est plus disponible'; end if;
  if l.seller_id = me then raise exception 'Tu ne peux pas faire une offre sur ton propre article'; end if;
  select vacation into vac from public.profiles where id = l.seller_id;
  if coalesce(vac, false) then raise exception 'Le vendeur est en vacances : réessaie à son retour'; end if;
  if amt >= l.price then raise exception 'Ton offre doit être inférieure au prix affiché'; end if;
  if amt < greatest(1, ceil(l.price * 50) / 100) then
    raise exception 'Ton offre doit être d’au moins % (la moitié du prix)', public.eur_txt(greatest(1, ceil(l.price * 50) / 100));
  end if;
  if exists (select 1 from public.offers where listing_id = l.id and buyer_id = me and status in ('en_attente','contre')) then
    raise exception 'Tu as déjà une offre en cours sur cet article';
  end if;
  if exists (select 1 from public.offers where listing_id = l.id and buyer_id = me and status = 'acceptee') then
    raise exception 'Ton offre est déjà acceptée : tu peux acheter l’article à ce prix';
  end if;
  if (select count(*) from public.offers where listing_id = l.id and buyer_id = me and created_at > now() - interval '7 days') >= 3 then
    raise exception 'Tu as déjà fait 3 offres sur cet article cette semaine';
  end if;
  if (select count(*) from public.offers where buyer_id = me and created_at > now() - interval '1 day') >= 25 then
    raise exception 'Tu as fait beaucoup d’offres aujourd’hui : réessaie demain';
  end if;
  insert into public.offers (listing_id, buyer_id, seller_id, list_price, amount)
  values (l.id, me, l.seller_id, l.price, amt) returning * into o;
  perform public.offer_message(o, 'Offre : ' || public.eur_txt(amt) || ' au lieu de ' || public.eur_txt(l.price)
    || ' pour « ' || left(l.title, 80) || ' ». Réponds depuis Mon compte › Offres (48 h).');
  return o.id;
end $$;
revoke all on function public.make_offer(uuid, numeric) from public, anon;
grant execute on function public.make_offer(uuid, numeric) to authenticated;

-- Répondre : 'accepter', 'refuser', 'contre' (vendeur, avec p_amount) ou 'annuler' (acheteur)
create or replace function public.respond_offer(p_offer uuid, p_action text, p_amount numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o public.offers; l record; amt numeric := round(coalesce(p_amount, 0), 2);
begin
  if me is null then raise exception 'Connexion requise'; end if;
  perform public.expire_offers();
  select * into o from public.offers where id = p_offer for update;
  if o is null or me not in (o.buyer_id, o.seller_id) then raise exception 'Offre introuvable'; end if;
  if o.status not in ('en_attente','contre') then raise exception 'Cette offre n’attend plus de réponse'; end if;
  select * into l from public.listings where id = o.listing_id;

  if p_action = 'annuler' then
    if me <> o.buyer_id or o.status <> 'en_attente' then raise exception 'Action impossible'; end if;
    update public.offers set status = 'annulee', updated_at = now() where id = o.id;
    perform public.offer_message(o, 'J’ai retiré mon offre de ' || public.eur_txt(o.amount) || '.');
    return;
  end if;

  -- c'est au vendeur de répondre à une offre, à l'acheteur de répondre à une contre-offre
  if (o.status = 'en_attente' and me <> o.seller_id) or (o.status = 'contre' and me <> o.buyer_id) then
    raise exception 'Attends la réponse de l’autre personne';
  end if;

  if p_action = 'refuser' then
    update public.offers set status = 'refusee', updated_at = now() where id = o.id;
    perform public.offer_message(o, case when me = o.seller_id
      then 'Offre de ' || public.eur_txt(o.amount) || ' refusée.'
      else 'Contre-offre de ' || public.eur_txt(o.amount) || ' refusée.' end);
    return;
  end if;

  if l is null or l.status <> 'active' then raise exception 'Cet article n’est plus disponible'; end if;

  if p_action = 'accepter' then
    if o.amount >= l.price then raise exception 'Le prix de l’article a baissé : il est déjà plus bas que cette offre'; end if;
    update public.offers set status = 'acceptee',
      valid_until = case when public.achats_ouverts() then now() + interval '48 hours' end,   -- vitrine : 48 h dès l'ouverture
      updated_at = now() where id = o.id;
    perform public.offer_message(o, case when me = o.seller_id
      then 'Offre acceptée : « ' || left(l.title, 80) || ' » est à ' || public.eur_txt(o.amount) || ' pour toi '
           || case when public.achats_ouverts() then 'pendant 48 h.' else 'pendant 48 h dès l’ouverture des achats.' end
      else 'J’accepte la contre-offre : ' || public.eur_txt(o.amount) || '.' end);
    return;
  end if;

  if p_action = 'contre' then
    if me <> o.seller_id or o.countered then raise exception 'Une seule contre-offre possible'; end if;
    if amt <= o.amount or amt >= l.price then
      raise exception 'Ta contre-offre doit être entre % et %', public.eur_txt(o.amount), public.eur_txt(l.price);
    end if;
    update public.offers set status = 'contre', amount = amt, countered = true,
      expires_at = now() + interval '48 hours', updated_at = now() where id = o.id;
    o.amount := amt;
    perform public.offer_message(o, 'Contre-offre : ' || public.eur_txt(amt) || '. Réponds depuis Mon compte › Offres (48 h).');
    return;
  end if;

  raise exception 'Action inconnue';
end $$;
revoke all on function public.respond_offer(uuid, text, numeric) from public, anon;
grant execute on function public.respond_offer(uuid, text, numeric) to authenticated;

-- Article vendu, retiré ou réservé : les offres sans réponse tombent
create or replace function public.listing_close_offers()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'active' and old.status = 'active' then
    update public.offers set status = 'annulee', updated_at = now()
     where listing_id = new.id and status in ('en_attente','contre');
  end if;
  return new;
end $$;
revoke all on function public.listing_close_offers() from public, anon, authenticated;
drop trigger if exists listings_close_offers on public.listings;
create trigger listings_close_offers after update of status on public.listings
  for each row execute function public.listing_close_offers();

-- ---------- 3. PRIX PAYÉ (offre acceptée, sinon réduction de lot) ----------
create or replace function public.item_price(p_listing uuid, p_buyer uuid, p_n int)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare l record; o numeric;
begin
  select price, seller_id into l from public.listings where id = p_listing;
  select min(amount) into o from public.offers
   where listing_id = p_listing and buyer_id = p_buyer and status = 'acceptee' and (valid_until is null or valid_until > now());
  if o is not null then return least(o, l.price); end if;
  return round(l.price * (100 - public.lot_percent(l.seller_id, coalesce(p_n, 1))) / 100.0, 2);
end $$;
revoke all on function public.item_price(uuid, uuid, int) from public, anon, authenticated;

-- Nombre d'articles par vendeur dans un panier
create or replace function public.cart_counts(p_items jsonb)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) from (
    select l.seller_id::text s, count(distinct l.id) n
    from jsonb_array_elements(p_items) e join public.listings l on l.id = (e->>'listing')::uuid
    group by 1) x;
$$;
revoke all on function public.cart_counts(jsonb) from public, anon, authenticated;

-- Commande d'un article (démo)
CREATE OR REPLACE FUNCTION public.create_order(p_listing uuid, p_delivery text, p_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_zip text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare l record; new_id uuid; pr numeric;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  select * into l from public.listings where id = p_listing for update;
  if l is null or l.status <> 'active' then raise exception 'Article indisponible'; end if;
  if l.seller_id = auth.uid() then raise exception 'Tu ne peux pas acheter ton propre article'; end if;
  if p_delivery not in ('main_propre','colis') then raise exception 'Mode de livraison invalide'; end if;
  if p_delivery = 'colis' and (coalesce(trim(p_name),'') = '' or coalesce(trim(p_address),'') = ''
     or coalesce(trim(p_zip),'') = '' or coalesce(trim(p_city),'') = '') then
    raise exception 'Adresse de livraison incomplète';
  end if;
  pr := public.item_price(l.id, auth.uid(), 1);

  insert into public.orders (listing_id, buyer_id, seller_id, title, photo, price, fee, delivery,
                             ship_name, ship_address, ship_zip, ship_city, demo)
  values (l.id, auth.uid(), l.seller_id, l.title, l.photos[1], pr, public.order_fee(pr), p_delivery,
          nullif(trim(p_name),''), nullif(trim(p_address),''), nullif(trim(p_zip),''), nullif(trim(p_city),''), true)
  returning id into new_id;

  update public.offers set status = 'utilisee', used_at = now(), updated_at = now()
   where listing_id = l.id and buyer_id = auth.uid() and status = 'acceptee';
  -- L'article est réservé : il disparaît du catalogue
  update public.listings set status = 'sold' where id = l.id;

  -- Ouvre (ou retrouve) la conversation acheteur / vendeur
  insert into public.conversations (listing_id, buyer_id, seller_id)
  values (l.id, auth.uid(), l.seller_id)
  on conflict (listing_id, buyer_id) do nothing;

  return new_id;
end $function$;

-- Panier (démo)
CREATE OR REPLACE FUNCTION public.create_cart_orders(p_items jsonb, p_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_zip text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare it jsonb; l record; pay uuid := gen_random_uuid(); dlv text; n int := 0; cnt jsonb; pr numeric;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Panier vide'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Trop d’articles dans le panier'; end if;
  cnt := public.cart_counts(p_items);
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
    pr := public.item_price(l.id, auth.uid(), (cnt->>l.seller_id::text)::int);
    insert into public.orders (listing_id, buyer_id, seller_id, title, photo, price, fee, delivery,
                               ship_name, ship_address, ship_zip, ship_city, demo, payment_id)
    values (l.id, auth.uid(), l.seller_id, l.title, l.photos[1], pr, public.order_fee(pr), dlv,
            case when dlv='colis' then nullif(trim(p_name),'') end, case when dlv='colis' then nullif(trim(p_address),'') end,
            case when dlv='colis' then nullif(trim(p_zip),'') end, case when dlv='colis' then nullif(trim(p_city),'') end,
            true, pay);
    update public.offers set status = 'utilisee', used_at = now(), updated_at = now()
     where listing_id = l.id and buyer_id = auth.uid() and status = 'acceptee';
    update public.listings set status = 'sold' where id = l.id;
    insert into public.conversations (listing_id, buyer_id, seller_id)
    values (l.id, auth.uid(), l.seller_id) on conflict (listing_id, buyer_id) do nothing;
    n := n + 1;
  end loop;
  return pay;
end $function$;

-- Paiement réel (Mangopay) : prix figés au début du paiement
create or replace function public.start_checkout(
  p_items jsonb, p_name text default null, p_address text default null, p_zip text default null, p_city text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare it jsonb; l record; dlv text; total numeric := 0; fees numeric := 0; clean jsonb := '[]'::jsonb; cid uuid; cnt jsonb; pr numeric;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if public.payment_mode() <> 'mangopay' then raise exception 'Le paiement par carte n''est pas encore ouvert'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Panier vide'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Trop d’articles dans le panier'; end if;
  cnt := public.cart_counts(p_items);
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
    pr := public.item_price(l.id, auth.uid(), (cnt->>l.seller_id::text)::int);
    total := total + pr; fees := fees + public.order_fee(pr);
    clean := clean || jsonb_build_object('listing', l.id, 'delivery', dlv, 'price', pr, 'fee', public.order_fee(pr));
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
    values (l.id, c.buyer_id, l.seller_id, l.title, l.photos[1], (it->>'price')::numeric, coalesce((it->>'fee')::numeric, public.order_fee((it->>'price')::numeric)), dlv,
            case when dlv='colis' then c.ship_name end, case when dlv='colis' then c.ship_address end,
            case when dlv='colis' then c.ship_zip end, case when dlv='colis' then c.ship_city end,
            false, c.id);
    update public.offers set status = 'utilisee', used_at = now(), updated_at = now()
     where listing_id = l.id and buyer_id = c.buyer_id and status = 'acceptee';
    insert into public.wallet_moves (user_id, kind, amount, status, provider_ref)
    values (l.seller_id, 'vente', (it->>'price')::numeric, 'bloque', p_payin);
    insert into public.conversations (listing_id, buyer_id, seller_id)
    values (l.id, c.buyer_id, l.seller_id) on conflict (listing_id, buyer_id) do nothing;
  end loop;
end $$;

-- Ouverture des achats : les offres acceptées pendant la vitrine ont 48 h à partir de maintenant
create or replace function public.open_purchases_offers()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.achats_ouverts and not coalesce(old.achats_ouverts, false) then
    update public.offers set valid_until = now() + interval '48 hours', updated_at = now()
     where status = 'acceptee' and valid_until is null;
  end if;
  return new;
end $$;
revoke all on function public.open_purchases_offers() from public, anon, authenticated;
drop trigger if exists site_settings_open_offers on public.site_settings;
create trigger site_settings_open_offers after update of achats_ouverts on public.site_settings
  for each row execute function public.open_purchases_offers();

-- Expiration automatique toutes les 15 minutes (avec les autres délais)
do $$ begin
  perform cron.schedule('revoo-delais', '*/15 * * * *',
    'select public.settle_orders(); select public.settle_trades(); select public.expire_offers();');
exception when others then raise notice 'pg_cron indisponible : les offres expireront à la prochaine visite'; end $$;

select 'Offres et lots prêts' as info;

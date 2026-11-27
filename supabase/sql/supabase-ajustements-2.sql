-- =====================================================================
-- ORLEOO — ajustements n°2 du fondateur (27/11/2026)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-ajustements.sql. Peut être relancé sans risque.
--   • l'échange est ouvert à tous (plus besoin de 3 achats) ;
--   • les articles sont réservés 5 minutes pendant le paiement ;
--   • le panier n'a plus de limite d'articles ;
--   • identifiant : 2 changements gratuits, les suivants seront payants ;
--   • 5 styles : Casual, Chic, Sport, Streetwear, Vintage.
-- =====================================================================

-- ---------- Échange ouvert à tous ----------
CREATE OR REPLACE FUNCTION public.propose_trade(p_offered uuid, p_wanted uuid, p_topup numeric, p_message text, p_name text, p_address text, p_zip text, p_city text, p_topup_from text DEFAULT 'proposer'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; b record; new_id uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.respond_trade(p_trade uuid, p_accept boolean, p_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_zip text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; n int;
begin
  select * into t from public.trades where id = p_trade for update;
  if t is null or auth.uid() not in (t.proposer_id, t.receiver_id) or t.status <> 'proposed' then raise exception 'Action impossible sur cet échange'; end if;
  if not p_accept then
    update public.trades set status = case when auth.uid() = t.proposer_id then 'cancelled' else 'declined' end, updated_at = now() where id = p_trade;
    return;
  end if;
  if t.turn is distinct from auth.uid() then raise exception 'Attends la réponse de l’autre personne'; end if;
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
end $function$;

-- ---------- Réservation de 5 minutes pendant le paiement ----------
alter table public.checkouts alter column expires_at set default now() + interval '5 minutes';

-- ---------- Panier sans limite d'articles ----------
CREATE OR REPLACE FUNCTION public.create_cart_orders(p_items jsonb, p_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_zip text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare it jsonb; l record; pay uuid := gen_random_uuid(); dlv text; n int := 0; cnt jsonb; pr numeric;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Panier vide'; end if;
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

CREATE OR REPLACE FUNCTION public.start_checkout(p_items jsonb, p_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_zip text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare it jsonb; l record; dlv text; total numeric := 0; fees numeric := 0; clean jsonb := '[]'::jsonb; cid uuid; cnt jsonb; pr numeric;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if public.payment_mode() <> 'mangopay' then raise exception 'Le paiement par carte n''est pas encore ouvert'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Panier vide'; end if;
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
end $function$;

-- ---------- Identifiant : 2 changements gratuits ----------
CREATE OR REPLACE FUNCTION public.enforce_username_rule()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare next_ok timestamptz;
begin
  if new.name is distinct from old.name and not public.is_admin() then
    if old.username_changes >= 2 then
      raise exception 'Tu as utilisé tes 2 changements gratuits d’identifiant : les suivants seront payants (bientôt disponible)';
    end if;
    next_ok := coalesce(old.username_changed_at, old.created_at) + interval '30 days';
    if now() < next_ok then
      raise exception 'Tu pourras modifier ton identifiant à partir du %', to_char(next_ok at time zone 'Europe/Paris', 'DD/MM/YYYY');
    end if;
    new.username_changes := old.username_changes + 1;
    new.username_changed_at := now();
  else
    new.username_changes := old.username_changes;
    new.username_changed_at := old.username_changed_at;
  end if;
  return new;
end $function$;

-- ---------- 5 styles ----------
update public.listings set style = 'Casual' where style in ('Doux','Bohème');
alter table public.listings drop constraint if exists listings_style_check;
alter table public.listings add constraint listings_style_check check (style = any (array['Vintage','Streetwear','Chic','Casual','Sport']));

select 'Ajustements n°2 appliqués' as info;

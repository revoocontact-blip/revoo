-- =====================================================================
-- ORLEOO — frais acheteur : 5 % du prix + 0,70 € par article
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-paiement-securise.sql. Peut être relancé sans risque.
-- Pour changer plus tard (exemple 4 % + 0,50 €) :
--   update public.site_settings set fee_percent = 4, fee_fixed = 0.50 where id = 1;
--   (et les mêmes valeurs dans index.html : fraisPourcent / fraisFixes)
-- =====================================================================
-- Frais acheteur par article : pourcentage du prix + montant fixe (réglables ici)
alter table public.site_settings add column if not exists fee_percent numeric(5,2) not null default 5;
alter table public.site_settings add column if not exists fee_fixed numeric(10,2) not null default 0.70;
create or replace function public.order_fee(p_price numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select round(coalesce(p_price,0) * coalesce((select fee_percent from public.site_settings where id = 1), 5) / 100
               + coalesce((select fee_fixed from public.site_settings where id = 1), 0.70), 2);
$$;
grant execute on function public.order_fee(numeric) to anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_order(p_listing uuid, p_delivery text, p_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_zip text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l record; new_id uuid;
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

  insert into public.orders (listing_id, buyer_id, seller_id, title, photo, price, fee, delivery,
                             ship_name, ship_address, ship_zip, ship_city, demo)
  values (l.id, auth.uid(), l.seller_id, l.title, l.photos[1], l.price, public.order_fee(l.price), p_delivery,
          nullif(trim(p_name),''), nullif(trim(p_address),''), nullif(trim(p_zip),''), nullif(trim(p_city),''), true)
  returning id into new_id;

  -- L'article est réservé : il disparaît du catalogue
  update public.listings set status = 'sold' where id = l.id;

  -- Ouvre (ou retrouve) la conversation acheteur / vendeur
  insert into public.conversations (listing_id, buyer_id, seller_id)
  values (l.id, auth.uid(), l.seller_id)
  on conflict (listing_id, buyer_id) do nothing;

  return new_id;
end $function$;

CREATE OR REPLACE FUNCTION public.create_cart_orders(p_items jsonb, p_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_zip text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare it jsonb; l record; pay uuid := gen_random_uuid(); dlv text; n int := 0;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
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
    insert into public.orders (listing_id, buyer_id, seller_id, title, photo, price, fee, delivery,
                               ship_name, ship_address, ship_zip, ship_city, demo, payment_id)
    values (l.id, auth.uid(), l.seller_id, l.title, l.photos[1], l.price, public.order_fee(l.price), dlv,
            case when dlv='colis' then nullif(trim(p_name),'') end, case when dlv='colis' then nullif(trim(p_address),'') end,
            case when dlv='colis' then nullif(trim(p_zip),'') end, case when dlv='colis' then nullif(trim(p_city),'') end,
            true, pay);
    update public.listings set status = 'sold' where id = l.id;
    insert into public.conversations (listing_id, buyer_id, seller_id)
    values (l.id, auth.uid(), l.seller_id) on conflict (listing_id, buyer_id) do nothing;
    n := n + 1;
  end loop;
  return pay;
end $function$;

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
    total := total + l.price; fees := fees + public.order_fee(l.price);   -- mêmes frais que create_cart_orders
    clean := clean || jsonb_build_object('listing', l.id, 'delivery', dlv, 'price', l.price, 'fee', public.order_fee(l.price));
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
    insert into public.wallet_moves (user_id, kind, amount, status, provider_ref)
    values (l.seller_id, 'vente', (it->>'price')::numeric, 'bloque', p_payin);
    insert into public.conversations (listing_id, buyer_id, seller_id)
    values (l.id, c.buyer_id, l.seller_id) on conflict (listing_id, buyer_id) do nothing;
  end loop;
end $$;

select 'Frais : ' || (select fee_percent from public.site_settings where id = 1) || ' % + '
       || (select fee_fixed from public.site_settings where id = 1) || ' € par article' as info;

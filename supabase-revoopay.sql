-- =====================================================================
-- REVOO PAY — commandes (interface ; le paiement Mangopay sera branché plus tard)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- (À lancer après les autres scripts. Peut être relancé sans risque.)
--
-- Tant que Mangopay n'est pas branché, chaque commande est marquée demo = true :
-- AUCUN argent n'est encaissé.
-- =====================================================================

-- ---------- 1. COMMANDES ----------
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid references public.listings(id) on delete set null,
  buyer_id      uuid not null references public.profiles(id) on delete cascade,
  seller_id     uuid not null references public.profiles(id) on delete cascade,
  title         text not null,
  photo         text,
  price         numeric(10,2) not null check (price >= 0),
  fee           numeric(10,2) not null check (fee >= 0),
  delivery      text not null check (delivery in ('main_propre','colis')),
  ship_name     text check (char_length(ship_name) <= 80),
  ship_address  text check (char_length(ship_address) <= 200),
  ship_zip      text check (char_length(ship_zip) <= 10),
  ship_city     text check (char_length(ship_city) <= 80),
  status        text not null default 'paid' check (status in ('paid','shipped','received','problem','cancelled')),
  tracking      text check (char_length(tracking) <= 60),
  problem       text check (char_length(problem) <= 1000),
  demo          boolean not null default true,
  created_at    timestamptz not null default now(),
  shipped_at    timestamptz,
  received_at   timestamptz,
  updated_at    timestamptz not null default now(),
  check (buyer_id <> seller_id)
);
create index if not exists orders_buyer_idx  on public.orders (buyer_id, created_at desc);
create index if not exists orders_seller_idx on public.orders (seller_id, created_at desc);
alter table public.orders enable row level security;

-- Visibles uniquement par l'acheteur, le vendeur et la modération.
-- Aucune écriture directe : tout passe par les fonctions ci-dessous (règles contrôlées).
drop policy if exists "voir mes commandes" on public.orders;
create policy "voir mes commandes" on public.orders
  for select to authenticated using (auth.uid() in (buyer_id, seller_id) or public.is_admin());

-- ---------- 2. PASSER COMMANDE ----------
create or replace function public.create_order(
  p_listing uuid, p_delivery text,
  p_name text default null, p_address text default null, p_zip text default null, p_city text default null)
returns uuid language plpgsql security definer set search_path = public as $$
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
  values (l.id, auth.uid(), l.seller_id, l.title, l.photos[1], l.price, 1.00, p_delivery,
          nullif(trim(p_name),''), nullif(trim(p_address),''), nullif(trim(p_zip),''), nullif(trim(p_city),''), true)
  returning id into new_id;

  -- L'article est réservé : il disparaît du catalogue
  update public.listings set status = 'sold' where id = l.id;

  -- Ouvre (ou retrouve) la conversation acheteur / vendeur
  insert into public.conversations (listing_id, buyer_id, seller_id)
  values (l.id, auth.uid(), l.seller_id)
  on conflict (listing_id, buyer_id) do nothing;

  return new_id;
end $$;

-- ---------- 3. SUIVI DE LA COMMANDE ----------
-- Le vendeur indique l'envoi (numéro de suivi facultatif pour la main propre)
create or replace function public.mark_shipped(p_order uuid, p_tracking text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders set status = 'shipped', tracking = nullif(trim(p_tracking),''), shipped_at = now(), updated_at = now()
  where id = p_order and seller_id = auth.uid() and status = 'paid';
  if not found then raise exception 'Action impossible sur cette commande'; end if;
end $$;

-- L'acheteur confirme la bonne réception
create or replace function public.confirm_received(p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders set status = 'received', received_at = now(), updated_at = now()
  where id = p_order and buyer_id = auth.uid() and status in ('paid','shipped');
  if not found then raise exception 'Action impossible sur cette commande'; end if;
end $$;

-- L'acheteur signale un problème (l'argent restera bloqué jusqu'à la résolution)
create or replace function public.report_order_problem(p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Décris le problème'; end if;
  update public.orders set status = 'problem', problem = left(trim(p_reason), 1000), updated_at = now()
  where id = p_order and buyer_id = auth.uid() and status in ('paid','shipped');
  if not found then raise exception 'Action impossible sur cette commande'; end if;
end $$;

-- Annulation : par le vendeur avant l'envoi, ou par la modération (litige). L'article est remis en vente.
create or replace function public.cancel_order(p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from public.orders where id = p_order for update;
  if o is null then raise exception 'Commande introuvable'; end if;
  if not ((o.seller_id = auth.uid() and o.status = 'paid') or (public.is_admin() and o.status in ('paid','shipped','problem'))) then
    raise exception 'Action impossible sur cette commande';
  end if;
  update public.orders set status = 'cancelled', updated_at = now() where id = p_order;
  update public.listings set status = 'active' where id = o.listing_id and status = 'sold';
end $$;

-- Modération : clore un litige en faveur du vendeur (commande considérée comme reçue)
create or replace function public.admin_close_problem(p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à la modération'; end if;
  update public.orders set status = 'received', received_at = now(), updated_at = now()
  where id = p_order and status = 'problem';
  if not found then raise exception 'Action impossible sur cette commande'; end if;
end $$;

revoke all on function public.create_order(uuid,text,text,text,text,text) from public, anon;
revoke all on function public.mark_shipped(uuid,text) from public, anon;
revoke all on function public.confirm_received(uuid) from public, anon;
revoke all on function public.report_order_problem(uuid,text) from public, anon;
revoke all on function public.cancel_order(uuid) from public, anon;
revoke all on function public.admin_close_problem(uuid) from public, anon;
grant execute on function public.create_order(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.mark_shipped(uuid,text) to authenticated;
grant execute on function public.confirm_received(uuid) to authenticated;
grant execute on function public.report_order_problem(uuid,text) to authenticated;
grant execute on function public.cancel_order(uuid) to authenticated;
grant execute on function public.admin_close_problem(uuid) to authenticated;

-- =====================================================================
-- PANIER : plusieurs articles payés en une seule fois
-- =====================================================================
alter table public.orders add column if not exists payment_id uuid;
create index if not exists orders_payment_idx on public.orders (payment_id);

-- p_items : [{"listing":"<id>","delivery":"main_propre"|"colis"}, …]
-- Tout ou rien : si un article n'est plus disponible, aucune commande n'est créée.
create or replace function public.create_cart_orders(
  p_items jsonb, p_name text default null, p_address text default null, p_zip text default null, p_city text default null)
returns uuid language plpgsql security definer set search_path = public as $$
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
    values (l.id, auth.uid(), l.seller_id, l.title, l.photos[1], l.price, 1.00, dlv,
            case when dlv='colis' then nullif(trim(p_name),'') end, case when dlv='colis' then nullif(trim(p_address),'') end,
            case when dlv='colis' then nullif(trim(p_zip),'') end, case when dlv='colis' then nullif(trim(p_city),'') end,
            true, pay);
    update public.listings set status = 'sold' where id = l.id;
    insert into public.conversations (listing_id, buyer_id, seller_id)
    values (l.id, auth.uid(), l.seller_id) on conflict (listing_id, buyer_id) do nothing;
    n := n + 1;
  end loop;
  return pay;
end $$;
revoke all on function public.create_cart_orders(jsonb,text,text,text,text) from public, anon;
grant execute on function public.create_cart_orders(jsonb,text,text,text,text) to authenticated;

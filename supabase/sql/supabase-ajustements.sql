-- =====================================================================
-- ORLEOO — ajustements demandés par le fondateur (27/11/2026)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-durcissement.sql. Peut être relancé sans risque.
-- =====================================================================

-- ---------- 1. Offres : négociation libre des deux côtés, pas de délai pour répondre ----------
create or replace function public.expire_offers()
returns void language sql security definer set search_path = public as $$
  -- seules les offres acceptées expirent (48 h pour payer) ; on répond quand on veut
  update public.offers set status = 'expiree', updated_at = now()
   where status = 'acceptee' and valid_until is not null and valid_until < now();
$$;

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
  if (select count(*) from public.offers where buyer_id = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Tu as déjà fait 10 offres aujourd’hui : réessaie demain';
  end if;
  insert into public.offers (listing_id, buyer_id, seller_id, list_price, amount)
  values (l.id, me, l.seller_id, l.price, amt) returning * into o;
  perform public.offer_message(o, 'Offre : ' || public.eur_txt(amt) || ' au lieu de ' || public.eur_txt(l.price)
    || ' pour « ' || left(l.title, 80) || ' ». Réponds depuis Mon compte › Offres.');
  return o.id;
end $$;

-- 'accepter', 'refuser', 'contre' (vendeur OU acheteur, avec p_amount) ou 'annuler' (acheteur)
create or replace function public.respond_offer(p_offer uuid, p_action text, p_amount numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o public.offers; l record; amt numeric := round(coalesce(p_amount, 0), 2); mn numeric;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  perform public.expire_offers();
  select * into o from public.offers where id = p_offer for update;
  if o is null or me not in (o.buyer_id, o.seller_id) then raise exception 'Offre introuvable'; end if;
  if o.status not in ('en_attente','contre') then raise exception 'Cette offre n’attend plus de réponse'; end if;
  select * into l from public.listings where id = o.listing_id;

  if p_action = 'annuler' then
    if me <> o.buyer_id then raise exception 'Action impossible'; end if;
    update public.offers set status = 'annulee', updated_at = now() where id = o.id;
    perform public.offer_message(o, 'J’ai retiré mon offre.');
    return;
  end if;

  -- en_attente : au vendeur de répondre ; contre : à l'acheteur
  if (o.status = 'en_attente' and me <> o.seller_id) or (o.status = 'contre' and me <> o.buyer_id) then
    raise exception 'Attends la réponse de l’autre personne';
  end if;

  if p_action = 'refuser' then
    update public.offers set status = 'refusee', updated_at = now() where id = o.id;
    perform public.offer_message(o, 'Proposition de ' || public.eur_txt(o.amount) || ' refusée.');
    return;
  end if;

  if l is null or l.status <> 'active' then raise exception 'Cet article n’est plus disponible'; end if;

  if p_action = 'accepter' then
    if o.amount >= l.price then raise exception 'Le prix de l’article a baissé : il est déjà plus bas que cette offre'; end if;
    update public.offers set status = 'acceptee',
      valid_until = case when public.achats_ouverts() then now() + interval '48 hours' end,
      updated_at = now() where id = o.id;
    perform public.offer_message(o, 'Offre acceptée : « ' || left(l.title, 80) || ' » est à ' || public.eur_txt(o.amount) || ' pour '
      || case when me = o.seller_id then 'toi' else 'moi' end || ' '
      || case when public.achats_ouverts() then 'pendant 48 h.' else 'pendant 48 h dès l’ouverture des achats.' end);
    return;
  end if;

  if p_action = 'contre' then
    mn := greatest(1, ceil(l.price * 50) / 100);
    if me = o.seller_id then
      -- le vendeur propose plus que l'acheteur, mais moins que le prix affiché
      if amt <= o.amount or amt >= l.price then
        raise exception 'Ta contre-offre doit être entre % et %', public.eur_txt(o.amount + 0.01), public.eur_txt(l.price - 0.01);
      end if;
    else
      -- l'acheteur propose moins que le vendeur, et au moins la moitié du prix
      if amt >= o.amount or amt < mn then
        raise exception 'Ta proposition doit être entre % et %', public.eur_txt(mn), public.eur_txt(o.amount - 0.01);
      end if;
    end if;
    update public.offers set status = case when me = o.seller_id then 'contre' else 'en_attente' end,
      amount = amt, countered = true, updated_at = now() where id = o.id;
    o.amount := amt;
    perform public.offer_message(o, (case when me = o.seller_id then 'Contre-offre : ' else 'Nouvelle proposition : ' end)
      || public.eur_txt(amt) || '. Réponds depuis Mon compte › Offres.');
    return;
  end if;

  raise exception 'Action inconnue';
end $$;
revoke all on function public.respond_offer(uuid, text, numeric) from public, anon;
grant execute on function public.respond_offer(uuid, text, numeric) to authenticated;

-- ---------- 2. Lots : le vendeur choisit aussi le nombre d'articles de chaque palier ----------
alter table public.profiles add column if not exists lot_n1 smallint not null default 2;
alter table public.profiles add column if not exists lot_n2 smallint not null default 3;
alter table public.profiles add column if not exists lot_n3 smallint not null default 5;
do $$ begin
  alter table public.profiles add constraint profiles_lot_n_check check (lot_n1 between 2 and 20 and lot_n2 between 2 and 20 and lot_n3 between 2 and 20);
exception when duplicate_object then null; end $$;
-- lot2 / lot3 / lot5 = pourcentage des paliers 1 / 2 / 3 (noms historiques)
create or replace function public.lot_percent(p_seller uuid, p_n int)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select greatest(
           case when p_n >= lot_n1 then lot2 else 0 end,
           case when p_n >= lot_n2 then lot3 else 0 end,
           case when p_n >= lot_n3 then lot5 else 0 end)
         from public.profiles where id = p_seller), 0);
$$;

-- ---------- 3. Badge « Vendeur fondateur » retiré ----------
drop trigger if exists listings_award_founding on public.listings;

-- ---------- 4. Baisse de prix : au moins 1 € ----------
create or replace function public.min_price_drop()
returns trigger language plpgsql as $$
begin
  if new.price < old.price and old.price - new.price < 1 then
    raise exception 'Une baisse de prix doit être d’au moins 1 € (prix actuel : %)', public.eur_txt(old.price);
  end if;
  return new;
end $$;
revoke all on function public.min_price_drop() from public, anon, authenticated;
drop trigger if exists listings_min_price_drop on public.listings;
create trigger listings_min_price_drop before update of price on public.listings
  for each row execute function public.min_price_drop();

-- ---------- 5. Coup de pouce : rappeler la mise en avant ----------
create or replace function public.nudge_stale_listings()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select l.seller_id, count(*) nb, min(l.title) titre
    from public.listings l
    where l.status = 'active' and l.nudged_at is null and l.created_at < now() - interval '14 days'
      and not exists (select 1 from public.favorites f where f.listing_id = l.id)
    group by l.seller_id
  loop
    update public.listings set nudged_at = now()
     where seller_id = r.seller_id and status = 'active' and nudged_at is null and created_at < now() - interval '14 days'
       and not exists (select 1 from public.favorites f where f.listing_id = listings.id);
    begin
      perform public.send_revoo_email(r.seller_id,
        case when r.nb > 1 then r.nb || ' annonces attendent un coup de pouce' else 'Un coup de pouce pour « ' || left(r.titre, 60) || ' » ?' end,
        'Après 14 jours, ' || case when r.nb > 1 then 'certaines de tes annonces n’ont' else 'ton annonce n’a' end
          || ' pas encore de favori. Une petite baisse de prix (les personnes intéressées sont prévenues) ou une photo portée suffit souvent.'
          || chr(10) || chr(10)
          || 'Pense aussi à la mise en avant : avec un abonnement Orleoo, ton annonce repasse en tête du catalogue à chaque mise en avant. '
          || 'Orleoo n’oublie pas tes annonces : tout se fait en un clic depuis Mon compte › Mes annonces.',
        'https://revoocontact-blip.github.io/revoo/#/compte/annonces');
    exception when others then null;
    end;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.nudge_stale_listings() from public, anon, authenticated;

-- ---------- 6. Notifications sur téléphone : en pause (on choisira plus tard quoi envoyer) ----------
drop trigger if exists messages_push on public.messages;
drop trigger if exists price_drops_push on public.price_drops;
drop trigger if exists alert_hits_push on public.alert_hits;
drop trigger if exists orders_push on public.orders;

-- ---------- 7. Ouverture : rappel la veille ----------
alter table public.launch_emails add column if not exists reminded_at timestamptz;
create or replace function public.send_launch_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare at timestamptz; r record; n int := 0; site text := 'https://revoocontact-blip.github.io/revoo/';
begin
  select launch_at into at from public.site_settings where id = 1;
  if at is null or public.achats_ouverts() or at < now() or at > now() + interval '24 hours' then return 0; end if;
  for r in select * from public.launch_emails where reminded_at is null and notified_at is null and unsubscribed_at is null loop
    perform public.send_raw_email(r.email, 'Demain, Orleoo ouvre ses achats',
      'C’est pour demain : les achats ouvrent sur Orleoo le ' || to_char(at at time zone 'Europe/Paris', 'DD/MM à HH24"h"MI')
        || '. Vêtements et livres de seconde main, avec un paiement protégé jusqu’à la réception.',
      site || coalesce('?src=' || r.source, ''), site || '#/desinscription/' || r.token);
    update public.launch_emails set reminded_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.send_launch_reminders() from public, anon, authenticated;
do $$ begin
  perform cron.schedule('orleoo-rappel-ouverture', '7 * * * *', 'select public.send_launch_reminders()');
exception when others then raise notice 'pg_cron indisponible'; end $$;

-- ---------- 8. Blocage : message neutre « membre indisponible » ----------
create or replace function public.enforce_blocks()
returns trigger language plpgsql security definer set search_path = public as $$
declare a uuid; b uuid;
begin
  if tg_table_name = 'messages' then
    select buyer_id, seller_id into a, b from public.conversations where id = new.conversation_id;
  elsif tg_table_name = 'conversations' then a := new.buyer_id; b := new.seller_id;
  elsif tg_table_name = 'offers' then a := new.buyer_id; b := new.seller_id;
  elsif tg_table_name = 'trades' then a := new.proposer_id; b := new.receiver_id;
  end if;
  if a is not null and b is not null and public.is_blocked(a, b) then
    raise exception 'Membre indisponible.';
  end if;
  return new;
end $$;
revoke all on function public.enforce_blocks() from public, anon, authenticated;

-- ---------- 9. Tailles : jusqu'à 20 caractères (« Pointure 38 », « Taille unique ») ----------
alter table public.listings drop constraint if exists listings_size_check;
alter table public.listings add constraint listings_size_check check (char_length(size) between 1 and 20);

select 'Ajustements appliqués' as info;

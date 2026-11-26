-- =====================================================================
-- ORLEOO — baisses de prix, « Mes tailles », blocage de membres,
-- coup de pouce aux annonces qui ne bougent pas, tableau de bord du lancement
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-offres-lots.sql. Peut être relancé sans risque.
-- =====================================================================

-- ---------- 1. ALERTE BAISSE DE PRIX (pour les personnes qui ont l'article en favori) ----------
create table if not exists public.price_drops (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  listing_id  uuid not null references public.listings(id) on delete cascade,
  old_price   numeric(10,2) not null,
  new_price   numeric(10,2) not null,
  created_at  timestamptz not null default now(),
  mailed      boolean not null default false,
  seen_at     timestamptz
);
create index if not exists price_drops_user_idx on public.price_drops (user_id, created_at desc);
alter table public.price_drops enable row level security;
drop policy if exists "mes baisses de prix" on public.price_drops;
create policy "mes baisses de prix" on public.price_drops for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.price_drops from anon, authenticated;

create or replace function public.mark_price_drops_seen()
returns void language sql security definer set search_path = public as $$
  update public.price_drops set seen_at = now() where user_id = auth.uid() and seen_at is null;
$$;
grant execute on function public.mark_price_drops_seen() to authenticated;

create or replace function public.notify_price_drop()
returns trigger language plpgsql security definer set search_path = public as $$
declare f record; mail boolean;
begin
  if new.status <> 'active' or new.price >= old.price then return new; end if;
  for f in select user_id from public.favorites where listing_id = new.id and user_id <> new.seller_id loop
    -- au plus un e-mail par article et par personne toutes les 24 h
    mail := not exists (select 1 from public.price_drops where user_id = f.user_id and listing_id = new.id
                         and mailed and created_at > now() - interval '24 hours');
    insert into public.price_drops (user_id, listing_id, old_price, new_price, mailed) values (f.user_id, new.id, old.price, new.price, mail);
    if mail then
      begin
        perform public.send_revoo_email(f.user_id,
          'Baisse de prix : « ' || left(new.title, 60) || ' »',
          'Bonne nouvelle : « ' || new.title || ' », que tu as mis en favori, passe de ' || public.eur_txt(old.price)
            || ' à ' || public.eur_txt(new.price) || '.',
          'https://revoocontact-blip.github.io/revoo/#/article/' || new.id);
      exception when others then null;
      end;
    end if;
  end loop;
  return new;
exception when others then
  raise warning 'baisse de prix non notifiée : %', sqlerrm;
  return new;
end $$;
revoke all on function public.notify_price_drop() from public, anon, authenticated;
drop trigger if exists listings_price_drop on public.listings;
create trigger listings_price_drop after update of price on public.listings
  for each row execute function public.notify_price_drop();

-- ---------- 2. « MES TAILLES » (données privées du membre) ----------
alter table public.profiles_private add column if not exists my_sizes text[] not null default '{}';
do $$ begin
  alter table public.profiles_private add constraint profiles_private_sizes_check check (cardinality(my_sizes) <= 20);
exception when duplicate_object then null; end $$;

-- ---------- 3. BLOQUER UN MEMBRE ----------
create table if not exists public.blocks (
  blocker_id  uuid not null references public.profiles(id) on delete cascade,
  blocked_id  uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
alter table public.blocks enable row level security;
drop policy if exists "mes blocages : voir" on public.blocks;
create policy "mes blocages : voir" on public.blocks for select to authenticated using (blocker_id = auth.uid());
drop policy if exists "mes blocages : bloquer" on public.blocks;
create policy "mes blocages : bloquer" on public.blocks for insert to authenticated with check (blocker_id = auth.uid());
drop policy if exists "mes blocages : débloquer" on public.blocks;
create policy "mes blocages : débloquer" on public.blocks for delete to authenticated using (blocker_id = auth.uid());

-- L'un des deux a-t-il bloqué l'autre ?
create or replace function public.is_blocked(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a));
$$;
revoke all on function public.is_blocked(uuid, uuid) from public, anon, authenticated;   -- usage interne seulement

-- Membres qui m'ont bloqué (sans dire qui) : pour griser le champ de message
create or replace function public.blocked_me(p_other uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks where blocker_id = p_other and blocked_id = auth.uid());
$$;
grant execute on function public.blocked_me(uuid) to authenticated;

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
    raise exception 'Impossible : un de vous deux a bloqué l’autre.';
  end if;
  return new;
end $$;
revoke all on function public.enforce_blocks() from public, anon, authenticated;
drop trigger if exists messages_blocks on public.messages;
create trigger messages_blocks before insert on public.messages for each row execute function public.enforce_blocks();
drop trigger if exists conversations_blocks on public.conversations;
create trigger conversations_blocks before insert on public.conversations for each row execute function public.enforce_blocks();
drop trigger if exists offers_blocks on public.offers;
create trigger offers_blocks before insert on public.offers for each row execute function public.enforce_blocks();
drop trigger if exists trades_blocks on public.trades;
create trigger trades_blocks before insert on public.trades for each row execute function public.enforce_blocks();

-- Bloquer : les offres en cours entre les deux tombent
create or replace function public.blocks_close_offers()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.offers set status = 'annulee', updated_at = now()
   where status in ('en_attente','contre','acceptee')
     and ((buyer_id = new.blocker_id and seller_id = new.blocked_id) or (buyer_id = new.blocked_id and seller_id = new.blocker_id));
  return new;
end $$;
revoke all on function public.blocks_close_offers() from public, anon, authenticated;
drop trigger if exists blocks_close_offers on public.blocks;
create trigger blocks_close_offers after insert on public.blocks for each row execute function public.blocks_close_offers();

-- ---------- 4. COUP DE POUCE AUX ANNONCES QUI NE BOUGENT PAS ----------
alter table public.listings add column if not exists nudged_at timestamptz;

-- Chaque jour : annonces en ligne depuis 14 jours, sans aucun favori, jamais relancées → un e-mail au vendeur
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
          || ' pas encore de favori. Une baisse de 10 % (les personnes intéressées sont prévenues) ou une photo portée suffit souvent : '
          || 'tout se fait en un clic depuis Mon compte › Mes annonces.',
        'https://revoocontact-blip.github.io/revoo/#/compte/annonces');
    exception when others then null;
    end;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.nudge_stale_listings() from public, anon, authenticated;
do $$ begin
  perform cron.schedule('orleoo-coup-de-pouce', '23 9 * * *', 'select public.nudge_stale_listings()');
exception when others then raise notice 'pg_cron indisponible : relances non planifiées'; end $$;

-- ---------- 5. TABLEAU DE BORD DU LANCEMENT (équipe seulement) ----------
create or replace function public.launch_stats(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d int := greatest(7, least(coalesce(p_days, 30), 180)); res jsonb;
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Orleoo'; end if;
  with jours as (select generate_series((current_date - (d - 1))::date, current_date, interval '1 day')::date as jour)
  select jsonb_build_object(
    'totaux', jsonb_build_object(
      'membres',    (select count(*) from public.profiles),
      'annonces',   (select count(*) from public.listings where status in ('active','sold')),
      'vendeurs',   (select count(distinct seller_id) from public.listings where status in ('active','sold')),
      'fondateurs', (select count(*) from public.founding_sellers),
      'attentes',   (select count(distinct user_id) from public.launch_waitlist),
      'filleuls',   (select count(*) from public.referrals)),
    'jours', (select jsonb_agg(jsonb_build_object(
      'jour', j.jour,
      'membres',    (select count(*) from public.profiles p where p.created_at::date = j.jour),
      'annonces',   (select count(*) from public.listings l where l.created_at::date = j.jour),
      'fondateurs', (select count(*) from public.founding_sellers f where f.awarded_at::date = j.jour),
      'attentes',   (select count(*) from public.launch_waitlist w where w.created_at::date = j.jour),
      'filleuls',   (select count(*) from public.referrals r where r.created_at::date = j.jour)) order by j.jour)
      from jours j)) into res;
  return res;
end $$;
revoke all on function public.launch_stats(int) from public, anon;
grant execute on function public.launch_stats(int) to authenticated;

select 'Fidélité prête : baisses de prix, tailles, blocages, coups de pouce, lancement' as info;

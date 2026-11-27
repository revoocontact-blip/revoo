-- =====================================================================
-- ORLEOO — suivre un vendeur + tableau de bord « Santé du site » (équipe)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-pret.sql. Peut être relancé sans risque.
-- =====================================================================

-- ---------- 1. SUIVRE UN VENDEUR ----------
create table if not exists public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  seller_id   uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, seller_id),
  check (follower_id <> seller_id)
);
create index if not exists follows_seller_idx on public.follows (seller_id);
alter table public.follows enable row level security;
drop policy if exists "suivis : voir les miens" on public.follows;
create policy "suivis : voir les miens" on public.follows for select to authenticated using (follower_id = auth.uid());
drop policy if exists "suivis : suivre" on public.follows;
create policy "suivis : suivre" on public.follows for insert to authenticated with check (follower_id = auth.uid());
drop policy if exists "suivis : ne plus suivre" on public.follows;
create policy "suivis : ne plus suivre" on public.follows for delete to authenticated using (follower_id = auth.uid());
revoke update on public.follows from anon, authenticated;

create or replace function public.follows_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_blocked(new.follower_id, new.seller_id) then raise exception 'Membre indisponible.'; end if;
  if (select count(*) from public.follows where follower_id = new.follower_id) >= 500 then
    raise exception 'Tu suis déjà 500 vendeurs : arrête d’en suivre quelques-uns pour en ajouter';
  end if;
  return new;
end $$;
revoke all on function public.follows_guard() from public, anon, authenticated;
drop trigger if exists follows_guard on public.follows;
create trigger follows_guard before insert on public.follows for each row execute function public.follows_guard();

-- Nombre d'abonnés d'un vendeur (public)
create or replace function public.follower_count(p_seller uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.follows where seller_id = p_seller;
$$;
grant execute on function public.follower_count(uuid) to anon, authenticated;

-- Bloquer : on ne se suit plus, dans les deux sens
create or replace function public.blocks_drop_follows()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.follows where (follower_id = new.blocker_id and seller_id = new.blocked_id) or (follower_id = new.blocked_id and seller_id = new.blocker_id);
  return new;
end $$;
revoke all on function public.blocks_drop_follows() from public, anon, authenticated;
drop trigger if exists blocks_drop_follows on public.blocks;
create trigger blocks_drop_follows after insert on public.blocks for each row execute function public.blocks_drop_follows();

-- Nouveautés des vendeurs suivis
create table if not exists public.follow_hits (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  seller_id  uuid not null references public.profiles(id) on delete cascade,
  listing_id uuid not null references public.listings(id) on delete cascade,
  created_at timestamptz not null default now(),
  mailed     boolean not null default false,
  seen_at    timestamptz,
  unique (user_id, listing_id)
);
create index if not exists follow_hits_user_idx on public.follow_hits (user_id, created_at desc);
alter table public.follow_hits enable row level security;
drop policy if exists "nouveautés suivies : les miennes" on public.follow_hits;
create policy "nouveautés suivies : les miennes" on public.follow_hits for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.follow_hits from anon, authenticated;

create or replace function public.mark_follow_hits_seen()
returns void language sql security definer set search_path = public as $$
  update public.follow_hits set seen_at = now() where user_id = auth.uid() and seen_at is null;
$$;
grant execute on function public.mark_follow_hits_seen() to authenticated;

-- Nouvelle annonce en ligne : chaque abonné la voit ; un e-mail au plus par vendeur et par 24 h,
-- seulement aux membres qui ont accepté les e-mails « nouveautés »
create or replace function public.notify_followers()
returns trigger language plpgsql security definer set search_path = public as $$
declare f record; who text; mail boolean;
begin
  if new.status <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'active' then return new; end if;
  select name into who from public.profiles where id = new.seller_id;
  for f in select fo.follower_id, coalesce(p.notify_digest, false) ok
           from public.follows fo join public.profiles p on p.id = fo.follower_id
           where fo.seller_id = new.seller_id loop
    mail := f.ok and not exists (select 1 from public.follow_hits h where h.user_id = f.follower_id and h.seller_id = new.seller_id
                                 and h.mailed and h.created_at > now() - interval '24 hours');
    insert into public.follow_hits (user_id, seller_id, listing_id, mailed) values (f.follower_id, new.seller_id, new.id, mail)
    on conflict (user_id, listing_id) do nothing;
    if mail then
      begin
        perform public.send_revoo_email(f.follower_id, '@' || coalesce(who, 'un vendeur') || ' a mis un nouvel article en ligne',
          'Un vendeur que tu suis vient de publier « ' || left(new.title, 80) || ' » à ' || public.eur_txt(new.price) || '.'
            || chr(10) || 'Tu reçois cet e-mail car tu suis @' || coalesce(who, 'ce vendeur') || ' et tu as accepté les e-mails « nouveautés » (désactivable dans Mon compte).',
          'https://revoocontact-blip.github.io/revoo/#/article/' || new.id);
      exception when others then null;
      end;
    end if;
  end loop;
  return new;
exception when others then
  raise warning 'abonnés non prévenus : %', sqlerrm;
  return new;
end $$;
revoke all on function public.notify_followers() from public, anon, authenticated;
drop trigger if exists listings_notify_followers on public.listings;
create trigger listings_notify_followers after insert or update of status on public.listings
  for each row execute function public.notify_followers();

-- ---------- 2. SANTÉ DU SITE (équipe seulement) ----------
create or replace function public.site_health(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d int := greatest(7, least(coalesce(p_days, 30), 180)); since timestamptz := now() - make_interval(days => d); res jsonb;
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Orleoo'; end if;
  with act as (
    select seller_id u, created_at t from public.listings
    union all select sender_id, created_at from public.messages
    union all select buyer_id, created_at from public.offers
    union all select user_id, created_at from public.favorites
    union all select proposer_id, created_at from public.trades
    union all select borrower_id, created_at from public.loans
  ),
  conv as (
    select c.id, c.created_at,
      (select min(m.created_at) from public.messages m where m.conversation_id = c.id and m.sender_id = c.seller_id) first_reply
    from public.conversations c where c.created_at > since
  ),
  cats as (
    select k.cat,
      (select count(*) from public.listings l where l.category = k.cat and l.status = 'active') offre,
      (select count(*) from public.favorites f join public.listings l on l.id = f.listing_id where l.category = k.cat and f.created_at > since) favoris,
      (select count(*) from public.saved_searches s where s.category = k.cat) alertes
    from unnest(array['Femme','Homme','Enfant','Unisexe','Livres']) k(cat)
  )
  select jsonb_build_object(
    'jours', d,
    'actifs_7j',  (select count(distinct u) from act where t > now() - interval '7 days'),
    'actifs_30j', (select count(distinct u) from act where t > now() - interval '30 days'),
    'membres',    (select count(*) from public.profiles),
    'conversations', (select count(*) from conv),
    'repondues',     (select count(*) from conv where first_reply is not null),
    'repondues_24h', (select count(*) from conv where first_reply is not null and first_reply - created_at <= interval '24 hours'),
    'delai_median_h', (select round(extract(epoch from percentile_cont(0.5) within group (order by first_reply - created_at)) / 3600, 1) from conv where first_reply is not null),
    'messages',   (select count(*) from public.messages where created_at > since),
    'offres',     (select count(*) from public.offers where created_at > since),
    'offres_ok',  (select count(*) from public.offers where created_at > since and status in ('acceptee','utilisee')),
    'echanges',   (select count(*) from public.trades where created_at > since),
    'echanges_ok',(select count(*) from public.trades where created_at > since and status in ('accepted','completed')),
    'prets',      (select count(*) from public.loans where created_at > since),
    'prets_ok',   (select count(*) from public.loans where created_at > since and status in ('acceptee','en_cours','rendu','terminee')),
    'suivis',     (select count(*) from public.follows),
    'suivis_new', (select count(*) from public.follows where created_at > since),
    'categories', (select jsonb_agg(jsonb_build_object('cat', cat, 'offre', offre, 'favoris', favoris, 'alertes', alertes) order by cat) from cats),
    'recherches', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select lower(trim(q)) q, count(*) n from public.saved_searches
                    where coalesce(trim(q), '') <> '' group by 1 order by 2 desc, 1 limit 8) x)
  ) into res;
  return res;
end $$;
revoke all on function public.site_health(int) from public, anon;
grant execute on function public.site_health(int) to authenticated;

select 'Suivis de vendeurs et tableau « Santé du site » prêts' as info;

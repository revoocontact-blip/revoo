-- =====================================================================
-- ORLEOO — croissance : alertes de recherche, parrainage,
-- statistiques des annonces, badges de confiance
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- Peut être relancé sans risque.
-- =====================================================================

-- Texte en minuscules sans accents (pour comparer les recherches)
create or replace function public.norm_txt(p text)
returns text language sql immutable as $$
  select regexp_replace(lower(translate(coalesce(p, ''), 'ÀÂÄÁÃÇÉÈÊËÎÏÍÔÖÓÙÛÜÚàâäáãçéèêëîïíôöóùûüú', 'AAAAACEEEEIIIOOOUUUUaaaaaceeeeiiiooouuuu')), '[^a-z0-9 ]', '', 'g');
$$;

-- ---------- 1. ALERTES DE RECHERCHE ----------
create table if not exists public.saved_searches (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  label       text not null check (char_length(label) between 1 and 120),
  q           text check (char_length(q) <= 60),
  category    text,
  sizes       text[] not null default '{}',
  conditions  text[] not null default '{}',
  brand       text check (char_length(brand) <= 40),
  min_price   numeric(10,2),
  max_price   numeric(10,2),
  created_at  timestamptz not null default now(),
  last_mail_at timestamptz
);
create index if not exists saved_searches_user_idx on public.saved_searches (user_id);
alter table public.saved_searches enable row level security;
drop policy if exists "mes alertes" on public.saved_searches;
create policy "mes alertes" on public.saved_searches for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.limit_saved_searches()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.saved_searches where user_id = new.user_id) >= 10 then
    raise exception 'Tu as déjà 10 alertes : supprime-en une pour en créer une nouvelle.';
  end if;
  return new;
end $$;
drop trigger if exists saved_searches_limit on public.saved_searches;
create trigger saved_searches_limit before insert on public.saved_searches
  for each row execute function public.limit_saved_searches();

create table if not exists public.alert_hits (
  id          uuid primary key default gen_random_uuid(),
  search_id   uuid not null references public.saved_searches(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  listing_id  uuid not null references public.listings(id) on delete cascade,
  created_at  timestamptz not null default now(),
  seen_at     timestamptz,
  unique (search_id, listing_id)
);
create index if not exists alert_hits_user_idx on public.alert_hits (user_id, created_at desc);
alter table public.alert_hits enable row level security;
drop policy if exists "mes résultats d'alerte" on public.alert_hits;
create policy "mes résultats d'alerte" on public.alert_hits for select to authenticated using (user_id = auth.uid());
drop policy if exists "je supprime mes résultats" on public.alert_hits;
create policy "je supprime mes résultats" on public.alert_hits for delete to authenticated using (user_id = auth.uid());

create or replace function public.mark_alerts_seen()
returns void language sql security definer set search_path = public as $$
  update public.alert_hits set seen_at = now() where user_id = auth.uid() and seen_at is null;
$$;
grant execute on function public.mark_alerts_seen() to authenticated;

-- À chaque nouvelle annonce en ligne : on cherche les alertes qui correspondent
create or replace function public.match_saved_searches()
returns trigger language plpgsql security definer set search_path = public as $$
declare s record; txt text; w text; ok boolean;
begin
  if new.status <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'active' then return new; end if;
  txt := public.norm_txt(new.title || ' ' || coalesce(new.brand, '') || ' ' || coalesce(new.description, ''));
  for s in select * from public.saved_searches where user_id <> new.seller_id loop
    ok := (s.category is null or s.category = new.category)
      and (cardinality(s.sizes) = 0 or new.size = any(s.sizes))
      and (cardinality(s.conditions) = 0 or new.condition = any(s.conditions))
      and (s.brand is null or public.norm_txt(s.brand) = public.norm_txt(new.brand))
      and (s.min_price is null or new.price >= s.min_price)
      and (s.max_price is null or new.price <= s.max_price);
    if ok and coalesce(trim(s.q), '') <> '' then
      foreach w in array regexp_split_to_array(public.norm_txt(trim(s.q)), '\s+') loop
        if char_length(w) >= 2 and position(w in txt) = 0 then ok := false; exit; end if;
      end loop;
    end if;
    if ok then
      insert into public.alert_hits (search_id, user_id, listing_id) values (s.id, s.user_id, new.id)
      on conflict do nothing;
      -- e-mail au plus une fois toutes les 6 h par alerte
      if s.last_mail_at is null or s.last_mail_at < now() - interval '6 hours' then
        update public.saved_searches set last_mail_at = now() where id = s.id;
        begin
          perform public.send_revoo_email(s.user_id,
            'Nouvelle annonce pour ton alerte « ' || left(s.label, 60) || ' »',
            'Bonne nouvelle : « ' || new.title || ' » vient d’être publiée à ' || new.price || ' € et correspond à ton alerte « ' || s.label || ' ».',
            'https://revoocontact-blip.github.io/revoo/#/article/' || new.id);
        exception when others then null;
        end;
      end if;
    end if;
  end loop;
  return new;
exception when others then
  raise warning 'alertes non traitées : %', sqlerrm;
  return new;
end $$;
revoke all on function public.match_saved_searches() from public, anon, authenticated;
drop trigger if exists listings_match_alerts on public.listings;
create trigger listings_match_alerts after insert or update of status on public.listings
  for each row execute function public.match_saved_searches();

-- ---------- 2. PARRAINAGE ----------
create table if not exists public.referrals (
  filleul_id  uuid primary key references public.profiles(id) on delete cascade,
  parrain_id  uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  check (filleul_id <> parrain_id)
);
create index if not exists referrals_parrain_idx on public.referrals (parrain_id);
alter table public.referrals enable row level security;
drop policy if exists "mes parrainages" on public.referrals;
create policy "mes parrainages" on public.referrals for select to authenticated
  using (parrain_id = auth.uid() or filleul_id = auth.uid() or public.is_admin());

-- Appelée juste après l'inscription, avec l'identifiant du parrain (lien ?parrain=...)
create or replace function public.set_referrer(p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); par uuid; born timestamptz;
begin
  if me is null or coalesce(trim(p_name), '') = '' then return false; end if;
  select created_at into born from public.profiles where id = me;
  if born is null or born < now() - interval '2 days' then return false; end if;  -- seulement les nouveaux comptes
  select id into par from public.profiles where lower(name) = lower(trim(p_name));
  if par is null or par = me then return false; end if;
  insert into public.referrals (filleul_id, parrain_id) values (me, par) on conflict do nothing;
  return true;
end $$;
revoke all on function public.set_referrer(text) from public, anon;
grant execute on function public.set_referrer(text) to authenticated;

create or replace function public.my_referrals()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.referrals where parrain_id = auth.uid();
$$;
grant execute on function public.my_referrals() to authenticated;

-- Pour l'équipe : les meilleurs parrains
create or replace function public.referral_top(p_limit int default 10)
returns table (user_id uuid, identifiant text, filleuls bigint, filleuls_actifs bigint)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, count(r.*),
         count(r.*) filter (where exists (select 1 from public.listings l where l.seller_id = r.filleul_id))
  from public.referrals r join public.profiles p on p.id = r.parrain_id
  where public.is_admin()
  group by p.id, p.name order by count(r.*) desc, p.name
  limit greatest(1, least(coalesce(p_limit, 10), 50));
$$;
grant execute on function public.referral_top(int) to authenticated;

-- ---------- 3. STATISTIQUES DES ANNONCES ----------
create table if not exists public.listing_views (
  listing_id uuid primary key references public.listings(id) on delete cascade,
  views      int not null default 0
);
alter table public.listing_views enable row level security;   -- lecture via my_listing_stats uniquement

create or replace function public.bump_view(p_listing uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.listings where id = p_listing and status = 'active'
             and seller_id is distinct from auth.uid()) then
    insert into public.listing_views (listing_id, views) values (p_listing, 1)
    on conflict (listing_id) do update set views = listing_views.views + 1;
  end if;
end $$;
grant execute on function public.bump_view(uuid) to anon, authenticated;

create or replace function public.my_listing_stats()
returns table (listing_id uuid, vues int, favoris bigint, attentes bigint)
language sql stable security definer set search_path = public as $$
  select l.id, coalesce(v.views, 0),
         (select count(*) from public.favorites f where f.listing_id = l.id),
         (select count(*) from public.launch_waitlist w where w.listing_id = l.id)
  from public.listings l left join public.listing_views v on v.listing_id = l.id
  where l.seller_id = auth.uid();
$$;
grant execute on function public.my_listing_stats() to authenticated;

-- ---------- 4. BADGES DE CONFIANCE (publics) ----------
create or replace function public.seller_badges(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with conv as (
    select c.id,
      (select min(m.created_at) from public.messages m where m.conversation_id = c.id and m.sender_id = c.buyer_id) as q_at,
      (select min(m.created_at) from public.messages m where m.conversation_id = c.id and m.sender_id = c.seller_id
         and m.created_at > (select min(m2.created_at) from public.messages m2 where m2.conversation_id = c.id and m2.sender_id = c.buyer_id)) as r_at
    from public.conversations c where c.seller_id = p_user
  )
  select jsonb_build_object(
    'depuis',  (select created_at from public.profiles where id = p_user),
    'ventes',  (select count(*) from public.orders where seller_id = p_user and status = 'received' and not demo),
    'avis',    (select count(*) from public.reviews where seller_id = p_user and not demo),
    'note',    (select round(avg(rating)::numeric, 1) from public.reviews where seller_id = p_user and not demo),
    'conversations', (select count(*) from conv where r_at is not null),
    'reponse_h', (select round((percentile_cont(0.5) within group (order by extract(epoch from (r_at - q_at)) / 3600))::numeric, 1) from conv where r_at is not null)
  );
$$;
grant execute on function public.seller_badges(uuid) to anon, authenticated;

select 'Croissance prête : alertes, parrainage, statistiques et badges' as info;
